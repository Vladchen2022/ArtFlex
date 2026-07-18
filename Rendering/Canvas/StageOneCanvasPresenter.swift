import Foundation
import Metal
import simd

enum CanvasDisplaySamplingMode: Sendable, Equatable {
    case linear
    case nearest
}

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

struct CanvasLayerCompositeInput {
    var texture: MTLTexture
    var opacity: Float
    var blendMode: LayerBlendMode = .normal
    var clipMaskTexture: MTLTexture? = nil
}

private struct CanvasBlendUniforms {
    var layerOpacity: Float
    var blendMode: UInt32
    var usesClipMask: UInt32
    var _padding: UInt32 = 0
}

private final class CanvasCompositeTexturePair: @unchecked Sendable {
    let first: MTLTexture
    let second: MTLTexture
    var isInUse = false

    init(first: MTLTexture, second: MTLTexture) {
        self.first = first
        self.second = second
    }
}

final class StageOneCanvasPresenter: @unchecked Sendable {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let blendPipelineState: MTLRenderPipelineState
    private let checkerboardPipelineState: MTLRenderPipelineState
    private let linearSamplerState: MTLSamplerState
    private let nearestSamplerState: MTLSamplerState
    private let canvasVertexBuffer: MTLBuffer
    private let compositePoolLock = NSLock()
    private var compositeTexturePool: [CanvasCompositeTexturePair] = []

