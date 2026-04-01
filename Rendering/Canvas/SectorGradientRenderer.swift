import Foundation
import Metal
import simd

private struct SectorGradientVertex {
    var position: SIMD2<Float>
}

private struct SectorGradientUniforms {
    var canvasSize: SIMD2<Float>
    var center: SIMD2<Float>
    var maxRadius: Float
    var color: SIMD4<Float>
    var colorJitterAmount: Float
    var usesSelectionMask: Float
}

enum SectorGradientMaskQuality {
    case preview
    case commit
}

func sectorGradientTriangleFanVertexPositions(
    center: CanvasPoint,
    pathPoints: [CanvasPoint]
) -> [CanvasPoint] {
    let boundaryPoints = normalizedSectorGradientBoundaryPoints(
        center: center,
        pathPoints: pathPoints
    )
    guard boundaryPoints.count >= 2 else { return [] }

    var vertices: [CanvasPoint] = []
    vertices.reserveCapacity((boundaryPoints.count - 1) * 3)
    for index in 0..<(boundaryPoints.count - 1) {
        vertices.append(center)
        vertices.append(boundaryPoints[index])
        vertices.append(boundaryPoints[index + 1])
    }
    return vertices
}

private func normalizedSectorGradientBoundaryPoints(
    center: CanvasPoint,
    pathPoints: [CanvasPoint]
) -> [CanvasPoint] {
    var boundaryPoints = pathPoints
    while let first = boundaryPoints.first, distanceBetween(first, center) <= 0.5 {
        boundaryPoints.removeFirst()
    }
    while let last = boundaryPoints.last, distanceBetween(last, center) <= 0.5 {
        boundaryPoints.removeLast()
    }

    guard !boundaryPoints.isEmpty else { return [] }
    var deduplicated: [CanvasPoint] = []
    deduplicated.reserveCapacity(boundaryPoints.count)

    for point in boundaryPoints {
        if let last = deduplicated.last, distanceBetween(last, point) <= 0.25 {
            continue
        }
        deduplicated.append(point)
    }

    return deduplicated
}

