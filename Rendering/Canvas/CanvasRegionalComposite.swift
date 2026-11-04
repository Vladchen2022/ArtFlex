import Foundation
import Metal

/// Owned by one canvas view. Only consecutive live brush frames with known write bounds
/// qualify. Metadata, resources, revisions, preview changes, or errors force full rendering.
final class CanvasRegionalComposite {
    static let isEnabled = true // Pixel parity and 2K/4K GPU workload comparisons gate this path.
    private var samplingMode: CanvasDisplaySamplingMode?

    private var cached: MTLTexture?
    private var update: MTLTexture?
    private var identities: [CanvasCompositeInputIdentity] = []
    private var revisions: [LayerChangeCursor] = []
    private var lastCommand: MTLCommandBuffer?
    private var queueID: ObjectIdentifier?
    private(set) var partialFrameCount = 0
    private(set) var fullFrameCount = 0

    func discard() {
        cached = nil; update = nil; identities = []; revisions = []; lastCommand = nil; queueID = nil
    }

    func encode(inputs: [CanvasLayerCompositeInput], revisions: [LayerChangeCursor],
                changedRegion: PixelRegion, canvasSize: CanvasSize, presenter: StageOneCanvasPresenter,
                sampling: CanvasDisplaySamplingMode, into pass: MTLRenderPassDescriptor,
                command: MTLCommandBuffer, budget: WorkingResourceBudget? = nil) -> Bool? {
        guard let target = pass.colorAttachments[0].texture,
              canvasSize.width > 0, canvasSize.height > 0,
              inputs.contains(where: { $0.blendMode != .normal || $0.layerMaskTexture != nil || $0.clipMaskTexture != nil || $0.curveAdjustmentLUTs != nil }),
              target.width * target.height * (target.pixelFormat == .rgba16Float ? 8 : 4) <= 128 * 1024 * 1024 else {
            discard(); return nil
        }
        let keys = inputs.map(CanvasCompositeInputIdentity.init)
        var needsFull = keys != identities || revisions != self.revisions || queueID != ObjectIdentifier(command.commandQueue)
            || lastCommand?.status == .error || samplingMode != sampling
        if cached?.width != target.width || cached?.height != target.height || cached?.pixelFormat != target.pixelFormat {
            discard()
            let bytes = target.width * target.height * (target.pixelFormat == .rgba16Float ? 8 : 4) * 2
            let reservation: WorkingResourceBudget.Reservation?
            do { reservation = try budget?.reserve(bytes: bytes, residentBytes: target.device.currentAllocatedSize) }
            catch { return nil }
            defer { withExtendedLifetime(reservation) {} }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: target.pixelFormat,
                width: target.width, height: target.height, mipmapped: false)
            descriptor.storageMode = .private; descriptor.usage = [.renderTarget, .shaderRead]
            cached = target.device.makeTexture(descriptor: descriptor)
            update = target.device.makeTexture(descriptor: descriptor)
            needsFull = true
        }
        guard let cached, let update else { discard(); return nil }
        let bounds = PixelRegion(originX: 0, originY: 0, width: target.width, height: target.height)
        let region = needsFull ? bounds : Self.project(changedRegion, from: canvasSize, to: bounds)
        guard !region.isEmpty else { return nil }
        let staging = MTLRenderPassDescriptor()
        staging.colorAttachments[0].texture = update
        staging.colorAttachments[0].loadAction = .clear
        staging.colorAttachments[0].storeAction = .store
        staging.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard presenter.encode(layerInputs: inputs, samplingMode: sampling, updateRegion: region,
                               into: staging, commandBuffer: command),
              let copy = command.makeBlitCommandEncoder() else { discard(); return false }
        copy.copy(from: update, sourceSlice: 0, sourceLevel: 0,
            sourceOrigin: .init(x: region.originX, y: region.originY, z: 0),
            sourceSize: .init(width: region.width, height: region.height, depth: 1),
            to: cached, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: .init(x: region.originX, y: region.originY, z: 0))
        copy.endEncoding()
        samplingMode = sampling; identities = keys; self.revisions = revisions; queueID = ObjectIdentifier(command.commandQueue); lastCommand = command
        if needsFull { fullFrameCount += 1 } else { partialFrameCount += 1 }
        PerformanceAuditStore.shared.recordInt("Canvas.compositeUpdatedPixels", value: region.width * region.height)
        PerformanceAuditStore.shared.recordInt("Canvas.compositeTotalPixels", value: target.width * target.height)
        return presenter.encode(layerTextures: [(cached, 1)], samplingMode: sampling, into: pass, commandBuffer: command)
    }

    /// Linear sampling touches adjacent source texels; expand before rounding to drawable pixels.
    static func project(_ region: PixelRegion, from canvas: CanvasSize, to target: PixelRegion) -> PixelRegion {
        let sx = Double(target.width) / Double(canvas.width), sy = Double(target.height) / Double(canvas.height)
        let x = max(0, Int(floor(Double(region.originX - 2) * sx)))
        let y = max(0, Int(floor(Double(region.originY - 2) * sy)))
        let right = min(target.width, Int(ceil(Double(region.maxX + 2) * sx)))
        let bottom = min(target.height, Int(ceil(Double(region.maxY + 2) * sy)))
        return .init(originX: x, originY: y, width: max(0, right - x), height: max(0, bottom - y))
    }
}
