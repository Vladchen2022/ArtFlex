import Foundation

extension WorkspaceViewModel {
    func cancelPendingBlockReferenceEditForHistory() -> Bool {
        guard workspace.toolSession.activeTool == .blockReference,
              blockReferenceWorkflow.interactionPreview != nil || blockReferenceWorkflow.pendingPlacement != nil
                || blockReferenceEditorState.draft != nil || blockReferenceEditorState.numericTransform != nil
                || blockReferenceCameraPreview != nil else { return false }
        cancelBlockReferenceInteraction()
        return true
    }

    func renameBlockReferenceCameraSlot(_ index: Int, name: String) {
        _ = updateBlockReferenceDocument { scene in
            guard let i = scene?.cameraSlots.firstIndex(where: { $0.index == index }),
                  scene?.cameraSlots[i].isLocked == false else { return }
            scene?.cameraSlots[i].name = String(name.prefix(48))
        }
    }
    func beginBlockReferenceFaceDrag(at point: CanvasPoint) {
        guard let scene = blockReferenceScene,
              let face = blockHitTestFace(scene: scene, canvasPoint: point, canvasSize: workspace.document.canvasSize),
              let object = scene.objects.first(where: { $0.id == face.objectID }),
              !object.isLocked, object.customMesh == nil, object.kind != .sphere else { return }
        let axes = BlockReferenceAxis.allCases.map { ($0, blockRotate($0.unitVector, rotation: object.rotation)) }
        guard let axis = axes.max(by: { abs($0.1.dot(face.normal)) < abs($1.1.dot(face.normal)) }),
              object.kind == .box || axis.0 == .z else { return }
        let center = face.vertices.reduce(BlockVector3.zero, +) / Double(face.vertices.count)
        guard let p = projectBlockPoint(center, camera: scene.camera, canvasSize: workspace.document.canvasSize),
              let q = projectBlockPoint(center + face.normal * 100, camera: scene.camera, canvasSize: workspace.document.canvasSize) else { return }
        let vector = CanvasPoint(x: (q.canvasPoint.x - p.canvasPoint.x) / 100, y: (q.canvasPoint.y - p.canvasPoint.y) / 100)
        guard hypot(vector.x, vector.y) > 0.02 else {
            blockReferenceEditorState.instruction = "这个面正对相机，请稍微转动视角再拖动。"
            return
        }
        blockReferenceWorkflow.faceDrag = .init(object: object, axis: axis.0,
            sign: axis.1.dot(face.normal) < 0 ? -1 : 1, normal: face.normal, start: point, screenVector: vector)
        blockReferenceEditorState.selectedObjectID = object.id
        blockReferenceEditorState.selectedObjectIDs = [object.id]
        blockReferenceEditorState.selectedFaceIndex = face.faceIndex
        blockReferenceEditorState.phase = .transformingGizmo
        blockReferenceEditorState.instruction = "沿选中面的法线拖动尺寸；Esc 完整取消。"
    }

