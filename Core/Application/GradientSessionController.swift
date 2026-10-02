import Foundation
import ArtFlexLifecycle

struct DeferredGradientDrag {
    var tool: ToolKind
    var points: [CanvasPoint]
    var modifiers: CanvasModifierState
    var didEnd: Bool
}

enum DeferredGradientAction {
    case toolSwitch(ToolKind)
    case layerSwitch(LayerID)
    case gradientDrag(DeferredGradientDrag)
}

struct GradientCommitToken: Equatable, Sendable {
    let id: UUID
    let version: DocumentVersion
    let layerID: LayerID
    let tool: ToolKind
}

/// Owns editable drafts and the commit/continuation boundary. Geometry and rendering
/// keep their existing implementations; no AppKit input or workspace object is retained.
@MainActor
final class GradientSessionController {
    var linear = LinearGradientInteractionState() { didSet { onStateChange?() } }
    var sector = SectorGradientInteractionState() { didSet { onStateChange?() } }
    var deferredAction: DeferredGradientAction?
    private(set) var commit: GradientCommitToken?
    var isCommitting: Bool { commit != nil }
    var hasDraft: Bool { linear.isActiveSession || sector.isActiveSession }
    var onStateChange: (() -> Void)?

    func shouldApplyBeforeLeaving(_ tool: ToolKind) -> Bool {
        switch tool {
        case .linearGradient: return shouldAutoApplyGradientForToolSwitch(phase: linear.phase)
        case .sectorGradient: return sector.geometry != nil
        default: return false
        }
    }

    func beginCommit(version: DocumentVersion, layerID: LayerID, tool: ToolKind) -> GradientCommitToken? {
        guard commit == nil else { return nil }
        let token = GradientCommitToken(id: UUID(), version: version, layerID: layerID, tool: tool)
        commit = token
        onStateChange?()
        return token
    }

    func finish(_ token: GradientCommitToken, succeeded: Bool) -> DeferredGradientAction? {
        guard commit == token else { return nil }
        commit = nil
        let next = succeeded ? deferredAction : nil
        deferredAction = nil
        if succeeded {
            if token.tool == .linearGradient { linear = .init() }
            else { sector = .init() }
        }
        onStateChange?()
        return next
    }

    func cancel() {
        commit = nil
        deferredAction = nil
        linear = .init()
        sector = .init()
        onStateChange?()
    }
}
