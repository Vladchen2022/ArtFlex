import Foundation
@preconcurrency import Metal
import simd

private final class TransformTexturePairBox: @unchecked Sendable {
    let baseTexture: MTLTexture?
    let extractedTexture: MTLTexture?

    init(baseTexture: MTLTexture?, extractedTexture: MTLTexture?) {
        self.baseTexture = baseTexture
        self.extractedTexture = extractedTexture
    }
}

private final class TransformTextureBox: @unchecked Sendable {
    let texture: MTLTexture?

    init(_ texture: MTLTexture?) {
        self.texture = texture
    }
}

private struct TransformQuadVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

private struct TransformExtractUniforms {
    var sourceOriginNormalized: SIMD2<Float>
    var sourceSizeNormalized: SIMD2<Float>
    var hasMask: UInt32
    var _padding: UInt32 = 0
}

private struct TransformPunchOutUniforms {
    var hasMask: UInt32
    var _padding: SIMD3<UInt32> = .zero
}

enum TransformGPUCompositorInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(String, Error)
    case samplerStateCreation
    case canvasPresenter(Error)

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile TransformGPUCompositor shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing TransformGPUCompositor shader function: \(name)"
        case .pipelineState(let name, let error):
            return "Failed to create TransformGPUCompositor pipeline (\(name)): \(error.localizedDescription)"
        case .samplerStateCreation:
            return "Failed to create TransformGPUCompositor sampler state."
        case .canvasPresenter(let error):
            return "Failed to initialize TransformGPUCompositor presenter: \(error.localizedDescription)"
        }
    }
}

final class TransformGPUCompositor {
    private let device: MTLDevice
    private let extractPipelineState: MTLRenderPipelineState
    private let punchOutPipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState
    private let canvasPresenter: StageOneCanvasPresenter

