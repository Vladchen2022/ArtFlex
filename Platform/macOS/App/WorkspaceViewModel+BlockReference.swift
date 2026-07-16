import AppKit
import Foundation

extension WorkspaceViewModel {
    var blockReferenceScene: BlockReferenceScene? {
        guard var scene = workspace.document.blockReferenceScene else { return nil }
        if let blockReferenceCameraPreview {
            scene.camera = blockReferenceCameraPreview
        }
        return scene
    }

    var selectedBlockReferenceObject: BlockReferenceObject? {
        guard let selectedID = blockReferenceEditorState.selectedObjectID else { return nil }
        return blockReferenceScene?.objects.first(where: { $0.id == selectedID })
    }

    var selectedBlockReferenceObjectIDs: Set<UUID> {
        guard let scene = blockReferenceScene else { return [] }
        return blockReferenceExpandedSelectionIDs(
            in: scene,
            selection: blockReferenceEditorState.resolvedSelectedObjectIDs
        )
    }

    var selectedBlockReferenceObjects: [BlockReferenceObject] {
        let selectedIDs = selectedBlockReferenceObjectIDs
        return blockReferenceScene?.objects.filter { selectedIDs.contains($0.id) } ?? []
    }

    var editableSelectedBlockReferenceObjects: [BlockReferenceObject] {
        selectedBlockReferenceObjects.filter { $0.isVisible && !$0.isLocked }
    }

    var canApplyBlockReferenceBoolean: Bool {
        selectedBlockReferenceObjectIDs.count == 2
            && editableSelectedBlockReferenceObjects.count == 2
            && editableSelectedBlockReferenceObjects.allSatisfy(\.allowsBooleanOperations)
            && selectedBlockReferenceObject != nil
    }

    var displayedSelectedBlockReferenceObject: BlockReferenceObject? {
        guard let object = selectedBlockReferenceObject else { return nil }
        return blockReferenceEditorState.numericTransform?.applying(to: object) ?? object
    }

    var blockReferenceSelectionCenter: BlockVector3? {
        let objects = editableSelectedBlockReferenceObjects
        guard !objects.isEmpty else { return nil }
        return objects.reduce(.zero) { $0 + $1.position } / Double(objects.count)
    }

    var resolvedBlockReferencePivot: BlockVector3? {
        guard let scene = blockReferenceScene else { return blockReferenceSelectionCenter }
        switch scene.pivotMode {
        case .selectionCenter:
            return blockReferenceSelectionCenter
        case .activeObject:
            return selectedBlockReferenceObject?.position ?? blockReferenceSelectionCenter
        case .workingPlaneOrigin:
            return scene.workingPlane.origin
        case .custom:
            return scene.customPivot
        }
    }

    var blockReferenceGizmoAxisDirections: [BlockReferenceAxis: BlockVector3] {
        blockReferenceAxisDirections(for: blockReferenceEditorState.gizmoCoordinateSpace)
    }

    private func blockReferenceAxisDirections(
        for space: BlockReferenceGizmoCoordinateSpace,
        activeRotation: BlockEulerRotation? = nil
    ) -> [BlockReferenceAxis: BlockVector3] {
        return Dictionary(uniqueKeysWithValues: BlockReferenceAxis.allCases.map { axis in
            let direction: BlockVector3
            switch space {
            case .world:
                direction = axis.unitVector
            case .local:
                let rotation = activeRotation ?? selectedBlockReferenceObject?.rotation ?? .zero
                direction = blockRotate(axis.unitVector, rotation: rotation)
            case .workingPlane:
                switch axis {
                case .x: direction = blockReferenceScene?.workingPlane.axisU ?? .unitX
                case .y: direction = blockReferenceScene?.workingPlane.axisV ?? .unitY
                case .z: direction = blockReferenceScene?.workingPlane.normal ?? .unitZ
                }
            }
            return (axis, direction.normalized(fallback: axis.unitVector))
        })
    }

