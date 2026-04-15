import Foundation
@preconcurrency import Metal

private struct CurveAdjustmentVertex {
    var position: SIMD2<Float>
}

private struct CurveAdjustmentPreviewUniforms {
    var canvasSize: SIMD2<UInt32>
    var maskReadMode: UInt32
    var overlayOnly: UInt32
    var padding: UInt32 = 0
}

enum CurveAdjustmentRendererInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(Error)
    case fallbackMaskTextureCreation

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile CurveAdjustmentRenderer shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing CurveAdjustmentRenderer shader function: \(name)"
        case .pipelineState(let error):
            return "Failed to create CurveAdjustmentRenderer pipeline: \(error.localizedDescription)"
        case .fallbackMaskTextureCreation:
            return "Failed to create CurveAdjustmentRenderer fallback mask texture."
        }
    }
}

private struct SendableCurveAdjustmentCompletion: @unchecked Sendable {
    let callback: () -> Void
}

final class CurveAdjustmentRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let fallbackMaskTexture: MTLTexture

    init(device: MTLDevice) throws {
        self.device = device

        let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct CurveAdjustmentVertex {
            float2 position;
        };

        struct CurveAdjustmentPreviewUniforms {
            uint2 canvasSize;
            uint maskReadMode;
            uint overlayOnly;
            uint padding;
        };

        struct VertexOut {
            float4 position [[position]];
        };

        float srgbChannelToLinear(float value) {
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4);
        }

        float linearChannelToSrgb(float value) {
            value = clamp(value, 0.0, 1.0);
            return value <= 0.0031308
                ? value * 12.92
                : (1.055 * pow(value, 1.0 / 2.4)) - 0.055;
        }

        float3 srgbToLinear(float3 color) {
            return float3(
                srgbChannelToLinear(color.r),
                srgbChannelToLinear(color.g),
                srgbChannelToLinear(color.b)
            );
        }

        float3 linearToSrgb(float3 color) {
            return float3(
                linearChannelToSrgb(color.r),
                linearChannelToSrgb(color.g),
                linearChannelToSrgb(color.b)
            );
        }

        float sampleCurveLUT(constant float *lut, float value) {
            float scaled = clamp(value, 0.0, 1.0) * 255.0;
            uint lowerIndex = uint(floor(scaled));
            uint upperIndex = min(lowerIndex + 1, 255u);
            float t = scaled - float(lowerIndex);
            return mix(lut[lowerIndex], lut[upperIndex], t);
        }

        float3 safeUnpremultiply(float4 premultiplied) {
            if (premultiplied.a <= 0.0001) {
                return float3(0.0);
            }
            return clamp(premultiplied.rgb / premultiplied.a, 0.0, 1.0);
        }

        vertex VertexOut curveAdjustmentVertex(
            const device CurveAdjustmentVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            return out;
        }

        fragment float4 curveAdjustmentPreviewFragment(
            VertexOut in [[stage_in]],
            texture2d<float, access::read> sourceTexture [[texture(0)]],
            texture2d<float, access::read> maskTexture [[texture(1)]],
            constant CurveAdjustmentPreviewUniforms &uniforms [[buffer(0)]],
            constant float *compositeLUT [[buffer(1)]],
            constant float *redLUT [[buffer(2)]],
            constant float *greenLUT [[buffer(3)]],
            constant float *blueLUT [[buffer(4)]]
        ) {
            uint2 gid = uint2(in.position.xy);
            if (gid.x >= uniforms.canvasSize.x || gid.y >= uniforms.canvasSize.y) {
                return float4(0.0);
            }

            float4 base = sourceTexture.read(gid);
            float influence = uniforms.maskReadMode == 0
                ? maskTexture.read(gid).r
                : base.a;
            influence = clamp(influence, 0.0, 1.0);

            if (influence <= 0.0001) {
                return base;
            }

            if (uniforms.overlayOnly != 0) {
                float overlayAlpha = influence * 0.38;
                float3 overlayColor = float3(0.19, 0.47, 1.0);
                float3 overlayPremultiplied = overlayColor * overlayAlpha;

                float3 rgb = overlayPremultiplied + (base.rgb * (1.0 - overlayAlpha));
                float alpha = overlayAlpha + (base.a * (1.0 - overlayAlpha));
                return float4(rgb, alpha);
            }

            if (base.a <= 0.0001) {
                return base;
            }

            float3 baseLinear = safeUnpremultiply(base);
            float3 display = linearToSrgb(baseLinear);

            display.r = sampleCurveLUT(compositeLUT, display.r);
            display.g = sampleCurveLUT(compositeLUT, display.g);
            display.b = sampleCurveLUT(compositeLUT, display.b);

            display.r = sampleCurveLUT(redLUT, display.r);
            display.g = sampleCurveLUT(greenLUT, display.g);
            display.b = sampleCurveLUT(blueLUT, display.b);

            float3 adjustedLinear = srgbToLinear(display);
            float4 adjustedPremultiplied = float4(adjustedLinear * base.a, base.a);
            return mix(base, adjustedPremultiplied, influence);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            throw CurveAdjustmentRendererInitializationError.shaderLibrary(error)
        }

        guard let vertexFunction = library.makeFunction(name: "curveAdjustmentVertex") else {
            throw CurveAdjustmentRendererInitializationError.missingFunction("curveAdjustmentVertex")
        }
        guard let fragmentFunction = library.makeFunction(name: "curveAdjustmentPreviewFragment") else {
            throw CurveAdjustmentRendererInitializationError.missingFunction("curveAdjustmentPreviewFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw CurveAdjustmentRendererInitializationError.pipelineState(error)
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = [.shaderRead]
        fallbackDescriptor.storageMode = .shared
        guard let fallbackMaskTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            throw CurveAdjustmentRendererInitializationError.fallbackMaskTextureCreation
        }
        var opaqueMask: UInt8 = 255
        fallbackMaskTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &opaqueMask,
            bytesPerRow: 1
        )
        self.fallbackMaskTexture = fallbackMaskTexture
    }

    func renderPreview(
        sourceTexture: MTLTexture,
        previewTexture: MTLTexture,
        maskTexture: MTLTexture?,
        maskReadMode: CurveAdjustmentRegionReadMode,
        luts: CurveLUTs,
        overlayOnly: Bool,
        effectRegion: MTLRegion?,
        commandQueue: MTLCommandQueue,
        completion: (() -> Void)? = nil
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion?()
            return
        }

        encodePreview(
            sourceTexture: sourceTexture,
            previewTexture: previewTexture,
            maskTexture: maskTexture,
            maskReadMode: maskReadMode,
            luts: luts,
            overlayOnly: overlayOnly,
            effectRegion: effectRegion,
            commandBuffer: commandBuffer
        )

        if let completion {
            let sendableCompletion = SendableCurveAdjustmentCompletion(callback: completion)
            commandBuffer.addCompletedHandler { _ in
                sendableCompletion.callback()
            }
        }
        commandBuffer.commit()
    }

    func encodePreview(
        sourceTexture: MTLTexture,
        previewTexture: MTLTexture,
        maskTexture: MTLTexture?,
        maskReadMode: CurveAdjustmentRegionReadMode,
        luts: CurveLUTs,
        overlayOnly: Bool,
        effectRegion: MTLRegion?,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: .init(width: sourceTexture.width, height: sourceTexture.height, depth: 1),
            to: previewTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = previewTexture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipelineState)
        if let effectRegion {
            encoder.setScissorRect(MTLScissorRect(
                x: effectRegion.origin.x,
                y: effectRegion.origin.y,
                width: effectRegion.size.width,
                height: effectRegion.size.height
            ))
        }

        let vertices: [CurveAdjustmentVertex] = [
            .init(position: SIMD2(-1, -1)),
            .init(position: SIMD2(1, -1)),
            .init(position: SIMD2(-1, 1)),
            .init(position: SIMD2(1, 1))
        ]
        var uniforms = CurveAdjustmentPreviewUniforms(
            canvasSize: SIMD2(
                UInt32(sourceTexture.width),
                UInt32(sourceTexture.height)
            ),
            maskReadMode: maskReadMode == .maskRed ? 0 : 1,
            overlayOnly: overlayOnly ? 1 : 0
        )

        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<CurveAdjustmentVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(maskTexture ?? fallbackMaskTexture, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CurveAdjustmentPreviewUniforms>.stride,
            index: 0
        )

        let composite = preparedLUT(luts.composite)
        let red = preparedLUT(luts.red)
        let green = preparedLUT(luts.green)
        let blue = preparedLUT(luts.blue)

        composite.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            encoder.setFragmentBytes(
                baseAddress,
                length: MemoryLayout<Float>.stride * buffer.count,
                index: 1
            )
        }
        red.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            encoder.setFragmentBytes(
                baseAddress,
                length: MemoryLayout<Float>.stride * buffer.count,
                index: 2
            )
        }
        green.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            encoder.setFragmentBytes(
                baseAddress,
                length: MemoryLayout<Float>.stride * buffer.count,
                index: 3
            )
        }
        blue.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            encoder.setFragmentBytes(
                baseAddress,
                length: MemoryLayout<Float>.stride * buffer.count,
                index: 4
            )
        }

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    private func preparedLUT(_ values: [Float], sampleCount: Int = 256) -> [Float] {
        if values.count == sampleCount {
            return values.map { min(max($0, 0), 1) }
        }

        var output = [Float](repeating: 0, count: sampleCount)
        if values.isEmpty {
            for index in output.indices {
                output[index] = Float(index) / Float(sampleCount - 1)
            }
            return output
        }

        for index in output.indices {
            output[index] = values[min(index, values.count - 1)]
        }
        return output
    }
}
