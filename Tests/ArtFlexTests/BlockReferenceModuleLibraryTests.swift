import Foundation
import Metal
import Testing
@testable import ArtFlex

struct BlockReferenceModuleLibraryTests {
    @Test
    func presetCategoriesAcceptPersistentUserModulesWithoutDuplicatingCustomCategories() throws {
        var library = BlockReferenceModuleLibraryState.empty
        #expect(library.categories.map(\.name) == ["基础体", "人物", "建筑", "自定义"])
        #expect(library.nonPresetCategories.map(\.name) == ["自定义"])
        #expect(library.addCategory(named: "建筑") == nil)

        let addedModule = library.addModule(
            named: "自制门框",
            categoryID: BlockReferenceModuleLibraryState.architectureCategoryID,
            sourceObjects: [makeObject(name: "门框", position: .zero)],
            basePoint: .zero
        )
        let module = try #require(addedModule)
        #expect(module.categoryID == BlockReferenceModuleLibraryState.architectureCategoryID)
        #expect(library.modules(in: BlockReferenceModuleLibraryState.architectureCategoryID).map(\.id) == [module.id])

        let decoded = try JSONDecoder().decode(
            BlockReferenceModuleLibraryState.self,
            from: JSONEncoder().encode(library)
        )
        #expect(decoded == library)

        let legacyCategory = BlockReferenceModuleCategory(name: "建筑")
        let legacyAsset = BlockReferenceModuleAsset(
            categoryID: legacyCategory.id,
            name: "旧版建筑模块",
            sourceObjects: [makeObject(name: "墙体", position: .zero)],
            basePoint: .zero
        )
        let migrated = BlockReferenceModuleLibraryState(
            categories: [legacyCategory],
            modules: [legacyAsset],
            selectedCategoryID: legacyCategory.id
        )
        #expect(!migrated.categories.contains { $0.id == legacyCategory.id })
        #expect(migrated.module(id: legacyAsset.id)?.categoryID == BlockReferenceModuleLibraryState.architectureCategoryID)
        #expect(migrated.selectedCategoryID == BlockReferenceModuleLibraryState.architectureCategoryID)
    }

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

    @Test
    @MainActor
    func moduleBasePointLoadsExactlyAtTheActiveWorkingPlaneOrigin() throws {
        guard let metalContext = MetalDeviceContext() else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexBlockModuleBasePointTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let source = makeObject(
            name: "桌体",
            position: .init(x: 40, y: 30, z: 25)
        )
        let basePoint = BlockVector3(x: 10, y: 15, z: 5)
        _ = viewModel.updateBlockReferenceDocument { scene in
            scene?.objects = [source]
            scene?.pivotMode = .custom
            scene?.customPivot = basePoint
        }
        viewModel.selectBlockReferenceObject(source.id, extending: false)

        viewModel.beginPickingBlockReferenceModuleBasePoint()
        #expect(viewModel.blockReferenceEditorState.mode == .setPivot)
        #expect(viewModel.blockReferenceEditorState.instruction.contains("模块基准点"))
        viewModel.cancelBlockReferenceInteraction()

        let assetID = try #require(viewModel.saveSelectedBlockReferenceObjectsAsModule(
            named: "桌体模块",
            categoryID: BlockReferenceModuleLibraryState.defaultCategoryID
        ))
        let target = BlockVector3(x: 180, y: -35, z: 12)
        _ = viewModel.updateBlockReferenceDocument { scene in
            scene?.workingPlane.origin = target
        }
        viewModel.instantiateBlockReferenceModule(assetID: assetID)

        let instance = try #require(viewModel.blockReferenceScene?.customModuleInstances.last)
        let loadedID = try #require(instance.objectIDs.first)
        let loaded = try #require(
            viewModel.blockReferenceScene?.objects.first(where: { $0.id == loadedID })
        )
        #expect(instance.basePoint == target)
        #expect(loaded.position == target + (source.position - basePoint))
    }

    @Test
    @MainActor
    func loadedModuleBasePointFollowsWholeModuleTransformsButNotComponentEdits() throws {
        guard let metalContext = MetalDeviceContext() else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtFlexBlockModuleAnchorTransformTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        let first = makeObject(name: "模块上部", position: .init(x: 20, y: 0, z: 30))
        let second = makeObject(name: "模块下部", position: .init(x: -20, y: 0, z: 10))
        _ = viewModel.updateBlockReferenceDocument { scene in
            scene?.objects = [first, second]
            scene?.pivotMode = .custom
            scene?.customPivot = .zero
        }
        viewModel.blockReferenceEditorState.selectedObjectIDs = [first.id, second.id]
        viewModel.blockReferenceEditorState.selectedObjectID = second.id
        let assetID = try #require(viewModel.saveSelectedBlockReferenceObjectsAsModule(
            named: "可移动模块",
            categoryID: BlockReferenceModuleLibraryState.architectureCategoryID
        ))

        let target = BlockVector3(x: 100, y: 50, z: 0)
        _ = viewModel.updateBlockReferenceDocument { scene in
            scene?.workingPlane.origin = target
        }
        viewModel.instantiateBlockReferenceModule(assetID: assetID)
        let initialInstance = try #require(viewModel.blockReferenceScene?.customModuleInstances.last)
        let initialPositions = Dictionary(uniqueKeysWithValues: try #require(
            viewModel.blockReferenceScene?.objects
                .filter { Set(initialInstance.objectIDs).contains($0.id) }
                .map { ($0.id, $0.position) }
        ))
        #expect(viewModel.blockReferenceScene?.customPivot == target)
        #expect(viewModel.blockReferenceScene?.pivotMode == .custom)

        let active = try #require(viewModel.selectedBlockReferenceObject)
        let delta = BlockVector3(x: 35, y: -12, z: 8)
        viewModel.setSelectedBlockReferencePosition(active.position + delta)
        let movedInstance = try #require(viewModel.blockReferenceScene?.customModuleInstances.last)
        #expect(movedInstance.basePoint == target + delta)
        #expect(viewModel.blockReferenceScene?.customPivot == target + delta)
        for objectID in movedInstance.objectIDs {
            let moved = try #require(viewModel.blockReferenceScene?.objects.first { $0.id == objectID })
            #expect(moved.position == initialPositions[objectID]! + delta)
        }

        viewModel.beginBlockReferenceNumericTransform(.move)
        viewModel.setBlockReferenceNumericTransformAxis(.z)
        viewModel.setBlockReferenceNumericTransformInput("12")
        viewModel.commitBlockReferenceNumericTransform()
        let numericallyMovedInstance = try #require(viewModel.blockReferenceScene?.customModuleInstances.last)
        let expectedWholeModuleAnchor = target + delta + BlockVector3(x: 0, y: 0, z: 12)
        #expect(numericallyMovedInstance.basePoint == expectedWholeModuleAnchor)
        #expect(viewModel.blockReferenceScene?.customPivot == expectedWholeModuleAnchor)

        let editedObjectID = try #require(numericallyMovedInstance.objectIDs.first)
        viewModel.beginEditingBlockReferenceModuleInstance(containing: editedObjectID)
        viewModel.selectBlockReferenceObject(editedObjectID, extending: false)
        let editedObject = try #require(viewModel.selectedBlockReferenceObject)
        viewModel.setSelectedBlockReferencePosition(editedObject.position + .init(x: 20, y: 0, z: 0))
        #expect(viewModel.blockReferenceScene?.customModuleInstances.last?.basePoint == expectedWholeModuleAnchor)
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
