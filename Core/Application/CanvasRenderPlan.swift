import Foundation

struct CanvasPixelResourceID: Codable, Hashable, Sendable, Equatable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

enum CanvasPixelResourceFormat: String, Codable, Sendable, Equatable {
    case bgra8UnormSRGB
    case r8Unorm

    var bytesPerPixel: Int {
        switch self {
        case .bgra8UnormSRGB: 4
        case .r8Unorm: 1
        }
    }
}

/// Describes where a platform-owned pixel resource belongs in canvas space.
/// A resource may cover the full canvas or one tile; this type owns no GPU object.
struct CanvasPixelResourceDescriptor: Codable, Sendable, Equatable {
    var id: CanvasPixelResourceID
    var format: CanvasPixelResourceFormat
    var canvasRegion: PixelRegion
}

/// `nil` means no mask. A non-nil reference also defines the value of unallocated mask tiles.
struct CanvasMaskResourceReference: Codable, Sendable, Equatable {
    var defaultValue: UInt8
    var resourceIDs: [CanvasPixelResourceID]

    init(defaultValue: UInt8 = 255, resourceIDs: [CanvasPixelResourceID] = []) {
        self.defaultValue = defaultValue
        self.resourceIDs = resourceIDs
    }
}

enum CanvasAdjustmentDescriptor: Codable, Sendable, Equatable {
    case curves(CurveAdjustmentParameters)

    var curveLUTs: CurveLUTs? {
        switch self {
        case .curves(let parameters):
            return CurveLUTBuilder.buildAll(from: parameters)
        }
    }
}

struct CanvasPaintRenderNode: Codable, Sendable, Equatable {
    var layerID: LayerID
    var contentResourceIDs: [CanvasPixelResourceID]
    var mask: CanvasMaskResourceReference?
    var opacity: Float
    var blendMode: LayerBlendMode
    var clipTargetLayerID: LayerID?

    init(
        layerID: LayerID,
        contentResourceIDs: [CanvasPixelResourceID],
        mask: CanvasMaskResourceReference? = nil,
        opacity: Float = 1,
        blendMode: LayerBlendMode = .normal,
        clipTargetLayerID: LayerID? = nil
    ) {
        self.layerID = layerID
        self.contentResourceIDs = contentResourceIDs
        self.mask = mask
        self.opacity = opacity
        self.blendMode = blendMode
        self.clipTargetLayerID = clipTargetLayerID
    }
}

/// Applies its descriptor to the backdrop accumulated before this node in the same group.
struct CanvasAdjustmentRenderNode: Codable, Sendable, Equatable {
    var layerID: LayerID
    var adjustment: CanvasAdjustmentDescriptor
    var mask: CanvasMaskResourceReference?
    var opacity: Float

    init(
        layerID: LayerID,
        adjustment: CanvasAdjustmentDescriptor,
        mask: CanvasMaskResourceReference? = nil,
        opacity: Float = 1
    ) {
        self.layerID = layerID
        self.adjustment = adjustment
        self.mask = mask
        self.opacity = opacity
    }
}

struct CanvasGroupRenderNode: Codable, Sendable, Equatable {
    var layerID: LayerID
    var opacity: Float
    var blendMode: LayerBlendMode
    /// Children are ordered from bottom to top.
    var children: [CanvasRenderNode]

    init(
        layerID: LayerID,
        opacity: Float = 1,
        blendMode: LayerBlendMode = .normal,
        children: [CanvasRenderNode]
    ) {
        self.layerID = layerID
        self.opacity = opacity
        self.blendMode = blendMode
        self.children = children
    }
}

indirect enum CanvasRenderNode: Codable, Sendable, Equatable {
    case paint(CanvasPaintRenderNode)
    case adjustment(CanvasAdjustmentRenderNode)
    case group(CanvasGroupRenderNode)

    var layerID: LayerID {
        switch self {
        case .paint(let node): node.layerID
        case .adjustment(let node): node.layerID
        case .group(let node): node.layerID
        }
    }
}

