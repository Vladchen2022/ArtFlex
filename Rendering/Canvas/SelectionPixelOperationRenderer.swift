import Foundation
import Metal
import simd

enum SelectionPixelOperationRenderMode: UInt32 {
    case clear = 0
    case fill = 1
}

private struct SelectionPixelOperationVertex {
    var position: SIMD2<Float>
}

private struct SelectionPixelOperationUniforms {
    var canvasSize: SIMD2<Float>
    var selectionBoundsMin: SIMD2<Float>
    var selectionBoundsMax: SIMD2<Float>
    var fillColor: SIMD4<Float>
    var operationMode: UInt32
    var usesAlphaLock: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
}

final class SelectionPixelOperationRenderer {
    private let device: MTLDevice
    private let clearPipelineState: MTLRenderPipelineState
    private let fillPipelineState: MTLRenderPipelineState
    private let alphaLockedPipelineState: MTLRenderPipelineState
    private let fallbackAlphaLockTexture: MTLTexture
    private var reusableSelectionMaskTexture: MTLTexture?
    private var reusableSelectionMaskTextureSize: SIMD2<Int>?

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct SelectionPixelOperationVertex {
            float2 position;
        };

        struct SelectionPixelOperationUniforms {
            float2 canvasSize;
            float2 selectionBoundsMin;
            float2 selectionBoundsMax;
            float4 fillColor;
            uint operationMode;
            uint usesAlphaLock;
            uint padding0;
            uint padding1;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
        };

