import Foundation
import Metal

final class LayerMergeController {
    private let metalContext: MetalDeviceContext
    private let canvasPresenter: StageOneCanvasPresenter

    init(
        metalContext: MetalDeviceContext,
        canvasPresenter: StageOneCanvasPresenter
    ) {
        self.metalContext = metalContext
        self.canvasPresenter = canvasPresenter
    }

    func merge(
        sourceTexture: MTLTexture,
        sourceOpacity: Float,
        sourceVisible: Bool,
        into destinationTexture: MTLTexture,
        destinationOpacity: Float,
        destinationVisible: Bool
    ) throws {
        try composite(
            layers: [
                (texture: destinationTexture, opacity: destinationOpacity, isVisible: destinationVisible),
                (texture: sourceTexture, opacity: sourceOpacity, isVisible: sourceVisible)
            ],
            into: destinationTexture
        )
    }

    func mergeVisible(
        layers: [(texture: MTLTexture, opacity: Float, isVisible: Bool)],
        into targetTexture: MTLTexture
    ) throws {
        try composite(layers: layers, into: targetTexture)
    }

    private func composite(
        layers: [(texture: MTLTexture, opacity: Float, isVisible: Bool)],
        into targetTexture: MTLTexture
    ) throws {
        guard let first = layers.first else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard layers.allSatisfy({
            $0.texture.width == first.texture.width &&
            $0.texture.height == first.texture.height &&
            $0.texture.pixelFormat == first.texture.pixelFormat
        }) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let compositeInputs = layers.compactMap { layer -> (texture: MTLTexture, opacity: Float)? in
            let effectiveOpacity = layer.isVisible ? layer.opacity : 0
            guard effectiveOpacity > 0 else { return nil }
            return (texture: layer.texture, opacity: effectiveOpacity)
        }

        guard !compositeInputs.isEmpty else {
            try clear(texture: targetTexture)
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: first.texture.pixelFormat,
            width: first.texture.width,
            height: first.texture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private

        guard let compositeTexture = metalContext.device.makeTexture(descriptor: descriptor) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = compositeTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )

        guard
            let commandBuffer = metalContext.commandQueue.makeCommandBuffer()
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        canvasPresenter.encode(
            layerTextures: compositeInputs,
            into: renderPassDescriptor,
            commandBuffer: commandBuffer
        )

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw CocoaError(.fileWriteUnknown)
        }

        blitEncoder.copy(
            from: compositeTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: compositeTexture.width, height: compositeTexture.height, depth: 1),
            to: targetTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }

    private func clear(texture: MTLTexture) throws {
        guard let commandBuffer = metalContext.commandQueue.makeCommandBuffer() else {
            throw CocoaError(.fileWriteUnknown)
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw CocoaError(.fileWriteUnknown)
        }

        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
