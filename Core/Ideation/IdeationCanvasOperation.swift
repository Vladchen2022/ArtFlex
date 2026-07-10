import AppKit
import Foundation

struct CanvasModifierState: Sendable, Equatable {
    var shift = false
    var option = false
    var command = false
    var control = false

    init(flags: NSEvent.ModifierFlags = []) {
        shift = flags.contains(.shift)
        option = flags.contains(.option)
        command = flags.contains(.command)
        control = flags.contains(.control)
    }

    var eventFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if command { flags.insert(.command) }
        if control { flags.insert(.control) }
        return flags
    }
}

enum IdeationCanvasOperation: Sendable {
    case beginStroke(paintVariationSeed: UInt32)
    case applyStroke([CanvasStrokeSample])
    case endStroke
    case beginGradientDrag(point: CanvasPoint, modifiers: CanvasModifierState)
    case updateGradientDrag(point: CanvasPoint, modifiers: CanvasModifierState)
    case endGradientDrag(point: CanvasPoint, modifiers: CanvasModifierState)
    case enterGradientEditing
    case applyGradientSession
    case cancelGradientSession
    case fillAtPoint(CanvasPoint)
    case applyCanvasCrop(CanvasRect)
    case handleCanvasToolClick(
        point: CanvasPoint,
        modifiers: CanvasModifierState,
        clickCount: Int,
        paintVariationSeed: UInt32
    )
    case beginSelection(kind: SelectionShapeKind, start: CanvasPoint, modifiers: CanvasModifierState)
    case updateSelection(point: CanvasPoint, modifiers: CanvasModifierState)
    case commitSelection(end: CanvasPoint, modifiers: CanvasModifierState)
    case moveSelectionPreview(deltaX: Double, deltaY: Double)
    case commitSelectionMove
    case beginSelectionTransform(start: CanvasPoint, mode: FreeTransformInteractionMode)
    case updateSelectionTransform(point: CanvasPoint)
    case commitSelectionTransform(end: CanvasPoint)
    case setTransformPreviewOffset(CanvasPoint)
    case applySelectionTransform
    case cancelSelectionTransform
}
