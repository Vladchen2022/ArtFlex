import AppKit
import Foundation

extension WorkspaceViewModel {
    func selectAllBlockReferenceObjects() {
        let ids = Set(blockReferenceScene?.objects.filter { $0.isVisible && !$0.isLocked }.map(\.id) ?? [])
        blockReferenceEditorState.selectedObjectIDs = ids
        blockReferenceEditorState.selectedObjectID = blockReferenceScene?.objects.last(where: { ids.contains($0.id) })?.id
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.instruction = "已选择全部 \(ids.count) 个可编辑体块。"
    }

    func deselectAllBlockReferenceObjects() {
        cancelBlockReferenceInteraction()
        blockReferenceEditorState.selectedObjectIDs = []
        blockReferenceEditorState.selectedObjectID = nil
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.selectedHumanJoint = nil
        blockReferenceEditorState.activeHumanJointAxis = nil
        blockReferenceEditorState.instruction = "已取消选择。"
    }

    func hideSelectedBlockReferenceObjects() {
        let ids = selectedBlockReferenceObjectIDs
        guard !ids.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.hide") { scene in
            guard var value = scene else { return }
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                value.objects[index].isVisible = false
            }
            scene = value
        }
        deselectAllBlockReferenceObjects()
    }

    func showAllBlockReferenceObjects() {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.showAll") { scene in
            guard var value = scene else { return }
            for index in value.objects.indices { value.objects[index].isVisible = true }
            scene = value
        }
        blockReferenceEditorState.instruction = "全部体块已显示。"
    }

    func isolateSelectedBlockReferenceObjects() {
        let ids = selectedBlockReferenceObjectIDs
        guard !ids.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.isolate") { scene in
            guard var value = scene else { return }
            for index in value.objects.indices {
                value.objects[index].isVisible = ids.contains(value.objects[index].id)
            }
            scene = value
        }
        blockReferenceEditorState.instruction = "仅显示已选体块；Option+H 可恢复全部。"
    }

    func clearSelectedBlockReferenceTransform(_ kind: BlockReferenceNumericTransformKind) {
        let ids = selectedBlockReferenceObjectIDs
        guard !ids.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.clearTransform.\(kind.rawValue)") { scene in
            guard var value = scene else { return }
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                switch kind {
                case .move: value.objects[index].position = .zero
                case .rotate: value.objects[index].rotation = .zero
                case .scale:
                    if let mesh = value.objects[index].customMesh {
                        value.objects[index].dimensions = mesh.baseDimensions
                    }
                }
            }
            scene = value
        }
    }

    func groupSelectedBlockReferenceObjects() {
        let ids = selectedBlockReferenceObjectIDs
        guard ids.count >= 2, let center = blockReferenceSelectionCenter else {
            blockReferenceEditorState.instruction = "编组至少需要两个体块。"
            return
        }
        let group = BlockReferenceGroup(
            name: "组 \((blockReferenceScene?.groups.count ?? 0) + 1)",
            pivot: center
        )
        _ = updateBlockReferenceDocument(operationKind: "blockReference.group") { scene in
            guard var value = scene else { return }
            value.groups.append(group)
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                value.objects[index].groupID = group.id
            }
            scene = value
        }
        blockReferenceEditorState.instruction = "已将 \(ids.count) 个体块编组。"
    }

    func ungroupSelectedBlockReferenceObjects() {
        let ids = selectedBlockReferenceObjectIDs
        let groupIDs = Set(selectedBlockReferenceObjects.compactMap(\.groupID))
        guard !ids.isEmpty, !groupIDs.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.ungroup") { scene in
            guard var value = scene else { return }
            for index in value.objects.indices where value.objects[index].groupID.map(groupIDs.contains) == true {
                value.objects[index].groupID = nil
            }
            value.groups.removeAll { groupIDs.contains($0.id) }
            scene = value
        }
        blockReferenceEditorState.instruction = "已取消编组。"
    }

    func mirrorSelectedBlockReferenceObjects(axis: BlockReferenceAxis) {
        let source = editableSelectedBlockReferenceObjects
        guard !source.isEmpty else { return }
        let pivot = resolvedBlockReferencePivot ?? .zero
        let normal = blockReferenceGizmoAxisDirections[axis] ?? axis.unitVector
        let copies = source.compactMap {
            blockReferenceMirroredObject(
                $0,
                pivot: pivot,
                normal: normal,
                name: "\($0.name) 镜像"
            )
        }
        guard copies.count == source.count else {
            blockReferenceEditorState.instruction = "镜像失败：所选体块没有有效几何。"
            return
        }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.mirror") { $0?.objects.append(contentsOf: copies) }
        blockReferenceEditorState.selectedObjectIDs = Set(copies.map(\.id))
        blockReferenceEditorState.selectedObjectID = copies.last?.id
        blockReferenceEditorState.instruction = "已沿 \(axis.displayName) 轴生成镜像副本。"
    }

    func createBlockReferenceLinearArray(
        count rawCount: Int,
        spacing: Double,
        axis: BlockReferenceAxis
    ) {
        let sources = editableSelectedBlockReferenceObjects
        let count = min(max(rawCount, 2), 32)
        guard !sources.isEmpty, spacing.isFinite else { return }
        let direction = blockReferenceGizmoAxisDirections[axis] ?? axis.unitVector
        var copies: [BlockReferenceObject] = []
        for step in 1..<count {
            for source in sources where copies.count < 256 {
                var copy = source
                copy.id = UUID()
                copy.name = "\(source.geometryDisplayName) 阵列 \(step + 1)"
                copy.position = source.position + direction * (spacing * Double(step))
                copy.groupID = nil
                copies.append(copy)
            }
        }
        guard !copies.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.linearArray") { $0?.objects.append(contentsOf: copies) }
        blockReferenceEditorState.selectedObjectIDs = Set(copies.map(\.id))
        blockReferenceEditorState.selectedObjectID = copies.last?.id
        blockReferenceEditorState.instruction = "已沿 \(axis.displayName) 轴生成 \(copies.count) 个线性阵列副本。"
    }

    func createBlockReferenceRadialArray(
        count rawCount: Int,
        totalDegrees: Double,
        axis: BlockReferenceAxis
    ) {
        let sources = editableSelectedBlockReferenceObjects
        let count = min(max(rawCount, 2), 32)
        guard !sources.isEmpty, totalDegrees.isFinite else { return }
        let pivot = resolvedBlockReferencePivot ?? .zero
        let axisDirection = blockReferenceGizmoAxisDirections[axis] ?? axis.unitVector
        var copies: [BlockReferenceObject] = []
        for step in 1..<count {
            let degrees = totalDegrees / Double(count) * Double(step)
            for source in sources where copies.count < 256 {
                var copy = source
                copy.id = UUID()
                copy.name = "\(source.geometryDisplayName) 环阵 \(step + 1)"
                copy.position = pivot + blockRotateAroundAxis(
                    source.position - pivot,
                    axis: axisDirection,
                    degrees: degrees
                )
                copy.rotation = blockRotation(
                    applyingWorldAxisVector: axisDirection,
                    degrees: degrees,
                    to: source.rotation
                )
                copy.groupID = nil
                copies.append(copy)
            }
        }
        guard !copies.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.radialArray") { $0?.objects.append(contentsOf: copies) }
        blockReferenceEditorState.selectedObjectIDs = Set(copies.map(\.id))
        blockReferenceEditorState.selectedObjectID = copies.last?.id
        blockReferenceEditorState.instruction = "已绕 \(axis.displayName) 轴生成 \(copies.count) 个环形阵列副本。"
    }

    func storeBlockReferenceCameraSlot(_ index: Int) {
        guard let scene = blockReferenceScene, (1...5).contains(index) else { return }
        if let current = scene.cameraSlots.first(where: { $0.index == index }), current.isLocked {
            blockReferenceEditorState.instruction = "视角槽 \(index) 已锁定。"
            return
        }
        let slot = BlockReferenceCameraSlot(index: index, name: "视角 \(index)", camera: scene.camera)
        _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraSlot.store") { stored in
            guard var value = stored else { return }
            value.cameraSlots.removeAll { $0.index == index }
            value.cameraSlots.append(slot)
            stored = value
        }
        blockReferenceEditorState.instruction = "当前视角已保存到槽 \(index)。"
    }

    func recallBlockReferenceCameraSlot(_ index: Int) {
        guard let camera = blockReferenceScene?.cameraSlots.first(where: { $0.index == index })?.camera else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraSlot.recall") { $0?.camera = camera }
    }

    func clearBlockReferenceCameraSlot(_ index: Int) {
        guard let slot = blockReferenceScene?.cameraSlots.first(where: { $0.index == index }), !slot.isLocked else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraSlot.clear") {
            $0?.cameraSlots.removeAll { $0.index == index }
        }
    }

    func setBlockReferenceCameraSlotLocked(_ index: Int, locked: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraSlot.lock") { scene in
            guard let slotIndex = scene?.cameraSlots.firstIndex(where: { $0.index == index }) else { return }
            scene?.cameraSlots[slotIndex].isLocked = locked
        }
    }

    func saveCurrentBlockReferenceWorkingPlane() {
        guard let scene = blockReferenceScene else { return }
        let plane = BlockSavedWorkingPlane(
            name: "工作面 \(scene.savedWorkingPlanes.count + 1)",
            plane: scene.workingPlane
        )
        _ = updateBlockReferenceDocument(operationKind: "blockReference.workPlane.save") {
            $0?.savedWorkingPlanes.append(plane)
        }
    }

    func recallBlockReferenceWorkingPlane(_ id: UUID) {
        guard let plane = blockReferenceScene?.savedWorkingPlanes.first(where: { $0.id == id })?.plane else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.workPlane.recall") { $0?.workingPlane = plane }
    }

    func offsetBlockReferenceWorkingPlane(_ distance: Double) {
        guard distance.isFinite else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.workPlane.offset") { scene in
            guard var plane = scene?.workingPlane else { return }
            plane.origin = plane.origin + plane.normal * distance
            plane.sourceObjectID = nil
            plane.sourceFaceIndex = nil
            scene?.workingPlane = plane
        }
    }

    func addBlockReferenceConstructionAxis(_ axis: BlockReferenceAxis) {
        guard let scene = blockReferenceScene else { return }
        let line = BlockConstructionLine(
            name: "\(axis.displayName) 辅助线 \(scene.constructionLines.count + 1)",
            origin: scene.workingPlane.origin,
            direction: blockReferenceGizmoAxisDirections[axis] ?? axis.unitVector
        )
        _ = updateBlockReferenceDocument(operationKind: "blockReference.constructionLine.add") {
            $0?.constructionLines.append(line)
        }
    }

    func clearBlockReferenceConstructionLines() {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.constructionLine.clear") {
            $0?.constructionLines.removeAll()
        }
    }

    func setBlockReferenceSectionEnabled(_ enabled: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.section.enabled") { scene in
            guard var value = scene else { return }
            value.section.isEnabled = enabled
            if enabled { value.section.plane = value.workingPlane }
            scene = value
        }
    }

    func setBlockReferenceSectionInverted(_ inverted: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.section.inverted") {
            $0?.section.isInverted = inverted
        }
    }

    func saveBlockReferenceSceneSnapshot() {
        guard let scene = blockReferenceScene else { return }
        let snapshot = blockReferenceSceneSnapshot(
            name: "场景快照 \(scene.snapshots.count + 1)",
            scene: scene
        )
        _ = updateBlockReferenceDocument(operationKind: "blockReference.snapshot.save") { stored in
            stored?.snapshots.append(snapshot)
            if (stored?.snapshots.count ?? 0) > 6 { stored?.snapshots.removeFirst() }
        }
    }

    func restoreBlockReferenceSceneSnapshot(_ id: UUID) {
        guard let snapshot = blockReferenceScene?.snapshots.first(where: { $0.id == id }) else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.snapshot.restore") { scene in
            guard var value = scene else { return }
            value.objects = snapshot.objects
            value.measurements = snapshot.measurements
            value.workingPlane = snapshot.workingPlane
            value.constructionLines = snapshot.constructionLines
            value.savedWorkingPlanes = snapshot.savedWorkingPlanes
            value.groups = snapshot.groups
            value.camera = snapshot.camera
            value.section = snapshot.section
            scene = value
        }
        deselectAllBlockReferenceObjects()
    }

    func deleteBlockReferenceSceneSnapshot(_ id: UUID) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.snapshot.delete") {
            $0?.snapshots.removeAll { $0.id == id }
        }
    }

    func setSelectedBlockReferenceObjectStyle(_ style: BlockReferenceObjectStyle) {
        let ids = selectedBlockReferenceObjectIDs
        guard !ids.isEmpty else { return }
        _ = updateBlockReferenceDocument(
            operationKind: isAdjustingBlockReferenceParameters ? nil : "blockReference.objectStyle"
        ) { scene in
            guard var value = scene else { return }
            for index in value.objects.indices where ids.contains(value.objects[index].id) {
                value.objects[index].style = style
            }
            scene = value
        }
    }

    func updateSelectedBlockReferenceModule(
        parameters: BlockReferenceModuleParameters? = nil,
        pose: BlockHumanPose? = nil
    ) {
        guard let selected = selectedBlockReferenceObject,
              let kind = selected.moduleKind else { return }
        let resolvedParameters = parameters ?? selected.moduleParameters ?? .default
        let resolvedPose = pose ?? selected.humanPose ?? .standing
        guard let geometry = blockReferenceAdvancedModuleGeometry(
            kind: kind,
            parameters: resolvedParameters,
            pose: resolvedPose
        ) else { return }
        _ = updateBlockReferenceDocument(
            operationKind: isAdjustingBlockReferenceParameters ? nil : "blockReference.moduleParameters"
        ) { scene in
            guard let index = scene?.objects.firstIndex(where: { $0.id == selected.id }) else { return }
            scene?.objects[index].customMesh = BlockReferenceCustomMesh(
                faces: geometry.faces,
                baseDimensions: geometry.dimensions
            )
            scene?.objects[index].dimensions = geometry.dimensions
            scene?.objects[index].moduleParameters = kind.isParametric ? resolvedParameters : nil
            scene?.objects[index].humanPose = kind == .poseableHuman ? resolvedPose : nil
        }
    }

    func createPerspectiveGuideFromBlockReferenceCamera() {
        guard let scene = blockReferenceScene,
              !scene.camera.isOrthographic,
              let object = selectedBlockReferenceObject
                ?? scene.objects.last(where: { $0.isVisible }),
              let x = blockReferenceVanishingPoint(
                direction: blockRotate(.unitX, rotation: object.rotation),
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
              ),
              let y = blockReferenceVanishingPoint(
                direction: blockRotate(.unitY, rotation: object.rotation),
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
              ),
              let z = blockReferenceVanishingPoint(
                direction: blockRotate(.unitZ, rotation: object.rotation),
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
              ) else {
            blockReferenceEditorState.instruction = "请先选择一个可见体块，并使用透视投影。"
            return
        }
        var guide = PerspectiveGuideState.initial(canvasSize: workspace.document.canvasSize)
        guide.leftVanishingPoint = x.x <= y.x ? x : y
        guide.rightVanishingPoint = x.x <= y.x ? y : x
        guide.verticalVanishingPoint = z
        guide.verticalDirection = z.y < (x.y + y.y) * 0.5 ? .above : .below
        let xIsLeft = x.x <= y.x
        guide.anchors = blockReferencePerspectiveEdgeLines(
            object: object,
            camera: scene.camera,
            canvasSize: workspace.document.canvasSize,
            maximumLinesPerAxis: 2
        ).map { line in
            PerspectiveGuideAnchor(
                position: CanvasPoint(
                    x: (line.edgeStart.x + line.edgeEnd.x) * 0.5,
                    y: (line.edgeStart.y + line.edgeEnd.y) * 0.5
                ),
                connectsLeft: line.axis == (xIsLeft ? .x : .y),
                connectsRight: line.axis == (xIsLeft ? .y : .x),
                connectsVertical: line.axis == .z
            )
        }
        guide.isVisible = true
        guide.isLocked = false
        replacePerspectiveGuideFromBlockReference(guide)
        _ = updateBlockReferenceDocument(operationKind: "blockReference.perspectiveGuide") {
            $0?.display.showsPerspectiveGuides = false
        }
        blockReferenceEditorState.instruction = "已把 \(object.name) 的实际棱边冻结为二维三点透视；可编辑消失点或清除。"
    }

    func setBlockReferenceLivePerspectiveLines(_ isVisible: Bool) {
        guard let scene = blockReferenceScene,
              !scene.camera.isOrthographic,
              selectedBlockReferenceObject != nil || scene.objects.contains(where: { $0.isVisible }) else {
            blockReferenceEditorState.instruction = "实时透视线需要一个选中的可见体块和透视相机。"
            return
        }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.livePerspective") {
            $0?.display.showsPerspectiveGuides = isVisible
        }
        blockReferenceEditorState.instruction = isVisible
            ? "实时透视线已绑定活动体块棱边；旋转相机或体块时会同步更新。"
            : "已隐藏实时透视线。"
    }

    func clearBlockReferencePerspectiveGuides() {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.clearPerspective") {
            $0?.display.showsPerspectiveGuides = false
        }
        if perspectiveGuide != nil { clearPerspectiveGuide() }
        blockReferenceEditorState.instruction = "已清除实时透视线和冻结的二维透视辅助。"
    }

    func matchBlockReferenceCameraToPerspectiveGuide() {
        guard let scene = blockReferenceScene,
              let guide = perspectiveGuide,
              let camera = blockReferenceCameraMatchingPerspectiveGuide(
                guide,
                currentCamera: scene.camera,
                canvasSize: workspace.document.canvasSize
              ) else {
            blockReferenceEditorState.instruction = "需要有效的三点透视辅助才能反推 3D 相机。"
            return
        }
        let changed = abs(camera.yawDegrees - scene.camera.yawDegrees) > 0.01
            || abs(camera.pitchDegrees - scene.camera.pitchDegrees) > 0.01
            || abs(camera.fieldOfViewDegrees - scene.camera.fieldOfViewDegrees) > 0.01
        cancelBlockReferenceInteraction()
        blockReferenceCameraPreview = nil
        blockReferenceCameraRenderState.cancelNavigation()
        _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraFromPerspective") {
            $0?.camera = camera
        }
        blockReferenceEditorState.instruction = changed
            ? String(
                format: "3D 相机已更新：水平 %.1f°，俯仰 %.1f°，视场 %.1f°。",
                camera.yawDegrees,
                camera.pitchDegrees,
                camera.fieldOfViewDegrees
            )
            : "当前三点透视本来就来自这台相机，因此画面不变；先移动消失点，再执行反推。"
    }

}
