import Foundation

struct CanvasLayerPickCandidate: Identifiable, Sendable, Equatable {
    let id: LayerID
    let name: String
    let groupPath: String
    let isLocked: Bool
    let isEditableFill: Bool
}
