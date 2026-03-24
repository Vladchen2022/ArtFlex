import Foundation
import Metal
import simd

private struct SectorGradientVertex {
    var position: SIMD2<Float>
}

private struct SectorGradientUniforms {
    var canvasSize: SIMD2<Float>
    var center: SIMD2<Float>
    var radius: Float
    var startAngle: Float
    var sweepAngle: Float
    var isFullCircle: UInt32
    var color: SIMD4<Float>
}

final class SectorGradientRenderer {
    private let pipelineState: MTLRenderPipelineState

    init(device: MTLDevice) {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        constant float kTau = 6.28318530718;

        struct SectorGradientVertex {
            float2 position;
        };

        struct SectorGradientUniforms {
            float2 canvasSize;
            float2 center;
            float radius;
            float startAngle;
            float sweepAngle;
            uint isFullCircle;
            float4 color;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
        };

        float positiveModulo(float value, float modulus) {
            float remainder = fmod(value, modulus);
            return remainder < 0.0 ? remainder + modulus : remainder;
        }

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

        fragment float4 sectorGradientFragmentShader(
            VertexOut in [[stage_in]],
            constant SectorGradientUniforms &uniforms [[buffer(1)]]
        ) {
            float2 offset = in.canvasPosition - uniforms.center;
            float radius = length(offset);
            if (uniforms.radius <= 0.001 || radius > uniforms.radius) {
                return float4(0.0);
            }

            if (uniforms.isFullCircle == 0) {
                float angle = atan2(offset.y, offset.x);
                if (uniforms.sweepAngle >= 0.0) {
                    float relative = positiveModulo(angle - uniforms.startAngle, kTau);
                    if (relative > uniforms.sweepAngle) {
                        return float4(0.0);
                    }
                } else {
                    float relative = positiveModulo(uniforms.startAngle - angle, kTau);
                    if (relative > -uniforms.sweepAngle) {
                        return float4(0.0);
                    }
                }
            }

            float t = clamp(radius / uniforms.radius, 0.0, 1.0);
            float alpha = (1.0 - t) * uniforms.color.a;
            float3 premultiplied = uniforms.color.rgb * alpha;
            return float4(premultiplied, alpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile SectorGradientRenderer shader: \(error)")
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
            fatalError("Failed to create SectorGradientRenderer pipeline: \(error)")
        }
    }

    func render(
        into texture: MTLTexture,
        center: CanvasPoint,
        radius: Double,
        startAngle: Double,
        sweepAngle: Double,
        isFullCircle: Bool,
        color: RGBAColor,
        commandQueue: MTLCommandQueue
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        encode(
            into: descriptor,
            commandBuffer: commandBuffer,
            canvasSize: .init(width: texture.width, height: texture.height),
            center: center,
            radius: radius,
            startAngle: startAngle,
            sweepAngle: sweepAngle,
            isFullCircle: isFullCircle,
            color: color
        )
        commandBuffer.commit()
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        center: CanvasPoint,
        radius: Double,
        startAngle: Double,
        sweepAngle: Double,
        isFullCircle: Bool,
        color: RGBAColor
    ) {
        guard radius > 0.5 else { return }

        let minX = max(Float(center.x - radius), 0)
        let minY = max(Float(center.y - radius), 0)
        let maxX = min(Float(center.x + radius), Float(canvasSize.width))
        let maxY = min(Float(center.y + radius), Float(canvasSize.height))

        let vertices: [SectorGradientVertex] = [
            .init(position: SIMD2(minX, minY)),
            .init(position: SIMD2(maxX, minY)),
            .init(position: SIMD2(minX, maxY)),
            .init(position: SIMD2(maxX, maxY))
        ]

        var uniforms = SectorGradientUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            center: SIMD2(Float(center.x), Float(center.y)),
            radius: Float(radius),
            startAngle: Float(startAngle),
            sweepAngle: Float(sweepAngle),
            isFullCircle: isFullCircle ? 1 : 0,
            color: SIMD4(color.red, color.green, color.blue, color.alpha)
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<SectorGradientVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SectorGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SectorGradientUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }
}
