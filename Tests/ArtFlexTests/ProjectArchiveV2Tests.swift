import Foundation
import Testing
@testable import ArtFlex

struct ProjectArchiveV2Tests {
    @Test
    func zlibRoundTripsStandardStreamAndRejectsTrailingBytes() throws {
        let source = Data((0..<16_384).map { UInt8($0 % 251) })

        let compressed = try ZlibCodec.compress(source)
        #expect(compressed.starts(with: [0x78]))
        #expect(try ZlibCodec.decompress(compressed, expectedSize: source.count) == source)

        var withTrailingByte = compressed
        withTrailingByte.append(0)
        #expect(throws: ZlibCodecError.self) {
            try ZlibCodec.decompress(withTrailingByte, expectedSize: source.count)
        }
    }

    @Test
    func relativePathValidationRejectsTraversalAbsoluteAndAmbiguousPaths() throws {
        #expect(try ProjectArchiveRelativePath.validate("layers/a.bgra.zlib") == ["layers", "a.bgra.zlib"])

        for path in ["../outside", "/absolute", "layers/../outside", "layers//a", "layers\\a"] {
            #expect(throws: ProjectArchiveV2Error.self) {
                try ProjectArchiveRelativePath.validate(path)
            }
        }
    }

    @Test
    func referenceImagePayloadUsesContentAddressAndRejectsMismatchedData() throws {
        let data = Data([1, 3, 3, 7])
        let first = try ProjectReferenceImagePayload(
            slotIndex: 1,
            displayName: "参考",
            originalFilename: "reference.png",
            typeIdentifier: "public.png",
            pixelWidth: 64,
            pixelHeight: 48,
            encodedImageData: data
        )
        let secondID = ProjectReferenceImageAssetID(encodedImageData: data)

        #expect(first.descriptor.assetID == secondID)
        #expect(first.descriptor.assetID.rawValue.hasPrefix("reference-"))
        #expect(throws: ProjectReferenceImageError.assetIdentifierMismatch) {
            try ProjectReferenceImagePayload(
                descriptor: first.descriptor,
                encodedImageData: Data([9, 9, 9])
            )
        }
    }

    @Test
    func archiveRoundTripsProjectLayersAndSelfContainedReferences() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("RoundTrip.artflex", isDirectory: true)
        let payload = try makePayload(pixelSeed: 11)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let manifest = try ProjectArchiveV2Writer().write(
            payload,
            to: archiveURL,
            savedAt: savedAt
        )
        let restored = try ProjectArchiveV2Reader().read(from: archiveURL)

        #expect(manifest.formatIdentifier == ProjectArchiveV2Manifest.formatIdentifier)
        #expect(manifest.formatVersion == 2)
        #expect(manifest.savedAt == savedAt)
        #expect(manifest.layers.count == payload.package.layerSnapshots.count)
        #expect(manifest.layers.allSatisfy { $0.asset.compression == .zlib })
        #expect(restored == payload)
    }

    @Test
    func archiveRoundTripsLayerMaskAsIndependentR8Resource() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("Mask.artflex", isDirectory: true)
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = CanvasSize(width: 3, height: 2)
        workspace.document.metadata.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        workspace.document.metadata.updatedAt = Date(timeIntervalSince1970: 1_700_000_001)
        let maskedLayerID = workspace.document.paintLayers[0].id
        let maskedLayerIndex = try #require(
            workspace.document.layers.firstIndex(where: { $0.id == maskedLayerID })
        )
        workspace.document.layers[maskedLayerIndex].mask = LayerMaskDescriptor(isEnabled: true)

        var snapshots = workspace.document.paintLayers.map { layer in
            LayerHistorySnapshot(
                layerID: layer.id,
                texture: LayerTextureSnapshot(
                    width: 3,
                    height: 2,
                    bytesPerRow: 12,
                    pixelData: Data(repeating: 77, count: 24)
                )
            )
        }
        snapshots.append(
            LayerHistorySnapshot(
                layerID: maskedLayerID,
                resourceKind: .mask,
                texture: LayerTextureSnapshot(
                    width: 3,
                    height: 2,
                    bytesPerRow: 3,
                    pixelData: Data([0, 64, 128, 192, 224, 255])
                )
            )
        )
        let payload = ProjectArchivePayload(
            package: ProjectPackage.fromWorkspace(workspace, layerSnapshots: snapshots)
        )

        let manifest = try ProjectArchiveV2Writer().write(payload, to: archiveURL)
        let restored = try ProjectArchiveV2Reader().read(from: archiveURL)

        #expect(manifest.layers.count == snapshots.count)
        #expect(manifest.layers.contains {
            $0.layerID == maskedLayerID &&
                $0.resourceKind == .mask &&
                $0.pixelFormat == .grayscale8Unorm &&
                $0.bytesPerRow == 3
        })
        #expect(restored == payload)
    }

    @Test
    func archiveRoundTripsFullResolutionSavedSnapshotsAsCheckedResources() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("Snapshots.artflex", isDirectory: true)
        var payload = try makePayload(pixelSeed: 41)
        let descriptor = PersistentCanvasSnapshotDescriptor(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000811")!,
            displayName: "快照 1",
            createdAt: Date(timeIntervalSince1970: 1_700_000_123),
            canvasSize: .init(width: 3, height: 2),
            pixelResourceID: CanvasPixelResourceID(
                rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000812")!
            )
        )
        payload.savedSnapshots = [
            PersistentCanvasSnapshotPayload(
                descriptor: descriptor,
                pixels: LayerTextureSnapshot(
                    width: 3,
                    height: 2,
                    bytesPerRow: 12,
                    pixelData: Data((0..<24).map(UInt8.init))
                )
            )
        ]

        let manifest = try ProjectArchiveV2Writer().write(payload, to: archiveURL)
        let restored = try ProjectArchiveV2Reader().read(from: archiveURL)

        #expect(manifest.savedSnapshots.count == 1)
        #expect(manifest.savedSnapshots[0].asset.compression == .zlib)
        #expect(manifest.savedSnapshots[0].asset.relativePath.hasPrefix("snapshots/"))
        #expect(restored == payload)
    }

    @Test
    func archiveReaderTreatsMissingSavedSnapshotsKeyAsEmptyForOlderV2Packages() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("OldV2.artflex", isDirectory: true)
        let payload = try makePayload(pixelSeed: 12)
        try ProjectArchiveV2Writer().write(payload, to: archiveURL)

        let manifestURL = archiveURL.appendingPathComponent(ProjectArchiveV2Manifest.manifestFilename)
        let manifestData = try Data(contentsOf: manifestURL)
        var object = try #require(
            JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        object.removeValue(forKey: "savedSnapshots")
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let restored = try ProjectArchiveV2Reader().read(from: archiveURL)
        #expect(restored == payload)
        #expect(restored.savedSnapshots.isEmpty)
    }

    @Test
    func archiveWriterRejectsMoreThanSixSavedSnapshots() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var payload = try makePayload(pixelSeed: 22)
        payload.savedSnapshots = (0..<7).map { index in
            PersistentCanvasSnapshotPayload(
                descriptor: PersistentCanvasSnapshotDescriptor(
                    displayName: "快照 \(index + 1)",
                    createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                    canvasSize: .init(width: 3, height: 2),
                    pixelResourceID: CanvasPixelResourceID()
                ),
                pixels: LayerTextureSnapshot(
                    width: 3,
                    height: 2,
                    bytesPerRow: 12,
                    pixelData: Data(repeating: UInt8(index), count: 24)
                )
            )
        }

        #expect(throws: ProjectArchiveV2Error.self) {
            try ProjectArchiveV2Writer().write(
                payload,
                to: root.appendingPathComponent("TooMany.artflex", isDirectory: true)
            )
        }
    }

    @Test
    func archiveWriterAtomicallyReplacesExistingDirectoryPackage() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("Replace.artflex", isDirectory: true)
        let first = try makePayload(pixelSeed: 17)
        let second = try makePayload(pixelSeed: 93)

        try ProjectArchiveV2Writer().write(first, to: archiveURL)
        try ProjectArchiveV2Writer().write(second, to: archiveURL)

        #expect(try ProjectArchiveV2Reader().read(from: archiveURL) == second)
    }

    @Test
    func archiveWriterSupportsSavePanelStylePathUnderTmpSymlink() throws {
        let root = URL(
            fileURLWithPath: "/tmp/ArtFlex-ProjectArchiveV2Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("SavePanel.artflex", isDirectory: true)
        let payload = try makePayload(pixelSeed: 73)

        try ProjectArchiveV2Writer().write(payload, to: archiveURL)

        #expect(try ProjectArchiveV2Reader().read(from: archiveURL) == payload)
    }

    @Test
    func archiveReaderRejectsUnsupportedFutureManifest() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("Future.artflex", isDirectory: true)
        try ProjectArchiveV2Writer().write(try makePayload(pixelSeed: 4), to: archiveURL)

        let manifestURL = archiveURL.appendingPathComponent(ProjectArchiveV2Manifest.manifestFilename)
        var manifest = try makeDecoder().decode(
            ProjectArchiveV2Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        manifest.formatVersion = 999
        try makeEncoder().encode(manifest).write(to: manifestURL, options: .atomic)

        #expect(throws: ProjectArchiveV2Error.unsupportedFormatVersion(999)) {
            try ProjectArchiveV2Reader().read(from: archiveURL)
        }
    }

    @Test
    func archiveReaderRejectsReferenceChecksumMismatchWithoutTouchingProjectState() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archiveURL = root.appendingPathComponent("Corrupt.artflex", isDirectory: true)
        try ProjectArchiveV2Writer().write(try makePayload(pixelSeed: 31), to: archiveURL)

        let manifestURL = archiveURL.appendingPathComponent(ProjectArchiveV2Manifest.manifestFilename)
        let manifest = try makeDecoder().decode(
            ProjectArchiveV2Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let referenceAsset = try #require(manifest.referenceImages.first?.asset)
        let referenceURL = archiveURL.appendingPathComponent(referenceAsset.relativePath)
        var corrupted = try Data(contentsOf: referenceURL)
        corrupted[0] ^= 0xff
        try corrupted.write(to: referenceURL, options: .atomic)

        #expect(throws: ProjectArchiveV2Error.checksumMismatch(referenceAsset.relativePath)) {
            try ProjectArchiveV2Reader().read(from: archiveURL)
        }
    }

    private func makePayload(pixelSeed: UInt8) throws -> ProjectArchivePayload {
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = CanvasSize(width: 3, height: 2)
        workspace.document.metadata.createdAt = Date(timeIntervalSince1970: 1_600_000_000)
        workspace.document.metadata.updatedAt = Date(timeIntervalSince1970: 1_600_000_100)

        let snapshots = workspace.document.paintLayers.enumerated().map { index, layer in
            LayerHistorySnapshot(
                layerID: layer.id,
                texture: LayerTextureSnapshot(
                    width: 3,
                    height: 2,
                    bytesPerRow: 12,
                    pixelData: Data(repeating: pixelSeed &+ UInt8(index), count: 24)
                )
            )
        }
        let package = ProjectPackage.fromWorkspace(workspace, layerSnapshots: snapshots)
        let reference = try ProjectReferenceImagePayload(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000909")!,
            slotIndex: 2,
            displayName: "构图参考",
            originalFilename: "composition.png",
            typeIdentifier: "public.png",
            pixelWidth: 320,
            pixelHeight: 180,
            encodedImageData: Data([137, 80, 78, 71, pixelSeed])
        )
        return ProjectArchivePayload(package: package, referenceImages: [reference])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlex-ProjectArchiveV2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