enum ActiveEditTarget: Codable, Sendable, Equatable {
    case layerContent(LayerID)
    case layerMask(LayerID)
}

/// Required order for converting one paint node into a contribution to the backdrop.
enum CanvasPaintCompositingStage: String, Codable, CaseIterable, Sendable, Equatable {
    case sourcePixels
    case layerMask
    case layerOpacity
    case clipTargetAlpha
    case blendWithBackdrop
}

enum CanvasRenderExecutionStepKind: String, Codable, Sendable, Equatable {
    case beginGroup
    case paint
    case adjustment
    case endGroup
}

struct CanvasRenderExecutionStep: Codable, Sendable, Equatable {
    var kind: CanvasRenderExecutionStepKind
    var layerID: LayerID
}

enum CanvasRenderPlanValidationIssue: Sendable, Equatable {
    case invalidCanvasSize
    case duplicateResourceID(CanvasPixelResourceID)
    case invalidResourceRegion(CanvasPixelResourceID)
    case duplicateLayerID(LayerID)
    case missingResource(CanvasPixelResourceID)
    case unexpectedResourceFormat(
        resourceID: CanvasPixelResourceID,
        expected: CanvasPixelResourceFormat,
        actual: CanvasPixelResourceFormat
    )
    case invalidOpacity(LayerID)
    case missingClipTarget(layerID: LayerID, targetLayerID: LayerID)
}

/// Platform-neutral render graph. Top-level nodes and group children are bottom-to-top.
struct CanvasRenderPlan: Codable, Sendable, Equatable {
    static let standardPaintCompositingOrder: [CanvasPaintCompositingStage] = [
        .sourcePixels,
        .layerMask,
        .layerOpacity,
        .clipTargetAlpha,
        .blendWithBackdrop
    ]

    var canvasSize: CanvasSize
    var resources: [CanvasPixelResourceDescriptor]
    var nodes: [CanvasRenderNode]

    var executionSteps: [CanvasRenderExecutionStep] {
        var steps: [CanvasRenderExecutionStep] = []
        for node in nodes {
            Self.appendExecutionSteps(for: node, to: &steps)
        }
        return steps
    }

    func validationIssues() -> [CanvasRenderPlanValidationIssue] {
        guard let canvasBounds = PixelRegion.canvasBounds(for: canvasSize) else {
            return [.invalidCanvasSize]
        }

        var issues: [CanvasRenderPlanValidationIssue] = []
        var resourcesByID: [CanvasPixelResourceID: CanvasPixelResourceDescriptor] = [:]
        for resource in resources {
            if resourcesByID[resource.id] != nil {
                issues.append(.duplicateResourceID(resource.id))
            } else {
                resourcesByID[resource.id] = resource
            }
            if resource.canvasRegion.isEmpty ||
                resource.canvasRegion.intersection(with: canvasBounds) != resource.canvasRegion {
                issues.append(.invalidResourceRegion(resource.id))
            }
        }

        var allLayerIDs: [LayerID] = []
        var paintLayerIDs: Set<LayerID> = []
        for node in nodes {
            Self.collectLayerIDs(from: node, allLayerIDs: &allLayerIDs, paintLayerIDs: &paintLayerIDs)
        }
        var seenLayerIDs: Set<LayerID> = []
        for layerID in allLayerIDs where !seenLayerIDs.insert(layerID).inserted {
            issues.append(.duplicateLayerID(layerID))
        }

        for node in nodes {
            Self.validate(
                node,
                resourcesByID: resourcesByID,
                paintLayerIDs: paintLayerIDs,
                issues: &issues
            )
        }
        return issues
    }

