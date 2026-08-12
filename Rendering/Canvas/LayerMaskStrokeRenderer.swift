import Foundation
import Metal
import simd

private struct LayerMaskStrokePointGPU {
    var position: SIMD2<Float>
    var radius: Float
    var opacity: Float
    var angleDegrees: Float
    var padding: Float = 0
}

private struct LayerMaskStrokeUniforms {
    var origin: SIMD2<UInt32>
    var extent: SIMD2<UInt32>
    var brushOpacity: Float
    var targetValue: Float
    var pointCount: UInt32
    var tipShape: UInt32
    var tipHardness: Float
    var tipSoftness: Float
    var tipRoundness: Float
    var padding: Float = 0
}

final class LayerMaskStrokeRenderer {
    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState
    private let fallbackTipTexture: MTLTexture
    private var cachedCustomTipData: Data?
    private var cachedCustomTipTexture: MTLTexture?

    init(device: MTLDevice) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct LayerMaskStrokePointGPU {
            float2 position;
            float radius;
            float opacity;
            float angleDegrees;
            float padding;
        };

        struct LayerMaskStrokeUniforms {
            uint2 origin;
            uint2 extent;
            float brushOpacity;
            float targetValue;
            uint pointCount;
            uint tipShape;
            float tipHardness;
            float tipSoftness;
            float tipRoundness;
            float padding;
        };

        float segmentDistance(float2 p, float2 a, float2 b, thread float &segmentT) {
            float2 ab = b - a;
            float denominator = max(dot(ab, ab), 0.000001);
            segmentT = clamp(dot(p - a, ab) / denominator, 0.0, 1.0);
            return length(p - (a + ab * segmentT));
        }

        float smoothHardnessAlpha(float distance, float hardness, float edgeWidth) {
            if (hardness >= 0.999) {
                return 1.0 - smoothstep(max(1.0 - edgeWidth, 0.0), 1.0 + edgeWidth, distance);
            }
            if (distance >= 1.0) {
                return 0.0;
            }
            if (distance <= hardness) {
                return 1.0;
            }
            float t = clamp((distance - hardness) / max(1.0 - hardness, 0.0001), 0.0, 1.0);
            return 1.0 - smoothstep(0.0, 1.0, t);
        }

        float tipAlpha(
            float2 localPoint,
            float radius,
            float angleDegrees,
            constant LayerMaskStrokeUniforms &uniforms,
            texture2d<float, access::sample> customTipMask
        ) {
            constexpr sampler tipSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            float radiansValue = angleDegrees * 0.017453292519943295;
            float cosine = cos(radiansValue);
            float sine = sin(radiansValue);
            float2 rotatedPoint = float2(
                (localPoint.x * cosine) + (localPoint.y * sine),
                (-localPoint.x * sine) + (localPoint.y * cosine)
            );
            float edgeWidth = min(0.5, 1.0 / max(radius, 1.0));

            if (uniforms.tipShape == 2) {
                float squareDistance = max(abs(rotatedPoint.x), abs(rotatedPoint.y));
                return 1.0 - smoothstep(max(1.0 - edgeWidth, 0.0), 1.0 + edgeWidth, squareDistance);
            }
            if (uniforms.tipShape == 1) {
                float roundDistance = length(localPoint);
                if (roundDistance >= 1.0) {
                    return 0.0;
                }
                float feather = clamp(1.0 - roundDistance, 0.0, 1.0);
                return feather * feather;
            }
            if (uniforms.tipShape == 3) {
                float roundness = clamp(uniforms.tipRoundness, 0.25, 1.0);
                float2 shapedPoint = float2(rotatedPoint.x / roundness, rotatedPoint.y);
                if (max(abs(shapedPoint.x), abs(shapedPoint.y)) >= 1.0) {
                    return 0.0;
                }
                float2 uv = float2(
                    clamp((shapedPoint.x + 1.0) * 0.5, 0.0, 1.0),
                    clamp((shapedPoint.y + 1.0) * 0.5, 0.0, 1.0)
                );
                float sampledAlpha = customTipMask.sample(tipSampler, uv).r;
                float exponent = mix(3.2, 0.75, clamp(uniforms.tipSoftness, 0.0, 1.0));
                return pow(clamp(sampledAlpha, 0.0, 1.0), exponent);
            }
            return smoothHardnessAlpha(length(localPoint), uniforms.tipHardness, edgeWidth);
        }

