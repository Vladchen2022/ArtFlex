import Foundation

struct CanvasSize: Codable, Sendable, Equatable {
    var width: Int
    var height: Int

    static let stageOneDefault = CanvasSize(width: 2048, height: 2048)
}

struct DocumentMetadata: Codable, Sendable, Equatable {
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var resolutionDPI: Int
    var drawingStatsID: UUID
    var accumulatedPaintingTime: TimeInterval

    init(
        name: String,
        createdAt: Date,
        updatedAt: Date,
        resolutionDPI: Int = 300,
        drawingStatsID: UUID = UUID(),
        accumulatedPaintingTime: TimeInterval = 0
    ) {
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolutionDPI = resolutionDPI
        self.drawingStatsID = drawingStatsID
        self.accumulatedPaintingTime = accumulatedPaintingTime
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case createdAt
        case updatedAt
        case resolutionDPI
        case drawingStatsID
        case accumulatedPaintingTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        resolutionDPI = try container.decodeIfPresent(Int.self, forKey: .resolutionDPI) ?? 300
        drawingStatsID = try container.decodeIfPresent(UUID.self, forKey: .drawingStatsID) ?? UUID()
        accumulatedPaintingTime = try container.decodeIfPresent(TimeInterval.self, forKey: .accumulatedPaintingTime) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(resolutionDPI, forKey: .resolutionDPI)
        try container.encode(drawingStatsID, forKey: .drawingStatsID)
        try container.encode(accumulatedPaintingTime, forKey: .accumulatedPaintingTime)
    }
}

struct MergeDownContext: Sendable, Equatable {
    var source: LayerRecord
    var destination: LayerRecord
}

struct MergeVisibleContext: Sendable, Equatable {
    var target: LayerRecord
    var visibleLayers: [LayerRecord]
}

struct ArtDocument: Codable, Sendable, Equatable {
    var metadata: DocumentMetadata
    var canvasSize: CanvasSize
    var colorStandard: ArtColorStandard
    var layers: [LayerRecord]
    var activeLayerID: LayerID
    var perspectiveGuide: PerspectiveGuideState?
    var blockReferenceScene: BlockReferenceScene?

    init(
        metadata: DocumentMetadata,
        canvasSize: CanvasSize,
        colorStandard: ArtColorStandard = .stageOneDefault,
        layers: [LayerRecord],
        activeLayerID: LayerID,
        perspectiveGuide: PerspectiveGuideState? = nil,
        blockReferenceScene: BlockReferenceScene? = nil
    ) {
        self.metadata = metadata
        self.canvasSize = canvasSize
        self.colorStandard = colorStandard
        self.layers = layers
        self.activeLayerID = activeLayerID
        self.perspectiveGuide = perspectiveGuide
        self.blockReferenceScene = blockReferenceScene
    }

    static func stageOneDefault(name: String = "未命名") -> ArtDocument {
        let layers = stageOneDefaultLayers()
        let now = Date()

        return ArtDocument(
            metadata: DocumentMetadata(
                name: name,
                createdAt: now,
                updatedAt: now
            ),
            canvasSize: .stageOneDefault,
            layers: layers,
            activeLayerID: layers.last?.id ?? layers[0].id
        )
    }

