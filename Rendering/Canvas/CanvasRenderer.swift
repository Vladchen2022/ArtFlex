import Foundation

struct CanvasRenderSnapshot: Sendable, Equatable {
    var document: ArtDocument
    var viewport: CanvasViewport
    var canvasContentRevision: UInt64 = 0
    var viewportRevision: UInt64 = 0
}

protocol CanvasRenderer {
    func render(snapshot: CanvasRenderSnapshot)
}
