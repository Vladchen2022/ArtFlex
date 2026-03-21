import Foundation
import Metal
import simd

private struct LinearGradientVertex {
    var position: SIMD2<Float>
    var gradientT: Float
}

private struct LinearGradientUniforms {
    var canvasSize: SIMD2<Float>
    var color: SIMD4<Float>
}

final class LinearGradientRenderer {
    private let pipelineState: MTLRenderPipelineState

    init(device: MTLDevice) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct LinearGradientVertex {
            float2 position;
            float gradientT;
        };

        struct LinearGradientUniforms {
            float2 canvasSize;
            float4 color;
        };

        struct VertexOut {
            float4 position [[position]];
            float gradientT;
        };

        vertex VertexOut linearGradientVertexShader(
            const device LinearGradientVertex *vertices [[buffer(0)]],
            constant LinearGradientUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            LinearGradientVertex inputVertex = vertices[vertexID];
            float2 normalized = float2(
                (inputVertex.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (inputVertex.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            VertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.gradientT = clamp(inputVertex.gradientT, 0.0, 1.0);
            return out;
        }

        fragment float4 linearGradientFragmentShader(
            VertexOut in [[stage_in]],
            constant LinearGradientUniforms &uniforms [[buffer(1)]]
        ) {
            float alpha = (1.0 - in.gradientT) * uniforms.color.a;
            float3 premultiplied = uniforms.color.rgb * alpha;
            return float4(premultiplied, alpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile LinearGradientRenderer shader: \(error)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "linearGradientVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "linearGradientFragmentShader")
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
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create LinearGradientRenderer pipeline: \(error)")
        }
    }

    func render(
        into texture: MTLTexture,
        pointA: CanvasPoint,
        pointB: CanvasPoint,
        pointC: CanvasPoint,
        color: RGBAColor,
        commandQueue: MTLCommandQueue
    ) {
        let pointD = CanvasPoint(
            x: pointA.x + (pointC.x - pointB.x),
            y: pointA.y + (pointC.y - pointB.y)
        )
        let vertices: [LinearGradientVertex] = [
            .init(position: SIMD2(Float(pointA.x), Float(pointA.y)), gradientT: 0),
            .init(position: SIMD2(Float(pointB.x), Float(pointB.y)), gradientT: 0),
            .init(position: SIMD2(Float(pointD.x), Float(pointD.y)), gradientT: 1),
            .init(position: SIMD2(Float(pointC.x), Float(pointC.y)), gradientT: 1)
        ]
        var uniforms = LinearGradientUniforms(
            canvasSize: SIMD2(Float(texture.width), Float(texture.height)),
            color: SIMD4(color.red, color.green, color.blue, color.alpha)
        )

        guard
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<LinearGradientVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LinearGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LinearGradientUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