final class SectorGradientRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let fallbackSelectionMaskTexture: MTLTexture
    private var cachedSelectionMaskShape: SelectionShape?
    private var cachedSelectionMaskCanvasSize: CanvasSize?
    private var cachedSelectionMaskTexture: MTLTexture?
    private var reusableVertexBuffer: MTLBuffer?
    private var reusableVertexBufferLength = 0

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct SectorGradientVertex {
            float2 position;
        };

        struct SectorGradientUniforms {
            float2 canvasSize;
            float2 center;
            float maxRadius;
            float4 color;
            float colorJitterAmount;
            float usesSelectionMask;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
        };

        vertex VertexOut sectorGradientVertexShader(
            const device SectorGradientVertex *vertices [[buffer(0)]],
            constant SectorGradientUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            SectorGradientVertex inputVertex = vertices[vertexID];
            float2 normalized = float2(
                (inputVertex.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (inputVertex.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            VertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.canvasPosition = inputVertex.position;
            return out;
        }

        float3 rgbToHsv(float3 c) {
            float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
            float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }

        float3 hsvToRgb(float3 c) {
            float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }

        float hash12(float2 point) {
            return fract(sin(dot(point, float2(127.1, 311.7))) * 43758.5453123);
        }

        float3 radialStripedJitteredGradientSrgbColor(
            float3 srgbColor,
            float angleNormalized,
            float amount
        ) {
            if (amount <= 0.001) {
                return srgbColor;
            }

            float rightBoost = pow(amount, 1.75);
            float stripeCoordPrimary = clamp(angleNormalized, 0.0, 1.0);

            float macroBandCount = floor(10.0 + (amount * 16.0));
            macroBandCount = max(macroBandCount, 2.0);
            float macroBandIndex = floor(stripeCoordPrimary * macroBandCount);
            float macroWarp = ((hash12(float2(macroBandIndex + 151.0, 3.0)) * 2.0) - 1.0) * ((0.022 * amount) + (0.082 * rightBoost));

            float fineWarpSeed = floor(stripeCoordPrimary * 220.0);
            float fineWarp = ((hash12(float2(fineWarpSeed + 5.0, 9.0)) * 2.0) - 1.0) * ((0.010 * amount) + (0.03 * rightBoost));

            float warpedCoord = clamp(stripeCoordPrimary + macroWarp + fineWarp, 0.0, 0.999);
            float stripeCount = floor(46.0 + (amount * 52.0));
            stripeCount = max(stripeCount, 8.0);
            float stripeIndex = floor(warpedCoord * stripeCount);
            float hueRandom = hash12(float2(stripeIndex + 1.0, 7.0));
            float saturationRandom = hash12(float2(stripeIndex + 31.0, 11.0));
            float valueRandom = hash12(float2(stripeIndex + 61.0, 23.0));
            float accentRandom = hash12(float2(stripeIndex + 91.0, 37.0));
            float stripeShapeRandom = hash12(float2(stripeIndex + 121.0, 43.0));

            float layeringBandCount = floor(16.0 + (amount * 18.0));
            layeringBandCount = max(layeringBandCount, 2.0);
            float layeringBandIndex = floor(warpedCoord * layeringBandCount);
            float bandSaturationRandom = hash12(float2(layeringBandIndex + 211.0, 17.0));
            float bandValueRandom = hash12(float2(layeringBandIndex + 241.0, 29.0));

            float3 hsv = rgbToHsv(srgbColor);
            float hueOffsetRange = 0.30 * amount;
            float saturationOffsetRange = (0.95 * amount) + (0.7 * rightBoost);
            float valueOffsetRange = (0.52 * amount) + (0.38 * rightBoost);

            float hueOffset = ((hueRandom * 2.0) - 1.0) * hueOffsetRange;
            float accentGate = step(0.82 - (0.18 * amount), accentRandom);
            hueOffset += ((accentRandom * 2.0) - 1.0) * (0.03 * rightBoost) * accentGate;

            float saturationBase = mix(saturationRandom, bandSaturationRandom, 0.55);
            float valueBase = mix(valueRandom, bandValueRandom, 0.45);
            float saturationOffset = ((saturationBase * 2.0) - 1.0) * saturationOffsetRange;
            float valueOffset = ((valueBase * 2.0) - 1.0) * valueOffsetRange;

            float vividBoost = accentGate * ((0.24 * amount) + (0.38 * rightBoost));
            float darkLightSwing = ((stripeShapeRandom * 2.0) - 1.0) * ((0.08 * amount) + (0.18 * rightBoost));

            hsv.x = fract(hsv.x + hueOffset + 1.0);
            hsv.y = clamp(hsv.y + saturationOffset + (0.20 * rightBoost) + vividBoost, 0.0, 1.0);
            hsv.z = clamp(hsv.z + valueOffset + darkLightSwing, 0.0, 1.0);
            return hsvToRgb(hsv);
        }

        fragment float4 sectorGradientFragmentShader(
            VertexOut in [[stage_in]],
            constant SectorGradientUniforms &uniforms [[buffer(1)]],
            texture2d<float> selectionMask [[texture(0)]]
        ) {
            constexpr sampler selectionSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

            float maskAlpha = 1.0;
            if (uniforms.usesSelectionMask > 0.5) {
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 uv = in.canvasPosition / canvasSize;
                maskAlpha = selectionMask.sample(selectionSampler, uv).r;
                if (maskAlpha <= 0.001) {
                    return float4(0.0);
                }
            }

            float radius = length(in.canvasPosition - uniforms.center);
            float t = clamp(radius / max(uniforms.maxRadius, 0.0001), 0.0, 1.0);
            float easedAlpha = 1.0 - smoothstep(0.0, 1.0, t);
            float alpha = easedAlpha * uniforms.color.a * maskAlpha;
            float angle = atan2(in.canvasPosition.y - uniforms.center.y, in.canvasPosition.x - uniforms.center.x);
            float angleNormalized = (angle / 6.283185307179586) + 0.5;
            float3 jitteredColor = radialStripedJitteredGradientSrgbColor(
                uniforms.color.rgb,
                angleNormalized,
                clamp(uniforms.colorJitterAmount, 0.0, 1.0)
            );
            float3 premultiplied = jitteredColor * alpha;
            return float4(premultiplied, alpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile SectorGradientRenderer shader: \\(error)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sectorGradientVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "sectorGradientFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create SectorGradientRenderer pipeline: \\(error)")
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = .shaderRead
        fallbackDescriptor.storageMode = .shared
        guard let fallbackTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            fatalError("Failed to create fallback selection mask texture.")
        }
        let fullMask: [UInt8] = [255]
        fallbackTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: fullMask,
            bytesPerRow: 1
        )
        self.fallbackSelectionMaskTexture = fallbackTexture
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        center: CanvasPoint,
        pathPoints: [CanvasPoint],
        maxRadius: Double,
        color: RGBAColor,
        colorJitterAmount: Float = 0,
        maskQuality: SectorGradientMaskQuality = .commit,
        selectionShape: SelectionShape? = nil
    ) {
        _ = maskQuality
        guard pathPoints.count >= 3, maxRadius > 0.5 else { return }

        let vertexPositions = sectorGradientTriangleFanVertexPositions(
            center: center,
            pathPoints: pathPoints
        )
        guard vertexPositions.count >= 3 else { return }

        let vertices = vertexPositions.map {
            SectorGradientVertex(position: SIMD2(Float($0.x), Float($0.y)))
        }
        guard let vertexBuffer = makeVertexBuffer(vertices: vertices) else {
            return
        }

        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: canvasSize
        ) ?? fallbackSelectionMaskTexture

        var uniforms = SectorGradientUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            center: SIMD2(Float(center.x), Float(center.y)),
            maxRadius: Float(maxRadius),
            color: SIMD4(color.red, color.green, color.blue, color.alpha),
            colorJitterAmount: colorJitterAmount,
            usesSelectionMask: selectionShape == nil ? 0 : 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SectorGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SectorGradientUniforms>.stride, index: 1)
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    private func makeVertexBuffer(vertices: [SectorGradientVertex]) -> MTLBuffer? {
        let length = MemoryLayout<SectorGradientVertex>.stride * vertices.count
        guard length > 0 else { return nil }

        if reusableVertexBuffer == nil || reusableVertexBufferLength < length {
            let capacity = max(length, 16 * 1024)
            reusableVertexBuffer = device.makeBuffer(length: capacity, options: .storageModeShared)
            reusableVertexBufferLength = capacity
        }

        guard let reusableVertexBuffer else { return nil }
        vertices.withUnsafeBytes { rawBuffer in
            guard let sourceBaseAddress = rawBuffer.baseAddress else { return }
            reusableVertexBuffer.contents().copyMemory(
                from: sourceBaseAddress,
                byteCount: rawBuffer.count
            )
        }
        return reusableVertexBuffer
    }

    private func makeSelectionMaskTexture(
        for selectionShape: SelectionShape?,
        canvasSize: CanvasSize
    ) -> MTLTexture? {
        guard let selectionShape else {
            cachedSelectionMaskShape = nil
            cachedSelectionMaskCanvasSize = nil
            cachedSelectionMaskTexture = nil
            return nil
        }

        if
            cachedSelectionMaskShape == selectionShape,
            cachedSelectionMaskCanvasSize == canvasSize,
            let cachedSelectionMaskTexture
        {
            return cachedSelectionMaskTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: canvasSize.width,
            height: canvasSize.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        let pixels: [UInt8]
        if let maskData = selectionShape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            pixels = [UInt8](maskData.alphaBytes)
        } else {
            var generated = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            let minX = max(Int(selectionShape.bounds.minX.rounded(.down)), 0)
            let minY = max(Int(selectionShape.bounds.minY.rounded(.down)), 0)
            let maxX = min(Int(selectionShape.bounds.maxX.rounded(.up)), canvasSize.width)
            let maxY = min(Int(selectionShape.bounds.maxY.rounded(.up)), canvasSize.height)

            if minX < maxX && minY < maxY {
                for y in minY..<maxY {
                    for x in minX..<maxX {
                        if selectionShape.contains(CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                            generated[(y * canvasSize.width) + x] = 255
                        }
                    }
                }
            }
            pixels = generated
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, canvasSize.width, canvasSize.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: canvasSize.width
        )

        cachedSelectionMaskShape = selectionShape
        cachedSelectionMaskCanvasSize = canvasSize
        cachedSelectionMaskTexture = texture
        return texture
    }
}
