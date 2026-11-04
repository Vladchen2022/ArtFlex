import Foundation

/// A closed branch owns an immutable native-project asset, not a live canvas or undo stack.
struct StoredIdeationBranch: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let savedAt: Date
    var project: EditableSourceAsset
    var canvasSize: CanvasSize
    var layerCount: Int

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 128,
              layerCount > 0, layerCount <= 4096, canvasSize.width > 0, canvasSize.height > 0,
              canvasSize.width <= 32768, canvasSize.height <= 32768 else { throw CocoaError(.fileReadCorruptFile) }
    }
}
