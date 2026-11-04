import Foundation

struct LayerSubsetImport {
    var document: ArtDocument
    var importedLayerIDs: Set<LayerID>
    var snapshots: [LayerHistorySnapshot]

    static func includedLayerIDs(in source: ArtDocument, selected: Set<LayerID>) -> Set<LayerID> {
        var included = selected.intersection(Set(source.layers.map(\.id)))
        var pending = Array(included)
        while let id = pending.popLast(), let layer = source.layer(id) {
            var dependencies: [LayerID] = []
            if let parent = layer.parentID { dependencies.append(parent) }
            if let clip = layer.clipTargetLayerID { dependencies.append(clip) }
            // An explicitly selected group selects its descendants. Ancestors added only to
            // preserve structure do not import all their otherwise unselected children.
            if layer.isGroup && selected.contains(id) {
                dependencies.append(contentsOf: source.descendantLayerIDs(of: id))
            }
            if layer.isAdjustmentLayer, let index = source.layers.firstIndex(where: { $0.id == id }) {
                dependencies += source.layers.prefix(index).filter { $0.parentID == layer.parentID }.map(\.id)
            }
            for dependency in dependencies where source.layer(dependency) != nil && included.insert(dependency).inserted { pending.append(dependency) }
        }
        return included
    }

    static func prepare(source: ProjectArchivePayload, selected: Set<LayerID>, destination: ArtDocument, name: String) throws -> Self {
        let sourceDocument = source.package.document
        guard sourceDocument.canvasSize == destination.canvasSize, sourceDocument.colorStandard == destination.colorStandard else {
            throw CanvasResourceError(message: "方案与主稿的尺寸或颜色格式不同，请先以独立文档打开方案")
        }
        let included = includedLayerIDs(in: sourceDocument, selected: selected)
        guard !included.isEmpty else { throw CanvasResourceError(message: "请至少选择一个图层") }
        let ids = Dictionary(uniqueKeysWithValues: sourceDocument.layers.filter { included.contains($0.id) }.map { ($0.id, LayerID()) })
        let group = LayerRecord(id: LayerID(), name: name, kind: .group, isVisible: true, isLocked: false, locksTransparentPixels: false, opacity: 1)
        var document = destination
        document.layers.append(group)
        for layer in sourceDocument.layers where included.contains(layer.id) {
            document.layers.append(.init(id: ids[layer.id]!, name: layer.name, kind: layer.kind,
                parentID: layer.parentID.flatMap { ids[$0] } ?? group.id, isVisible: layer.isVisible, isLocked: layer.isLocked,
                locksTransparentPixels: layer.locksTransparentPixels, opacity: layer.opacity, blendMode: layer.blendMode,
                clipTargetLayerID: layer.clipTargetLayerID.flatMap { ids[$0] }, isReference: layer.isReference,
                mask: layer.mask, adjustment: layer.adjustment, editableContent: layer.editableContent))
        }
        let snapshots = source.package.layerSnapshots.compactMap { snapshot -> LayerHistorySnapshot? in
            guard let id = ids[snapshot.layerID] else { return nil }
            var copy = snapshot; copy.layerID = id; return copy
        }
        if let sourceRetention = sourceDocument.cropRetention {
            var retention = destination.cropRetention ?? .init(fullBounds: .init(originX: 0, originY: 0,
                width: destination.canvasSize.width, height: destination.canvasSize.height), tiles: [])
            retention.fullBounds = retention.fullBounds.union(sourceRetention.fullBounds)
            retention.tiles += sourceRetention.tiles.compactMap { tile in
                guard let id = ids[tile.key.layerID] else { return nil }
                var copy = tile; copy.key.layerID = id; return copy
            }
            document.cropRetention = try retention.validated(for: document)
        }
        document.activeLayerID = ids[sourceDocument.activeLayerID] ?? document.layers.last!.id
        return .init(document: document, importedLayerIDs: Set(ids.values), snapshots: snapshots)
    }
}