        vertex VertexOut selectionPixelOperationVertexShader(
            const device SelectionPixelOperationVertex *vertices [[buffer(0)]],
            constant SelectionPixelOperationUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            SelectionPixelOperationVertex inputVertex = vertices[vertexID];
            float2 normalized = float2(
                (inputVertex.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (inputVertex.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            VertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.canvasPosition = inputVertex.position;
            return out;
        }

        fragment float4 selectionPixelOperationFragmentShader(
            VertexOut in [[stage_in]],
            constant SelectionPixelOperationUniforms &uniforms [[buffer(1)]],
            texture2d<float> selectionMask [[texture(0)]],
            texture2d<float> alphaLockTexture [[texture(1)]]
        ) {
            float2 boundsSize = max(uniforms.selectionBoundsMax - uniforms.selectionBoundsMin, float2(1.0, 1.0));
            float2 localCoord = clamp((in.canvasPosition - uniforms.selectionBoundsMin) / boundsSize, 0.0, 1.0);
            constexpr sampler maskSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

            float maskAlpha = selectionMask.sample(maskSampler, localCoord).r;
            if (maskAlpha <= 0.001) {
                discard_fragment();
            }

            float lockedDestinationAlpha = 1.0;
            if (uniforms.usesAlphaLock != 0) {
                float2 canvasUV = in.canvasPosition / max(uniforms.canvasSize, float2(1.0, 1.0));
                lockedDestinationAlpha = alphaLockTexture.sample(maskSampler, canvasUV).a;
                if (lockedDestinationAlpha <= 0.001) {
                    discard_fragment();
                }
            }

            if (uniforms.operationMode == 0) {
                return float4(0.0, 0.0, 0.0, maskAlpha);
            }
            if (uniforms.usesAlphaLock != 0) {
                float sourceAlpha = max(uniforms.fillColor.a, 0.0);
                float3 visibleFillColor = sourceAlpha > 0.0001
                    ? clamp(uniforms.fillColor.rgb / sourceAlpha, 0.0, 1.0)
                    : float3(0.0);
                return float4(visibleFillColor * lockedDestinationAlpha, maskAlpha);
            }
            return float4(uniforms.fillColor.rgb, maskAlpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile SelectionPixelOperationRenderer shader: \(error)")
        }

        func makePipeline(
            configure attachment: (MTLRenderPipelineColorAttachmentDescriptor) -> Void
        ) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "selectionPixelOperationVertexShader")
            descriptor.fragmentFunction = library.makeFunction(name: "selectionPixelOperationFragmentShader")
            let colorAttachment = descriptor.colorAttachments[0]!
            colorAttachment.pixelFormat = .bgra8Unorm_srgb
            colorAttachment.isBlendingEnabled = true
            attachment(colorAttachment)
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        do {
            clearPipelineState = try makePipeline { attachment in
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .zero
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .zero
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            fillPipelineState = try makePipeline { attachment in
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .blendAlpha
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            alphaLockedPipelineState = try makePipeline { attachment in
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .zero
                attachment.destinationAlphaBlendFactor = .one
            }
        } catch {
            fatalError("Failed to create SelectionPixelOperationRenderer pipelines: \(error)")
        }

        let fallbackAlphaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackAlphaDescriptor.usage = .shaderRead
        fallbackAlphaDescriptor.storageMode = .shared
        guard let fallbackAlphaTexture = device.makeTexture(descriptor: fallbackAlphaDescriptor) else {
            fatalError("Failed to create fallback alpha lock texture.")
        }
        let fullAlphaPixel: [UInt8] = [255, 255, 255, 255]
        fallbackAlphaTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: fullAlphaPixel,
            bytesPerRow: 4
        )
        self.fallbackAlphaLockTexture = fallbackAlphaTexture
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        selectionMaskOriginX: Int,
        selectionMaskOriginY: Int,
        selectionMaskWidth: Int,
        selectionMaskHeight: Int,
        selectionMaskAlphaBytes: Data,
        operationMode: SelectionPixelOperationRenderMode,
        premultipliedFillColor: RGBAColor,
        alphaLockTexture: MTLTexture? = nil
    ) {
        let minX = max(selectionMaskOriginX, 0)
        let minY = max(selectionMaskOriginY, 0)
        let maxX = min(selectionMaskOriginX + selectionMaskWidth, canvasSize.width)
        let maxY = min(selectionMaskOriginY + selectionMaskHeight, canvasSize.height)
        guard minX < maxX, minY < maxY else {
            return
        }
        guard selectionMaskAlphaBytes.count == selectionMaskWidth * selectionMaskHeight else {
            return
        }

        let vertices: [SelectionPixelOperationVertex] = [
            .init(position: SIMD2(Float(minX), Float(minY))),
            .init(position: SIMD2(Float(maxX), Float(minY))),
            .init(position: SIMD2(Float(minX), Float(maxY))),
            .init(position: SIMD2(Float(maxX), Float(maxY)))
        ]
        guard let selectionMaskTexture = makeSelectionMaskTexture(
            alphaBytes: selectionMaskAlphaBytes,
            width: selectionMaskWidth,
            height: selectionMaskHeight
        ) else {
            return
        }

        var uniforms = SelectionPixelOperationUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            selectionBoundsMin: SIMD2(Float(minX), Float(minY)),
            selectionBoundsMax: SIMD2(Float(maxX), Float(maxY)),
            fillColor: SIMD4(
                premultipliedFillColor.red,
                premultipliedFillColor.green,
                premultipliedFillColor.blue,
                premultipliedFillColor.alpha
            ),
            operationMode: operationMode.rawValue,
            usesAlphaLock: alphaLockTexture == nil ? 0 : 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let pipelineState: MTLRenderPipelineState
        if alphaLockTexture != nil {
            pipelineState = alphaLockedPipelineState
        } else {
            pipelineState = operationMode == .clear ? clearPipelineState : fillPipelineState
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setBlendColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: premultipliedFillColor.alpha
        )
        encoder.setScissorRect(MTLScissorRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ))
        encoder.setVertexBytes(vertices, length: MemoryLayout<SelectionPixelOperationVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SelectionPixelOperationUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SelectionPixelOperationUniforms>.stride, index: 1)
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    private func makeSelectionMaskTexture(
        alphaBytes: Data,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard width > 0, height > 0 else {
            return nil
        }
        guard alphaBytes.count == width * height else {
            return nil
        }

        let texture: MTLTexture
        if reusableSelectionMaskTextureSize != SIMD2(width, height) || reusableSelectionMaskTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let newTexture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            reusableSelectionMaskTexture = newTexture
            reusableSelectionMaskTextureSize = SIMD2(width, height)
        }
        guard let reusableSelectionMaskTexture else {
            return nil
        }
        texture = reusableSelectionMaskTexture

        alphaBytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }

        return texture
    }
}
