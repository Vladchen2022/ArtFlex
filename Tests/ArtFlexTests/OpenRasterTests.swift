import Foundation
import Testing
import ZIPFoundation
@testable import ArtFlex

struct OpenRasterTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ora-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture() -> (ProjectArchivePayload, LayerTextureSnapshot) {
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = .init(width: 16, height: 16)
        let base = state.document.layers[0]
        let group = LayerRecord(id: .init(), name: "组 & <名称>", kind: .group, isVisible: true, isLocked: false, locksTransparentPixels: false, opacity: 0.7)
        let top = LayerRecord(id: .init(), name: "顶层", parentID: group.id, isVisible: false, isLocked: false, locksTransparentPixels: false, opacity: 0.4, blendMode: .multiply)
        state.document.layers = [base, group, top]; state.document.activeLayerID = top.id
        let pixels = LayerTextureSnapshot(width: 16, height: 16, bytesPerRow: 64,
            pixelData: Data(Array(repeating: [UInt8(10), 20, 120, 255], count: 256).flatMap { $0 }))
        let small = LayerTextureSnapshot(width: 8, height: 8, bytesPerRow: 32,
            pixelData: Data(Array(repeating: [UInt8(100), 50, 10, 128], count: 64).flatMap { $0 }))
        return (.init(package: .fromWorkspace(state, layerSnapshots: [.init(layerID: base.id, texture: pixels), .init(layerID: top.id, texture: small, originX: 3, originY: 4)])), pixels)
    }

    @Test func layeredRoundTripKeepsStackGroupsOffsetsVisibilityOpacityAndPixels() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("交换.ora"), (payload, merged) = fixture()
        try OpenRasterCodec.write(payload, merged: merged, to: url)
        let archive = try Archive(url: url, accessMode: .read)
        #expect(Array(archive).first?.path == "mimetype")
        #expect(archive["mergedimage.png"] != nil && archive["Thumbnails/thumbnail.png"] != nil)
        let read = try OpenRasterCodec.read(from: url)
        #expect(read.workspace.document.layers.map(\.name) == payload.package.document.layers.map(\.name))
        let group = read.workspace.document.layers[1], top = read.workspace.document.layers[2]
        #expect(group.isGroup && group.opacity == 0.7 && top.parentID == group.id)
        #expect(!top.isVisible && top.opacity == 0.4 && top.blendMode == .multiply)
        #expect(read.layerSnapshots[1].originX == 3 && read.layerSnapshots[1].originY == 4)
        #expect(read.layerSnapshots[0].texture == merged)
        let a = read.layerSnapshots[1].texture.linearPixel(x: 3, y: 3)
        let b = payload.package.layerSnapshots[1].texture.linearPixel(x: 3, y: 3)
        #expect(abs(a.red - b.red) < 0.01 && abs(a.alpha - b.alpha) < 0.005)
    }

    @Test func effectsRequireExplicitFlattenAndCancellationPreservesDestination() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("protected.ora")
        var (payload, merged) = fixture()
        payload.package.document.layers[0].mask = .init()
        #expect(throws: (any Error).self) { try OpenRasterCodec.write(payload, merged: merged, to: url) }
        try OpenRasterCodec.write(payload, merged: merged, to: url, flattened: true)
        let original = try Data(contentsOf: url)
        let loaded = try OpenRasterCodec.read(from: url)
        #expect(loaded.workspace.document.layers.count == 1)
        let token = WorkCancellation()
        let context = ProjectReadContext(cancellation: token) { if $0.phase == .writing { token.cancel() } }
        payload.package.document.layers[0].mask = nil
        #expect(throws: (any Error).self) { try OpenRasterCodec.write(payload, merged: merged, to: url, context: context) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["protected.ora"])
        #expect(throws: (any Error).self) { try OpenRasterCodec.read(from: url, context: context) }
    }

    private func replaceXML(_ xml: String, original: URL, output: URL, extra: String? = nil) throws {
        let input = try Archive(url: original, accessMode: .read), archive = try Archive(url: output, accessMode: .create)
        func add(_ path: String, _ bytes: Data) throws {
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(bytes.count)) { pos, count in
                bytes.subdata(in: Int(pos)..<min(bytes.count, Int(pos) + count))
            }
        }
        for entry in input where entry.path != "stack.xml" {
            var bytes = Data(); _ = try input.extract(entry) { bytes.append($0) }; try add(entry.path, bytes)
        }
        try add("stack.xml", Data(xml.utf8))
        if let extra { try add(extra, Data([1])) }
    }

    @Test func unsafeZIPXMLDimensionsAndUnsupportedIsolationAreRejected() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original.ora"), (payload, merged) = fixture()
        try OpenRasterCodec.write(payload, merged: merged, to: original)
        let invalid = [
            "<!DOCTYPE image [<!ENTITY a SYSTEM 'file:///etc/passwd'>]><image w='16' h='16'><stack/></image>",
            "<image w='999999999999' h='16'><stack/></image>",
            "<image w='16' h='16'><stack><stack><layer src='mergedimage.png'/></stack></stack></image>",
            "<image w='16' h='16'><stack><layer src='mergedimage.png' opacity='nan'/></stack></image>",
            "<image w='16' h='16'><stack><layer src='mergedimage.png' x='-1'/></stack></image>"
        ]
        for (index, xml) in invalid.enumerated() {
            let url = root.appendingPathComponent("bad\(index).ora")
            try replaceXML(xml, original: original, output: url)
            #expect(throws: (any Error).self) { try OpenRasterCodec.read(from: url) }
            if index == 2 { #expect(try OpenRasterCodec.read(from: url, flattened: true).workspace.document.layers.count == 1) }
        }
        let path = root.appendingPathComponent("path.ora")
        try replaceXML("<image w='16' h='16'><stack/></image>", original: original, output: path, extra: "../escape")
        #expect(throws: (any Error).self) { try OpenRasterCodec.read(from: path) }
        var limits = ProjectArchiveReadLimits.standard; limits.maximumTotalUncompressedBytes = 8
        #expect(throws: (any Error).self) { try OpenRasterCodec.read(from: original, limits: limits) }
    }
}
