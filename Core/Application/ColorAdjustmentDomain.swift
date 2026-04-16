import Foundation
@preconcurrency import Metal

struct ColorAdjustmentParameters: Equatable, Sendable {
    var selectedHueDegrees: Float = 0
    var hueStrength: Float = 0
    var brightness: Float = 0
    var contrast: Float = 0
    var purity: Float = 0

    static let neutral = Self()

    var isNeutral: Bool {
        abs(selectedHueDegrees) < 0.0001
            && abs(hueStrength) < 0.0001
            && abs(brightness) < 0.0001
            && abs(contrast) < 0.0001
            && abs(purity) < 0.0001
    }
}

enum ColorAdjustmentBrushMode: Equatable, Sendable {
    case paint
    case erase
}

enum ColorAdjustmentResolutionReason: Equatable, Sendable {
    case toolChange
    case panelChange
    case layerChange
    case historyNavigation
    case documentOpen
    case closeOrQuit

    var continuesTriggeringActionAfterResolution: Bool {
        switch self {
        case .historyNavigation:
            return true
        case .toolChange, .panelChange, .layerChange, .documentOpen, .closeOrQuit:
            return true
        }
    }
}

enum ColorAdjustmentResolutionDecision: Equatable, Sendable {
    case apply
    case discard
    case cancel
}

enum ColorAdjustmentMaskReadMode: Sendable {
    case maskRed
    case sourceAlpha
}

struct PaintedMaskState {
    var maskTexture: MTLTexture
    var paintedBounds: CanvasRect?
    var brushSamplingState: BrushStrokeSamplingState?
    var opacityCapSession: OpacityCapSessionResources?
}

struct SelectionMaskState {
    var maskTexture: MTLTexture
    var bounds: CanvasRect
    var capturedSelectionShape: SelectionShape
    var capturedSelectionRevision: UInt64
}

struct WholeLayerMaskState {
    var effectBounds: CanvasRect?
    var capturedCanvasRevision: UInt64
}

enum ColorAdjustmentSource {
    case painted(PaintedMaskState)
    case selection(SelectionMaskState)
    case wholeLayer(WholeLayerMaskState)

    var effectiveBounds: CanvasRect? {
        switch self {
        case .painted(let state):
            return state.paintedBounds
        case .selection(let state):
            return state.bounds
        case .wholeLayer(let state):
            return state.effectBounds
        }
    }

    var sourceKindForOverlay: ColorAdjustmentOverlayState.SourceKind {
        switch self {
        case .painted:
            return .paintedMask
        case .selection:
            return .selection
        case .wholeLayer:
            return .wholeLayer
        }
    }
}

struct ColorAdjustmentSession {
    var layerID: LayerID
    var source: ColorAdjustmentSource
    var previewTexture: MTLTexture
    var parameters: ColorAdjustmentParameters = .neutral
    var brushMode: ColorAdjustmentBrushMode = .paint
    var showsOriginalPreview: Bool = false

    var hasVisiblePreview: Bool {
        switch source {
        case .painted(let state):
            return state.paintedBounds != nil || !parameters.isNeutral
        case .selection, .wholeLayer:
            return !parameters.isNeutral
        }
    }

    var hasPendingCommittedEffect: Bool {
        guard !parameters.isNeutral else { return false }

        switch source {
        case .painted(let state):
            return state.paintedBounds != nil
        case .selection, .wholeLayer:
            return true
        }
    }
}

struct ColorAdjustmentOverlayState: Equatable {
    enum SourceKind: Equatable {
        case none
        case paintedMask
        case selection
        case wholeLayer
    }

    var isActive: Bool = false
    var brushMode: ColorAdjustmentBrushMode = .paint
    var selectedHueDegrees: Float = 0
    var hueStrength: Float = 0
    var brightness: Float = 0
    var contrast: Float = 0
    var purity: Float = 0
    var showsOriginalPreview: Bool = false
    var effectiveBounds: CanvasRect?
    var sourceKind: SourceKind = .none

    static let inactive = Self()
}
