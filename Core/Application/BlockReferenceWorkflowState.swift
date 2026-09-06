import Foundation

/// Transient interaction state, deliberately excluded from project persistence.
struct BlockReferenceWorkflowState {
    var interactionPreview: BlockReferenceScene?
    var interactionOperation: String?
    var inspectionCamera: BlockReferenceCamera?
    var navigationMode: BlockReferenceNavigationMode?
    var continuousPlacement = false
    var temporarilyDisablesSnapping = false
    var pendingPlacement: BlockReferencePlacement?
    var resizesFace = false
    var faceDrag: BlockReferenceFaceDrag?
}

struct BlockReferenceFaceDrag {
    var object: BlockReferenceObject
    var axis: BlockReferenceAxis
    var sign: Double
    var normal: BlockVector3
    var start: CanvasPoint
    var screenVector: CanvasPoint
}

func blockReferenceResizingFace(_ drag: BlockReferenceFaceDrag, distance: Double) -> BlockReferenceObject {
    var object = drag.object
    let original: Double
    switch drag.axis {
    case .x: original = object.dimensions.width
    case .y: original = object.dimensions.depth
    case .z: original = object.dimensions.height
    }
    let change = min(max(distance, 1 - original), 10_000 - original)
    switch drag.axis {
    case .x: object.dimensions.width += change
    case .y: object.dimensions.depth += change
    case .z: object.dimensions.height += change
    }
    if drag.axis != .z { object.position = object.position + drag.normal * (change * 0.5) }
    else if drag.sign < 0 { object.position = object.position + drag.normal * change }
    return object
}

struct BlockReferencePlacement {
    var objects: [BlockReferenceObject]
    var instance: BlockReferenceCustomModuleInstance?
    var group: BlockReferenceGroup?
    var basePoint: BlockVector3
    var location: BlockVector3?
}

enum BlockReferenceDisplayPreset: String, CaseIterable {
    case structure = "结构线"
    case gray = "灰模"
    case overlay = "半透明叠看"
}
