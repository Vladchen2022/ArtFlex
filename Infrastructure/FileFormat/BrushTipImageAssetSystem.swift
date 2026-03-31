import CryptoKit
import Foundation

struct BrushTipImageAssetID: Hashable, Codable, Sendable, Equatable, Comparable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(maskData: Data) {
        let digest = SHA256.hash(data: maskData)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        self.rawValue = "tip-\(hex)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: BrushTipImageAssetID, rhs: BrushTipImageAssetID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct BrushTipImageAsset: Codable, Sendable, Equatable, Identifiable {
    var id: BrushTipImageAssetID
    var maskData: Data

    init(id: BrushTipImageAssetID, maskData: Data) {
        self.id = id
        self.maskData = maskData
    }

    init(maskData: Data) {
        self.init(id: BrushTipImageAssetID(maskData: maskData), maskData: maskData)
    }
}

enum BrushTipImageAssetSystem {
    static func archivedWorkspace(_ state: WorkspaceState) -> (workspace: WorkspaceState, assets: [BrushTipImageAsset]) {
        var collector = AssetCollector()
        var normalized = state
        normalized.tipImageLibrary = archivedTipImageLibrary(state.tipImageLibrary, collector: &collector)
        normalized.toolSession.brush = collector.archivedBrush(state.toolSession.brush)
        normalized.brushLibrary = archivedBrushLibrary(state.brushLibrary, collector: &collector)
        return (normalized, collector.assets)
    }

    static func resolveWorkspace(_ state: WorkspaceState, assets: [BrushTipImageAsset]) -> WorkspaceState {
        let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        var resolved = state
        resolved.tipImageLibrary = resolveTipImageLibrary(state.tipImageLibrary, lookup: lookup)
        resolved.toolSession.brush = resolveBrush(state.toolSession.brush, lookup: lookup)
        resolved.brushLibrary = resolveLibrary(state.brushLibrary, lookup: lookup)
        return resolved
    }

    static func archivedLibrary(
        _ library: BrushLibraryState,
        tipImageLibrary: TipImageLibraryState = .empty
    ) -> (library: BrushLibraryState, tipImageLibrary: TipImageLibraryState, assets: [BrushTipImageAsset]) {
        var collector = AssetCollector()
        let normalizedLibrary = archivedBrushLibrary(library, collector: &collector)
        let normalizedTipImageLibrary = archivedTipImageLibrary(tipImageLibrary, collector: &collector)
        return (normalizedLibrary, normalizedTipImageLibrary, collector.assets)
    }

    static func resolveLibrary(_ library: BrushLibraryState, assets: [BrushTipImageAsset]) -> BrushLibraryState {
        let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return resolveLibrary(library, lookup: lookup)
    }

    static func resolveTipImageLibrary(
        _ library: TipImageLibraryState,
        assets: [BrushTipImageAsset]
    ) -> TipImageLibraryState {
        let lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        return resolveTipImageLibrary(library, lookup: lookup)
    }

    private static func archivedBrushLibrary(
        _ library: BrushLibraryState,
        collector: inout AssetCollector
    ) -> BrushLibraryState {
        var normalized = library
        normalized.presets = library.presets.map { preset in
            var normalizedPreset = preset
            normalizedPreset.brush = collector.archivedBrush(preset.brush)
            return normalizedPreset
        }
        return normalized
    }

    private static func archivedTipImageLibrary(
        _ library: TipImageLibraryState,
        collector: inout AssetCollector
    ) -> TipImageLibraryState {
        var normalized = library
        normalized.items = library.items.map { item in
            var archivedItem = item
            if let maskData = item.maskData {
                let asset = BrushTipImageAsset(id: item.id, maskData: maskData)
                collector.insertAsset(asset)
                archivedItem.maskData = nil
            }
            return archivedItem
        }
        return normalized
    }

    private static func resolveLibrary(
        _ library: BrushLibraryState,
        lookup: [BrushTipImageAssetID: BrushTipImageAsset]
    ) -> BrushLibraryState {
        var resolved = library
        resolved.presets = library.presets.map { preset in
            var resolvedPreset = preset
            resolvedPreset.brush = resolveBrush(preset.brush, lookup: lookup)
            return resolvedPreset
        }
        return resolved
    }

    private static func resolveTipImageLibrary(
        _ library: TipImageLibraryState,
        lookup: [BrushTipImageAssetID: BrushTipImageAsset]
    ) -> TipImageLibraryState {
        var resolved = library
        resolved.items = library.items.map { item in
            var resolvedItem = item
            if let asset = lookup[item.id] {
                resolvedItem.maskData = asset.maskData
            }
            return resolvedItem
        }
        return resolved
    }

    private static func resolveBrush(
        _ brush: BrushSettings,
        lookup: [BrushTipImageAssetID: BrushTipImageAsset]
    ) -> BrushSettings {
        var resolved = brush

        if resolved.customTipSourceSemantic == .importedImage,
           let assetID = resolved.customTipAssetID,
           let asset = lookup[assetID] {
            resolved.customTipMaskData = asset.maskData
        }

        if resolved.secondaryTipDescriptor.sourceSemantic == .importedImage,
           let assetID = resolved.secondaryTipDescriptor.tipAssetID,
           let asset = lookup[assetID] {
            resolved.secondaryTipDescriptor.customTipMaskData = asset.maskData
        }

        return resolved
    }

    private struct AssetCollector {
        private var assetsByID: [BrushTipImageAssetID: BrushTipImageAsset] = [:]

        var assets: [BrushTipImageAsset] {
            assetsByID.values.sorted { $0.id < $1.id }
        }

        mutating func insertAsset(_ asset: BrushTipImageAsset) {
            assetsByID[asset.id] = asset
        }

        mutating func archivedBrush(_ brush: BrushSettings) -> BrushSettings {
            var normalized = brush

            if normalized.customTipSourceSemantic == .importedImage {
                if let maskData = normalized.customTipMaskData {
                    let asset = BrushTipImageAsset(maskData: maskData)
                    insertAsset(asset)
                    normalized.customTipAssetID = asset.id
                }
                normalized.customTipMaskData = nil
            } else {
                normalized.customTipAssetID = nil
            }

            normalized.secondaryTipDescriptor = archivedSecondaryTip(normalized.secondaryTipDescriptor)
            return normalized
        }

        private mutating func archivedSecondaryTip(_ secondary: SecondaryTipDescriptor) -> SecondaryTipDescriptor {
            var normalized = secondary

            if normalized.sourceSemantic == .importedImage {
                if let maskData = normalized.customTipMaskData {
                    let asset = BrushTipImageAsset(maskData: maskData)
                    insertAsset(asset)
                    normalized.tipAssetID = asset.id
                }
                normalized.customTipMaskData = nil
            } else {
                normalized.tipAssetID = nil
            }

            return normalized
        }
    }
}