        kernel void layerMaskStrokeKernel(
            texture2d<float, access::read_write> mask [[texture(0)]],
            texture2d<float, access::sample> customTipMask [[texture(1)]],
            const device LayerMaskStrokePointGPU *points [[buffer(0)]],
            constant LayerMaskStrokeUniforms &uniforms [[buffer(1)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= uniforms.extent.x || gid.y >= uniforms.extent.y || uniforms.pointCount == 0) {
                return;
            }
            uint2 pixel = uniforms.origin + gid;
            if (pixel.x >= mask.get_width() || pixel.y >= mask.get_height()) {
                return;
            }

            float2 samplePosition = float2(pixel) + 0.5;
            float coverage = 0.0;
            if (uniforms.pointCount == 1) {
                float radius = max(points[0].radius, 0.5);
                coverage = tipAlpha(
                    (samplePosition - points[0].position) / radius,
                    radius,
                    points[0].angleDegrees,
                    uniforms,
                    customTipMask
                ) * points[0].opacity;
            } else {
                for (uint index = 1; index < uniforms.pointCount; ++index) {
                    float segmentT = 0.0;
                    segmentDistance(
                        samplePosition,
                        points[index - 1].position,
                        points[index].position,
                        segmentT
                    );
                    float2 center = mix(points[index - 1].position, points[index].position, segmentT);
                    float radius = max(mix(points[index - 1].radius, points[index].radius, segmentT), 0.5);
                    float opacity = mix(points[index - 1].opacity, points[index].opacity, segmentT);
                    float angleDegrees = mix(points[index - 1].angleDegrees, points[index].angleDegrees, segmentT);
                    float segmentCoverage = tipAlpha(
                        (samplePosition - center) / radius,
                        radius,
                        angleDegrees,
                        uniforms,
                        customTipMask
                    ) * opacity;
                    coverage = max(coverage, segmentCoverage);
                }
            }

            coverage = clamp(coverage * uniforms.brushOpacity, 0.0, 1.0);
            if (coverage <= 0.0001) {
                return;
            }
            float current = mask.read(pixel).r;
            float next = mix(current, uniforms.targetValue, coverage);
            mask.write(float4(next, 0.0, 0.0, 1.0), pixel);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "layerMaskStrokeKernel") else {
            throw CocoaError(.featureUnsupported)
        }
        self.device = device
        pipeline = try device.makeComputePipelineState(function: function)
        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = [.shaderRead]
        guard let fallbackTipTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            throw CocoaError(.featureUnsupported)
        }
        var opaque: UInt8 = 255
        fallbackTipTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &opaque,
            bytesPerRow: 1
        )
        self.fallbackTipTexture = fallbackTipTexture
    }

    @discardableResult
    func render(
        samples: [CanvasStrokeSample],
        brush: BrushSettings,
        targetValue: Float,
        into texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        waitUntilCompleted: Bool = false
    ) -> BrushPixelBounds? {
        guard !samples.isEmpty else { return nil }
        let points: [LayerMaskStrokePointGPU] = samples.enumerated().map { index, sample in
            let pressure = min(max(sample.pressure, 0), 1)
            let curvedSizePressure = BrushSettings.resolvedSizeCurvePressure(
                pressure: max(pressure, 0.01),
                pressureSensitivity: brush.pressureSensitivity,
                sizeLowerBound: brush.sizeLowerBound,
                state: brush.resolvedSizePressureCurveState
            )
            let primarySizeFactor = BrushSettings.resolvedPressureFactor(
                responseAmount: brush.pressureSizeAmount,
                curvedPressure: curvedSizePressure
            )
            let globalSizeFactor = brush.compoundBrush.enabled
                ? BrushSettings.resolvedPressureFactor(
                    responseAmount: brush.compoundBrush.globalPressureSizeAmount,
                    curvedPressure: curvedSizePressure
                )
                : 1
            let curvedOpacityPressure = BrushSettings.resolvedOpacityCurvePressure(
                pressure: max(pressure, 0.005),
                pressureSensitivity: brush.pressureSensitivity,
                state: brush.resolvedOpacityPressureCurveState
            )
            let opacityFactor = BrushSettings.resolvedPressureFactor(
                responseAmount: brush.pressureOpacityAmount,
                curvedPressure: curvedOpacityPressure
            )
            let directionDegrees: Float
            if brush.followsStrokeDirection, samples.count > 1 {
                let neighbor = index > 0 ? samples[index - 1] : sample
                let target = index > 0 ? sample : samples[1]
                let dx = target.location.x - neighbor.location.x
                let dy = target.location.y - neighbor.location.y
                directionDegrees = Float(atan2(dy, dx) * 180 / .pi)
            } else {
                directionDegrees = 0
            }
            return LayerMaskStrokePointGPU(
                position: SIMD2(Float(sample.location.x), Float(sample.location.y)),
                radius: max((brush.size * primarySizeFactor * globalSizeFactor) * 0.5, 0.5),
                opacity: opacityFactor,
                angleDegrees: directionDegrees + brush.stampRotationDegrees + brush.customTipAngleDegrees
            )
        }
        let maximumRadius = Double((points.map(\.radius).max() ?? 0.5) + 3)
        let minX = max(Int(floor(samples.map(\.location.x).min()! - maximumRadius)), 0)
        let minY = max(Int(floor(samples.map(\.location.y).min()! - maximumRadius)), 0)
        let maxX = min(Int(ceil(samples.map(\.location.x).max()! + maximumRadius)), texture.width)
        let maxY = min(Int(ceil(samples.map(\.location.y).max()! + maximumRadius)), texture.height)
        guard minX < maxX, minY < maxY else { return nil }

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        var uniforms = LayerMaskStrokeUniforms(
            origin: SIMD2(UInt32(minX), UInt32(minY)),
            extent: SIMD2(UInt32(maxX - minX), UInt32(maxY - minY)),
            brushOpacity: min(max(brush.opacity, 0), 1),
            targetValue: min(max(targetValue, 0), 1),
            pointCount: UInt32(points.count),
            tipShape: tipShapeCode(brush.tipShape),
            tipHardness: brush.tipShape.hardness,
            tipSoftness: brush.customTipSoftness,
            tipRoundness: brush.customTipRoundness
        )
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setTexture(customTipTexture(for: brush) ?? fallbackTipTexture, index: 1)
        points.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                encoder.setBytes(baseAddress, length: rawBuffer.count, index: 0)
            }
        }
        encoder.setBytes(&uniforms, length: MemoryLayout<LayerMaskStrokeUniforms>.stride, index: 1)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: maxX - minX, height: maxY - minY, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        if waitUntilCompleted {
            commandBuffer.waitUntilCompleted()
        }
        return BrushPixelBounds(originX: minX, originY: minY, width: maxX - minX, height: maxY - minY)
    }

    private func tipShapeCode(_ shape: BrushTipShape) -> UInt32 {
        switch shape {
        case .hardRound: 0
        case .softRound: 1
        case .square: 2
        case .customRound: 3
        }
    }

    private func customTipTexture(for brush: BrushSettings) -> MTLTexture? {
        guard brush.tipShape == .customRound,
              let data = brush.customTipMaskData,
              !data.isEmpty else {
            return nil
        }
        if cachedCustomTipData == data {
            return cachedCustomTipTexture
        }
        let side = Int(Double(data.count).squareRoot().rounded())
        guard side > 0, side * side == data.count else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: side,
            height: side,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, side, side),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: side
            )
        }
        cachedCustomTipData = data
        cachedCustomTipTexture = texture
        return texture
    }
}