    static func stageOneDefaultLayers() -> [LayerRecord] {
        let backgroundLayer = LayerRecord.stageOneDefault()
        let drawingLayer = LayerRecord(
            id: LayerID(),
            name: "图层 2",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        return [backgroundLayer, drawingLayer]
    }

    var paintLayers: [LayerRecord] {
        layers.filter(\.isPaintLayer)
    }

    func layer(_ layerID: LayerID) -> LayerRecord? {
        layers.first(where: { $0.id == layerID })
    }

    func childLayers(of groupID: LayerID) -> [LayerRecord] {
        layers.filter { $0.parentID == groupID }
    }

    func isLayerEffectivelyVisible(_ layerID: LayerID) -> Bool {
        guard let layer = layer(layerID), layer.isVisible else { return false }
        var visited: Set<LayerID> = [layerID]
        var parentID = layer.parentID
        while let resolvedParentID = parentID {
            guard !visited.contains(resolvedParentID),
                  let parent = self.layer(resolvedParentID),
                  parent.isGroup,
                  parent.isVisible else {
                return false
            }
            visited.insert(resolvedParentID)
            parentID = parent.parentID
        }
        return true
    }

    func isLayerEffectivelyLocked(_ layerID: LayerID) -> Bool {
        guard let layer = layer(layerID) else { return true }
        if layer.isLocked { return true }
        var visited: Set<LayerID> = [layerID]
        var parentID = layer.parentID
        while let resolvedParentID = parentID {
            guard !visited.contains(resolvedParentID),
                  let parent = self.layer(resolvedParentID),
                  parent.isGroup else {
                return true
            }
            if parent.isLocked { return true }
            visited.insert(resolvedParentID)
            parentID = parent.parentID
        }
        return false
    }

    func effectiveLayerOpacity(_ layerID: LayerID) -> Float {
        guard let layer = layer(layerID) else { return 0 }
        var opacity = layer.opacity
        var visited: Set<LayerID> = [layerID]
        var parentID = layer.parentID
        while let resolvedParentID = parentID {
            guard !visited.contains(resolvedParentID),
                  let parent = self.layer(resolvedParentID),
                  parent.isGroup else { return 0 }
            opacity *= parent.opacity
            visited.insert(resolvedParentID)
            parentID = parent.parentID
        }
        return min(max(opacity, 0), 1)
    }

    mutating func addLayer(named name: String? = nil) -> LayerRecord {
        let newLayerIndex = layers.count + 1
        let activeParentID = layer(activeLayerID)?.parentID
        let layer = LayerRecord(
            id: LayerID(),
            name: name ?? "图层 \(newLayerIndex)",
            parentID: activeParentID,
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        layers.append(layer)
        activeLayerID = layer.id
        return layer
    }

    mutating func addGroup(named name: String? = nil, containing layerIDs: Set<LayerID> = []) -> LayerRecord {
        let group = LayerRecord(
            id: LayerID(),
            name: name ?? "图层组",
            kind: .group,
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        layers.append(group)
        let validChildIDs = Set(layers.filter { $0.isPaintLayer && layerIDs.contains($0.id) }.map(\.id))
        for index in layers.indices where validChildIDs.contains(layers[index].id) {
            layers[index].parentID = group.id
        }
        return group
    }

    @discardableResult
    mutating func removeGroupKeepingChildren(_ groupID: LayerID) -> Bool {
        guard let groupIndex = layers.firstIndex(where: { $0.id == groupID && $0.isGroup }) else {
            return false
        }
        let parentID = layers[groupIndex].parentID
        for index in layers.indices where layers[index].parentID == groupID {
            layers[index].parentID = parentID
        }
        layers.remove(at: groupIndex)
        return true
    }

    mutating func removeActiveLayer() {
        guard paintLayers.count > 1 else { return }
        guard let activeIndex = layers.firstIndex(where: { $0.id == activeLayerID }) else { return }

        let removedID = layers[activeIndex].id
        layers.remove(at: activeIndex)
        for index in layers.indices where layers[index].clipTargetLayerID == removedID {
            layers[index].clipTargetLayerID = nil
        }

        if let fallbackLayer = layers.last(where: \.isPaintLayer) {
            activeLayerID = fallbackLayer.id
        }
    }

    @discardableResult
    mutating func removeLayers(_ layerIDs: Set<LayerID>) -> Set<LayerID> {
        guard !layerIDs.isEmpty else { return [] }
        var removalIDs = layerIDs
        let groupIDs = layers.filter { layerIDs.contains($0.id) && $0.isGroup }.map(\.id)
        for groupID in groupIDs {
            removalIDs.formUnion(descendantLayerIDs(of: groupID))
        }

        let remainingPaintCount = layers.filter { $0.isPaintLayer && !removalIDs.contains($0.id) }.count
        guard remainingPaintCount >= 1 else { return [] }

        layers.removeAll { removalIDs.contains($0.id) }
        for index in layers.indices {
            if layers[index].parentID.map(removalIDs.contains) == true {
                layers[index].parentID = nil
            }
            if layers[index].clipTargetLayerID.map(removalIDs.contains) == true {
                layers[index].clipTargetLayerID = nil
            }
        }
        if removalIDs.contains(activeLayerID), let fallback = layers.last(where: \.isPaintLayer) {
            activeLayerID = fallback.id
        }
        return removalIDs
    }

    func descendantLayerIDs(of groupID: LayerID) -> Set<LayerID> {
        var result: Set<LayerID> = []
        var frontier: [LayerID] = [groupID]
        while let parent = frontier.popLast() {
            let children = layers.filter { $0.parentID == parent }
            for child in children where result.insert(child.id).inserted {
                if child.isGroup { frontier.append(child.id) }
            }
        }
        return result
    }

    mutating func normalizeLayerHierarchy() {
        let validGroupIDs = Set(layers.filter(\.isGroup).map(\.id))
        let validPaintIDs = Set(layers.filter(\.isPaintLayer).map(\.id))
        for index in layers.indices {
            if let parentID = layers[index].parentID, !validGroupIDs.contains(parentID) {
                layers[index].parentID = nil
            }
            if let clipTargetLayerID = layers[index].clipTargetLayerID,
               (!layers[index].isPaintLayer || !validPaintIDs.contains(clipTargetLayerID)) {
                layers[index].clipTargetLayerID = nil
            }
        }

        for index in layers.indices where layers[index].parentID != nil {
            let layerID = layers[index].id
            var visited: Set<LayerID> = [layerID]
            var parentID = layers[index].parentID
            var invalid = false
            while let resolvedParentID = parentID {
                guard visited.insert(resolvedParentID).inserted,
                      let parent = layer(resolvedParentID), parent.isGroup else {
                    invalid = true
                    break
                }
                parentID = parent.parentID
            }
            if invalid { layers[index].parentID = nil }
        }

        for index in layers.indices where layers[index].clipTargetLayerID != nil {
            guard let targetID = layers[index].clipTargetLayerID,
                  let targetIndex = layers.firstIndex(where: { $0.id == targetID }),
                  targetIndex < index,
                  layers[targetIndex].parentID == layers[index].parentID else {
                layers[index].clipTargetLayerID = nil
                continue
            }
        }

        if !validPaintIDs.contains(activeLayerID), let fallback = layers.last(where: \.isPaintLayer) {
            activeLayerID = fallback.id
        }
    }

    mutating func setActiveLayer(_ layerID: LayerID) {
        guard layers.contains(where: { $0.id == layerID && $0.isPaintLayer }) else { return }
        activeLayerID = layerID
    }

    mutating func setLayerVisibility(_ layerID: LayerID, isVisible: Bool) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        layers[index].isVisible = isVisible
    }

    mutating func setLayerOpacity(_ layerID: LayerID, opacity: Float) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        layers[index].opacity = min(max(opacity, 0), 1)
    }

    mutating func setLayerBlendMode(_ layerID: LayerID, blendMode: LayerBlendMode) {
        guard let index = layers.firstIndex(where: { $0.id == layerID && $0.isPaintLayer }) else { return }
        layers[index].blendMode = blendMode
    }

    mutating func toggleLayerReference(_ layerID: LayerID) {
        guard let index = layers.firstIndex(where: { $0.id == layerID && $0.isPaintLayer }) else { return }
        layers[index].isReference.toggle()
    }

    mutating func toggleLayerClipping(_ layerID: LayerID) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == layerID && $0.isPaintLayer }) else { return false }
        if layers[index].clipTargetLayerID != nil {
            layers[index].clipTargetLayerID = nil
            return true
        }
        let parentID = layers[index].parentID
        let lowerPaintLayer = layers[..<index].last(where: { $0.isPaintLayer && $0.parentID == parentID })
        guard let lowerPaintLayer else { return false }
        layers[index].clipTargetLayerID = lowerPaintLayer.id
        return true
    }

    @discardableResult
    mutating func setParent(_ layerIDs: Set<LayerID>, groupID: LayerID?) -> Bool {
        if let groupID {
            guard let group = layer(groupID), group.isGroup else { return false }
            guard !layerIDs.contains(groupID) else { return false }
            for layerID in layerIDs {
                guard !descendantLayerIDs(of: layerID).contains(groupID) else { return false }
            }
        }
        var changed = false
        for index in layers.indices where layerIDs.contains(layers[index].id) {
            guard layers[index].parentID != groupID else { continue }
            layers[index].parentID = groupID
            changed = true
        }
        return changed
    }

    mutating func moveActiveLayerUp() -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID }) else { return false }
        guard index < layers.count - 1 else { return false }

        layers.swapAt(index, index + 1)
        return true
    }

    mutating func moveActiveLayerDown() -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == activeLayerID }) else { return false }
        guard index > 0 else { return false }

        layers.swapAt(index, index - 1)
        return true
    }

    mutating func moveLayer(_ layerID: LayerID, toIndex targetIndex: Int) -> Bool {
        guard let sourceIndex = layers.firstIndex(where: { $0.id == layerID }) else {
            return false
        }

        let clampedTargetIndex = min(max(targetIndex, 0), layers.count - 1)
        guard sourceIndex != clampedTargetIndex else {
            return false
        }

        let layer = layers.remove(at: sourceIndex)
        layers.insert(layer, at: clampedTargetIndex)
        return true
    }

    mutating func moveLayer(_ layerID: LayerID, toDisplayInsertionIndex insertionIndex: Int) -> Bool {
        var displayLayers = Array(layers.reversed())
        guard let sourceDisplayIndex = displayLayers.firstIndex(where: { $0.id == layerID }) else {
            return false
        }

        let layer = displayLayers.remove(at: sourceDisplayIndex)
        let clampedInsertionIndex = min(max(insertionIndex, 0), displayLayers.count)
        let adjustedInsertionIndex = sourceDisplayIndex < clampedInsertionIndex
            ? clampedInsertionIndex - 1
            : clampedInsertionIndex

        displayLayers.insert(layer, at: adjustedInsertionIndex)

        let reorderedLayers = Array(displayLayers.reversed())
        guard reorderedLayers.map(\.id) != layers.map(\.id) else {
            return false
        }

        layers = reorderedLayers
        return true
    }

    mutating func renameLayer(_ layerID: LayerID, to name: String) -> Bool {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else {
            return false
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, layers[index].name != trimmedName else {
            return false
        }

        layers[index].name = trimmedName
        return true
    }

    mutating func toggleLayerLock(_ layerID: LayerID) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        layers[index].isLocked.toggle()
    }

    mutating func toggleLayerTransparentPixelLock(_ layerID: LayerID) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        layers[index].locksTransparentPixels.toggle()
    }

    mutating func duplicateActiveLayer(named name: String? = nil) -> LayerRecord? {
        guard let activeIndex = layers.firstIndex(where: { $0.id == activeLayerID }) else {
            return nil
        }

        let source = layers[activeIndex]
        guard source.isPaintLayer else { return nil }
        let duplicated = LayerRecord(
            id: LayerID(),
            name: name ?? "\(source.name) Copy",
            parentID: source.parentID,
            isVisible: source.isVisible,
            isLocked: false,
            locksTransparentPixels: source.locksTransparentPixels,
            opacity: source.opacity,
            blendMode: source.blendMode,
            clipTargetLayerID: source.clipTargetLayerID,
            isReference: source.isReference
        )

        let insertIndex = activeIndex + 1
        layers.insert(duplicated, at: insertIndex)
        activeLayerID = duplicated.id
        return duplicated
    }

    var activeMergeDownContext: MergeDownContext? {
        guard let activeIndex = layers.firstIndex(where: { $0.id == activeLayerID }) else {
            return nil
        }

        let source = layers[activeIndex]
        guard source.isPaintLayer,
              let destination = layers[..<activeIndex].last(where: {
                  $0.isPaintLayer && $0.parentID == source.parentID
              }) else { return nil }

        return MergeDownContext(
            source: source,
            destination: destination
        )
    }

    var mergeVisibleContext: MergeVisibleContext? {
        let visibleLayers = layers.enumerated().compactMap { index, layer -> (index: Int, layer: LayerRecord)? in
            layer.isPaintLayer && isLayerEffectivelyVisible(layer.id) ? (index, layer) : nil
        }

        guard visibleLayers.count >= 2, let target = visibleLayers.last?.layer else {
            return nil
        }

        return MergeVisibleContext(
            target: target,
            visibleLayers: visibleLayers.map(\.layer)
        )
    }

    mutating func completeMergeDown(
        using context: MergeDownContext,
        mergedVisibility: Bool,
        mergedOpacity: Float = 1
    ) -> Bool {
        guard
            let sourceIndex = layers.firstIndex(where: { $0.id == context.source.id }),
            let destinationIndex = layers.firstIndex(where: { $0.id == context.destination.id }),
            sourceIndex > destinationIndex,
            layers[(destinationIndex + 1)..<sourceIndex].contains(where: {
                $0.isPaintLayer && $0.parentID == context.source.parentID
            }) == false
        else {
            return false
        }

        layers[destinationIndex].isVisible = mergedVisibility
        layers[destinationIndex].opacity = min(max(mergedOpacity, 0), 1)
        layers[destinationIndex].blendMode = .normal
        layers[destinationIndex].clipTargetLayerID = nil
        layers.remove(at: sourceIndex)
        for index in layers.indices where layers[index].clipTargetLayerID == context.source.id {
            layers[index].clipTargetLayerID = context.destination.id
        }
        activeLayerID = context.destination.id
        return true
    }

    mutating func completeMergeVisible(
        using context: MergeVisibleContext,
        mergedVisibility: Bool,
        mergedOpacity: Float = 1
    ) -> Bool {
        let visibleLayerIDs = Set(context.visibleLayers.map(\.id))
        guard
            visibleLayerIDs.count >= 2,
            layers.contains(where: { $0.id == context.target.id })
        else {
            return false
        }

        layers.removeAll { layer in
            visibleLayerIDs.contains(layer.id) && layer.id != context.target.id
        }

        guard let targetIndex = layers.firstIndex(where: { $0.id == context.target.id }) else {
            return false
        }

        layers[targetIndex].isVisible = mergedVisibility
        layers[targetIndex].opacity = min(max(mergedOpacity, 0), 1)
        layers[targetIndex].blendMode = .normal
        layers[targetIndex].clipTargetLayerID = nil
        for index in layers.indices where layers[index].clipTargetLayerID.map(visibleLayerIDs.contains) == true {
            layers[index].clipTargetLayerID = context.target.id
        }
        activeLayerID = context.target.id
        return true
    }
}
