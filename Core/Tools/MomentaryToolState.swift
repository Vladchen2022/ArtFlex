import Foundation

/// A tap selects normally; a held key returns after the current pointer gesture.
/// Event timestamps make this independent of keyboard repeat preferences.
struct MomentaryToolState {
    static let holdDuration: TimeInterval = 0.25
    let keyCode: UInt16
    let startedAt: TimeInterval
    let tool: ToolKind
    let originalTool: ToolKind
    let originalBrush: BrushSettings
    let originalMaskLayerID: LayerID?
    var restoreWhenPointerEnds = false

    func shouldRestore(at timestamp: TimeInterval) -> Bool {
        timestamp - startedAt >= Self.holdDuration
    }
}
