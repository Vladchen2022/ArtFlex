import CoreGraphics
import Foundation
@preconcurrency import Metal
import simd

private struct PatternPlacementVertex {
    var position: SIMD2<Float>
    var textureCoordinate: SIMD2<Float>
}

private struct PatternPlacementUniforms {
    var canvasSize: SIMD2<Float>
    var opacity: Float
    var _padding: Float = 0
}

enum PatternPlacementRendererInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(Error)
    case samplerState

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile PatternPlacementRenderer shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing PatternPlacementRenderer shader function: \(name)"
        case .pipelineState(let error):
            return "Failed to create PatternPlacementRenderer pipeline: \(error.localizedDescription)"
        case .samplerState:
            return "Failed to create PatternPlacementRenderer sampler state."
        }
    }
}

final class PatternPlacementRenderer {
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState

    init(device: MTLDevice) throws {
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct PatternPlacementVertex {
            float2 position;
            float2 textureCoordinate;
        };

        struct PatternPlacementUniforms {
            float2 canvasSize;
            float opacity;
            float padding;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 textureCoordinate;
        };

        vertex VertexOut patternPlacementVertex(
            const device PatternPlacementVertex *vertices [[buffer(0)]],
            constant PatternPlacementUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            PatternPlacementVertex inputVertex = vertices[vertexID];
            float2 normalized = float2(
                (inputVertex.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (inputVertex.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            VertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.textureCoordinate = inputVertex.textureCoordinate;
            return out;
        }

        fragment float4 patternPlacementFragment(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            sampler sourceSampler [[sampler(0)]],
            constant PatternPlacementUniforms &uniforms [[buffer(1)]]
        ) {
            float4 sampled = sourceTexture.sample(sourceSampler, in.textureCoordinate);
            return sampled * uniforms.opacity;
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw PatternPlacementRendererInitializationError.shaderLibrary(error)
        }

        guard
            let vertexFunction = library.makeFunction(name: "patternPlacementVertex"),
            let fragmentFunction = library.makeFunction(name: "patternPlacementFragment")
        else {
            throw PatternPlacementRendererInitializationError.missingFunction(
                "patternPlacementVertex/patternPlacementFragment"
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
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
            throw PatternPlacementRendererInitializationError.pipelineState(error)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw PatternPlacementRendererInitializationError.samplerState
        }
        self.samplerState = samplerState
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        sourceTexture: MTLTexture,
        canvasSize: CanvasSize,
        destinationRect: CGRect,
        flipHorizontally: Bool = false,
        opacity: Float = 1
    ) {
        let standardizedRect = destinationRect.standardized
        guard let renderTargetTexture = renderPassDescriptor.colorAttachments[0].texture else {
            return
        }
        guard let scissorRect = patternPlacementScissorRect(
            destinationRect: standardizedRect,
            canvasSize: canvasSize,
            renderTargetWidth: renderTargetTexture.width,
            renderTargetHeight: renderTargetTexture.height
        ) else {
            return
        }

        let textureCoordinates = patternPlacementTextureCoordinates(flipHorizontally: flipHorizontally)
        let vertices: [PatternPlacementVertex] = [
            .init(
                position: SIMD2(Float(standardizedRect.minX), Float(standardizedRect.minY)),
                textureCoordinate: textureCoordinates.topLeft
            ),
            .init(
                position: SIMD2(Float(standardizedRect.maxX), Float(standardizedRect.minY)),
                textureCoordinate: textureCoordinates.topRight
            ),
            .init(
                position: SIMD2(Float(standardizedRect.minX), Float(standardizedRect.maxY)),
                textureCoordinate: textureCoordinates.bottomLeft
            ),
            .init(
                position: SIMD2(Float(standardizedRect.maxX), Float(standardizedRect.maxY)),
                textureCoordinate: textureCoordinates.bottomRight
            )
        ]
        var uniforms = PatternPlacementUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            opacity: min(max(opacity, 0), 1)
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<PatternPlacementVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<PatternPlacementUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PatternPlacementUniforms>.stride,
            index: 1
        )
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setScissorRect(scissorRect)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }
}

func patternPlacementScissorRect(
    destinationRect: CGRect,
    canvasSize: CanvasSize,
    renderTargetWidth: Int,
    renderTargetHeight: Int
) -> MTLScissorRect? {
    let standardizedRect = destinationRect.standardized
    let canvasBounds = CGRect(
        x: 0,
        y: 0,
        width: canvasSize.width,
        height: canvasSize.height
    )
    let clippedRect = standardizedRect.intersection(canvasBounds)

    guard !clippedRect.isNull,
          clippedRect.width > 0,
          clippedRect.height > 0 else {
        return nil
    }

    let safeCanvasWidth = max(canvasSize.width, 1)
    let safeCanvasHeight = max(canvasSize.height, 1)
    let targetWidth = max(renderTargetWidth, 1)
    let targetHeight = max(renderTargetHeight, 1)

    let minX = max(0, min(targetWidth, Int(((clippedRect.minX / Double(safeCanvasWidth)) * Double(targetWidth)).rounded(.down))))
    let minY = max(0, min(targetHeight, Int(((clippedRect.minY / Double(safeCanvasHeight)) * Double(targetHeight)).rounded(.down))))
    let maxX = max(minX, min(targetWidth, Int(((clippedRect.maxX / Double(safeCanvasWidth)) * Double(targetWidth)).rounded(.up))))
    let maxY = max(minY, min(targetHeight, Int(((clippedRect.maxY / Double(safeCanvasHeight)) * Double(targetHeight)).rounded(.up))))

    guard maxX > minX, maxY > minY else {
        return nil
    }

    return MTLScissorRect(
        x: minX,
        y: minY,
        width: maxX - minX,
        height: maxY - minY
    )
}

struct PatternPlacementTextureCoordinates {
    var topLeft: SIMD2<Float>
    var topRight: SIMD2<Float>
    var bottomLeft: SIMD2<Float>
    var bottomRight: SIMD2<Float>
}

func patternPlacementTextureCoordinates(flipHorizontally: Bool) -> PatternPlacementTextureCoordinates {
    if flipHorizontally {
        return PatternPlacementTextureCoordinates(
            topLeft: SIMD2(1, 0),
            topRight: SIMD2(0, 0),
            bottomLeft: SIMD2(1, 1),
            bottomRight: SIMD2(0, 1)
        )
    }

    return PatternPlacementTextureCoordinates(
        topLeft: SIMD2(0, 0),
        topRight: SIMD2(1, 0),
        bottomLeft: SIMD2(0, 1),
        bottomRight: SIMD2(1, 1)
    )
}
