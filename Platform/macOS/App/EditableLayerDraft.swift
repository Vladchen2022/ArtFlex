import AppKit
import Metal

private struct EditableLayerRenderResult: @unchecked Sendable {
    let content: EditableLayerContent
    let texture: MTLTexture
    let image: CGImage?
    let retained: [RetainedCropTile]?
}

@MainActor
final class EditableLayerDraft: ObservableObject, Identifiable {
    let id = UUID()
    let layerID: LayerID
    let canvas: CanvasSize
    @Published var content: EditableLayerContent { didSet { updatePreview() } }
    @Published private(set) var preview: CGImage?
    @Published private(set) var isComputing = false
    @Published private(set) var error: String?
    private let renderer: EditableLayerRenderer
    private let serializer: LayerTextureSerializer
    private let makeImage: @Sendable (LayerTextureSnapshot) -> CGImage?
    private let retainedBounds: PixelRegion?
    private let publish: (EditableLayerContent, MTLTexture, [RetainedCropTile]?) -> Bool
    private let coordinator = LatestPreviewCoordinator<EditableLayerRenderResult>()
    private var rendered: EditableLayerRenderResult?

    init(layerID: LayerID, content: EditableLayerContent, canvas: CanvasSize,
         renderer: EditableLayerRenderer, serializer: LayerTextureSerializer, retainedBounds: PixelRegion?,
         makeImage: @escaping @Sendable (LayerTextureSnapshot) -> CGImage?,
         publish: @escaping (EditableLayerContent, MTLTexture, [RetainedCropTile]?) -> Bool) {
        self.layerID = layerID; self.content = content; self.canvas = canvas
        self.renderer = renderer; self.serializer = serializer; self.makeImage = makeImage; self.publish = publish
        self.retainedBounds = retainedBounds
        updatePreview()
    }

    var canApply: Bool { !isComputing && error == nil && rendered?.content == content }

    func updatePreview() {
        isComputing = true; error = nil
        let content = content, canvas = canvas, renderer = renderer, makeImage = makeImage
        let layerID = layerID, retainedBounds = retainedBounds
        let serializer = WorkspaceUncheckedBox(serializer)
        coordinator.submit { cancellation in
            let result = try renderer.renderRetainingCrop(content, canvas: canvas, layerID: layerID, retainedBounds: retainedBounds, cancellation: cancellation)
            let texture = result.texture
            let divisor = max(1, (max(canvas.width, canvas.height) + 599) / 600)
            let snapshot = try serializer.value.downsampledSnapshot(texture: texture, divisor: divisor)
            try cancellation.check()
            return EditableLayerRenderResult(content: content, texture: texture, image: makeImage(snapshot), retained: result.retained)
        } completion: { [weak self] result in
            guard let self else { return }
            self.isComputing = false
            switch result {
            case .success(let rendered): self.rendered = rendered; self.preview = rendered.image
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    func apply() -> Bool {
        guard canApply, let rendered else { return false }
        return publish(content, rendered.texture, rendered.retained)
    }

    func cancel() { coordinator.cancel(); rendered = nil; preview = nil }
}
