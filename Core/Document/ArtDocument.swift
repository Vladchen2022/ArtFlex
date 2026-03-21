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

    init(
        name: String,
        createdAt: Date,
        updatedAt: Date,
        resolutionDPI: Int = 300
    ) {
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolutionDPI = resolutionDPI
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case createdAt
        case updatedAt
        case resolutionDPI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        resolutionDPI = try container.decodeIfPresent(Int.self, forKey: .resolutionDPI) ?? 300
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(resolutionDPI, forKey: .resolutionDPI)
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

    init(
        metadata: DocumentMetadata,
        canvasSize: CanvasSize,
        colorStandard: ArtColorStandard = .stageOneDefault,
        layers: [LayerRecord],
        activeLayerID: LayerID
    ) {
        self.metadata = metadata
        self.canvasSize = canvasSize
        self.colorStandard = colorStandard
        self.layers = layers
        self.activeLayerID = activeLayerID
    }

    static func stageOneDefault(name: String = "未命名") -> ArtDocument {
        let layer = LayerRecord.stageOneDefault()
        let now = Date()

        return ArtDocument(
            metadata: DocumentMetadata(
                name: name,
                createdAt: now,
                updatedAt: now
            ),
            canvasSize: .stageOneDefault,
            layers: [layer],
            activeLayerID: layer.id
        )
    }

    mutating func addLayer(named name: String? = nil) -> LayerRecord {
        let newLayerIndex = layers.count + 1
        let layer = LayerRecord(
            id: LayerID(),
            name: name ?? "图层 \(newLayerIndex)",
            isVisible: true,
            isLocked: false,
            opacity: 1
        )
        layers.append(layer)
        activeLayerID = layer.id
        return layer
    }

    mutating func removeActiveLayer() {
        guard layers.count > 1 else { return }
        guard let activeIndex = layers.firstIndex(where: { $0.id == activeLayerID }) else { return }

        layers.remove(at: activeIndex)

        if let fallbackLayer = layers.last {
            activeLayerID = fallbackLayer.id
        }
    }

    mutating func setActiveLayer(_ layerID: LayerID) {
        guard layers.contains(where: { $0.id == layerID }) else { return }
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

    mutating func duplicateActiveLayer(named name: String? = nil) -> LayerRecord? {
        guard let activeIndex = layers.firstIndex(where: { $0.id == activeLayerID }) else {
            return nil
        }

        let source = layers[activeIndex]
        let duplicated = LayerRecord(
            id: LayerID(),
            name: name ?? "\(source.name) Copy",
            isVisible: source.isVisible,
            isLocked: false,
            opacity: source.opacity
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

        guard activeIndex > 0 else {
            return nil
        }

        return MergeDownContext(
            source: layers[activeIndex],
            destination: layers[activeIndex - 1]
        )
    }

    var mergeVisibleContext: MergeVisibleContext? {
        let visibleLayers = layers.enumerated().compactMap { index, layer -> (index: Int, layer: LayerRecord)? in
            layer.isVisible ? (index, layer) : nil
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
            sourceIndex == destinationIndex + 1
        else {
            return false
        }

        layers[destinationIndex].isVisible = mergedVisibility
        layers[destinationIndex].opacity = min(max(mergedOpacity, 0), 1)
        layers.remove(at: sourceIndex)
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
        activeLayerID = context.target.id
        return true
    }
}
