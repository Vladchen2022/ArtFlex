import Combine
import CoreGraphics
import Foundation

struct CanvasSavedSnapshot: Identifiable {
    let id: UUID
    let snapshot: LayerTextureSnapshot
    var thumbnailImage: CGImage?
    var previewImage: CGImage?
}

enum SnapshotCompareSlot: Int, CaseIterable, Identifiable {
    case topLeading
    case topTrailing
    case bottomLeading

    var id: Int { rawValue }
}

@MainActor
final class SnapshotCompareSessionState: ObservableObject {
    @Published var selectedSnapshotID: UUID?
    @Published private(set) var slotAssignments: [UUID?]
    @Published private(set) var frozenCurrentSnapshot: CanvasSavedSnapshot

    init(frozenCurrentSnapshot: CanvasSavedSnapshot) {
        self.frozenCurrentSnapshot = frozenCurrentSnapshot
        self.slotAssignments = Array(repeating: nil, count: SnapshotCompareSlot.allCases.count)
    }

    func assignedSnapshotID(for slot: SnapshotCompareSlot) -> UUID? {
        slotAssignments[slot.rawValue]
    }

    func assignSnapshot(_ snapshotID: UUID, to slot: SnapshotCompareSlot) {
        for index in slotAssignments.indices where slotAssignments[index] == snapshotID {
            slotAssignments[index] = nil
        }
        slotAssignments[slot.rawValue] = snapshotID
        selectedSnapshotID = snapshotID
    }

    func clearSlot(_ slot: SnapshotCompareSlot) {
        slotAssignments[slot.rawValue] = nil
    }

    func removeSnapshot(_ snapshotID: UUID) {
        for index in slotAssignments.indices where slotAssignments[index] == snapshotID {
            slotAssignments[index] = nil
        }
        if selectedSnapshotID == snapshotID {
            selectedSnapshotID = nil
        }
    }

    func updateFrozenCurrentSnapshot(_ snapshot: CanvasSavedSnapshot) {
        frozenCurrentSnapshot = snapshot
    }
}
