import Foundation
import Testing
@testable import ArtFlex

struct PersistentCanvasSnapshotDescriptorTests {
    @Test
    func descriptorRoundTripsWithoutEmbeddingPixelBytes() throws {
        let descriptor = PersistentCanvasSnapshotDescriptor(
            id: UUID(),
            displayName: "构图方案 A",
            createdAt: Date(timeIntervalSince1970: 1_725_000_000),
            canvasSize: .init(width: 3_000, height: 2_000),
            pixelResourceID: CanvasPixelResourceID(),
            thumbnailResourceID: CanvasPixelResourceID()
        )

        let data = try JSONEncoder().encode(descriptor)
        let restored = try JSONDecoder().decode(PersistentCanvasSnapshotDescriptor.self, from: data)

        #expect(restored == descriptor)
        #expect(restored.kind == .flattenedCanvas)
        #expect(!data.isEmpty)
        #expect(data.count < 2_048)
    }

    @Test
    func descriptorMakesFlattenedSemanticsExplicit() {
        let descriptor = PersistentCanvasSnapshotDescriptor(
            displayName: "快照 1",
            canvasSize: .init(width: 512, height: 512),
            pixelResourceID: CanvasPixelResourceID()
        )

        #expect(descriptor.kind == .flattenedCanvas)
        #expect(descriptor.thumbnailResourceID == nil)
    }
}
