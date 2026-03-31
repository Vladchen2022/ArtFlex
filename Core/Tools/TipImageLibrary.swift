import Foundation

struct TipImageLibraryItem: Codable, Sendable, Equatable, Identifiable {
    var id: BrushTipImageAssetID
    var sourceInfo: ImportedTipSourceInfo
    var maskData: Data?

    init(
        id: BrushTipImageAssetID,
        sourceInfo: ImportedTipSourceInfo,
        maskData: Data? = nil
    ) {
        self.id = id
        self.sourceInfo = sourceInfo
        self.maskData = maskData
    }

    var displayName: String {
        sourceInfo.sourceLabel
    }
}

struct TipImageLibraryState: Codable, Sendable, Equatable {
    static let suggestedCapacity = 30

    var items: [TipImageLibraryItem]

    static let empty = TipImageLibraryState(items: [])

    init(items: [TipImageLibraryItem]) {
        self.items = items
    }

    func item(id: BrushTipImageAssetID) -> TipImageLibraryItem? {
        items.first(where: { $0.id == id })
    }

    func contains(id: BrushTipImageAssetID) -> Bool {
        item(id: id) != nil
    }

    mutating func upsertImportedItem(
        id: BrushTipImageAssetID,
        sourceInfo: ImportedTipSourceInfo,
        maskData: Data
    ) -> TipImageLibraryItem {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].sourceInfo = sourceInfo
            items[index].maskData = maskData
            return items[index]
        }

        let item = TipImageLibraryItem(
            id: id,
            sourceInfo: sourceInfo,
            maskData: maskData
        )
        items.append(item)
        return item
    }

    mutating func upsertImportedTips(from brush: BrushSettings) -> Bool {
        var didChange = false

        if brush.customTipSourceSemantic == .importedImage,
           let sourceInfo = brush.customTipImportedSourceInfo,
           let maskData = brush.customTipMaskData {
            let assetID = brush.customTipAssetID ?? BrushTipImageAssetID(maskData: maskData)
            didChange = upsertImportedItemIfNeeded(
                id: assetID,
                sourceInfo: sourceInfo,
                maskData: maskData
            ) || didChange
        }

        let secondary = brush.secondaryTipDescriptor
        if secondary.sourceSemantic == .importedImage,
           let sourceInfo = secondary.importedSourceInfo,
           let maskData = secondary.customTipMaskData {
            let assetID = secondary.tipAssetID ?? BrushTipImageAssetID(maskData: maskData)
            didChange = upsertImportedItemIfNeeded(
                id: assetID,
                sourceInfo: sourceInfo,
                maskData: maskData
            ) || didChange
        }

        return didChange
    }

    mutating func moveItem(id: BrushTipImageAssetID, to targetIndex: Int) -> Bool {
        guard
            let currentIndex = items.firstIndex(where: { $0.id == id })
        else {
            return false
        }

        let clampedTargetIndex = max(0, min(items.count - 1, targetIndex))
        guard currentIndex != clampedTargetIndex else {
            return false
        }

        let item = items.remove(at: currentIndex)
        let insertionIndex: Int
        if currentIndex < clampedTargetIndex {
            insertionIndex = min(clampedTargetIndex, items.count)
        } else {
            insertionIndex = clampedTargetIndex
        }
        items.insert(item, at: insertionIndex)
        return true
    }

    mutating func deleteItem(id: BrushTipImageAssetID) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            return false
        }
        items.remove(at: index)
        return true
    }

    private mutating func upsertImportedItemIfNeeded(
        id: BrushTipImageAssetID,
        sourceInfo: ImportedTipSourceInfo,
        maskData: Data
    ) -> Bool {
        if let existing = item(id: id),
           existing.sourceInfo == sourceInfo,
           existing.maskData == maskData {
            return false
        }

        _ = upsertImportedItem(
            id: id,
            sourceInfo: sourceInfo,
            maskData: maskData
        )
        return true
    }
}
