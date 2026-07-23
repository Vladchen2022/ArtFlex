import Foundation
@preconcurrency import Metal

struct ColorAdjustmentParameters: Equatable, Sendable {
    var selectedHueDegrees: Float = 0
    var hueStrength: Float = 0
    var brightness: Float = 0
    var contrast: Float = 0
    var purity: Float = 0
    var vitalizationStrength: Float = 0
    var vitalizationBandScale: Float = 0.45
    var vitalizationColorTolerance: Float = 0.35
    var vitalizationDirectionDegrees: Float = 32

    static let neutral = Self()
    static let vitalizationDefault = Self(vitalizationStrength: 0.55)

    var isNeutral: Bool {
        abs(selectedHueDegrees) < 0.0001
            && abs(hueStrength) < 0.0001
            && abs(brightness) < 0.0001
            && abs(contrast) < 0.0001
            && abs(purity) < 0.0001
    }

    func isNeutral(for mode: ColorAdjustmentEffectMode) -> Bool {
        switch mode {
        case .standard:
            return isNeutral
        case .vitalization:
            return abs(vitalizationStrength) < 0.0001
        }
    }
}

enum ColorAdjustmentEffectMode: String, CaseIterable, Equatable, Sendable {
    case standard
    case vitalization

    var displayName: String {
        switch self {
        case .standard:
            return "色彩调整"
        case .vitalization:
            return "颜色活化"
        }
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
    var effectMode: ColorAdjustmentEffectMode = .standard
    var vitalizationReferenceColor: RGBAColor?
    var vitalizationSeed: UInt32 = 0
    var brushMode: ColorAdjustmentBrushMode = .paint
    var showsOriginalPreview: Bool = false

    var hasVisiblePreview: Bool {
        switch source {
        case .painted(let state):
            return state.paintedBounds != nil || !parameters.isNeutral(for: effectMode)
        case .selection, .wholeLayer:
            return !parameters.isNeutral(for: effectMode)
        }
    }

    var hasPendingCommittedEffect: Bool {
        guard !parameters.isNeutral(for: effectMode) else { return false }
        if effectMode == .vitalization, vitalizationReferenceColor == nil {
            return false
        }

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
    var effectMode: ColorAdjustmentEffectMode = .standard
    var vitalizationStrength: Float = 0
    var vitalizationBandScale: Float = 0.45
    var vitalizationColorTolerance: Float = 0.35
    var vitalizationDirectionDegrees: Float = 32
    var vitalizationReferenceColor: RGBAColor?
    var showsOriginalPreview: Bool = false
    var effectiveBounds: CanvasRect?
    var sourceKind: SourceKind = .none

    static let inactive = Self()
}
