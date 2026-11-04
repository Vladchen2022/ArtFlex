import Foundation

enum IdeationBranchArchive {
    /// Existing native writer/reader remains the single integrity and compatibility boundary.
    static func encode(_ payload: ProjectArchivePayload, name: String, limits: ProjectArchiveReadLimits) throws -> StoredIdeationBranch {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-Branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var payload = payload
        payload.package.document.storedBranches = nil // A branch cannot recursively capture the shelf.
        let package = root.appendingPathComponent("package"), file = root.appendingPathComponent("branch.artflex")
        _ = try ProjectArchiveV2Writer(limits: limits).write(payload, to: package)
        try ProjectArchiveFlatContainer().encodePackage(at: package, to: file)
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        guard bytes.count <= limits.maximumUncompressedAssetBytes else { throw CanvasResourceError(message: "该方案超过单个工程资产上限，请另存为独立工程") }
        let branch = try StoredIdeationBranch(id: UUID(), name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128)),
            savedAt: Date(), project: .init(data: bytes), canvasSize: payload.package.document.canvasSize,
            layerCount: payload.package.document.paintLayers.count)
        try branch.validate()
        return branch
    }

    static func decode(_ branch: StoredIdeationBranch, limits: ProjectArchiveReadLimits) throws -> ProjectArchivePayload {
        try branch.validate()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArtFlex-Branch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("branch.artflex")
        try branch.project.decoded(maximumBytes: limits.maximumUncompressedAssetBytes).write(to: file)
        let result = try ProjectArchiveFlatContainer().withExtractedPackage(from: file, limits: limits) {
            try ProjectArchiveV2Reader(limits: limits).read(from: $0)
        }
        guard result.package.document.storedBranches?.isEmpty != false,
              result.package.document.canvasSize == branch.canvasSize,
              result.package.document.paintLayers.count == branch.layerCount else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
}
