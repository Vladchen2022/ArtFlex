import Foundation

/// A user-managed category in the reusable 3D block library.
/// Kept in Core so the library can later be shared by non-macOS frontends.
struct BlockReferenceModuleCategory: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var name: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

/// A module is deliberately stored as editable scene objects rather than a flattened mesh.
/// Each object's position is relative to the module's chosen base point.
struct BlockReferenceModuleAsset: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var categoryID: UUID
    var name: String
    var templateObjects: [BlockReferenceObject]
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        categoryID: UUID,
        name: String,
        sourceObjects: [BlockReferenceObject],
        basePoint: BlockVector3,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.categoryID = categoryID
        self.name = Self.normalizedName(name)
        self.templateObjects = sourceObjects.prefix(256).map { source in
            var template = source
            template.id = UUID()
            template.position = source.position - basePoint
            template.groupID = nil
            template.isVisible = true
            template.isLocked = false
            template.normalize()
            return template
        }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var symbolName: String {
        templateObjects.count == 1
            ? (templateObjects.first?.geometrySymbolName ?? "cube")
            : "cube.transparent"
    }

    func instantiate(
        at basePoint: BlockVector3,
        grouped: Bool
    ) -> BlockReferenceModuleInstantiation? {
        guard !templateObjects.isEmpty else { return nil }
        let instanceID = UUID()
        let groupID = grouped && templateObjects.count > 1 ? UUID() : nil
        let objects = templateObjects.map { template -> BlockReferenceObject in
            var object = template
            object.id = UUID()
            object.position = basePoint + template.position
            object.groupID = groupID
            object.isVisible = true
            object.isLocked = false
            object.normalize()
            return object
        }
        let group = groupID.map {
            BlockReferenceGroup(id: $0, name: name, pivot: basePoint)
        }
        return BlockReferenceModuleInstantiation(
            objects: objects,
            group: group,
            instance: BlockReferenceCustomModuleInstance(
                id: instanceID,
                assetID: id,
                objectIDs: objects.map(\.id),
                basePoint: basePoint
            )
        )
    }

    static func normalizedName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "未命名模块" : trimmed).prefix(48))
    }
}

struct BlockReferenceModuleInstantiation: Sendable, Equatable {
    var objects: [BlockReferenceObject]
    var group: BlockReferenceGroup?
    var instance: BlockReferenceCustomModuleInstance
}

/// Scene-local provenance for a loaded library module.
/// It enables overwrite/save-as-new/detach without coupling every object to library storage.
struct BlockReferenceCustomModuleInstance: Identifiable, Codable, Sendable, Equatable {
    var id: UUID
    var assetID: UUID
    var objectIDs: [UUID]
    var basePoint: BlockVector3

    init(
        id: UUID = UUID(),
        assetID: UUID,
        objectIDs: [UUID],
        basePoint: BlockVector3
    ) {
        self.id = id
        self.assetID = assetID
        var seenObjectIDs = Set<UUID>()
        self.objectIDs = objectIDs.filter { seenObjectIDs.insert($0).inserted }.prefix(256).map { $0 }
        self.basePoint = basePoint
    }
}

struct BlockReferenceModuleLibraryState: Codable, Sendable, Equatable {
    static let defaultCategoryID = UUID(uuidString: "A27F5D49-F92C-47D7-B418-0F269561C115")!

    var categories: [BlockReferenceModuleCategory]
    var modules: [BlockReferenceModuleAsset]
    var selectedCategoryID: UUID

    init(
        categories: [BlockReferenceModuleCategory] = [],
        modules: [BlockReferenceModuleAsset] = [],
        selectedCategoryID: UUID = Self.defaultCategoryID
    ) {
        self.categories = categories
        self.modules = modules
        self.selectedCategoryID = selectedCategoryID
        normalize()
    }

    static let empty = BlockReferenceModuleLibraryState()

    mutating func normalize() {
        var seenCategoryIDs = Set<UUID>()
        categories = categories.filter { seenCategoryIDs.insert($0.id).inserted }
        if !categories.contains(where: { $0.id == Self.defaultCategoryID }) {
            categories.insert(
                BlockReferenceModuleCategory(
                    id: Self.defaultCategoryID,
                    name: "自定义",
                    createdAt: .distantPast
                ),
                at: 0
            )
        }
        categories = Array(categories.prefix(64))
        let validCategoryIDs = Set(categories.map(\.id))
        var seenModuleIDs = Set<UUID>()
        modules = modules
            .filter { !$0.templateObjects.isEmpty && seenModuleIDs.insert($0.id).inserted }
            .prefix(512)
            .map { asset in
                guard validCategoryIDs.contains(asset.categoryID) else {
                    var repaired = asset
                    repaired.categoryID = Self.defaultCategoryID
                    return repaired
                }
                return asset
            }
        if !validCategoryIDs.contains(selectedCategoryID) {
            selectedCategoryID = Self.defaultCategoryID
        }
    }

    @discardableResult
    mutating func addCategory(named name: String) -> BlockReferenceModuleCategory? {
        let normalized = Self.normalizedCategoryName(name)
        guard !normalized.isEmpty,
              categories.count < 64,
              !categories.contains(where: { $0.name.caseInsensitiveCompare(normalized) == .orderedSame })
        else { return nil }
        let category = BlockReferenceModuleCategory(name: normalized)
        categories.append(category)
        selectedCategoryID = category.id
        return category
    }

    @discardableResult
    mutating func addModule(
        named name: String,
        categoryID: UUID,
        sourceObjects: [BlockReferenceObject],
        basePoint: BlockVector3
    ) -> BlockReferenceModuleAsset? {
        guard !sourceObjects.isEmpty, modules.count < 512 else { return nil }
        let resolvedCategoryID = categories.contains(where: { $0.id == categoryID })
            ? categoryID
            : Self.defaultCategoryID
        let asset = BlockReferenceModuleAsset(
            categoryID: resolvedCategoryID,
            name: name,
            sourceObjects: sourceObjects,
            basePoint: basePoint
        )
        modules.append(asset)
        selectedCategoryID = resolvedCategoryID
        return asset
    }

    @discardableResult
    mutating func replaceModule(
        id: UUID,
        sourceObjects: [BlockReferenceObject],
        basePoint: BlockVector3
    ) -> BlockReferenceModuleAsset? {
        guard !sourceObjects.isEmpty,
              let index = modules.firstIndex(where: { $0.id == id })
        else { return nil }
        let existing = modules[index]
        let replacement = BlockReferenceModuleAsset(
            id: existing.id,
            categoryID: existing.categoryID,
            name: existing.name,
            sourceObjects: sourceObjects,
            basePoint: basePoint,
            createdAt: existing.createdAt,
            updatedAt: Date()
        )
        modules[index] = replacement
        selectedCategoryID = replacement.categoryID
        return replacement
    }

    func modules(in categoryID: UUID) -> [BlockReferenceModuleAsset] {
        modules.filter { $0.categoryID == categoryID }
    }

    func module(id: UUID) -> BlockReferenceModuleAsset? {
        modules.first { $0.id == id }
    }

    private static func normalizedCategoryName(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
    }
}
