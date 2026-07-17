import Foundation

extension WorkspaceViewModel {
    var blockReferenceModuleLibrary: BlockReferenceModuleLibraryState {
        workspace.blockReferenceModuleLibrary
    }

    func blockReferenceCustomModuleInstance(
        containing objectID: UUID
    ) -> BlockReferenceCustomModuleInstance? {
        blockReferenceScene?.customModuleInstances.first { $0.objectIDs.contains(objectID) }
    }

    func blockReferenceModuleAsset(for instance: BlockReferenceCustomModuleInstance) -> BlockReferenceModuleAsset? {
        blockReferenceModuleLibrary.module(id: instance.assetID)
    }

    @discardableResult
    func createBlockReferenceModuleCategory(named name: String) -> UUID? {
        var categoryID: UUID?
        updateBlockReferenceModuleLibrary { library in
            categoryID = library.addCategory(named: name)?.id
        }
        blockReferenceEditorState.instruction = categoryID == nil
            ? "类目名称为空、重复，或类目数量已达上限。"
            : "已新建体块类目。"
        return categoryID
    }

    func suggestedBlockReferenceModuleName(preferredObjectID: UUID? = nil) -> String {
        let preferred = preferredObjectID.flatMap { objectID in
            blockReferenceScene?.objects.first { $0.id == objectID }
        }
        if editableSelectedBlockReferenceObjects.count == 1,
           let object = preferred ?? editableSelectedBlockReferenceObjects.first {
            return object.name
        }
        return "自定义模块"
    }

    @discardableResult
    func saveSelectedBlockReferenceObjectsAsModule(
        named name: String,
        categoryID: UUID,
        preferredObjectID: UUID? = nil
    ) -> UUID? {
        if let preferredObjectID,
           !selectedBlockReferenceObjectIDs.contains(preferredObjectID) {
            selectBlockReferenceObject(preferredObjectID, extending: false)
        }
        let sources = editableSelectedBlockReferenceObjects
        guard !sources.isEmpty, let basePoint = resolvedBlockReferencePivot else {
            blockReferenceEditorState.instruction = "保存模块失败：请先选择至少一个未锁定体块。"
            return nil
        }
        var assetID: UUID?
        updateBlockReferenceModuleLibrary { library in
            assetID = library.addModule(
                named: name,
                categoryID: categoryID,
                sourceObjects: sources,
                basePoint: basePoint
            )?.id
        }
        blockReferenceEditorState.instruction = assetID == nil
            ? "保存模块失败：体块库已满或选区无效。"
            : "已将 \(sources.count) 个体块按当前模块基准点存入体块库；载入时该点会落在活动工作面原点。"
        return assetID
    }

    func instantiateBlockReferenceModule(
        assetID: UUID,
        forEditing: Bool = false
    ) {
        guard let scene = blockReferenceScene,
              let asset = blockReferenceModuleLibrary.module(id: assetID),
              let result = asset.instantiate(
                at: scene.workingPlane.origin,
                grouped: !forEditing
              )
        else {
            blockReferenceEditorState.instruction = "载入模块失败：模块数据不存在或为空。"
            return
        }
        let didInstantiate = updateBlockReferenceDocument(
            operationKind: "blockReference.customModule.instantiate"
        ) { stored in
            guard var value = stored else { return }
            value.objects.append(contentsOf: result.objects)
            if let group = result.group {
                value.groups.append(group)
            }
            value.customModuleInstances.append(result.instance)
            value.customPivot = result.instance.basePoint
            value.pivotMode = .custom
            stored = value
        }
        guard didInstantiate else { return }
        blockReferenceEditorState.selectedObjectIDs = Set(result.objects.map(\.id))
        blockReferenceEditorState.selectedObjectID = result.objects.last?.id
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.instruction = forEditing
            ? "已载入“\(asset.name)”并进入部件编辑；右键任一部件可保存或放弃库关联。"
            : "已在活动工作面原点载入“\(asset.name)”。"
    }

