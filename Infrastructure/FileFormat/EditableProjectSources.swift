import Foundation

enum EditableProjectSources {
    static func path(for hash: String) -> String { "editable/\(hash).zlib" }

    static func collect(from document: ArtDocument) throws -> [EditableSourceAsset] {
        var byHash: [String: EditableSourceAsset] = [:]
        for layer in document.layers {
            guard let content = layer.editableContent else { continue }
            guard layer.isPaintLayer, !layer.isAdjustmentLayer else { throw CocoaError(.fileReadCorruptFile) }
            try content.validate()
            for asset in content.assets {
                if let old = byHash[asset.sha256] {
                    guard old.byteCount == asset.byteCount else { throw CocoaError(.fileReadCorruptFile) }
                    continue
                }
                _ = try asset.decoded()
                byHash[asset.sha256] = asset
            }
        }
        return byHash.values.sorted { $0.sha256 < $1.sha256 }
    }
}