    private static func appendExecutionSteps(
        for node: CanvasRenderNode,
        to steps: inout [CanvasRenderExecutionStep]
    ) {
        switch node {
        case .paint(let paint):
            steps.append(.init(kind: .paint, layerID: paint.layerID))
        case .adjustment(let adjustment):
            steps.append(.init(kind: .adjustment, layerID: adjustment.layerID))
        case .group(let group):
            steps.append(.init(kind: .beginGroup, layerID: group.layerID))
            for child in group.children {
                appendExecutionSteps(for: child, to: &steps)
            }
            steps.append(.init(kind: .endGroup, layerID: group.layerID))
        }
    }

    private static func collectLayerIDs(
        from node: CanvasRenderNode,
        allLayerIDs: inout [LayerID],
        paintLayerIDs: inout Set<LayerID>
    ) {
        allLayerIDs.append(node.layerID)
        switch node {
        case .paint(let paint):
            paintLayerIDs.insert(paint.layerID)
        case .adjustment:
            break
        case .group(let group):
            for child in group.children {
                collectLayerIDs(from: child, allLayerIDs: &allLayerIDs, paintLayerIDs: &paintLayerIDs)
            }
        }
    }

    private static func validate(
        _ node: CanvasRenderNode,
        resourcesByID: [CanvasPixelResourceID: CanvasPixelResourceDescriptor],
        paintLayerIDs: Set<LayerID>,
        issues: inout [CanvasRenderPlanValidationIssue]
    ) {
        switch node {
        case .paint(let paint):
            validateOpacity(paint.opacity, layerID: paint.layerID, issues: &issues)
            validateResources(
                paint.contentResourceIDs,
                expectedFormat: .bgra8UnormSRGB,
                resourcesByID: resourcesByID,
                issues: &issues
            )
            validateMask(paint.mask, resourcesByID: resourcesByID, issues: &issues)
            if let targetLayerID = paint.clipTargetLayerID,
               !paintLayerIDs.contains(targetLayerID) {
                issues.append(.missingClipTarget(layerID: paint.layerID, targetLayerID: targetLayerID))
            }
        case .adjustment(let adjustment):
            validateOpacity(adjustment.opacity, layerID: adjustment.layerID, issues: &issues)
            validateMask(adjustment.mask, resourcesByID: resourcesByID, issues: &issues)
        case .group(let group):
            validateOpacity(group.opacity, layerID: group.layerID, issues: &issues)
            for child in group.children {
                validate(
                    child,
                    resourcesByID: resourcesByID,
                    paintLayerIDs: paintLayerIDs,
                    issues: &issues
                )
            }
        }
    }

    private static func validateMask(
        _ mask: CanvasMaskResourceReference?,
        resourcesByID: [CanvasPixelResourceID: CanvasPixelResourceDescriptor],
        issues: inout [CanvasRenderPlanValidationIssue]
    ) {
        guard let mask else { return }
        validateResources(
            mask.resourceIDs,
            expectedFormat: .r8Unorm,
            resourcesByID: resourcesByID,
            issues: &issues
        )
    }

    private static func validateResources(
        _ resourceIDs: [CanvasPixelResourceID],
        expectedFormat: CanvasPixelResourceFormat,
        resourcesByID: [CanvasPixelResourceID: CanvasPixelResourceDescriptor],
        issues: inout [CanvasRenderPlanValidationIssue]
    ) {
        for resourceID in resourceIDs {
            guard let resource = resourcesByID[resourceID] else {
                issues.append(.missingResource(resourceID))
                continue
            }
            if resource.format != expectedFormat {
                issues.append(
                    .unexpectedResourceFormat(
                        resourceID: resourceID,
                        expected: expectedFormat,
                        actual: resource.format
                    )
                )
            }
        }
    }

    private static func validateOpacity(
        _ opacity: Float,
        layerID: LayerID,
        issues: inout [CanvasRenderPlanValidationIssue]
    ) {
        if !opacity.isFinite || opacity < 0 || opacity > 1 {
            issues.append(.invalidOpacity(layerID))
        }
    }
}
