import Foundation

struct CanvasRenderSnapshot: Sendable, Equatable {
    var document: ArtDocument
    var viewport: CanvasViewport
}

protocol CanvasRenderer {
    func render(snapshot: CanvasRenderSnapshot)
}