    func beginEditingBlockReferenceModuleInstance(containing objectID: UUID) {
        guard let instance = blockReferenceCustomModuleInstance(containing: objectID) else { return }
        let ids = Set(instance.objectIDs)
        _ = updateBlockReferenceDocument(operationKind: "blockReference.customModule.beginEditing") { stored in
            guard var value = stored else { return }
            let affectedGroupIDs = Set(
                value.objects
                    .filter { ids.contains($0.id) }
                    .compactMap(\.groupID)
            )
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                value.objects[index].groupID = nil
            }
            value.groups.removeAll { affectedGroupIDs.contains($0.id) }
            stored = value
        }
        let existingIDs = ids.intersection(Set(blockReferenceScene?.objects.map(\.id) ?? []))
        blockReferenceEditorState.selectedObjectIDs = existingIDs
        blockReferenceEditorState.selectedObjectID = blockReferenceScene?.objects
            .last(where: { existingIDs.contains($0.id) })?.id
        blockReferenceEditorState.instruction = "模块已拆为可编辑部件。修改后右键任一部件选择替换、另存或不保存。"
    }

    func replaceEditedBlockReferenceModule(containing objectID: UUID) {
        guard let edit = blockReferenceModuleEditSources(containing: objectID) else { return }
        var replacement: BlockReferenceModuleAsset?
        updateBlockReferenceModuleLibrary { library in
            replacement = library.replaceModule(
                id: edit.instance.assetID,
                sourceObjects: edit.objects,
                basePoint: edit.basePoint
            )
        }
        guard replacement != nil else {
            blockReferenceEditorState.instruction = "替换失败：原模块已不存在或没有可保存的部件。"
            return
        }
        updateStoredBlockReferenceModuleInstance(
            edit.instance,
            objectIDs: edit.objects.map(\.id),
            assetID: edit.instance.assetID,
            basePoint: edit.basePoint,
            operationKind: "blockReference.customModule.replace"
        )
        blockReferenceEditorState.instruction = "已用当前场景部件替换原模块。"
    }

    @discardableResult
    func saveEditedBlockReferenceModuleAsNew(
        containing objectID: UUID,
        named name: String,
        categoryID: UUID
    ) -> UUID? {
        guard let edit = blockReferenceModuleEditSources(containing: objectID) else { return nil }
        var newAsset: BlockReferenceModuleAsset?
        updateBlockReferenceModuleLibrary { library in
            newAsset = library.addModule(
                named: name,
                categoryID: categoryID,
                sourceObjects: edit.objects,
                basePoint: edit.basePoint
            )
        }
        guard let newAsset else {
            blockReferenceEditorState.instruction = "另存失败：没有可保存的部件或体块库已满。"
            return nil
        }
        updateStoredBlockReferenceModuleInstance(
            edit.instance,
            objectIDs: edit.objects.map(\.id),
            assetID: newAsset.id,
            basePoint: edit.basePoint,
            operationKind: "blockReference.customModule.saveAs"
        )
        blockReferenceEditorState.instruction = "已另存为新模块“\(newAsset.name)”。"
        return newAsset.id
    }

    func detachBlockReferenceModuleInstance(containing objectID: UUID) {
        guard let instance = blockReferenceCustomModuleInstance(containing: objectID) else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.customModule.detach") { scene in
            scene?.customModuleInstances.removeAll { $0.id == instance.id }
        }
        blockReferenceEditorState.instruction = "已解除模块库关联；场景中的体块修改被保留，体块库未改变。"
    }

    private func blockReferenceModuleEditSources(
        containing objectID: UUID
    ) -> (
        instance: BlockReferenceCustomModuleInstance,
        objects: [BlockReferenceObject],
        basePoint: BlockVector3
    )? {
        guard let scene = blockReferenceScene,
              let instance = scene.customModuleInstances.first(where: { $0.objectIDs.contains(objectID) })
        else {
            blockReferenceEditorState.instruction = "此体块不属于可回存的自定义模块。"
            return nil
        }
        let originalIDs = Set(instance.objectIDs)
        let IDsOwnedByOtherInstances = Set(
            scene.customModuleInstances
                .filter { $0.id != instance.id }
                .flatMap(\.objectIDs)
        )
        let selectedAdditions = selectedBlockReferenceObjectIDs.subtracting(IDsOwnedByOtherInstances)
        let sourceIDs = originalIDs.union(selectedAdditions)
        let objects = scene.objects.filter {
            originalIDs.contains($0.id)
                || (sourceIDs.contains($0.id) && $0.isVisible && !$0.isLocked)
        }
        guard !objects.isEmpty else {
            blockReferenceEditorState.instruction = "模块没有可保存的部件。"
            return nil
        }
        let basePoint: BlockVector3
        if scene.pivotMode == .selectionCenter {
            basePoint = instance.basePoint
        } else {
            basePoint = resolvedBlockReferencePivot ?? instance.basePoint
        }
        return (instance, objects, basePoint)
    }

    private func updateStoredBlockReferenceModuleInstance(
        _ instance: BlockReferenceCustomModuleInstance,
        objectIDs: [UUID],
        assetID: UUID,
        basePoint: BlockVector3,
        operationKind: String
    ) {
        _ = updateBlockReferenceDocument(operationKind: operationKind) { stored in
            guard var value = stored,
                  let index = value.customModuleInstances.firstIndex(where: { $0.id == instance.id })
            else { return }
            value.customModuleInstances[index].assetID = assetID
            value.customModuleInstances[index].objectIDs = objectIDs
            value.customModuleInstances[index].basePoint = basePoint
            stored = value
        }
    }
}
