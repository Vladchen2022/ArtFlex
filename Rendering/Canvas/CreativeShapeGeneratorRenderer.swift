import Foundation
import Metal
import simd

private struct CreativeShapeGeneratorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct CreativeShapeGeneratorUniforms {
    var canvasSize: SIMD2<Float>
    var usesAlphaLock: Float
}

final class CreativeShapeGeneratorRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let fallbackAlphaLockTexture: MTLTexture

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct CreativeShapeGeneratorVertex {
            float2 position;
            float4 color;
        };

        struct CreativeShapeGeneratorUniforms {
            float2 canvasSize;
            float usesAlphaLock;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
            float4 color;
        };

        vertex VertexOut creativeShapeGeneratorVertexShader(
            const device CreativeShapeGeneratorVertex *vertices [[buffer(0)]],
            constant CreativeShapeGeneratorUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            CreativeShapeGeneratorVertex vertexData = vertices[vertexID];
            float2 normalized = float2(
                (vertexData.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (vertexData.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            VertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.canvasPosition = vertexData.position;
            out.color = vertexData.color;
            return out;
        }

        fragment float4 creativeShapeGeneratorFragmentShader(
            VertexOut in [[stage_in]],
            constant CreativeShapeGeneratorUniforms &uniforms [[buffer(1)]],
            texture2d<float> alphaLockTexture [[texture(0)]]
        ) {
            if (uniforms.usesAlphaLock > 0.5) {
                constexpr sampler alphaSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 canvasUV = in.canvasPosition / canvasSize;
                if (alphaLockTexture.sample(alphaSampler, canvasUV).a <= 0.001) {
                    return float4(0.0);
                }
            }
            return in.color;
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile CreativeShapeGeneratorRenderer shader: \(error)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "creativeShapeGeneratorVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "creativeShapeGeneratorFragmentShader")
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
            fatalError("Failed to create CreativeShapeGeneratorRenderer pipeline: \(error)")
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = .shaderRead
        fallbackDescriptor.storageMode = .shared
        guard let fallbackTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            fatalError("Failed to create CreativeShapeGeneratorRenderer alpha fallback texture.")
        }
        let fullAlphaPixel: [UInt8] = [255, 255, 255, 255]
        fallbackTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: fullAlphaPixel,
            bytesPerRow: 4
        )
        fallbackAlphaLockTexture = fallbackTexture
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        shapes: [CreativeShapeGeneratedShape],
        alphaLockTexture: MTLTexture? = nil
    ) {
        let vertices = triangleVertices(for: shapes)
        guard vertices.isEmpty == false else { return }
        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<CreativeShapeGeneratorVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            return
        }

        var uniforms = CreativeShapeGeneratorUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            usesAlphaLock: alphaLockTexture == nil ? 0 : 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<CreativeShapeGeneratorUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CreativeShapeGeneratorUniforms>.stride, index: 1)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 0)
        let scissorRect = bounds(for: vertices, canvasSize: canvasSize)
        if scissorRect.width > 0, scissorRect.height > 0 {
            encoder.setScissorRect(scissorRect)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    private func triangleVertices(for shapes: [CreativeShapeGeneratedShape]) -> [CreativeShapeGeneratorVertex] {
        var vertices: [CreativeShapeGeneratorVertex] = []
        for shape in shapes {
            guard shape.boundaryPoints.count >= 3 else { continue }
            let premultiplied = shape.color.premultiplied
            let color = SIMD4(premultiplied.red, premultiplied.green, premultiplied.blue, premultiplied.alpha)
            let transparentColor = SIMD4<Float>(repeating: 0)
            let center = SIMD2(Float(shape.center.x), Float(shape.center.y))
            let points = shape.boundaryPoints
            let featherAmount = max(0, min(shape.featherAmount, 0.45))

            if featherAmount > 0.001 {
                let innerPoints: [SIMD2<Float>] = points.map { point in
                    let outer = SIMD2(Float(point.x), Float(point.y))
                    let delta = outer - center
                    return center + (delta * (1 - featherAmount))
                }

                for index in 0..<points.count {
                    let currentInner = innerPoints[index]
                    let nextInner = innerPoints[(index + 1) % innerPoints.count]
                    vertices.append(.init(position: center, color: color))
                    vertices.append(.init(position: currentInner, color: color))
                    vertices.append(.init(position: nextInner, color: color))
                }

                for index in 0..<points.count {
                    let currentOuter = SIMD2(Float(points[index].x), Float(points[index].y))
                    let nextOuter = SIMD2(Float(points[(index + 1) % points.count].x), Float(points[(index + 1) % points.count].y))
                    let currentInner = innerPoints[index]
                    let nextInner = innerPoints[(index + 1) % innerPoints.count]

                    vertices.append(.init(position: currentInner, color: color))
                    vertices.append(.init(position: currentOuter, color: transparentColor))
                    vertices.append(.init(position: nextOuter, color: transparentColor))

                    vertices.append(.init(position: currentInner, color: color))
                    vertices.append(.init(position: nextOuter, color: transparentColor))
                    vertices.append(.init(position: nextInner, color: color))
                }
            } else {
                for index in 0..<points.count {
                    let current = points[index]
                    let next = points[(index + 1) % points.count]
                    vertices.append(.init(position: center, color: color))
                    vertices.append(.init(position: SIMD2(Float(current.x), Float(current.y)), color: color))
                    vertices.append(.init(position: SIMD2(Float(next.x), Float(next.y)), color: color))
                }
            }
        }
        return vertices
    }

    private func bounds(for vertices: [CreativeShapeGeneratorVertex], canvasSize: CanvasSize) -> MTLScissorRect {
        guard let first = vertices.first else {
            return MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
        }
        var minX = Int(floor(Double(first.position.x)))
        var minY = Int(floor(Double(first.position.y)))
        var maxX = Int(ceil(Double(first.position.x)))
        var maxY = Int(ceil(Double(first.position.y)))

        for vertex in vertices.dropFirst() {
            minX = min(minX, Int(floor(Double(vertex.position.x))))
            minY = min(minY, Int(floor(Double(vertex.position.y))))
            maxX = max(maxX, Int(ceil(Double(vertex.position.x))))
            maxY = max(maxY, Int(ceil(Double(vertex.position.y))))
        }

        minX = max(minX, 0)
        minY = max(minY, 0)
        maxX = min(maxX, canvasSize.width)
        maxY = min(maxY, canvasSize.height)

        return MTLScissorRect(
            x: max(minX, 0),
            y: max(minY, 0),
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }
}