    init(device: MTLDevice) throws {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct TransformQuadVertex {
            float2 position;
            float2 texCoord;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct TransformExtractUniforms {
            float2 sourceOriginNormalized;
            float2 sourceSizeNormalized;
            uint hasMask;
            uint padding;
        };

        struct TransformPunchOutUniforms {
            uint hasMask;
            uint3 padding;
        };

        vertex VertexOut transformQuadVertex(
            const device TransformQuadVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            out.texCoord = vertices[vertexID].texCoord;
            return out;
        }

        fragment float4 transformExtractFragment(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            texture2d<float> maskTexture [[texture(1)]],
            sampler layerSampler [[sampler(0)]],
            constant TransformExtractUniforms &uniforms [[buffer(0)]]
        ) {
            float2 sourceUV = uniforms.sourceOriginNormalized + (in.texCoord * uniforms.sourceSizeNormalized);
            float4 sampled = sourceTexture.sample(layerSampler, sourceUV);
            if (uniforms.hasMask == 0) {
                return sampled;
            }

            float mask = maskTexture.sample(layerSampler, in.texCoord).r;
            if (mask <= 0.001) {
                discard_fragment();
            }
            return sampled * mask;
        }

        fragment float4 transformPunchOutFragment(
            VertexOut in [[stage_in]],
            texture2d<float> maskTexture [[texture(0)]],
            sampler layerSampler [[sampler(0)]],
            constant TransformPunchOutUniforms &uniforms [[buffer(0)]]
        ) {
            if (uniforms.hasMask != 0) {
                float mask = maskTexture.sample(layerSampler, in.texCoord).r;
                if (mask <= 0.001) {
                    discard_fragment();
                }
            }
            return float4(0.0);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw TransformGPUCompositorInitializationError.shaderLibrary(error)
        }

        let extractDescriptor = MTLRenderPipelineDescriptor()
        guard
            let transformQuadVertex = library.makeFunction(name: "transformQuadVertex"),
            let transformExtractFragment = library.makeFunction(name: "transformExtractFragment")
        else {
            throw TransformGPUCompositorInitializationError.missingFunction("transformQuadVertex/transformExtractFragment")
        }
        extractDescriptor.vertexFunction = transformQuadVertex
        extractDescriptor.fragmentFunction = transformExtractFragment
        extractDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        extractDescriptor.colorAttachments[0].isBlendingEnabled = false
        do {
            extractPipelineState = try device.makeRenderPipelineState(descriptor: extractDescriptor)
        } catch {
            throw TransformGPUCompositorInitializationError.pipelineState("extract", error)
        }

        let punchOutDescriptor = MTLRenderPipelineDescriptor()
        guard let transformPunchOutFragment = library.makeFunction(name: "transformPunchOutFragment") else {
            throw TransformGPUCompositorInitializationError.missingFunction("transformPunchOutFragment")
        }
        punchOutDescriptor.vertexFunction = transformQuadVertex
        punchOutDescriptor.fragmentFunction = transformPunchOutFragment
        punchOutDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        punchOutDescriptor.colorAttachments[0].isBlendingEnabled = false
        do {
            punchOutPipelineState = try device.makeRenderPipelineState(descriptor: punchOutDescriptor)
        } catch {
            throw TransformGPUCompositorInitializationError.pipelineState("punchOut", error)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let samplerState = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw TransformGPUCompositorInitializationError.samplerStateCreation
        }
        self.samplerState = samplerState

        do {
            canvasPresenter = try StageOneCanvasPresenter(device: device)
        } catch {
            throw TransformGPUCompositorInitializationError.canvasPresenter(error)
        }
    }

    func buildSelectionTextures(
        sourceTexture: MTLTexture,
        canvasSize: CanvasSize,
        sourceBounds: CanvasRect,
        maskTexture: MTLTexture?,
        metal: MetalDeviceContext,
        completion: @escaping @MainActor (MTLTexture?, MTLTexture?) -> Void
    ) {
        let width = max(Int(sourceBounds.size.x.rounded(.up)), 1)
        let height = max(Int(sourceBounds.size.y.rounded(.up)), 1)

        guard
            let baseTexture = makeTexture(
                width: sourceTexture.width,
                height: sourceTexture.height,
                pixelFormat: sourceTexture.pixelFormat,
                usage: [.shaderRead, .renderTarget]
            ),
            let extractedTexture = makeTexture(
                width: width,
                height: height,
                pixelFormat: sourceTexture.pixelFormat,
                usage: [.shaderRead, .renderTarget]
            ),
            let commandBuffer = metal.commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            Task { @MainActor in
                completion(nil, nil)
            }
            return
        }

        let copySize = MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1)
        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: .init(x: 0, y: 0, z: 0),
            sourceSize: copySize,
            to: baseTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: .init(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()

        if let extractedPass = renderPassDescriptor(
            for: extractedTexture,
            loadAction: .clear,
            clearColor: .init(red: 0, green: 0, blue: 0, alpha: 0)
        ),
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: extractedPass) {
            var uniforms = TransformExtractUniforms(
                sourceOriginNormalized: .init(
                    Float(sourceBounds.minX / Double(max(canvasSize.width, 1))),
                    Float(sourceBounds.minY / Double(max(canvasSize.height, 1)))
                ),
                sourceSizeNormalized: .init(
                    Float(sourceBounds.size.x / Double(max(canvasSize.width, 1))),
                    Float(sourceBounds.size.y / Double(max(canvasSize.height, 1)))
                ),
                hasMask: maskTexture == nil ? 0 : 1
            )

            let vertices = fullScreenVertices()
            encoder.setRenderPipelineState(extractPipelineState)
            encoder.setVertexBytes(
                vertices,
                length: MemoryLayout<TransformQuadVertex>.stride * vertices.count,
                index: 0
            )
            encoder.setFragmentTexture(sourceTexture, index: 0)
            if let maskTexture {
                encoder.setFragmentTexture(maskTexture, index: 1)
            }
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<TransformExtractUniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        if let punchOutPass = renderPassDescriptor(
            for: baseTexture,
            loadAction: .load
        ),
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: punchOutPass) {
            var uniforms = TransformPunchOutUniforms(hasMask: maskTexture == nil ? 0 : 1)
            let vertices = quadVertices(
                bounds: sourceBounds,
                canvasSize: canvasSize
            )
            encoder.setRenderPipelineState(punchOutPipelineState)
            encoder.setVertexBytes(
                vertices,
                length: MemoryLayout<TransformQuadVertex>.stride * vertices.count,
                index: 0
            )
            if let maskTexture {
                encoder.setFragmentTexture(maskTexture, index: 0)
            }
            encoder.setFragmentSamplerState(samplerState, index: 0)
            encoder.setFragmentBytes(
                &uniforms,
                length: MemoryLayout<TransformPunchOutUniforms>.stride,
                index: 0
            )
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        let boxedTextures = TransformTexturePairBox(
            baseTexture: baseTexture,
            extractedTexture: extractedTexture
        )
        commandBuffer.addCompletedHandler { [boxedTextures] _ in
            Task { @MainActor in
                completion(boxedTextures.baseTexture, boxedTextures.extractedTexture)
            }
        }
        commandBuffer.commit()
    }