    func setBlockReferencePivotMode(_ mode: BlockReferencePivotMode) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.pivotMode") { scene in
            scene?.pivotMode = mode
        }
        blockReferenceEditorState.instruction = "变换枢轴：\(mode.displayName)。"
    }

    func useSelectionCenterAsBlockReferencePivot() {
        guard let center = blockReferenceSelectionCenter else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.pivot.selection") { scene in
            scene?.customPivot = center
            scene?.pivotMode = .custom
        }
    }

    func selectBlockReferenceObject(_ objectID: UUID, extending: Bool) {
        guard let object = blockReferenceScene?.objects.first(where: { $0.id == objectID }) else { return }
        cancelBlockReferenceInteraction()
        if blockReferenceEditorState.selectedObjectID != objectID || object.moduleKind != .poseableHuman {
            blockReferenceEditorState.selectedHumanJoint = nil
            blockReferenceEditorState.activeHumanJointAxis = nil
        }
        let linkedIDs: Set<UUID>
        if let groupID = object.groupID {
            linkedIDs = Set(blockReferenceScene?.objects.filter { $0.groupID == groupID }.map(\.id) ?? [objectID])
        } else {
            linkedIDs = [objectID]
        }
        var selection = blockReferenceEditorState.resolvedSelectedObjectIDs
        if extending {
            if selection.contains(objectID) {
                selection.subtract(linkedIDs)
                if blockReferenceEditorState.selectedObjectID.map(linkedIDs.contains) == true {
                    blockReferenceEditorState.selectedObjectID = blockReferenceScene?.objects
                        .last(where: { selection.contains($0.id) })?.id
                }
            } else {
                selection.formUnion(linkedIDs)
                blockReferenceEditorState.selectedObjectID = objectID
            }
        } else {
            selection = linkedIDs
            blockReferenceEditorState.selectedObjectID = objectID
        }
        blockReferenceEditorState.selectedObjectIDs = selection
        blockReferenceEditorState.selectedFaceIndex = nil
        if selection.isEmpty {
            blockReferenceEditorState.instruction = "未选择体块。"
        } else {
            let activeName = blockReferenceScene?.objects
                .first(where: { $0.id == blockReferenceEditorState.selectedObjectID })?.name
                ?? object.name
            blockReferenceEditorState.instruction = "已选择 \(selection.count) 个体块，活动对象：\(activeName)。"
        }
    }

    func setBlockReferenceGizmoCoordinateSpace(_ space: BlockReferenceGizmoCoordinateSpace) {
        guard blockReferenceEditorState.gizmoCoordinateSpace != space else { return }
        cancelBlockReferenceInteraction()
        blockReferenceEditorState.gizmoCoordinateSpace = space
        blockReferenceEditorState.instruction = "变换轴已切换为\(space.displayName)坐标。"
    }

    func activateBlockReferenceForEditing() {
        blockReferenceEditorState.phase = .idle
        blockReferenceEditorState.draft = nil
        blockReferenceEditorState.draftMeasurement = nil
        blockReferenceEditorState.snapPoint = nil
        blockReferenceInteractionStartPoint = nil
        blockReferenceInteractionStartWorldPoint = nil
        blockReferenceMoveStartPosition = nil
        blockReferenceMoveStartPositions = [:]
        blockReferenceInteractionHasCheckpoint = false
        blockReferenceGizmoDragSession = nil
        blockReferenceCameraNavigationMode = nil
        blockReferenceCameraNavigationStart = nil
        blockReferenceCameraNavigationHasCheckpoint = false
        blockReferenceCameraPreview = nil
        blockReferenceCameraRenderState.cancelNavigation()
        isBlockReferenceCameraNavigating = false
        blockReferenceEditorState.hoveredGizmoHandle = nil
        blockReferenceEditorState.activeGizmoHandle = nil
        blockReferenceEditorState.gizmoLiveValue = nil
        blockReferenceEditorState.gizmoAdjustment = nil

        if blockReferenceScene == nil {
            _ = updateBlockReferenceDocument(operationKind: "blockReference.create") { scene in
                scene = .empty
            }
        } else {
            _ = updateBlockReferenceDocument { scene in
                scene?.display.isVisible = true
                scene?.display.isFrozen = false
            }
        }
        blockReferenceEditorState.instruction = "在工作面拖出二维基面；松开后再次拖拉高度。"
    }

    func freezeBlockReferenceForPainting() {
        cancelBlockReferenceInteraction()
        _ = updateBlockReferenceDocument { scene in
            scene?.display.isFrozen = true
        }
    }

    func freezeBlockReferenceAndSelectBrush() {
        freezeBlockReferenceForPainting()
        selectTool(.brush)
    }

    func setBlockReferenceEditorMode(_ mode: BlockReferenceEditorMode) {
        cancelBlockReferenceInteraction()
        blockReferenceEditorState.mode = mode
        switch mode {
        case .select:
            blockReferenceEditorState.instruction = "点击选择体块；拖动可在当前工作面移动。"
        case .box, .cylinder, .cone:
            blockReferenceEditorState.instruction = "拖出二维基面，松开后再次沿法线方向拖拉高度。"
        case .sphere:
            blockReferenceEditorState.instruction = "在当前工作面拖出球体直径。"
        case .measure:
            blockReferenceEditorState.instruction = "在当前工作面拖出测量线；端点参与捕捉。"
        case .pickWorkPlane:
            blockReferenceEditorState.instruction = "点击任意可见体块表面，将其设为新的工作面。"
        case .setPivot:
            blockReferenceEditorState.instruction = "点击物体表面或当前工作面，放置自定变换枢轴。"
        }
    }

    func setBlockReferenceBuildsDirectlyOnSurfaces(_ isEnabled: Bool) {
        cancelBlockReferenceInteraction()
        blockReferenceEditorState.buildsDirectlyOnSurfaces = isEnabled
        blockReferenceEditorState.instruction = isEnabled
            ? "表面直接建模已开启；选择几何体后，可直接从现有体块表面拖建。"
            : "表面直接建模已关闭；新体块使用当前工作面。"
    }

    func beginBlockReferenceInteraction(
        at point: CanvasPoint,
        screenScale: Double,
        modifiers: NSEvent.ModifierFlags = []
    ) {
        guard workspace.toolSession.activeTool == .blockReference,
              var scene = blockReferenceScene,
              scene.display.isVisible,
              !scene.display.isFrozen else { return }

        blockReferenceInteractionStartPoint = point
        blockReferenceInteractionHasCheckpoint = false
        blockReferenceEditorState.gizmoAdjustment = nil

        if blockReferenceEditorState.phase == .awaitingExtrusion,
           blockReferenceEditorState.draft != nil {
            blockReferenceEditorState.phase = .extruding
            blockReferenceEditorState.snapPoint = nil
            blockReferenceEditorState.instruction = "沿工作面法线拖拉高度；松开完成体块。"
            return
        }

        switch blockReferenceEditorState.mode {
        case .select:
            cancelBlockReferenceNumericTransform()
            if let selected = selectedBlockReferenceObject,
               selected.moduleKind == .poseableHuman,
               let joint = blockReferenceEditorState.selectedHumanJoint,
               let jointPoint = blockReferenceHumanJointWorldPoints(object: selected)[joint],
               let layout = blockReferenceGizmoLayout(
                    center: jointPoint,
                    axisDirections: blockReferenceHumanJointWorldAxes(object: selected, joint: joint),
                    camera: scene.camera,
                    canvasSize: workspace.document.canvasSize,
                    screenScale: screenScale
               ),
               let handle = blockReferenceGizmoHitTest(
                    point: point,
                    layout: layout,
                    screenScale: screenScale
               ),
               handle.kind == .rotate,
               joint.rotationAxes.contains(handle.axis) {
                beginBlockReferenceHumanJointRotation(
                    object: selected,
                    joint: joint,
                    axis: handle.axis,
                    jointPoint: jointPoint,
                    point: point,
                    scene: scene
                )
                return
            }
            if let selected = selectedBlockReferenceObject,
               selected.moduleKind == .poseableHuman,
               let joint = blockReferenceHumanJointHitTest(
                    object: selected,
                    canvasPoint: point,
                    camera: scene.camera,
                    canvasSize: workspace.document.canvasSize,
                    screenScale: screenScale
               ) {
                blockReferenceEditorState.selectedHumanJoint = joint
                blockReferenceEditorState.activeHumanJointAxis = nil
                blockReferenceEditorState.phase = .idle
                blockReferenceEditorState.instruction = "已选择\(joint.displayName)；拖动彩色旋转环调整关节。"
                return
            }
            blockReferenceEditorState.selectedHumanJoint = nil
            blockReferenceEditorState.activeHumanJointAxis = nil
            if let center = resolvedBlockReferencePivot,
               let selected = selectedBlockReferenceObject,
               let layout = blockReferenceGizmoLayout(
                    center: center,
                    axisDirections: blockReferenceGizmoAxisDirections,
                    camera: scene.camera,
                    canvasSize: workspace.document.canvasSize,
                    screenScale: screenScale
               ),
               let handle = blockReferenceGizmoHitTest(
                    point: point,
                    layout: layout,
                    screenScale: screenScale
               ) {
                beginBlockReferenceGizmoDrag(
                    handle: handle,
                    object: selected,
                    selectedObjects: editableSelectedBlockReferenceObjects,
                    center: center,
                    axisDirections: blockReferenceGizmoAxisDirections,
                    point: point,
                    layout: layout,
                    scene: scene
                )
                return
            }
            guard let face = blockHitTestFace(
                scene: scene,
                canvasPoint: point,
                canvasSize: workspace.document.canvasSize
            ) else {
                if !modifiers.contains(.shift) {
                    blockReferenceEditorState.selectedObjectID = nil
                    blockReferenceEditorState.selectedObjectIDs = []
                    blockReferenceEditorState.selectedFaceIndex = nil
                }
                return
            }
            if modifiers.contains(.shift) {
                selectBlockReferenceObject(face.objectID, extending: true)
                return
            }
            var selection = blockReferenceEditorState.resolvedSelectedObjectIDs
            if !selection.contains(face.objectID) {
                selection = [face.objectID]
            }
            blockReferenceEditorState.selectedObjectIDs = selection
            blockReferenceEditorState.selectedObjectID = face.objectID
            blockReferenceEditorState.selectedFaceIndex = face.faceIndex
            guard let selected = scene.objects.first(where: { $0.id == face.objectID }),
                  !selected.isLocked,
                  let worldPoint = blockWorldPoint(
                    for: point,
                    plane: scene.workingPlane,
                    scene: scene,
                    screenScale: screenScale
                  ) else { return }
            blockReferenceInteractionStartWorldPoint = worldPoint
            blockReferenceMoveStartPosition = selected.position
            let movableIDs = Set(editableSelectedBlockReferenceObjects.map(\.id))
            blockReferenceMoveStartPositions = Dictionary(
                uniqueKeysWithValues: scene.objects
                    .filter { movableIDs.contains($0.id) }
                    .map { ($0.id, $0.position) }
            )
            blockReferenceEditorState.phase = .movingObject

        case .pickWorkPlane:
            guard let face = blockHitTestFace(
                scene: scene,
                canvasPoint: point,
                canvasSize: workspace.document.canvasSize
            ), let plane = blockWorkingPlane(from: face) else { return }
            blockReferenceEditorState.selectedObjectID = face.objectID
            blockReferenceEditorState.selectedObjectIDs = [face.objectID]
            blockReferenceEditorState.selectedFaceIndex = face.faceIndex
            _ = updateBlockReferenceDocument(operationKind: "blockReference.workPlane") { stored in
                stored?.workingPlane = plane
            }
            blockReferenceEditorState.mode = .select
            blockReferenceEditorState.instruction = "已使用所选斜面作为工作面。"

        case .setPivot:
            let ray = blockCameraRay(
                canvasPoint: point,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            )
            let pickedPoint: BlockVector3?
            if let face = blockHitTestFace(
                scene: scene,
                canvasPoint: point,
                canvasSize: workspace.document.canvasSize
            ) {
                let plane = BlockWorkingPlane(
                    origin: face.vertices.first ?? scene.workingPlane.origin,
                    axisU: scene.workingPlane.axisU,
                    axisV: scene.workingPlane.axisV,
                    normal: face.normal
                )
                pickedPoint = intersectBlockRay(ray, with: plane)
            } else {
                pickedPoint = intersectBlockRay(ray, with: scene.workingPlane)
            }
            guard let pickedPoint else { return }
            _ = updateBlockReferenceDocument(operationKind: "blockReference.pivot.pick") { stored in
                stored?.customPivot = pickedPoint
                stored?.pivotMode = .custom
            }
            blockReferenceEditorState.mode = .select
            blockReferenceEditorState.instruction = "已在场景中设置自定枢轴。"

        case .measure:
            guard let worldPoint = blockWorldPoint(
                for: point,
                plane: scene.workingPlane,
                scene: scene,
                screenScale: screenScale
            ) else { return }
            blockReferenceInteractionStartWorldPoint = worldPoint
            blockReferenceEditorState.draftMeasurement = BlockMeasurementGuide(
                start: worldPoint,
                end: worldPoint
            )
            blockReferenceEditorState.snapPoint = worldPoint
            blockReferenceEditorState.phase = .measuring

        case .box, .cylinder, .cone, .sphere:
            let constructionPlane = blockReferenceConstructionPlane(
                scene: scene,
                canvasPoint: point,
                canvasSize: workspace.document.canvasSize,
                buildsDirectlyOnSurfaces: blockReferenceEditorState.buildsDirectlyOnSurfaces
            )
            guard let kind = blockReferenceEditorState.mode.primitiveKind,
                  let worldPoint = blockWorldPoint(
                    for: point,
                    plane: constructionPlane,
                    scene: scene,
                    screenScale: screenScale
                  ) else { return }
            blockReferenceInteractionStartWorldPoint = worldPoint
            blockReferenceEditorState.draft = BlockCreationDraft(
                kind: kind,
                plane: constructionPlane,
                baseStart: worldPoint,
                baseEnd: worldPoint,
                height: 1
            )
            blockReferenceEditorState.snapPoint = worldPoint
            blockReferenceEditorState.phase = .drawingBase
        }
        scene.normalize()
    }

    func updateBlockReferenceInteraction(
        to point: CanvasPoint,
        screenScale: Double
    ) {
        guard var scene = blockReferenceScene else { return }
        switch blockReferenceEditorState.phase {
        case .drawingBase:
            guard var draft = blockReferenceEditorState.draft,
                  let worldPoint = blockWorldPoint(
                    for: point,
                    plane: draft.plane,
                    scene: scene,
                    screenScale: screenScale
                  ) else { return }
            draft.baseEnd = worldPoint
            blockReferenceEditorState.draft = draft
            blockReferenceEditorState.snapPoint = worldPoint

        case .extruding:
            guard var draft = blockReferenceEditorState.draft,
                  let startPoint = blockReferenceInteractionStartPoint else { return }
            let center = draft.center
            guard let projectedCenter = projectBlockPoint(
                center,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            ), let projectedNormal = projectBlockPoint(
                center + draft.plane.normal * 100,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            ) else { return }
            let axisX = projectedNormal.canvasPoint.x - projectedCenter.canvasPoint.x
            let axisY = projectedNormal.canvasPoint.y - projectedCenter.canvasPoint.y
            let axisLength = max(hypot(axisX, axisY), 0.001)
            let unitX = axisX / axisLength
            let unitY = axisY / axisLength
            let projectedDelta = ((point.x - startPoint.x) * unitX) + ((point.y - startPoint.y) * unitY)
            let worldUnitsPerCanvasPixel = 100 / axisLength
            let rawHeight = projectedDelta * worldUnitsPerCanvasPixel
            let snapped = snappedBlockExtrusionHeight(
                rawHeight,
                draft: draft,
                scene: scene,
                canvasSize: workspace.document.canvasSize,
                screenScale: screenScale
            )
            draft.height = snapped.height
            blockReferenceEditorState.draft = draft
            blockReferenceEditorState.snapPoint = snapped.kind == .vertex
                ? snapped.snapPoint
                : nil

        case .movingObject:
            guard blockReferenceEditorState.selectedObjectID != nil,
                  let startPoint = blockReferenceInteractionStartPoint,
                  let startWorld = blockReferenceInteractionStartWorldPoint,
                  let startPosition = blockReferenceMoveStartPosition,
                  let currentWorld = intersectBlockRay(
                    blockCameraRay(
                        canvasPoint: point,
                        camera: scene.camera,
                        canvasSize: workspace.document.canvasSize
                    ),
                    with: scene.workingPlane
                  ) else { return }
            let screenDistance = hypot(point.x - startPoint.x, point.y - startPoint.y) * max(screenScale, 0.000_001)
            guard screenDistance >= 3 else { return }
            let candidate = startPosition + (currentWorld - startWorld)
            let snapped = snappedBlockPoint(
                candidate,
                scene: scene,
                canvasSize: workspace.document.canvasSize,
                screenScale: screenScale
            )
            if !blockReferenceInteractionHasCheckpoint {
                guard captureBlockReferenceHistoryCheckpoint(operationKind: "blockReference.move") else { return }
                blockReferenceInteractionHasCheckpoint = true
            }
            let appliedDelta = snapped.point - startPosition
            let startPositions = blockReferenceMoveStartPositions
            _ = updateBlockReferenceDocument { stored in
                guard var scene = stored else { return }
                for index in scene.objects.indices {
                    guard let original = startPositions[scene.objects[index].id] else { continue }
                    scene.objects[index].position = original + appliedDelta
                }
                stored = scene
            }
            blockReferenceEditorState.snapPoint = snapped.kind == nil ? nil : snapped.point

        case .transformingGizmo:
            updateBlockReferenceGizmoDrag(to: point, scene: scene, screenScale: screenScale)

        case .posingHuman:
            updateBlockReferenceHumanJointDrag(to: point, screenScale: screenScale)

        case .measuring:
            guard var measurement = blockReferenceEditorState.draftMeasurement,
                  let worldPoint = blockWorldPoint(
                    for: point,
                    plane: scene.workingPlane,
                    scene: scene,
                    screenScale: screenScale
                  ) else { return }
            measurement.end = worldPoint
            blockReferenceEditorState.draftMeasurement = measurement
            blockReferenceEditorState.snapPoint = worldPoint

        case .idle, .awaitingExtrusion:
            break
        }
        scene.normalize()
    }

    func endBlockReferenceInteraction() {
        switch blockReferenceEditorState.phase {
        case .drawingBase:
            guard let draft = blockReferenceEditorState.draft else {
                cancelBlockReferenceInteraction()
                return
            }
            if draft.dimensions.width <= 1.01 || draft.dimensions.depth <= 1.01 {
                cancelBlockReferenceInteraction()
                return
            }
            if draft.kind == .sphere {
                commitBlockReferenceDraft(draft)
            } else {
                blockReferenceEditorState.phase = .awaitingExtrusion
                blockReferenceEditorState.instruction = "基面已确定。再次拖拉蓝色法线方向设置高度。"
                blockReferenceInteractionStartPoint = nil
            }

        case .extruding:
            if let draft = blockReferenceEditorState.draft {
                commitBlockReferenceDraft(draft)
            } else {
                cancelBlockReferenceInteraction()
            }

        case .movingObject:
            blockReferenceEditorState.phase = .idle
            blockReferenceEditorState.snapPoint = nil
            blockReferenceInteractionStartPoint = nil
            blockReferenceInteractionStartWorldPoint = nil
            blockReferenceMoveStartPosition = nil
            blockReferenceMoveStartPositions = [:]
            blockReferenceInteractionHasCheckpoint = false

        case .transformingGizmo:
            if let session = blockReferenceGizmoDragSession,
               blockReferenceInteractionHasCheckpoint,
               abs(session.accumulatedValue) > 0.000_001 {
                blockReferenceEditorState.gizmoAdjustment = session.adjustment
                let space = blockReferenceEditorState.gizmoCoordinateSpace.displayName
                let axisText = session.adjustment.handle.isUniformScale
                    ? "统一"
                    : "沿\(space) \(session.adjustment.handle.axis.displayName) 轴"
                blockReferenceEditorState.instruction = "已\(axisText)\(session.adjustment.handle.kind.displayName)；可直接输入精确数值。"
            }
            blockReferenceEditorState.phase = .idle
            blockReferenceEditorState.activeGizmoHandle = nil
            blockReferenceEditorState.gizmoLiveValue = nil
            blockReferenceGizmoDragSession = nil
            blockReferenceInteractionStartPoint = nil
            blockReferenceInteractionHasCheckpoint = false

        case .posingHuman:
            blockReferenceEditorState.phase = .idle
            blockReferenceHumanJointDragSession = nil
            blockReferenceEditorState.activeHumanJointAxis = nil
            blockReferenceInteractionHasCheckpoint = false
            blockReferenceEditorState.instruction = "人体关节姿势已确认；点击其他关节可继续调整。"

        case .measuring:
            if let measurement = blockReferenceEditorState.draftMeasurement,
               measurement.length >= 0.5 {
                _ = updateBlockReferenceDocument(operationKind: "blockReference.measure") { scene in
                    scene?.measurements.append(measurement)
                }
            }
            blockReferenceEditorState.draftMeasurement = nil
            blockReferenceEditorState.snapPoint = nil
            blockReferenceEditorState.phase = .idle

        case .idle, .awaitingExtrusion:
            break
        }
    }

    func cancelBlockReferenceInteraction() {
        cancelBlockReferenceNumericTransform()
        blockReferenceEditorState.phase = .idle
        blockReferenceEditorState.draft = nil
        blockReferenceEditorState.draftMeasurement = nil
        blockReferenceEditorState.snapPoint = nil
        blockReferenceInteractionStartPoint = nil
        blockReferenceInteractionStartWorldPoint = nil
        blockReferenceMoveStartPosition = nil
        blockReferenceMoveStartPositions = [:]
        blockReferenceInteractionHasCheckpoint = false
        blockReferenceGizmoDragSession = nil
        blockReferenceHumanJointDragSession = nil
        blockReferenceEditorState.activeHumanJointAxis = nil
        blockReferenceEditorState.hoveredGizmoHandle = nil
        blockReferenceEditorState.activeGizmoHandle = nil
        blockReferenceEditorState.gizmoLiveValue = nil
        blockReferenceEditorState.gizmoAdjustment = nil
        endBlockReferenceCameraNavigation()
    }

    private func beginBlockReferenceHumanJointRotation(
        object: BlockReferenceObject,
        joint: BlockHumanJoint,
        axis: BlockReferenceAxis,
        jointPoint: BlockVector3,
        point: CanvasPoint,
        scene: BlockReferenceScene
    ) {
        let worldAxis = (
            blockReferenceHumanJointWorldAxes(object: object, joint: joint)[axis]
                ?? axis.unitVector
        ).normalized(fallback: axis.unitVector)
        let plane = blockReferenceGizmoRotationPlane(center: jointPoint, axisVector: worldAxis)
        var rotationVector: BlockVector3?
        if let intersection = intersectBlockRay(
            blockCameraRay(
                canvasPoint: point,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            ),
            with: plane
        ) {
            let vector = intersection - jointPoint
            if vector.length > 0.000_001 { rotationVector = vector.normalized() }
        }
        let projected = projectBlockPoint(
            jointPoint,
            camera: scene.camera,
            canvasSize: workspace.document.canvasSize
        )?.canvasPoint ?? point
        blockReferenceHumanJointDragSession = .init(
            objectID: object.id,
            joint: joint,
            axis: axis,
            worldAxis: worldAxis,
            jointWorldPoint: jointPoint,
            startCanvasPoint: point,
            originalPose: object.humanPose ?? .standing,
            lastRotationVector: rotationVector,
            lastScreenAngle: atan2(point.y - projected.y, point.x - projected.x)
        )
        blockReferenceEditorState.phase = .posingHuman
        blockReferenceEditorState.activeHumanJointAxis = axis
        blockReferenceEditorState.instruction = "拖动\(joint.displayName)的 \(axis.displayName) 轴旋转环。"
    }

    private func updateBlockReferenceHumanJointDrag(
        to point: CanvasPoint,
        screenScale: Double
    ) {
        guard var session = blockReferenceHumanJointDragSession,
              let scene = blockReferenceScene else { return }
        let screenDistance = hypot(
            point.x - session.startCanvasPoint.x,
            point.y - session.startCanvasPoint.y
        ) * max(screenScale, 0.000_001)
        guard screenDistance >= 2 else { return }
        let plane = blockReferenceGizmoRotationPlane(
            center: session.jointWorldPoint,
            axisVector: session.worldAxis
        )
        var currentVector: BlockVector3?
        if let intersection = intersectBlockRay(
            blockCameraRay(
                canvasPoint: point,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            ),
            with: plane
        ) {
            let vector = intersection - session.jointWorldPoint
            if vector.length > 0.000_001 { currentVector = vector.normalized() }
        }
        if let previous = session.lastRotationVector,
           let currentVector {
            session.accumulatedDegrees += blockReferenceGizmoSignedAngleDegrees(
                from: previous,
                to: currentVector,
                around: session.worldAxis
            )
            session.lastRotationVector = currentVector
        } else {
            let projected = projectBlockPoint(
                session.jointWorldPoint,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            )?.canvasPoint ?? session.startCanvasPoint
            let angle = atan2(point.y - projected.y, point.x - projected.x)
            if let previous = session.lastScreenAngle {
                let delta = atan2(sin(angle - previous), cos(angle - previous))
                session.accumulatedDegrees -= delta * 180 / .pi
            }
            session.lastScreenAngle = angle
            session.lastRotationVector = currentVector
        }
        guard session.accumulatedDegrees.isFinite else { return }
        let pose = blockReferenceHumanPose(
            session.originalPose,
            rotating: session.joint,
            around: session.axis,
            by: session.accumulatedDegrees
        )
        if !blockReferenceInteractionHasCheckpoint {
            guard captureBlockReferenceHistoryCheckpoint(operationKind: "blockReference.humanJoint") else { return }
            blockReferenceInteractionHasCheckpoint = true
        }
        let geometry = blockReferencePoseableHumanGeometry(pose: pose)
        _ = updateBlockReferenceDocument { scene in
            guard let index = scene?.objects.firstIndex(where: { $0.id == session.objectID }) else { return }
            scene?.objects[index].humanPose = pose
            scene?.objects[index].customMesh = .init(
                faces: geometry.faces,
                baseDimensions: geometry.dimensions
            )
            scene?.objects[index].dimensions = geometry.dimensions
        }
        blockReferenceHumanJointDragSession = session
        blockReferenceEditorState.instruction = "\(session.joint.displayName) · \(session.axis.displayName) 轴：\(Int(session.accumulatedDegrees.rounded()))°"
    }

    func setBlockReferenceGizmoAdjustmentInput(_ input: String) {
        guard var adjustment = blockReferenceEditorState.gizmoAdjustment else { return }
        let normalized = input.replacingOccurrences(of: ",", with: ".")
        guard normalized.count <= 18 else { return }
        let partialValues = ["", "-", ".", "-."]
        guard partialValues.contains(normalized) || Double(normalized)?.isFinite == true else { return }
        adjustment.input = normalized
        blockReferenceEditorState.gizmoAdjustment = adjustment
        guard adjustment.value != nil else { return }
        _ = updateBlockReferenceDocument { stored in
            guard var scene = stored else { return }
            for index in scene.objects.indices {
                guard adjustment.originalTransforms[scene.objects[index].id] != nil else { continue }
                scene.objects[index] = adjustment.applying(to: scene.objects[index])
            }
            stored = scene
        }
    }

    @discardableResult
    func updateBlockReferenceGizmoHover(
        at point: CanvasPoint?,
        screenScale: Double
    ) -> Bool {
        guard blockReferenceEditorState.mode == .select,
              blockReferenceEditorState.phase == .idle,
              blockReferenceEditorState.selectedHumanJoint == nil,
              let point,
              let scene = blockReferenceScene,
              !scene.display.isFrozen,
              let center = resolvedBlockReferencePivot,
              !editableSelectedBlockReferenceObjects.isEmpty,
              let layout = blockReferenceGizmoLayout(
                center: center,
                axisDirections: blockReferenceGizmoAxisDirections,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize,
                screenScale: screenScale
              ) else {
            if blockReferenceEditorState.hoveredGizmoHandle != nil {
                blockReferenceEditorState.hoveredGizmoHandle = nil
            }
            return false
        }
        let handle = blockReferenceGizmoHitTest(
            point: point,
            layout: layout,
            screenScale: screenScale
        )
        if blockReferenceEditorState.hoveredGizmoHandle != handle {
            blockReferenceEditorState.hoveredGizmoHandle = handle
        }
        return handle != nil
    }

    func finishBlockReferenceGizmoAdjustment() {
        guard blockReferenceEditorState.gizmoAdjustment != nil else { return }
        blockReferenceEditorState.gizmoAdjustment = nil
        blockReferenceEditorState.instruction = "控件变换已确认。"
    }

    private func beginBlockReferenceGizmoDrag(
        handle: BlockReferenceGizmoHandle,
        object: BlockReferenceObject,
        selectedObjects: [BlockReferenceObject],
        center: BlockVector3,
        axisDirections: [BlockReferenceAxis: BlockVector3],
        point: CanvasPoint,
        layout: BlockReferenceGizmoLayout,
        scene: BlockReferenceScene
    ) {
        let moveLayout = handle.kind == .scale
            ? (handle.isUniformScale ? nil : layout.scaleHandles.first(where: { $0.axis == handle.axis }))
            : layout.moveHandles.first(where: { $0.axis == handle.axis })
        if handle.kind == .move, moveLayout == nil { return }
        if handle.kind == .scale, !handle.isUniformScale, moveLayout == nil { return }

        var rotationVector: BlockVector3?
        let axisDirection = axisDirections[handle.axis]?.normalized(fallback: handle.axis.unitVector)
            ?? handle.axis.unitVector
        if handle.kind == .rotate {
            let plane = blockReferenceGizmoRotationPlane(center: center, axisVector: axisDirection)
            if let intersection = intersectBlockRay(
                blockCameraRay(
                    canvasPoint: point,
                    camera: scene.camera,
                    canvasSize: workspace.document.canvasSize
                ),
                with: plane
            ) {
                let vector = intersection - center
                if vector.length > 0.000_001 {
                    rotationVector = vector.normalized()
                }
            }
        }

        let adjustment = BlockReferenceGizmoAdjustment(
            objectID: object.id,
            handle: handle,
            input: handle.kind == .scale ? "1" : "0",
            originalPosition: object.position,
            originalRotation: object.rotation,
            originalTransforms: Dictionary(uniqueKeysWithValues: selectedObjects.map {
                ($0.id, BlockReferenceObjectTransformSnapshot(
                    position: $0.position,
                    rotation: $0.rotation,
                    dimensions: $0.dimensions
                ))
            }),
            pivot: center,
            axisDirections: axisDirections
        )
        blockReferenceGizmoDragSession = BlockReferenceGizmoDragSession(
            adjustment: adjustment,
            startCanvasPoint: point,
            axisCanvasDirection: moveLayout?.canvasDirection,
            worldUnitsPerCanvasPixel: moveLayout?.worldUnitsPerCanvasPixel,
            lastRotationVector: rotationVector,
            lastScreenAngle: atan2(point.y - layout.center.y, point.x - layout.center.x),
            accumulatedValue: 0
        )
        blockReferenceEditorState.phase = .transformingGizmo
        blockReferenceEditorState.activeGizmoHandle = handle
        blockReferenceEditorState.gizmoLiveValue = handle.kind == .scale ? 1 : 0
        blockReferenceEditorState.instruction = handle.isUniformScale
            ? "拖动中心 S 控件进行统一缩放；可直接输入比例后回车。"
            : "拖动 \(handle.axis.displayName) 轴\(handle.kind.displayName)控件。"
    }

    private func updateBlockReferenceGizmoDrag(
        to point: CanvasPoint,
        scene: BlockReferenceScene,
        screenScale: Double
    ) {
        guard var session = blockReferenceGizmoDragSession,
              scene.objects.contains(where: { $0.id == session.adjustment.objectID }) else { return }
        let screenDistance = hypot(
            point.x - session.startCanvasPoint.x,
            point.y - session.startCanvasPoint.y
        ) * max(screenScale, 0.000_001)
        guard screenDistance >= 2 else { return }

        switch session.adjustment.handle.kind {
        case .move:
            guard let direction = session.axisCanvasDirection,
                  let worldUnitsPerCanvasPixel = session.worldUnitsPerCanvasPixel else { return }
            let deltaX = point.x - session.startCanvasPoint.x
            let deltaY = point.y - session.startCanvasPoint.y
            session.accumulatedValue = (
                deltaX * direction.x + deltaY * direction.y
            ) * worldUnitsPerCanvasPixel

        case .rotate:
            let axis = session.adjustment.handle.axis
            let axisDirection = session.adjustment.axisDirections[axis]?.normalized(fallback: axis.unitVector)
                ?? axis.unitVector
            let center = session.adjustment.pivot
            let plane = blockReferenceGizmoRotationPlane(center: center, axisVector: axisDirection)
            var resolvedWorldVector: BlockVector3?
            if let intersection = intersectBlockRay(
                blockCameraRay(
                    canvasPoint: point,
                    camera: scene.camera,
                    canvasSize: workspace.document.canvasSize
                ),
                with: plane
            ) {
                let vector = intersection - center
                if vector.length > 0.000_001 {
                    resolvedWorldVector = vector.normalized()
                }
            }
            if let previous = session.lastRotationVector,
               let current = resolvedWorldVector {
                session.accumulatedValue += blockReferenceGizmoSignedAngleDegrees(
                    from: previous,
                    to: current,
                    around: axisDirection
                )
                session.lastRotationVector = current
            } else {
                let projectedCenter = projectBlockPoint(
                    center,
                    camera: scene.camera,
                    canvasSize: workspace.document.canvasSize
                )?.canvasPoint ?? session.startCanvasPoint
                let angle = atan2(point.y - projectedCenter.y, point.x - projectedCenter.x)
                if let previous = session.lastScreenAngle {
                    let delta = atan2(sin(angle - previous), cos(angle - previous))
                    session.accumulatedValue -= delta * 180 / .pi
                }
                session.lastScreenAngle = angle
                session.lastRotationVector = resolvedWorldVector
            }
        case .scale:
            let deltaX = point.x - session.startCanvasPoint.x
            let deltaY = point.y - session.startCanvasPoint.y
            if session.adjustment.handle.isUniformScale {
                session.accumulatedValue = max(0.01, 1 + (deltaX * 0.35 - deltaY) / 120)
            } else {
                guard let direction = session.axisCanvasDirection else { return }
                session.accumulatedValue = max(
                    0.01,
                    1 + (deltaX * direction.x + deltaY * direction.y) / 120
                )
            }
        }

        guard session.accumulatedValue.isFinite else { return }
        session.adjustment.input = blockReferenceGizmoValueText(session.accumulatedValue)
        if !blockReferenceInteractionHasCheckpoint {
            let operationKind: String
            switch session.adjustment.handle.kind {
            case .move: operationKind = "blockReference.gizmoMove"
            case .rotate: operationKind = "blockReference.gizmoRotate"
            case .scale: operationKind = "blockReference.gizmoScale"
            }
            guard captureBlockReferenceHistoryCheckpoint(operationKind: operationKind) else { return }
            blockReferenceInteractionHasCheckpoint = true
        }
        _ = updateBlockReferenceDocument { stored in
            guard var scene = stored else { return }
            for index in scene.objects.indices {
                guard session.adjustment.originalTransforms[scene.objects[index].id] != nil else { continue }
                scene.objects[index] = session.adjustment.applying(to: scene.objects[index])
            }
            stored = scene
        }
        blockReferenceGizmoDragSession = session
        blockReferenceEditorState.gizmoLiveValue = session.accumulatedValue
    }

    private func blockReferenceGizmoValueText(_ value: Double) -> String {
        let formatted = String(format: "%.3f", value)
        return formatted
            .replacingOccurrences(of: #"\.?0+$"#, with: "", options: .regularExpression)
    }

    func deleteSelectedBlockReferenceObject() {
        let selectedIDs = selectedBlockReferenceObjectIDs
        guard !selectedIDs.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.delete") { scene in
            scene?.objects.removeAll { selectedIDs.contains($0.id) }
            if let sourceID = scene?.workingPlane.sourceObjectID,
               selectedIDs.contains(sourceID) {
                scene?.workingPlane = .ground
            }
        }
        blockReferenceEditorState.selectedObjectID = nil
        blockReferenceEditorState.selectedObjectIDs = []
        blockReferenceEditorState.selectedFaceIndex = nil
    }

    func duplicateSelectedBlockReferenceObject() {
        let selectedIDs = selectedBlockReferenceObjectIDs
        guard let scene = blockReferenceScene, !selectedIDs.isEmpty else { return }
        let offset = max(scene.snap.gridSpacing, 1)
        var nextIndex = scene.objects.count + 1
        var activeDuplicateID: UUID?
        var duplicates: [BlockReferenceObject] = []
        for source in scene.objects where selectedIDs.contains(source.id) {
            var object = source
            let sourceID = object.id
            object.id = UUID()
            object.name = "\(object.geometryDisplayName) \(nextIndex)"
            object.position = object.position + scene.workingPlane.axisU * offset + scene.workingPlane.axisV * offset
            object.isVisible = true
            object.isLocked = false
            object.groupID = nil
            if sourceID == blockReferenceEditorState.selectedObjectID {
                activeDuplicateID = object.id
            }
            duplicates.append(object)
            nextIndex += 1
        }
        guard !duplicates.isEmpty else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.duplicate") { stored in
            stored?.objects.append(contentsOf: duplicates)
        }
        blockReferenceEditorState.selectedObjectIDs = Set(duplicates.map(\.id))
        blockReferenceEditorState.selectedObjectID = activeDuplicateID ?? duplicates.last?.id
        blockReferenceEditorState.selectedFaceIndex = nil
    }

    func applyBlockReferenceBoolean(_ operation: BlockReferenceBooleanOperation) {
        guard canApplyBlockReferenceBoolean,
              let scene = blockReferenceScene,
              let active = selectedBlockReferenceObject,
              let other = editableSelectedBlockReferenceObjects.first(where: { $0.id != active.id }) else {
            blockReferenceEditorState.instruction = "布尔操作需要恰好选择两个可见且未锁定的体块。"
            return
        }

        let result: BlockReferenceObject
        do {
            result = try blockReferenceBooleanObject(
                active: active,
                other: other,
                operation: operation,
                name: "\(operation.displayName)结果 \(scene.objects.count + 1)"
            )
        } catch let error as BlockReferenceBooleanError {
            switch error {
            case .emptyResult:
                blockReferenceEditorState.instruction = operation == .intersection
                    ? "两个体块没有可生成的相交体积。"
                    : "布尔结果为空；检查主体顺序和体块重叠关系。"
            case .invalidInput:
                blockReferenceEditorState.instruction = "布尔输入不是有效的封闭体块，操作已取消。"
            case .invalidResult:
                blockReferenceEditorState.instruction = "布尔结果存在无法自动修复的破面，原体块未改变。"
            case .resultTooComplex:
                blockReferenceEditorState.instruction = "布尔结果面数过高，已取消以避免场景卡顿。"
            }
            return
        } catch {
            blockReferenceEditorState.instruction = "布尔计算失败，原体块未改变。"
            return
        }

        let sourceIDs: Set<UUID> = [active.id, other.id]
        guard updateBlockReferenceDocument(
            operationKind: "blockReference.boolean.\(operation.rawValue)",
            { stored in
            guard var value = stored else { return }
            value.objects.removeAll { sourceIDs.contains($0.id) }
            value.objects.append(result)
            if let sourceID = value.workingPlane.sourceObjectID,
               sourceIDs.contains(sourceID) {
                value.workingPlane = .ground
            }
            stored = value
            }
        ) else { return }

        blockReferenceEditorState.selectedObjectID = result.id
        blockReferenceEditorState.selectedObjectIDs = [result.id]
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.mode = .select
        blockReferenceEditorState.instruction = operation == .subtract
            ? "减去完成：\(active.name) − \(other.name)。"
            : "\(operation.displayName)完成，两个源体块已替换为一个结果。"
    }

    func setBlockReferenceObjectVisibility(_ objectID: UUID, isVisible: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.objectVisibility") { scene in
            guard let index = scene?.objects.firstIndex(where: { $0.id == objectID }) else { return }
            scene?.objects[index].isVisible = isVisible
        }
        if !isVisible {
            removeBlockReferenceObjectFromSelection(objectID)
        }
    }

    func setBlockReferenceObjectLocked(_ objectID: UUID, isLocked: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.objectLock") { scene in
            guard let index = scene?.objects.firstIndex(where: { $0.id == objectID }) else { return }
            scene?.objects[index].isLocked = isLocked
        }
        if isLocked {
            removeBlockReferenceObjectFromSelection(objectID)
        }
    }

    private func removeBlockReferenceObjectFromSelection(_ objectID: UUID) {
        var selection = blockReferenceEditorState.resolvedSelectedObjectIDs
        selection.remove(objectID)
        blockReferenceEditorState.selectedObjectIDs = selection
        if blockReferenceEditorState.selectedObjectID == objectID {
            blockReferenceEditorState.selectedObjectID = blockReferenceScene?.objects
                .last(where: { selection.contains($0.id) })?.id
            blockReferenceEditorState.selectedFaceIndex = nil
        }
    }

    func resetBlockReferenceWorkingPlane() {
        cancelBlockReferenceInteraction()
        _ = updateBlockReferenceDocument(operationKind: "blockReference.resetWorkPlane") { scene in
            scene?.workingPlane = .ground
        }
        blockReferenceEditorState.mode = .select
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.instruction = "已恢复默认地面工作面（XY 平面，Z 为上方）。"
    }

    func clearBlockReferenceMeasurements() {
        guard blockReferenceScene?.measurements.isEmpty == false else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.clearMeasurements") { scene in
            scene?.measurements.removeAll()
        }
    }

    func clearBlockReferenceScene() {
        guard blockReferenceScene != nil else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.clear") { scene in
            scene = nil
        }
        blockReferenceEditorState = .init()
    }

    func createEmptyBlockReferenceScene() {
        guard blockReferenceScene == nil else { return }
        _ = updateBlockReferenceDocument(operationKind: "blockReference.create") { scene in
            scene = .empty
        }
    }

    func addBlockReferenceModule(_ kind: BlockReferenceModuleKind) {
        guard let scene = blockReferenceScene else { return }
        cancelBlockReferenceInteraction()
        let sequence = scene.objects.lazy.filter { $0.moduleKind == kind }.count + 1
        let object = blockReferenceModuleObject(
            kind: kind,
            name: "\(kind.displayName) \(sequence)",
            position: scene.workingPlane.origin,
            rotation: blockRotation(alignedTo: scene.workingPlane)
        )
        guard updateBlockReferenceDocument(
            operationKind: "blockReference.addModule.\(kind.rawValue)",
            { stored in stored?.objects.append(object) }
        ) else { return }
        blockReferenceEditorState.selectedObjectID = object.id
        blockReferenceEditorState.selectedObjectIDs = [object.id]
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.mode = .select
        if kind == .poseableHuman {
            blockReferenceEditorState.instruction = "已添加可摆姿人体；在“变换”标签调整主要关节。"
        } else if kind.isParametric {
            blockReferenceEditorState.instruction = "已添加\(kind.displayName)；在“变换”标签调整尺寸和构造参数。"
        } else {
            blockReferenceEditorState.instruction = "已添加\(kind.displayName)；固定比例不可改尺寸，可直接移动或旋转。"
        }
    }

    func setBlockReferenceVisibility(_ isVisible: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.visibility") { scene in
            scene?.display.isVisible = isVisible
        }
    }

    func setBlockReferenceOpacity(_ opacity: Float) {
        _ = updateBlockReferenceDocument { scene in
            scene?.display.opacity = opacity
        }
    }

    func setBlockReferenceShowsFaces(_ showsFaces: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.faces") { scene in
            scene?.display.showsFaces = showsFaces
        }
    }

    func setBlockReferenceShowsEdges(_ showsEdges: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.edges") { scene in
            scene?.display.showsEdges = showsEdges
        }
    }

    func setBlockReferenceDisplayMode(_ mode: BlockReferenceDisplayMode) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.displayMode") { scene in
            scene?.display.mode = mode
        }
    }

    func setBlockReferenceSnapKind(_ kind: BlockReferenceSnapKind, enabled: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.snap") { scene in
            if enabled {
                scene?.snap.enabledKinds.insert(kind)
            } else {
                scene?.snap.enabledKinds.remove(kind)
            }
        }
    }

    func setBlockReferenceGridSpacing(_ spacing: Double) {
        updateBlockReferenceParameter { scene in
            scene.snap.gridSpacing = spacing
        }
    }

    func resetBlockReferenceCamera() {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.resetCamera") { scene in
            scene?.camera = .stageOneDefault
        }
    }

    func setBlockReferenceCameraYaw(_ value: Double) {
        updateBlockReferenceParameter { $0.camera.yawDegrees = value }
    }

    func setBlockReferenceCameraPitch(_ value: Double) {
        updateBlockReferenceParameter { $0.camera.pitchDegrees = value }
    }

    func setBlockReferenceCameraDistance(_ value: Double) {
        updateBlockReferenceParameter { $0.camera.distance = value }
    }

    func setBlockReferenceCameraFieldOfView(_ value: Double) {
        updateBlockReferenceParameter { $0.camera.fieldOfViewDegrees = value }
    }

    func setBlockReferenceOrthographic(_ enabled: Bool) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.projection") { scene in
            scene?.camera.isOrthographic = enabled
        }
    }

    func beginBlockReferenceNumericTransform(_ kind: BlockReferenceNumericTransformKind) {
        guard let object = selectedBlockReferenceObject,
              !object.isLocked,
              object.isVisible else { return }
        let objects = editableSelectedBlockReferenceObjects
        guard !objects.isEmpty else { return }
        let pivot = resolvedBlockReferencePivot ?? object.position
        blockReferenceEditorState.phase = .idle
        blockReferenceEditorState.draft = nil
        blockReferenceEditorState.draftMeasurement = nil
        blockReferenceEditorState.snapPoint = nil
        blockReferenceEditorState.numericTransform = BlockReferenceNumericTransform(
            objectID: object.id,
            kind: kind,
            axis: nil,
            input: "",
            originalPosition: object.position,
            originalRotation: object.rotation,
            originalTransforms: Dictionary(uniqueKeysWithValues: objects.map {
                ($0.id, BlockReferenceObjectTransformSnapshot(
                    position: $0.position,
                    rotation: $0.rotation,
                    dimensions: $0.dimensions
                ))
            }),
            pivot: pivot,
            axisDirections: blockReferenceGizmoAxisDirections,
            coordinateSpace: blockReferenceEditorState.gizmoCoordinateSpace
        )
        blockReferenceEditorState.instruction = kind == .scale
            ? "直接输入比例整体缩放；按轴键约束世界轴，再按同轴键切到局部轴。"
            : "按 X、Y、Z 使用世界轴；连续再按同一轴切到局部轴，然后输入数值。"
    }

    func setBlockReferenceNumericTransformAxis(_ axis: BlockReferenceAxis) {
        guard var transform = blockReferenceEditorState.numericTransform else { return }
        let space = blockReferenceEditorState.gizmoCoordinateSpace
        transform.axis = axis
        transform.coordinateSpace = space
        transform.axisDirections = blockReferenceAxisDirections(
            for: space,
            activeRotation: transform.originalRotation
        )
        blockReferenceEditorState.numericTransform = transform
        blockReferenceEditorState.instruction = "已锁定\(space.displayName) \(axis.displayName) 轴；输入正数或负数，Enter 确认。"
    }

    private func setBlockReferenceNumericTransformAxisFromShortcut(_ axis: BlockReferenceAxis) {
        guard var transform = blockReferenceEditorState.numericTransform else { return }
        let space: BlockReferenceGizmoCoordinateSpace
        if transform.axis == axis {
            space = transform.coordinateSpace == .local ? .world : .local
        } else {
            space = .world
        }
        transform.axis = axis
        transform.coordinateSpace = space
        transform.axisDirections = blockReferenceAxisDirections(
            for: space,
            activeRotation: transform.originalRotation
        )
        // Keep the visible gizmo and the modal Blender-style shortcut in the
        // same coordinate space. Pointer interaction can then take over from
        // G/R + XX without leaving an invisible modal lock behind.
        blockReferenceEditorState.gizmoCoordinateSpace = space
        blockReferenceEditorState.numericTransform = transform
        let repeatHint = space == .world ? "；再按一次 \(axis.displayName) 切到局部轴" : ""
        blockReferenceEditorState.instruction = "已锁定\(space.displayName) \(axis.displayName) 轴\(repeatHint)；输入数值后 Enter。"
    }

    func setBlockReferenceNumericTransformUniformScale() {
        guard blockReferenceEditorState.numericTransform?.kind == .scale else { return }
        blockReferenceEditorState.numericTransform?.axis = nil
        blockReferenceEditorState.instruction = "统一缩放：直接输入比例并按 Enter。"
    }

    func setBlockReferenceNumericTransformInput(_ input: String) {
        guard blockReferenceEditorState.numericTransform != nil else { return }
        let normalized = input.replacingOccurrences(of: ",", with: ".")
        guard normalized.count <= 18 else { return }
        let partialValues = ["", "-", ".", "-."]
        guard partialValues.contains(normalized) || Double(normalized)?.isFinite == true else { return }
        blockReferenceEditorState.numericTransform?.input = normalized
    }

    func appendBlockReferenceNumericTransformCharacter(_ character: Character) {
        guard let transform = blockReferenceEditorState.numericTransform else { return }
        setBlockReferenceNumericTransformInput(transform.input + String(character))
    }

    func removeLastBlockReferenceNumericTransformCharacter() {
        guard var transform = blockReferenceEditorState.numericTransform,
              !transform.input.isEmpty else { return }
        transform.input.removeLast()
        blockReferenceEditorState.numericTransform = transform
    }

    func commitBlockReferenceNumericTransform() {
        guard let transform = blockReferenceEditorState.numericTransform,
              let value = transform.value,
              let scene = blockReferenceScene else {
            return
        }
        guard transform.kind == .scale || transform.axis != nil else { return }
        let changedObjects = scene.objects.filter { object in
            transform.originalTransforms[object.id] != nil
                && transform.applying(to: object) != object
        }
        if !changedObjects.isEmpty {
            _ = updateBlockReferenceDocument(
                operationKind: {
                    switch transform.kind {
                    case .move: return "blockReference.numericMove"
                    case .rotate: return "blockReference.numericRotate"
                    case .scale: return "blockReference.numericScale"
                    }
                }()
            ) { stored in
                guard var scene = stored else { return }
                for index in scene.objects.indices {
                    guard transform.originalTransforms[scene.objects[index].id] != nil else { continue }
                    scene.objects[index] = transform.applying(to: scene.objects[index])
                }
                stored = scene
            }
        }
        blockReferenceEditorState.numericTransform = nil
        let axisText = transform.axis.map { "沿\(blockReferenceEditorState.gizmoCoordinateSpace.displayName) \($0.displayName) 轴" } ?? "整体"
        blockReferenceEditorState.instruction = "已\(axisText)\(transform.kind.displayName) \(value)。"
    }

    func cancelBlockReferenceNumericTransform() {
        guard blockReferenceEditorState.numericTransform != nil else { return }
        blockReferenceEditorState.numericTransform = nil
        blockReferenceEditorState.instruction = "数值变换已取消。"
    }

    func beginBlockReferenceCameraNavigation(_ mode: BlockReferenceNavigationMode) {
        guard let scene = blockReferenceScene,
              scene.display.isVisible,
              !scene.display.isFrozen else { return }
        blockReferenceCameraNavigationMode = mode
        blockReferenceCameraNavigationStart = scene.camera
        blockReferenceCameraNavigationHasCheckpoint = false
        blockReferenceCameraPreview = nil
        blockReferenceCameraRenderState.beginNavigation()
        isBlockReferenceCameraNavigating = true
    }

    func updateBlockReferenceCameraNavigation(
        mode: BlockReferenceNavigationMode,
        deltaX: Double,
        deltaY: Double,
        screenScale: Double
    ) {
        guard blockReferenceCameraNavigationMode == mode,
              let start = blockReferenceCameraNavigationStart,
              abs(deltaX) + abs(deltaY) > 0.01 else { return }
        if !blockReferenceCameraNavigationHasCheckpoint {
            guard captureBlockReferenceHistoryCheckpoint(operationKind: "blockReference.cameraNavigation") else { return }
            blockReferenceCameraNavigationHasCheckpoint = true
        }
        var camera = start
        switch mode {
        case .orbit:
            camera.yawDegrees -= deltaX * 0.34
            camera.pitchDegrees += deltaY * 0.30
        case .pan:
            let basis = blockCameraBasis(start)
            let canvasHeight = Double(max(workspace.document.canvasSize.height, 1))
            let verticalWorldSpan = max(
                start.distance * tan(start.fieldOfViewDegrees * .pi / 360) * 2,
                1
            )
            let worldUnitsPerScreenPoint = verticalWorldSpan
                / canvasHeight
                / max(screenScale, 0.000_001)
            camera.target = start.target
                - basis.right * (deltaX * worldUnitsPerScreenPoint)
                + basis.up * (deltaY * worldUnitsPerScreenPoint)
        case .zoom:
            camera.distance = start.distance * exp(deltaY * 0.012)
        }
        blockReferenceCameraRenderState.updateNavigation(camera: camera)
        blockReferenceCameraPreview = camera
    }

    func endBlockReferenceCameraNavigation() {
        if let camera = blockReferenceCameraPreview {
            let didCommit = updateBlockReferenceDocument { scene in
                scene?.camera = camera
            }
            if didCommit {
                blockReferenceCameraRenderState.finishNavigation(committedCamera: camera)
            } else {
                blockReferenceCameraRenderState.cancelNavigation()
            }
        } else {
            blockReferenceCameraRenderState.cancelNavigation()
        }
        blockReferenceCameraPreview = nil
        isBlockReferenceCameraNavigating = false
        blockReferenceCameraNavigationMode = nil
        blockReferenceCameraNavigationStart = nil
        blockReferenceCameraNavigationHasCheckpoint = false
    }

    func zoomBlockReferenceCamera(by multiplier: Double) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        _ = updateBlockReferenceDocument { scene in
            scene?.camera.distance *= multiplier
        }
    }

    func frameBlockReferenceCamera(selectedOnly: Bool) {
        guard let scene = blockReferenceScene else { return }
        let objects: [BlockReferenceObject]
        if selectedOnly {
            objects = selectedBlockReferenceObjects.filter(\.isVisible)
        } else {
            objects = scene.objects.filter(\.isVisible)
        }
        guard !objects.isEmpty else {
            resetBlockReferenceCamera()
            return
        }
        let vertices = objects.flatMap { blockObjectFaces($0).flatMap(\.vertices) }
        guard let first = vertices.first else { return }
        var minimum = first
        var maximum = first
        for point in vertices.dropFirst() {
            minimum.x = min(minimum.x, point.x)
            minimum.y = min(minimum.y, point.y)
            minimum.z = min(minimum.z, point.z)
            maximum.x = max(maximum.x, point.x)
            maximum.y = max(maximum.y, point.y)
            maximum.z = max(maximum.z, point.z)
        }
        let center = (minimum + maximum) * 0.5
        let radius = max((maximum - minimum).length * 0.5, 20)
        _ = updateBlockReferenceDocument(operationKind: "blockReference.frameCamera") { stored in
            stored?.camera.target = center
            let fovScale = max(tan((stored?.camera.fieldOfViewDegrees ?? 42) * .pi / 360), 0.1)
            stored?.camera.distance = radius / fovScale * 1.35
        }
    }

    func setBlockReferenceCameraView(yaw: Double, pitch: Double) {
        _ = updateBlockReferenceDocument(operationKind: "blockReference.cameraView") { scene in
            scene?.camera.yawDegrees = yaw
            scene?.camera.pitchDegrees = pitch
            scene?.camera.isOrthographic = true
        }
    }

    func handleBlockReferenceKeyDown(_ event: NSEvent) -> Bool {
        guard workspace.toolSession.activeTool == .blockReference else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = blockReferenceShortcutKey(for: event)

        if blockReferenceEditorState.awaitsMirrorAxis {
            if let axis = BlockReferenceAxis(rawValue: key) {
                blockReferenceEditorState.awaitsMirrorAxis = false
                mirrorSelectedBlockReferenceObjects(axis: axis)
                return true
            }
            if event.keyCode == 53 {
                blockReferenceEditorState.awaitsMirrorAxis = false
                blockReferenceEditorState.instruction = "镜像已取消。"
                return true
            }
        }

        if blockReferenceEditorState.numericTransform != nil {
            if event.keyCode == 36 || event.keyCode == 76 {
                commitBlockReferenceNumericTransform()
                return true
            }
            if event.keyCode == 53 {
                cancelBlockReferenceNumericTransform()
                return true
            }
            if event.keyCode == 51 || event.keyCode == 117 {
                removeLastBlockReferenceNumericTransformCharacter()
                return true
            }
            if let axis = BlockReferenceAxis(rawValue: key) {
                setBlockReferenceNumericTransformAxisFromShortcut(axis)
                return true
            }
            if key == "g" {
                beginBlockReferenceNumericTransform(.move)
                return true
            }
            if key == "r" {
                beginBlockReferenceNumericTransform(.rotate)
                return true
            }
            if key == "s" {
                beginBlockReferenceNumericTransform(.scale)
                return true
            }
            if key.count == 1,
               let character = key.first,
               character.isNumber || character == "-" || character == "." || character == "," {
                appendBlockReferenceNumericTransformCharacter(character)
                return true
            }
            return false
        }

        if modifiers == [.option] {
            switch key {
            case "g": clearSelectedBlockReferenceTransform(.move); return true
            case "r": clearSelectedBlockReferenceTransform(.rotate); return true
            case "s": clearSelectedBlockReferenceTransform(.scale); return true
            case "h": showAllBlockReferenceObjects(); return true
            case "a": deselectAllBlockReferenceObjects(); return true
            default: break
            }
        }

        if modifiers == [.control], key == "g" {
            groupSelectedBlockReferenceObjects()
            return true
        }
        if modifiers == [.control, .shift], key == "g" {
            ungroupSelectedBlockReferenceObjects()
            return true
        }
        if modifiers == [.control], key == "m" {
            guard !selectedBlockReferenceObjectIDs.isEmpty else { return false }
            blockReferenceEditorState.awaitsMirrorAxis = true
            blockReferenceEditorState.instruction = "镜像：按 X、Y 或 Z 选择轴；Esc 取消。"
            return true
        }
        if modifiers == [.shift], key == "d" {
            duplicateSelectedBlockReferenceObject()
            return true
        }
        if modifiers == [.shift], key == "h" {
            isolateSelectedBlockReferenceObjects()
            return true
        }
        if modifiers == [.shift], key == "c" {
            resetBlockReferenceCamera()
            frameBlockReferenceCamera(selectedOnly: false)
            return true
        }

        guard modifiers.isDisjoint(with: [.command, .option, .control]) else { return false }

        switch event.keyCode {
        case 83:
            setBlockReferenceCameraView(yaw: -90, pitch: 0)
            return true
        case 85:
            setBlockReferenceCameraView(yaw: 0, pitch: 0)
            return true
        case 89:
            setBlockReferenceCameraView(yaw: -90, pitch: 89.9)
            return true
        case 87:
            setBlockReferenceOrthographic(!(blockReferenceScene?.camera.isOrthographic ?? false))
            return true
        case 65:
            frameBlockReferenceCamera(selectedOnly: true)
            return true
        case 115:
            frameBlockReferenceCamera(selectedOnly: false)
            return true
        case 51, 117:
            guard blockReferenceEditorState.selectedObjectID != nil else { return false }
            deleteSelectedBlockReferenceObject()
            return true
        case 53:
            cancelBlockReferenceInteraction()
            return true
        default:
            break
        }

        if key == "g", selectedBlockReferenceObject != nil {
            beginBlockReferenceNumericTransform(.move)
            return true
        }
        if key == "r", selectedBlockReferenceObject != nil {
            beginBlockReferenceNumericTransform(.rotate)
            return true
        }
        if key == "s", selectedBlockReferenceObject != nil {
            beginBlockReferenceNumericTransform(.scale)
            return true
        }
        if key == "a" {
            selectAllBlockReferenceObjects()
            return true
        }
        if key == "h", selectedBlockReferenceObject != nil {
            hideSelectedBlockReferenceObjects()
            return true
        }
        if key == "x", selectedBlockReferenceObject != nil {
            deleteSelectedBlockReferenceObject()
            return true
        }
        return false
    }

    private func blockReferenceShortcutKey(for event: NSEvent) -> String {
        switch event.keyCode {
        case 0: return "a"
        case 1: return "s"
        case 2: return "d"
        case 4: return "h"
        case 5: return "g"
        case 6: return "z"
        case 7: return "x"
        case 8: return "c"
        case 15: return "r"
        case 16: return "y"
        case 46: return "m"
        default: return event.charactersIgnoringModifiers?.lowercased() ?? ""
        }
    }

    func setBlockReferenceParameterEditing(_ isEditing: Bool) {
        if isEditing {
            guard !isAdjustingBlockReferenceParameters else { return }
            isAdjustingBlockReferenceParameters = captureBlockReferenceHistoryCheckpoint(
                operationKind: "blockReference.parameters"
            )
        } else {
            isAdjustingBlockReferenceParameters = false
        }
    }

    func setSelectedBlockReferenceDimensions(_ dimensions: BlockDimensions) {
        guard selectedBlockReferenceObject?.allowsGeometryEditing == true else {
            blockReferenceEditorState.instruction = "固定人体模块不可修改尺寸；可以移动或旋转。"
            return
        }
        updateSelectedBlockReferenceObject { $0.dimensions = dimensions }
    }

    func setSelectedBlockReferencePosition(_ position: BlockVector3) {
        guard let selected = selectedBlockReferenceObject,
              selected.isVisible,
              !selected.isLocked else { return }
        let ids = selectedBlockReferenceObjectIDs
        let delta = position - selected.position
        updateBlockReferenceParameter { scene in
            for index in scene.objects.indices where ids.contains(scene.objects[index].id) {
                scene.objects[index].position = scene.objects[index].position + delta
            }
        }
    }

    func setSelectedBlockReferenceRotation(_ rotation: BlockEulerRotation) {
        guard let selected = selectedBlockReferenceObject,
              selected.isVisible,
              !selected.isLocked else { return }
        let ids = selectedBlockReferenceObjectIDs
        guard ids.count > 1 else {
            updateSelectedBlockReferenceObject { $0.rotation = rotation }
            return
        }
        let pivot = resolvedBlockReferencePivot ?? selected.position
        updateBlockReferenceParameter { scene in
            for index in scene.objects.indices where ids.contains(scene.objects[index].id) {
                let offset = scene.objects[index].position - pivot
                scene.objects[index].position = pivot + blockApplyRotationBasisChange(
                    offset,
                    from: selected.rotation,
                    to: rotation
                )
                scene.objects[index].rotation = blockRotation(
                    applyingBasisChangeFrom: selected.rotation,
                    to: rotation,
                    to: scene.objects[index].rotation
                )
            }
        }
    }

    private func updateBlockReferenceParameter(_ transform: (inout BlockReferenceScene) -> Void) {
        let operationKind = isAdjustingBlockReferenceParameters ? nil : "blockReference.parameters"
        _ = updateBlockReferenceDocument(operationKind: operationKind) { scene in
            guard var value = scene else { return }
            transform(&value)
            scene = value
        }
    }

    private func updateSelectedBlockReferenceObject(_ transform: (inout BlockReferenceObject) -> Void) {
        guard let selectedID = blockReferenceEditorState.selectedObjectID,
              let selected = blockReferenceScene?.objects.first(where: { $0.id == selectedID }),
              selected.isVisible,
              !selected.isLocked else { return }
        updateBlockReferenceParameter { scene in
            guard let index = scene.objects.firstIndex(where: { $0.id == selectedID }) else { return }
            transform(&scene.objects[index])
        }
    }

    private func blockWorldPoint(
        for canvasPoint: CanvasPoint,
        plane: BlockWorkingPlane,
        scene: BlockReferenceScene,
        screenScale: Double
    ) -> BlockVector3? {
        guard let point = intersectBlockRay(
            blockCameraRay(
                canvasPoint: canvasPoint,
                camera: scene.camera,
                canvasSize: workspace.document.canvasSize
            ),
            with: plane
        ) else { return nil }
        var snappingScene = scene
        snappingScene.workingPlane = plane
        return snappedBlockPoint(
            point,
            scene: snappingScene,
            canvasSize: workspace.document.canvasSize,
            screenScale: screenScale
        ).point
    }

    private func commitBlockReferenceDraft(_ draft: BlockCreationDraft) {
        guard let scene = blockReferenceScene else {
            cancelBlockReferenceInteraction()
            return
        }
        let object = BlockReferenceObject(
            name: "\(draft.kind.displayName) \(scene.objects.count + 1)",
            kind: draft.kind,
            position: draft.center,
            rotation: blockRotation(alignedTo: draft.plane),
            dimensions: draft.dimensions
        )
        _ = updateBlockReferenceDocument(operationKind: "blockReference.add") { stored in
            stored?.objects.append(object)
        }
        blockReferenceEditorState.selectedObjectID = object.id
        blockReferenceEditorState.selectedObjectIDs = [object.id]
        blockReferenceEditorState.selectedFaceIndex = nil
        blockReferenceEditorState.phase = .idle
        blockReferenceEditorState.draft = nil
        blockReferenceEditorState.snapPoint = nil
        blockReferenceEditorState.mode = .select
        blockReferenceEditorState.instruction = "体块已建立。拖动可移动；参数面板可精确调整尺寸。"
        blockReferenceInteractionStartPoint = nil
        blockReferenceInteractionStartWorldPoint = nil
    }
}