    init(device: MTLDevice) throws {
        self.device = device
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

        fragment float4 canvasCheckerboardFragment(VertexOut in [[stage_in]]) {
            const float squareSize = 12.0;
            uint2 square = uint2(floor(in.position.xy / squareSize));
            bool alternate = ((square.x + square.y) & 1u) != 0u;
            float value = alternate ? 0.72 : 0.84;
            return float4(value, value, value, 1.0);
        }

        struct CanvasBlendUniforms {
            float layerOpacity;
            uint blendMode;
            uint usesClipMask;
            uint padding;
        };

        float3 canvasSoftLight(float3 backdrop, float3 source) {
            float3 low = backdrop - (1.0 - 2.0 * source) * backdrop * (1.0 - backdrop);
            float3 d = select(sqrt(backdrop), ((16.0 * backdrop - 12.0) * backdrop + 4.0) * backdrop, backdrop <= 0.25);
            float3 high = backdrop + (2.0 * source - 1.0) * (d - backdrop);
            return select(high, low, source <= 0.5);
        }

        float3 canvasBlendColor(float3 backdrop, float3 source, uint mode) {
            switch (mode) {
                case 1: return backdrop * source;
                case 2: return backdrop + source - backdrop * source;
                case 3: return min(float3(1.0), backdrop + source);
                case 4: return select(
                    1.0 - 2.0 * (1.0 - backdrop) * (1.0 - source),
                    2.0 * backdrop * source,
                    backdrop <= 0.5
                );
                case 5: return canvasSoftLight(backdrop, source);
                case 6: return min(backdrop, source);
                case 7: return max(backdrop, source);
                default: return source;
            }
        }

        fragment float4 canvasBlendFragment(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            texture2d<float> backdropTexture [[texture(1)]],
            texture2d<float> clipMaskTexture [[texture(2)]],
            sampler layerSampler [[sampler(0)]],
            constant CanvasBlendUniforms &uniforms [[buffer(0)]]
        ) {
            float4 sourceSample = sourceTexture.sample(layerSampler, in.texCoord);
            float4 backdrop = backdropTexture.sample(layerSampler, in.texCoord);
            float clipAlpha = uniforms.usesClipMask != 0
                ? clipMaskTexture.sample(layerSampler, in.texCoord).a
                : 1.0;
            float opacity = clamp(uniforms.layerOpacity, 0.0, 1.0) * clipAlpha;
            float4 source = float4(sourceSample.rgb * opacity, sourceSample.a * opacity);
            float sourceAlpha = source.a;
            float backdropAlpha = backdrop.a;
            float3 straightSource = sourceAlpha > 0.00001 ? source.rgb / sourceAlpha : float3(0.0);
            float3 straightBackdrop = backdropAlpha > 0.00001 ? backdrop.rgb / backdropAlpha : float3(0.0);
            float3 blended = canvasBlendColor(straightBackdrop, straightSource, uniforms.blendMode);
            float outAlpha = sourceAlpha + backdropAlpha * (1.0 - sourceAlpha);
            float3 outColor =
                (1.0 - sourceAlpha) * backdrop.rgb +
                (1.0 - backdropAlpha) * source.rgb +
                sourceAlpha * backdropAlpha * blended;
            return float4(outColor, outAlpha);
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

        let blendDescriptor = MTLRenderPipelineDescriptor()
        blendDescriptor.vertexFunction = vertexFunction
        blendDescriptor.fragmentFunction = library.makeFunction(name: "canvasBlendFragment")
        blendDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        do {
            blendPipelineState = try device.makeRenderPipelineState(descriptor: blendDescriptor)
        } catch {
            throw StageOneCanvasPresenterInitializationError.pipelineState(error)
        }


        let checkerboardDescriptor = MTLRenderPipelineDescriptor()
        checkerboardDescriptor.vertexFunction = vertexFunction
        checkerboardDescriptor.fragmentFunction = library.makeFunction(name: "canvasCheckerboardFragment")
        checkerboardDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        do {
            checkerboardPipelineState = try device.makeRenderPipelineState(descriptor: checkerboardDescriptor)
        } catch {
            throw StageOneCanvasPresenterInitializationError.pipelineState(error)
        }

        let linearSamplerDescriptor = MTLSamplerDescriptor()
        linearSamplerDescriptor.minFilter = .linear
        linearSamplerDescriptor.magFilter = .linear
        linearSamplerDescriptor.sAddressMode = .clampToEdge
        linearSamplerDescriptor.tAddressMode = .clampToEdge
        let nearestSamplerDescriptor = MTLSamplerDescriptor()
        nearestSamplerDescriptor.minFilter = .nearest
        nearestSamplerDescriptor.magFilter = .nearest
        nearestSamplerDescriptor.sAddressMode = .clampToEdge
        nearestSamplerDescriptor.tAddressMode = .clampToEdge
        guard let linearSamplerState = device.makeSamplerState(descriptor: linearSamplerDescriptor),
              let nearestSamplerState = device.makeSamplerState(descriptor: nearestSamplerDescriptor) else {
            throw StageOneCanvasPresenterInitializationError.samplerStateCreation
        }
        self.linearSamplerState = linearSamplerState
        self.nearestSamplerState = nearestSamplerState

        var vertices = [
            CanvasPresenterVertex(position: SIMD2(-1, -1), texCoord: SIMD2(0, 1)),
            CanvasPresenterVertex(position: SIMD2(1, -1), texCoord: SIMD2(1, 1)),
            CanvasPresenterVertex(position: SIMD2(-1, 1), texCoord: SIMD2(0, 0)),
            CanvasPresenterVertex(position: SIMD2(1, 1), texCoord: SIMD2(1, 0))
        ]
        guard let vertexBuffer = device.makeBuffer(
            bytes: &vertices,
            length: MemoryLayout<CanvasPresenterVertex>.stride * vertices.count,
            options: .storageModeShared
        ) else {
            throw StageOneCanvasPresenterInitializationError.samplerStateCreation
        }
        self.canvasVertexBuffer = vertexBuffer
    }

    func encodeBackground(
        checkerboard: Bool,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        if checkerboard {
            encoder.setRenderPipelineState(checkerboardPipelineState)
            encoder.setVertexBuffer(canvasVertexBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }

    func encode(
        layerTextures: [(texture: MTLTexture, opacity: Float)],
        samplingMode: CanvasDisplaySamplingMode = .linear,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentSamplerState(
            samplingMode == .nearest ? nearestSamplerState : linearSamplerState,
            index: 0
        )
        encoder.setVertexBuffer(canvasVertexBuffer, offset: 0, index: 0)

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

    func encode(
        layerInputs: [CanvasLayerCompositeInput],
        samplingMode: CanvasDisplaySamplingMode = .linear,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        let visibleInputs = layerInputs.filter { $0.opacity > 0 }
        guard !visibleInputs.isEmpty else { return }

        if visibleInputs.allSatisfy({ $0.blendMode == .normal && $0.clipMaskTexture == nil }) {
            encode(
                layerTextures: visibleInputs.map { ($0.texture, $0.opacity) },
                samplingMode: samplingMode,
                into: renderPassDescriptor,
                commandBuffer: commandBuffer
            )
            return
        }

        guard let targetTexture = renderPassDescriptor.colorAttachments[0].texture,
              let texturePair = acquireCompositeTexturePair(
                width: targetTexture.width,
                height: targetTexture.height,
                pixelFormat: targetTexture.pixelFormat
              ) else {
            encode(
                layerTextures: visibleInputs.map { ($0.texture, $0.opacity) },
                samplingMode: samplingMode,
                into: renderPassDescriptor,
                commandBuffer: commandBuffer
            )
            return
        }

        clear(texturePair.first, commandBuffer: commandBuffer)
        var backdrop = texturePair.first
        var output = texturePair.second
        let sampler = samplingMode == .nearest ? nearestSamplerState : linearSamplerState

        for input in visibleInputs {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { continue }
            encoder.setRenderPipelineState(blendPipelineState)
            encoder.setVertexBuffer(canvasVertexBuffer, offset: 0, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.setFragmentTexture(input.texture, index: 0)
            encoder.setFragmentTexture(backdrop, index: 1)
            encoder.setFragmentTexture(input.clipMaskTexture ?? input.texture, index: 2)
            var uniforms = CanvasBlendUniforms(
                layerOpacity: input.opacity,
                blendMode: blendModeIndex(input.blendMode),
                usesClipMask: input.clipMaskTexture == nil ? 0 : 1
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CanvasBlendUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            swap(&backdrop, &output)
        }

        guard let finalEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            releaseCompositeTexturePair(texturePair)
            return
        }
        finalEncoder.setRenderPipelineState(pipelineState)
        finalEncoder.setVertexBuffer(canvasVertexBuffer, offset: 0, index: 0)
        finalEncoder.setFragmentSamplerState(sampler, index: 0)
        finalEncoder.setFragmentTexture(backdrop, index: 0)
        var finalUniforms = CanvasPresenterUniforms(layerOpacity: 1)
        finalEncoder.setFragmentBytes(
            &finalUniforms,
            length: MemoryLayout<CanvasPresenterUniforms>.stride,
            index: 0
        )
        finalEncoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        finalEncoder.endEncoding()

        commandBuffer.addCompletedHandler { [weak self, weak texturePair] _ in
            guard let self, let texturePair else { return }
            self.releaseCompositeTexturePair(texturePair)
        }
    }

    private func blendModeIndex(_ blendMode: LayerBlendMode) -> UInt32 {
        switch blendMode {
        case .normal: 0
        case .multiply: 1
        case .screen: 2
        case .add: 3
        case .overlay: 4
        case .softLight: 5
        case .darken: 6
        case .lighten: 7
        }
    }

    private func acquireCompositeTexturePair(
        width: Int,
        height: Int,
        pixelFormat: MTLPixelFormat
    ) -> CanvasCompositeTexturePair? {
        compositePoolLock.lock()
        defer { compositePoolLock.unlock() }
        if let pair = compositeTexturePool.first(where: {
            !$0.isInUse && $0.first.width == width && $0.first.height == height && $0.first.pixelFormat == pixelFormat
        }) {
            pair.isInUse = true
            return pair
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        guard let first = device.makeTexture(descriptor: descriptor),
              let second = device.makeTexture(descriptor: descriptor) else { return nil }
        let pair = CanvasCompositeTexturePair(first: first, second: second)
        pair.isInUse = true
        compositeTexturePool.append(pair)
        return pair
    }

    private func releaseCompositeTexturePair(_ pair: CanvasCompositeTexturePair) {
        compositePoolLock.lock()
        pair.isInUse = false
        compositePoolLock.unlock()
    }

    private func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass)
        encoder?.endEncoding()
    }

    func encodePreview(
        texture: MTLTexture,
        opacity: Float,
        canvasSize: CanvasSize,
        bounds: CanvasRect,
        pivotBounds: CanvasRect? = nil,
        preview: FreeTransformPreview,
        samplingMode: CanvasDisplaySamplingMode = .linear,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let corners = freeTransformCornerPoints(
            bounds: bounds,
            preview: preview,
            pivotBounds: pivotBounds
        )
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
        encoder.setFragmentSamplerState(
            samplingMode == .nearest ? nearestSamplerState : linearSamplerState,
            index: 0
        )

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

    func encodeMeshPreview(
        texture: MTLTexture,
        opacity: Float,
        canvasSize: CanvasSize,
        grid: MeshWarpGrid,
        textureCoordinateBounds: CanvasRect,
        samplingMode: CanvasDisplaySamplingMode = .linear,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let meshVertices = grid.tessellatedVertices()
        guard !meshVertices.isEmpty else {
            encoder.endEncoding()
            return
        }
        let vertices = meshVertices.map { vertex in
            CanvasPresenterVertex(
                position: ndcPoint(vertex.canvasPosition, canvasSize: canvasSize),
                texCoord: SIMD2(
                    Float(
                        textureCoordinateBounds.minX +
                        (vertex.textureCoordinate.x * textureCoordinateBounds.size.x)
                    ),
                    Float(
                        textureCoordinateBounds.minY +
                        (vertex.textureCoordinate.y * textureCoordinateBounds.size.y)
                    )
                )
            )
        }

        let vertexBufferLength = MemoryLayout<CanvasPresenterVertex>.stride * vertices.count
        let vertexBuffer = vertices.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: vertexBufferLength,
                options: .storageModeShared
            )
        }
        guard let vertexBuffer else {
            encoder.endEncoding()
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentSamplerState(
            samplingMode == .nearest ? nearestSamplerState : linearSamplerState,
            index: 0
        )

        var uniforms = CanvasPresenterUniforms(layerOpacity: opacity)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<CanvasPresenterUniforms>.stride,
            index: 0
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
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