    func composeTransformedTexture(
        session: TransformPreviewSession,
        preview: FreeTransformPreview,
        canvasSize: CanvasSize,
        metal: MetalDeviceContext,
        completion: @escaping @MainActor (MTLTexture?) -> Void
    ) {
        guard
            let targetTexture = makeTexture(
                width: canvasSize.width,
                height: canvasSize.height,
                pixelFormat: .bgra8Unorm_srgb,
                usage: [.shaderRead, .renderTarget]
            ),
            let commandBuffer = metal.commandQueue.makeCommandBuffer()
        else {
            Task { @MainActor in
                completion(nil)
            }
            return
        }

        let clearPass = renderPassDescriptor(
            for: targetTexture,
            loadAction: .clear,
            clearColor: .init(red: 0, green: 0, blue: 0, alpha: 0)
        )!

        if session.mode == .selection, let baseTexture = session.baseTexture {
            canvasPresenter.encode(
                layerTextures: [(texture: baseTexture, opacity: 1)],
                into: clearPass,
                commandBuffer: commandBuffer
            )
        }

        let overlayPass = renderPassDescriptor(
            for: targetTexture,
            loadAction: session.mode == .selection ? .load : .clear,
            clearColor: .init(red: 0, green: 0, blue: 0, alpha: 0)
        )!

        canvasPresenter.encodePreview(
            texture: session.extractedTexture,
            opacity: 1,
            canvasSize: canvasSize,
            bounds: session.operationBounds,
            pivotBounds: session.interactionBounds ?? session.operationBounds,
            preview: preview,
            into: overlayPass,
            commandBuffer: commandBuffer
        )

        let boxedTexture = TransformTextureBox(targetTexture)
        commandBuffer.addCompletedHandler { [boxedTexture] _ in
            Task { @MainActor in
                completion(boxedTexture.texture)
            }
        }
        commandBuffer.commit()
    }

    private func makeTexture(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat,
        usage: MTLTextureUsage
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = usage
        return device.makeTexture(descriptor: descriptor)
    }

    private func renderPassDescriptor(
        for texture: MTLTexture,
        loadAction: MTLLoadAction,
        clearColor: MTLClearColor = .init(red: 0, green: 0, blue: 0, alpha: 0)
    ) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = loadAction
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor
        return descriptor
    }

    private func fullScreenVertices() -> [TransformQuadVertex] {
        [
            .init(position: .init(-1, -1), texCoord: .init(0, 1)),
            .init(position: .init(1, -1), texCoord: .init(1, 1)),
            .init(position: .init(-1, 1), texCoord: .init(0, 0)),
            .init(position: .init(1, 1), texCoord: .init(1, 0))
        ]
    }

    private func quadVertices(
        bounds: CanvasRect,
        canvasSize: CanvasSize
    ) -> [TransformQuadVertex] {
        let minX = Float((bounds.minX / Double(max(canvasSize.width, 1))) * 2 - 1)
        let maxX = Float((bounds.maxX / Double(max(canvasSize.width, 1))) * 2 - 1)
        let minY = Float((1 - (bounds.maxY / Double(max(canvasSize.height, 1)))) * 2 - 1)
        let maxY = Float((1 - (bounds.minY / Double(max(canvasSize.height, 1)))) * 2 - 1)
        return [
            .init(position: .init(minX, minY), texCoord: .init(0, 1)),
            .init(position: .init(maxX, minY), texCoord: .init(1, 1)),
            .init(position: .init(minX, maxY), texCoord: .init(0, 0)),
            .init(position: .init(maxX, maxY), texCoord: .init(1, 0))
        ]
    }
}
