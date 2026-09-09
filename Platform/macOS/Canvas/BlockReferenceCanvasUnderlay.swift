import Metal
import Foundation

/// Transient display resource; never enters document surfaces, sampling, history or export.
@MainActor
final class BlockReferenceCanvasUnderlay {
    private let context: MetalDeviceContext
    private let renderer: BlockReferenceMetalSolidRenderer
    private var colorTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var cachedScene: BlockReferenceScene?
    private var cachedCanvasSize: CanvasSize?
    private var cachedViewportSize: CGSize?
    private var renderingCommandBuffer: MTLCommandBuffer?

    init(context: MetalDeviceContext) throws {
        self.context = context
        renderer = try BlockReferenceMetalSolidRenderer(context: context)
    }

    func texture(scene: BlockReferenceScene, canvasSize: CanvasSize, width: Int, height: Int,
                 viewportSize: CGSize, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard width > 0, height > 0, viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        if colorTexture?.width != width || colorTexture?.height != height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm_srgb, width: width, height: height, mipmapped: false)
            descriptor.storageMode = .private
            descriptor.usage = [.renderTarget, .shaderRead]
            colorTexture = context.device.makeTexture(descriptor: descriptor)
            colorTexture?.label = "Block Reference Display Underlay"
            descriptor.pixelFormat = .depth32Float
            descriptor.usage = .renderTarget
            depthTexture = context.device.makeTexture(descriptor: descriptor)
            cachedScene = nil
        }
        guard let colorTexture, let depthTexture else { return nil }
        if cachedScene == scene, cachedCanvasSize == canvasSize, cachedViewportSize == viewportSize,
           renderingCommandBuffer?.status != .error {
            return colorTexture
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        let transform = CanvasViewportTransform(canvasSize: canvasSize, viewport: .stageOneDefault,
            availableWidth: viewportSize.width, availableHeight: viewportSize.height, padding: 0)
        guard renderer.encode(scene: scene, editorState: .init(), selectedObjectIDs: [],
                              transform: transform, viewportSize: viewportSize,
                              into: pass, commandBuffer: commandBuffer) else {
            cachedScene = nil
            return nil
        }
        cachedScene = scene
        cachedCanvasSize = canvasSize
        cachedViewportSize = viewportSize
        renderingCommandBuffer = commandBuffer
        return colorTexture
    }
}
