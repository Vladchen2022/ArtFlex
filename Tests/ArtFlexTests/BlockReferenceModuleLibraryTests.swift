import Foundation
import Metal
import Testing
@testable import ArtFlex

struct BlockReferenceModuleLibraryTests {
    @Test
    func moduleStoresEditableObjectsRelativeToBasePointAndInstantiatesFreshIDs() throws {
        let first = makeObject(name: "桌面", position: .init(x: 120, y: 80, z: 75))
        let second = makeObject(name: "桌腿", position: .init(x: 90, y: 60, z: 35))
        let basePoint = BlockVector3(x: 100, y: 50, z: 0)
        let asset = BlockReferenceModuleAsset(
            categoryID: BlockReferenceModuleLibraryState.defaultCategoryID,
            name: "桌子",
            sourceObjects: [first, second],
            basePoint: basePoint
        )

        #expect(asset.templateObjects.map(\.position) == [
            .init(x: 20, y: 30, z: 75),
            .init(x: -10, y: 10, z: 35)
        ])
        #expect(asset.templateObjects.allSatisfy { $0.groupID == nil && !$0.isLocked })

        let target = BlockVector3(x: -40, y: 10, z: 8)
        let result = try #require(asset.instantiate(at: target, grouped: true))
        #expect(result.objects.map(\.position) == [
            .init(x: -20, y: 40, z: 83),
            .init(x: -50, y: 20, z: 43)
        ])
        #expect(Set(result.objects.map(\.id)).isDisjoint(with: [first.id, second.id]))
        #expect(result.objects.compactMap(\.groupID).count == 2)
        #expect(Set(result.objects.compactMap(\.groupID)).count == 1)
        #expect(result.instance.assetID == asset.id)
        #expect(Set(result.instance.objectIDs) == Set(result.objects.map(\.id)))
        #expect(result.instance.basePoint == target)
    }

    @Test
    func categoriesAndModulesPersistAndReplacingKeepsAssetIdentity() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexBlockModuleLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var library = BlockReferenceModuleLibraryState.empty
        let addedCategory = library.addCategory(named: "交通工具")
        let category = try #require(addedCategory)
        #expect(library.addCategory(named: "交通工具") == nil)
        let addedModule = library.addModule(
            named: "车辆",
            categoryID: category.id,
            sourceObjects: [makeObject(name: "车身", position: .zero)],
            basePoint: .zero
        )
        let original = try #require(addedModule)
        let replacementObject = makeObject(
            name: "加长车身",
            position: .init(x: 12, y: 0, z: 4)
        )
        let replacedModule = library.replaceModule(
            id: original.id,
            sourceObjects: [replacementObject],
            basePoint: .init(x: 2, y: 0, z: 0)
        )
        let replacement = try #require(replacedModule)

        #expect(replacement.id == original.id)
        #expect(replacement.categoryID == category.id)
        #expect(replacement.name == original.name)
        #expect(replacement.templateObjects.first?.position == .init(x: 10, y: 0, z: 4))

        let controller = BlockReferenceModuleLibraryPersistenceController(rootDirectoryURL: root)
        try controller.saveLibrary(library)
        #expect(controller.loadLibrary() == library)
    }

    @Test
    func scenePrunesDeletedModuleMembersAndLegacyWorkspaceGetsDefaultLibrary() throws {
        let object = makeObject(name: "部件", position: .zero)
        let missingID = UUID()
        let instance = BlockReferenceCustomModuleInstance(
            assetID: UUID(),
            objectIDs: [object.id, missingID],
            basePoint: .zero
        )
        let scene = BlockReferenceScene(
            objects: [object],
            measurements: [],
            workingPlane: .ground,
            camera: .stageOneDefault,
            display: .stageOneDefault,
            snap: .stageOneDefault,
            customModuleInstances: [instance]
        )
        #expect(scene.customModuleInstances.first?.objectIDs == [object.id])

        let encoded = try JSONEncoder().encode(WorkspaceState.stageOneDefault)
        var objectJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        objectJSON.removeValue(forKey: "blockReferenceModuleLibrary")
        let legacyData = try JSONSerialization.data(withJSONObject: objectJSON)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: legacyData)
        #expect(decoded.blockReferenceModuleLibrary == .empty)
    }

    @Test
    @MainActor
    func viewModelCanSaveLoadEditAndReplaceAMultiObjectModule() throws {
        guard let metalContext = MetalDeviceContext() else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexBlockModuleWorkflowTests-\(UUID().uuidString)", isDirectory: true)
        let bootstrap = try AppBootstrap(
            workspaceStore: WorkspaceStore(),
            metalContext: metalContext,
            layerSurfaceStore: StageOneLayerSurfaceStore(),
            blockReferenceModuleLibraryPersistenceController: .init(rootDirectoryURL: root)
        )
        let viewModel = WorkspaceViewModel(
            bootstrap: bootstrap,
            installsZoomKeyboardMonitor: false,
            preparesInitialTextures: false
        )
        viewModel.createEmptyBlockReferenceScene()
        let first = makeObject(name: "上部", position: .init(x: 10, y: 0, z: 20))
        let second = makeObject(name: "下部", position: .init(x: -10, y: 0, z: 5))
        _ = viewModel.updateBlockReferenceDocument { scene in
            scene?.objects = [first, second]
            scene?.pivotMode = .custom
            scene?.customPivot = .zero
        }
        viewModel.blockReferenceEditorState.selectedObjectIDs = [first.id, second.id]
        viewModel.blockReferenceEditorState.selectedObjectID = second.id

        let assetID = try #require(viewModel.saveSelectedBlockReferenceObjectsAsModule(
            named: "组合体",
            categoryID: BlockReferenceModuleLibraryState.defaultCategoryID
        ))
        viewModel.instantiateBlockReferenceModule(assetID: assetID, forEditing: true)

        let instance = try #require(viewModel.blockReferenceScene?.customModuleInstances.last)
        #expect(instance.objectIDs.count == 2)
        #expect(Set(instance.objectIDs).isDisjoint(with: [first.id, second.id]))

        viewModel.beginEditingBlockReferenceModuleInstance(containing: try #require(instance.objectIDs.first))
        let editedID = try #require(instance.objectIDs.first)
        let preservedID = try #require(instance.objectIDs.last)
        _ = viewModel.updateBlockReferenceDocument { scene in
            guard let index = scene?.objects.firstIndex(where: { $0.id == editedID }) else { return }
            scene?.objects[index].position.x = 65
            guard let preservedIndex = scene?.objects.firstIndex(where: { $0.id == preservedID }) else { return }
            scene?.objects[preservedIndex].isVisible = false
            scene?.objects[preservedIndex].isLocked = true
        }
        viewModel.replaceEditedBlockReferenceModule(containing: editedID)

        let replaced = try #require(viewModel.blockReferenceModuleLibrary.module(id: assetID))
        #expect(replaced.id == assetID)
        #expect(replaced.templateObjects.count == 2)
        #expect(replaced.templateObjects.contains { $0.position.x == 65 })
    }

    private func makeObject(name: String, position: BlockVector3) -> BlockReferenceObject {
        BlockReferenceObject(
            name: name,
            kind: .box,
            position: position,
            dimensions: .init(width: 40, depth: 30, height: 20)
        )
    }
}
