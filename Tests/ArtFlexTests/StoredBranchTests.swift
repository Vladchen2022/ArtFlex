import Foundation
import Testing
@testable import ArtFlex

struct StoredBranchTests {
    private func payload() throws -> ProjectArchivePayload {
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 16, height: 16)
        workspace.document.metadata.createdAt = Date(timeIntervalSince1970: 1000)
        workspace.document.metadata.updatedAt = Date(timeIntervalSince1970: 1000)
        let group = LayerRecord(id: LayerID(), name: "结构组", kind: .group, isVisible: true, isLocked: false, locksTransparentPixels: false, opacity: 0.7)
        workspace.document.layers[1].parentID = group.id
        workspace.document.layers[1].mask = .init()
        workspace.document.layers.insert(group, at: 1)
        let snapshot = LayerTextureSnapshot(width: 16, height: 16, bytesPerRow: 64, pixelData: Data(repeating: 127, count: 1024))
        workspace.document.layers[2].editableContent = try .init(source: .init(snapshot: snapshot), operation: .image(.init()))
        let clip = LayerRecord(id: LayerID(), name: "剪贴纹理", parentID: group.id, isVisible: true, isLocked: false,
            locksTransparentPixels: false, opacity: 0.8, blendMode: .multiply, clipTargetLayerID: workspace.document.layers[2].id)
        workspace.document.layers.append(clip)
        workspace.document.activeLayerID = clip.id
        var snapshots = workspace.document.paintLayers.map { LayerHistorySnapshot(layerID: $0.id, texture: snapshot) }
        snapshots.append(.init(layerID: workspace.document.layers[2].id, resourceKind: .mask,
            texture: .init(width: 16, height: 16, bytesPerRow: 16, pixelData: Data(repeating: 200, count: 256), encoding: .grayscale8)))
        return .init(package: .fromWorkspace(workspace, layerSnapshots: snapshots), referenceImages: [])
    }

    @Test func namedBranchRoundTripsInsideNativeProjectWithoutRecursiveShelf() throws {
        var input = try payload()
        let branch = try IdeationBranchArchive.encode(input, name: "透视方案", limits: .standard)
        input.package.document.storedBranches = [branch]
        let second = try IdeationBranchArchive.encode(input, name: "第二方案", limits: .standard)
        #expect(try IdeationBranchArchive.decode(second, limits: .standard).package.document.storedBranches == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ProjectArchiveV2Writer().write(input, to: root)
        let outer = try ProjectArchiveV2Reader().read(from: root)
        let reopened = try #require(outer.package.document.storedBranches?.first)
        #expect(reopened.name == branch.name)
        let content = try IdeationBranchArchive.decode(reopened, limits: .standard)
        #expect(content.package.layerSnapshots == input.package.layerSnapshots)
        #expect(content.package.document.layers == input.package.document.layers)
        #expect(try content.package.document.layers[2].editableContent?.source.snapshot().pixelData == Data(repeating: 127, count: 1024))
    }

    @Test func partialImportIncludesDependenciesAndRetainsSeparateMaskAndEditableSource() throws {
        let source = try payload()
        var destination = ArtDocument.stageOneDefault()
        destination.canvasSize = source.package.document.canvasSize
        let selected = source.package.document.activeLayerID
        let plan = try LayerSubsetImport.prepare(source: source, selected: [selected], destination: destination, name: "合入方案")
        #expect(plan.importedLayerIDs.count == 3) // clip, its base, and its ancestor group; excludes background.
        #expect(plan.document.layers.count == destination.layers.count + 4)
        #expect(plan.importedLayerIDs.isDisjoint(with: source.package.document.layers.map(\.id)))
        let clip = try #require(plan.document.layers.first { $0.name == "剪贴纹理" })
        let base = try #require(clip.clipTargetLayerID.flatMap { plan.document.layer($0) })
        #expect(base.mask != nil && base.editableContent != nil)
        #expect(clip.blendMode == .multiply && clip.opacity == 0.8)
        #expect(plan.snapshots.contains { $0.layerID == base.id && $0.resourceKind == .mask })
        #expect(plan.document.layer(clip.parentID!)?.opacity == 0.7)
    }

    @Test @MainActor func importingBranchIsAtomicAndUndoRestoresOriginalTopology() throws {
        let source = try payload()
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = source.package.document.canvasSize
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: workspace))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        let oldLayers = vm.workspace.document.layers
        let version = vm.branchDocumentVersion
        #expect(vm.importBranchLayers(source, selected: [source.package.document.activeLayerID], name: "方案", expectedVersion: version))
        let imported = vm.workspace.document.layers
        #expect(imported.count == oldLayers.count + 4)
        #expect(!vm.importBranchLayers(source, selected: [source.package.document.activeLayerID], name: "过期", expectedVersion: version))
        #expect(vm.workspace.document.layers == imported)
        vm.undo(); #expect(vm.workspace.document.layers == oldLayers)
        vm.redo(); #expect(vm.workspace.document.layers == imported)
    }

    @Test @MainActor func storedShelfSaveRenameDeleteAndReloadKeepMainDocumentIndependent() async throws {
        var workspace = WorkspaceState.stageOneDefault
        workspace.document.canvasSize = .init(width: 16, height: 16)
        let bootstrap = try AppBootstrap(workspaceStore: WorkspaceStore(state: workspace))
        let vm = WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false)
        vm.branches.storeCurrent(name: "主稿分支")
        for _ in 0..<500 where vm.branches.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let branch = try #require(vm.workspace.document.storedBranches?.first)
        vm.branches.rename(branch.id, name: "另一个名称")
        #expect(vm.workspace.document.storedBranches?.first?.name == "另一个名称")
        vm.branches.delete(branch.id)
        #expect(vm.workspace.document.storedBranches == nil)
        vm.undo()
        #expect(vm.workspace.document.storedBranches?.first?.id == branch.id)
        let originalLayers = vm.workspace.document.layers
        vm.branches.load(branch, forEditing: true)
        for _ in 0..<500 where vm.branches.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        let session = try #require(vm.ideationSession)
        session.activeBranchViewModel.addLayer()
        #expect(vm.workspace.document.layers == originalLayers)
        #expect(session.activeBranchViewModel.workspace.document.layers.count == originalLayers.count + 1)
    }
}