    func updateBlockReferenceFaceDrag(to point: CanvasPoint) {
        guard let drag = blockReferenceWorkflow.faceDrag else { return }
        let v = drag.screenVector
        let distance = ((point.x - drag.start.x) * v.x + (point.y - drag.start.y) * v.y) / (v.x * v.x + v.y * v.y)
        guard abs(distance) > 0.001, beginBlockReferencePreview(operation: "blockReference.faceResize") else { return }
        let object = blockReferenceResizingFace(drag, distance: distance)
        _ = updateBlockReferenceDocument { scene in
            if let index = scene?.objects.firstIndex(where: { $0.id == object.id }) { scene?.objects[index] = object }
        }
    }
    func setBlockReferenceStandardView(yaw: Double, pitch: Double) {
        if var camera = blockReferenceWorkflow.inspectionCamera {
            camera.yawDegrees = yaw; camera.pitchDegrees = pitch
            blockReferenceWorkflow.inspectionCamera = camera
        } else if blockReferenceScene?.display.isFrozen == false {
            _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraView") {
                $0?.camera.yawDegrees = yaw; $0?.camera.pitchDegrees = pitch
            }
        }
    }
    func beginBlockReferenceModulePlacement(_ kind: BlockReferenceModuleKind) {
        guard let scene = blockReferenceScene, !scene.display.isFrozen else { return }
        cancelBlockReferenceInteraction()
        let object = blockReferenceModuleObject(kind: kind, name: kind.displayName,
            position: scene.workingPlane.origin, rotation: blockRotation(alignedTo: scene.workingPlane))
        blockReferenceWorkflow.pendingPlacement = .init(objects: [object], basePoint: scene.workingPlane.origin)
        blockReferenceEditorState.mode = .select
        blockReferenceWorkflow.navigationMode = nil
        blockReferenceEditorState.instruction = "移动光标预览“\(kind.displayName)”；点击放置，Esc 取消。"
    }

    func beginBlockReferenceAssetPlacement(_ asset: BlockReferenceModuleAsset, forEditing: Bool = false) {
        guard let scene = blockReferenceScene, !scene.display.isFrozen,
              let result = asset.instantiate(at: scene.workingPlane.origin, grouped: !forEditing) else { return }
        cancelBlockReferenceInteraction()
        blockReferenceWorkflow.pendingPlacement = .init(objects: result.objects, instance: result.instance,
            group: result.group, basePoint: result.instance.basePoint)
        blockReferenceEditorState.mode = .select
        blockReferenceWorkflow.navigationMode = nil
        blockReferenceEditorState.instruction = "移动光标预览“\(asset.name)”；点击放置，Esc 取消。"
    }

    @discardableResult
    func updateBlockReferencePlacement(at point: CanvasPoint?, screenScale: Double) -> Bool {
        guard blockReferenceWorkflow.pendingPlacement != nil || blockReferenceEditorState.mode.primitiveKind != nil,
              blockReferenceEditorState.phase == .idle else { return false }
        guard let point, let scene = blockReferenceScene, !scene.display.isFrozen,
              let location = blockWorldPoint(for: point, plane: scene.workingPlane, scene: scene, screenScale: screenScale) else {
            blockReferenceEditorState.placementObjects = []
            blockReferenceWorkflow.pendingPlacement?.location = nil
            return true
        }
        if let pending = blockReferenceWorkflow.pendingPlacement {
            let delta = location - pending.basePoint
            blockReferenceEditorState.placementObjects = pending.objects.map { source in
                var object = source
                object.position = object.position + delta
                return object
            }
            blockReferenceWorkflow.pendingPlacement?.location = location
        } else if let kind = blockReferenceEditorState.mode.primitiveKind {
            var object = BlockReferenceObject(name: kind.displayName, kind: kind, position: location,
                rotation: blockRotation(alignedTo: scene.workingPlane), dimensions: .stageOneDefault)
            object.radialSegments = 24
            blockReferenceEditorState.placementObjects = [object]
        }
        return true
    }

    @discardableResult
    func commitBlockReferencePlacement(at point: CanvasPoint, screenScale: Double) -> Bool {
        guard blockReferenceWorkflow.pendingPlacement != nil else { return false }
        _ = updateBlockReferencePlacement(at: point, screenScale: screenScale)
        guard let pending = blockReferenceWorkflow.pendingPlacement, let location = pending.location else { return true }
        let objects = blockReferenceEditorState.placementObjects
        var instance = pending.instance
        instance?.basePoint = location
        var group = pending.group
        group?.pivot = location
        guard updateBlockReferenceDocument(operationKind: "blockReference.place", { scene in
            scene?.objects.append(contentsOf: objects)
            if let instance { scene?.customModuleInstances.append(instance) }
            if let group { scene?.groups.append(group) }
        }) else { return true }
        blockReferenceEditorState.selectedObjectID = objects.last?.id
        blockReferenceEditorState.selectedObjectIDs = Set(objects.map(\.id))
        blockReferenceEditorState.placementObjects = []
        blockReferenceWorkflow.pendingPlacement = nil
        if blockReferenceWorkflow.continuousPlacement {
            if let instance, let asset = blockReferenceModuleLibrary.module(id: instance.assetID) {
                beginBlockReferenceAssetPlacement(asset, forEditing: group == nil)
            } else if let kind = objects.first?.moduleKind { beginBlockReferenceModulePlacement(kind) }
        }
        blockReferenceEditorState.instruction = "已放置体块；可拖动调整，或使用移动／旋转／缩放。"
        return true
    }

    func setBlockReferenceNavigationTool(_ mode: BlockReferenceNavigationMode?) {
        cancelBlockReferenceInteraction()
        blockReferenceEditorState.mode = .select
        blockReferenceWorkflow.navigationMode = mode
    }

    func beginBlockReferenceInspection() {
        cancelBlockReferenceInteraction()
        guard let camera = workspace.document.blockReferenceScene?.camera else { return }
        blockReferenceWorkflow.inspectionCamera = camera
        blockReferenceWorkflow.navigationMode = .orbit
        blockReferenceEditorState.instruction = "临时检查视角；原构图不会改变。完成后点击“返回构图”。"
    }

    func returnToBlockReferenceComposition() {
        let wasInspecting = blockReferenceWorkflow.inspectionCamera != nil
        blockReferenceCameraPreview = nil
        blockReferenceCameraZoomCommitTask?.cancel()
        blockReferenceCameraZoomCommitTask = nil
        blockReferenceCameraRenderState.cancelNavigation()
        blockReferenceCameraNavigationMode = nil
        isBlockReferenceCameraNavigating = false
        blockReferenceWorkflow.inspectionCamera = nil
        blockReferenceWorkflow.navigationMode = nil
        if wasInspecting { blockReferenceEditorState.instruction = "已返回原构图。" }
    }

    func setBlockReferenceDisplayPreset(_ preset: BlockReferenceDisplayPreset) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.displayPreset") { scene in
            scene?.display.mode = preset == .structure ? .wireframe : .solid
            scene?.display.showsFaces = preset != .structure
            scene?.display.showsEdges = true
            scene?.display.paintingOpacity = preset == .gray ? 0.8 : 0.35
        }
    }

    func setBlockReferencePaintingOpacity(_ value: Float) {
        _ = updateBlockReferenceDocument(operationKind: isAdjustingBlockReferenceParameters ? nil : "blockReference.paintingOpacity") {
            $0?.display.paintingOpacity = value
        }
    }

    func setBlockReferenceLight(azimuth: Double? = nil, elevation: Double? = nil) {
        _ = updateBlockReferenceDocument(operationKind: isAdjustingBlockReferenceParameters ? nil : "blockReference.light") { scene in
            if let azimuth { scene?.display.lightAzimuth = azimuth }
            if let elevation { scene?.display.lightElevation = elevation }
        }
    }

    func landSelectedBlockReferenceObjects(onGround: Bool = false) {
        guard let scene = blockReferenceScene, !scene.display.isFrozen else { return }
        let objects = editableSelectedBlockReferenceObjects
        let plane = onGround ? BlockWorkingPlane.ground : scene.workingPlane
        guard let distance = objects.flatMap({ blockObjectFaces($0).flatMap(\.vertices) })
            .map({ ($0 - plane.origin).dot(plane.normal) }).min() else { return }
        let delta = plane.normal * -distance
        let ids = Set(objects.map(\.id))
        let anchors = blockReferenceModuleBasePointSnapshots(in: scene, transformedObjectIDs: ids)
        let trackedPivot = blockReferenceTrackedCustomPivot(in: scene, moduleBasePoints: anchors)
        _ = updateBlockReferenceDocument(operationKind: "blockReference.land") { stored in
            guard var value = stored else { return }
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                value.objects[index].position = value.objects[index].position + delta
            }
            for index in value.customModuleInstances.indices
                where Set(value.customModuleInstances[index].objectIDs).isSubset(of: ids) {
                value.customModuleInstances[index].basePoint = value.customModuleInstances[index].basePoint + delta
            }
            if let trackedPivot { value.customPivot = trackedPivot + delta }
            stored = value
        }
    }

    func setSelectedBlockReferenceCurveQuality(_ segments: Int) {
        guard blockReferenceScene?.display.isFrozen == false else { return }
        let ids = selectedBlockReferenceObjectIDs
        _ = updateBlockReferenceDocument(operationKind: "blockReference.curveQuality") { scene in
            guard var value = scene else { return }
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                value.objects[index].radialSegments = min(max(segments, 8), 32)
            }
            scene = value
        }
    }
    @discardableResult
    func beginBlockReferencePreview(operation: String) -> Bool {
        guard let scene = blockReferenceScene else { return false }
        if blockReferenceWorkflow.interactionPreview == nil {
            blockReferenceWorkflow.interactionPreview = workspace.document.blockReferenceScene ?? scene
            blockReferenceWorkflow.interactionOperation = operation
        }
        return true
    }

    func commitBlockReferencePreview() {
        guard let preview = blockReferenceWorkflow.interactionPreview else { return }
        let operation = blockReferenceWorkflow.interactionOperation ?? "blockReference.transform"
        blockReferenceWorkflow.interactionPreview = nil
        blockReferenceWorkflow.interactionOperation = nil
        if !updateBlockReferenceDocument(operationKind: operation, { $0 = preview }) {
            blockReferenceEditorState.instruction = "无法保存这次操作的撤销记录，已保留操作前的场景。"
        }
    }

    func unlockBlockReferenceForEditing() {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.unlock") { scene in
            if scene == nil { scene = .empty }
            scene?.display.isFrozen = false
            scene?.display.isVisible = true
        }
        blockReferenceEditorState.instruction = "参考已解锁；选择素材放置，或选择现有体块调整。"
    }

    func replaceBlockReferenceSceneSnapshot(_ id: UUID) {
        guard let scene = blockReferenceScene,
              let index = scene.snapshots.firstIndex(where: { $0.id == id }) else { return }
        var snapshot = blockReferenceSceneSnapshot(name: scene.snapshots[index].name, scene: scene)
        snapshot.id = id
        _ = updateBlockReferenceDocument(operationKind: "blockReference.snapshot.replace") {
            $0?.snapshots[index] = snapshot
        }
    }
}
