import Foundation
import Metal
import simd

enum StageOneCanvasPresenterInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(Error)
    case samplerStateCreation

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile StageOneCanvasPresenter shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing StageOneCanvasPresenter shader function: \(name)"
        case .pipelineState(let error):
            return "Failed to create StageOneCanvasPresenter pipeline: \(error.localizedDescription)"
        case .samplerStateCreation:
            return "Failed to create StageOneCanvasPresenter sampler state."
        }
    }
}

private struct CanvasPresenterVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct CanvasPresenterUniforms {
    var layerOpacity: Float
    var _padding: SIMD3<Float> = .zero
}

final class StageOneCanvasPresenter {
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState

    init(device: MTLDevice) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct CanvasPresenterVertex {
            float2 position;
            float2 texCoord;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct CanvasPresenterUniforms {
            float layerOpacity;
            float3 padding;
        };

        vertex VertexOut canvasPresenterVertex(
            const device CanvasPresenterVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            out.texCoord = vertices[vertexID].texCoord;
            return out;
        }

        fragment float4 canvasPresenterFragment(
            VertexOut in [[stage_in]],
            texture2d<float> layerTexture [[texture(0)]],
            sampler layerSampler [[sampler(0)]],
            constant CanvasPresenterUniforms &uniforms [[buffer(0)]]
        ) {
            float4 layer = layerTexture.sample(layerSampler, in.texCoord);
            return float4(layer.rgb * uniforms.layerOpacity, layer.a * uniforms.layerOpacity);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw StageOneCanvasPresenterInitializationError.shaderLibrary(error)
        }
        let descriptor = MTLRenderPipelineDescriptor()
        guard
            let vertexFunction = library.makeFunction(name: "canvasPresenterVertex"),
            let fragmentFunction = library.makeFunction(name: "canvasPresenterFragment")
        else {
            throw StageOneCanvasPresenterInitializationError.missingFunction("canvasPresenterVertex/canvasPresenterFragment")
        }
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
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
            throw StageOneCanvasPresenterInitializationError.pipelineState(error)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw StageOneCanvasPresenterInitializationError.samplerStateCreation
        }
        self.samplerState = samplerState
    }

    func encode(
        layerTextures: [(texture: MTLTexture, opacity: Float)],
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(samplerState, index: 0)

        let vertices = makeCanvasVertices()
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<CanvasPresenterVertex>.stride * vertices.count,
            index: 0
        )

        for layer in layerTextures {
            var uniforms = CanvasPresenterUniforms(layerOpacity: layer.opacity)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<CanvasPresenterUniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
    }

    func encodePreview(
        texture: MTLTexture,
        opacity: Float,
        canvasSize: CanvasSize,
        bounds: CanvasRect,
        preview: FreeTransformPreview,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let corners = freeTransformCornerPoints(bounds: bounds, preview: preview)
        guard corners.count == 4 else {
            encoder.endEncoding()
            return
        }

        let vertices = [
            CanvasPresenterVertex(position: ndcPoint(corners[3], canvasSize: canvasSize), texCoord: SIMD2(0, 1)),
            CanvasPresenterVertex(position: ndcPoint(corners[2], canvasSize: canvasSize), texCoord: SIMD2(1, 1)),
            CanvasPresenterVertex(position: ndcPoint(corners[0], canvasSize: canvasSize), texCoord: SIMD2(0, 0)),
            CanvasPresenterVertex(position: ndcPoint(corners[1], canvasSize: canvasSize), texCoord: SIMD2(1, 0))
        ]

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<CanvasPresenterVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentSamplerState(samplerState, index: 0)

        var uniforms = CanvasPresenterUniforms(layerOpacity: opacity)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CanvasPresenterUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func makeCanvasVertices() -> [CanvasPresenterVertex] {
        [
            CanvasPresenterVertex(position: SIMD2(-1, -1), texCoord: SIMD2(0, 1)),
            CanvasPresenterVertex(position: SIMD2(1, -1), texCoord: SIMD2(1, 1)),
            CanvasPresenterVertex(position: SIMD2(-1, 1), texCoord: SIMD2(0, 0)),
            CanvasPresenterVertex(position: SIMD2(1, 1), texCoord: SIMD2(1, 0))
        ]
    }

    private func ndcPoint(
        _ point: CanvasPoint,
        canvasSize: CanvasSize
    ) -> SIMD2<Float> {
        return SIMD2(
            Float((point.x / Double(max(canvasSize.width, 1))) * 2 - 1),
            Float((1 - (point.y / Double(max(canvasSize.height, 1)))) * 2 - 1)
        )
    }
}
