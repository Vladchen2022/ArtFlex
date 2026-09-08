import Foundation
@preconcurrency import Metal
import simd

private struct VisibleDeltaVertex {
    var position: SIMD2<Float>
}

private struct VisibleDeltaUniforms {
    var canvasSize: SIMD2<UInt32>
    var _padding: SIMD2<UInt32> = .zero
}

enum VisibleDeltaRendererInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(Error)

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile VisibleDeltaRenderer shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing VisibleDeltaRenderer shader function: \(name)"
        case .pipelineState(let error):
            return "Failed to create VisibleDeltaRenderer pipeline: \(error.localizedDescription)"
        }
    }
}

final class VisibleDeltaRenderer {
    private let pipelineVariants: ColorRenderPipelineVariants
    private let pipelineState: MTLRenderPipelineState

    init(device: MTLDevice) throws {
        let pipelineVariants = ColorRenderPipelineVariants(device: device)
        self.pipelineVariants = pipelineVariants
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VisibleDeltaVertex {
            float2 position;
        };

        struct VertexOut {
            float4 position [[position]];
        };

        struct VisibleDeltaUniforms {
            uint2 canvasSize;
            uint2 padding;
        };

        vertex VertexOut visibleDeltaVertex(
            const device VisibleDeltaVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            return out;
        }

        fragment float4 visibleDeltaFragment(
            VertexOut in [[stage_in]],
            texture2d<float, access::read> variantTexture [[texture(0)]],
            texture2d<float, access::read> baseTexture [[texture(1)]],
            constant VisibleDeltaUniforms &uniforms [[buffer(0)]]
        ) {
            uint2 gid = uint2(in.position.xy);
            if (gid.x >= uniforms.canvasSize.x || gid.y >= uniforms.canvasSize.y) {
                return float4(0.0);
            }

            float4 variant = variantTexture.read(gid);
            float4 base = baseTexture.read(gid);
            float4 delta = abs(variant - base);
            bool matches =
                delta.r <= 0.0001 &&
                delta.g <= 0.0001 &&
                delta.b <= 0.0001 &&
                delta.a <= 0.0001;

            if (matches) {
                return float4(0.0);
            }

            float alpha = variant.a;
            if (alpha <= 0.0001) {
                return float4(0.0);
            }

            return float4(variant.rgb, alpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw VisibleDeltaRendererInitializationError.shaderLibrary(error)
        }

        guard
            let vertexFunction = library.makeFunction(name: "visibleDeltaVertex"),
            let fragmentFunction = library.makeFunction(name: "visibleDeltaFragment")
        else {
            throw VisibleDeltaRendererInitializationError.missingFunction("visibleDeltaVertex/visibleDeltaFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            pipelineState = try pipelineVariants.makeState(descriptor: descriptor)
        } catch {
            throw VisibleDeltaRendererInitializationError.pipelineState(error)
        }
    }

    func encode(
        variantTexture: MTLTexture,
        baseTexture: MTLTexture,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let vertices = [
            VisibleDeltaVertex(position: SIMD2(-1, -1)),
            VisibleDeltaVertex(position: SIMD2(1, -1)),
            VisibleDeltaVertex(position: SIMD2(-1, 1)),
            VisibleDeltaVertex(position: SIMD2(1, 1))
        ]
        var uniforms = VisibleDeltaUniforms(
            canvasSize: SIMD2<UInt32>(
                UInt32(variantTexture.width),
                UInt32(variantTexture.height)
            )
        )

        encoder.setRenderPipelineState(pipelineVariants.state(pipelineState, for: renderPassDescriptor.colorAttachments[0].texture?.pixelFormat ?? .bgra8Unorm_srgb))
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<VisibleDeltaVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(variantTexture, index: 0)
        encoder.setFragmentTexture(baseTexture, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<VisibleDeltaUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
