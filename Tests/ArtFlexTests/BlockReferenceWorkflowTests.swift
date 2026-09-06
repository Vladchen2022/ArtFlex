import AppKit
import Foundation
import Testing
@testable import ArtFlex

@MainActor
struct BlockReferenceWorkflowTests {
    private func model() throws -> WorkspaceViewModel {
        let bootstrap = try AppBootstrap()
        return WorkspaceViewModel(bootstrap: bootstrap, installsZoomKeyboardMonitor: false, preparesInitialTextures: false)
    }
    private func box() -> BlockReferenceObject {
        .init(name: "测试方块", kind: .box, position: .zero, dimensions: .stageOneDefault)
    }
    private func install(_ object: BlockReferenceObject, in vm: WorkspaceViewModel) {
        vm.createEmptyBlockReferenceScene()
        _ = vm.updateBlockReferenceDocument { $0?.objects = [object] }
        vm.selectBlockReferenceObject(object.id, extending: false)
    }

    @Test func openingToolAndCancelPreviewDoNotChangeDocument() throws {
        let vm = try model()
        let original = vm.workspace.document
        vm.selectTool(.blockReference)
        #expect(vm.workspace.document == original)
        let object = box()
        install(object, in: vm)
        let stored = vm.workspace.document.blockReferenceScene
        #expect(vm.beginBlockReferencePreview(operation: "blockReference.move"))
        _ = vm.updateBlockReferenceDocument { $0?.objects[0].position.x = 42 }
        #expect(vm.blockReferenceScene?.objects[0].position.x == 42)
        #expect(vm.workspace.document.blockReferenceScene == stored)
        vm.cancelBlockReferenceInteraction()
        #expect(vm.blockReferenceScene == stored)
    }

    @Test func previewCommitIsUndoableAndRedoable() throws {
        let vm = try model(); let object = box(); install(object, in: vm)
        vm.beginBlockReferencePreview(operation: "blockReference.move")
        _ = vm.updateBlockReferenceDocument { $0?.objects[0].position.x = 52 }
        vm.commitBlockReferencePreview()
        #expect(vm.workspace.document.blockReferenceScene?.objects[0].position.x == 52)
        vm.undo()
        #expect(vm.workspace.document.blockReferenceScene?.objects[0].position == object.position)
        vm.redo()
        #expect(vm.workspace.document.blockReferenceScene?.objects[0].position.x == 52)
    }

    @Test func snapshotRestoresModuleIdentityAndWholeSceneSettings() throws {
        let vm = try model(); let object = box(); install(object, in: vm)
        let instance = BlockReferenceCustomModuleInstance(assetID: UUID(), objectIDs: [object.id], basePoint: .zero)
        _ = vm.updateBlockReferenceDocument {
            $0?.customModuleInstances = [instance]
            $0?.pivotMode = .custom
            $0?.customPivot = .init(x: 17, y: 23, z: 0)
            $0?.display.paintingOpacity = 0.25
        }
        vm.saveBlockReferenceSceneSnapshot()
        let snapshot = try #require(vm.blockReferenceScene?.snapshots.first)
        vm.deleteSelectedBlockReferenceObject()
        #expect(vm.blockReferenceScene?.customModuleInstances.isEmpty == true)
        vm.restoreBlockReferenceSceneSnapshot(snapshot.id)
        #expect(vm.blockReferenceScene?.customModuleInstances == [instance])
        #expect(vm.blockReferenceScene?.pivotMode == .custom)
        #expect(vm.blockReferenceScene?.customPivot.x == 17)
        #expect(vm.blockReferenceScene?.display.paintingOpacity == 0.25)
        let data = try JSONEncoder().encode(vm.workspace.document)
        let roundTrip = try JSONDecoder().decode(ArtDocument.self, from: data)
        #expect(roundTrip.blockReferenceScene == vm.workspace.document.blockReferenceScene)
    }

    @Test func fullSnapshotsDoNotSilentlyEvict() throws {
        let vm = try model(); install(box(), in: vm)
        for _ in 0..<6 { vm.saveBlockReferenceSceneSnapshot() }
        let snapshots = vm.blockReferenceScene?.snapshots
        vm.saveBlockReferenceSceneSnapshot()
        #expect(vm.blockReferenceScene?.snapshots == snapshots)
        vm.replaceBlockReferenceSceneSnapshot(try #require(snapshots?.first?.id))
        #expect(vm.blockReferenceScene?.snapshots.count == 6)
    }

    @Test func lockedCompositionSurvivesInspectionAndReentry() throws {
        let vm = try model(); install(box(), in: vm)
        vm.freezeBlockReferenceAndSelectBrush()
        let original = try #require(vm.workspace.document.blockReferenceScene)
        vm.selectTool(.blockReference)
        #expect(vm.blockReferenceScene?.display.isFrozen == true)
        vm.beginBlockReferenceInspection()
        vm.setBlockReferenceStandardView(yaw: 20, pitch: 45)
        #expect(vm.blockReferenceScene?.camera != original.camera)
        #expect(vm.workspace.document.blockReferenceScene == original)
        vm.returnToBlockReferenceComposition()
        #expect(vm.blockReferenceScene?.camera == original.camera)
    }

    @Test func placingModuleRequiresConfirmationAndCanCancel() throws {
        let vm = try model(); vm.selectTool(.blockReference)
        vm.beginBlockReferenceModulePlacement(.torus)
        #expect(vm.workspace.document.blockReferenceScene == nil)
        let point = try #require(projectBlockPoint(.zero, camera: .stageOneDefault, canvasSize: vm.workspace.document.canvasSize)?.canvasPoint)
        _ = vm.updateBlockReferencePlacement(at: point, screenScale: 1)
        #expect(!vm.blockReferenceEditorState.placementObjects.isEmpty)
        vm.cancelBlockReferenceInteraction()
        #expect(vm.workspace.document.blockReferenceScene == nil)
        vm.beginBlockReferenceModulePlacement(.torus)
        #expect(vm.commitBlockReferencePlacement(at: point, screenScale: 1))
        #expect(vm.workspace.document.blockReferenceScene?.objects.count == 1)
        vm.undo()
        #expect(vm.workspace.document.blockReferenceScene == nil)
    }

    @Test func landingUsesActualRotatedGeometry() throws {
        let vm = try model(); var object = box()
        object.position.z = 220
        object.rotation.xDegrees = 35
        install(object, in: vm)
        vm.landSelectedBlockReferenceObjects(onGround: true)
        let landed = try #require(vm.blockReferenceScene?.objects.first)
        let bottom = try #require(blockObjectFaces(landed).flatMap(\.vertices).map(\.z).min())
        #expect(abs(bottom) < 0.00001)
    }

    @Test func faceResizeKeepsOppositeFaceAndClampsSize() {
        let object = box()
        let drag = BlockReferenceFaceDrag(object: object, axis: .x, sign: 1, normal: .unitX,
            start: .init(x: 0, y: 0), screenVector: .init(x: 1, y: 0))
        let resized = blockReferenceResizingFace(drag, distance: 50)
        #expect(resized.dimensions.width == 170)
        #expect(resized.position.x - resized.dimensions.width / 2 == -60)
        #expect(blockReferenceResizingFace(drag, distance: -500).dimensions.width == 1)
    }

    @Test func nearlyParallelPairsAreNotReportedStable() {
        let lines = BlockReferenceAxis.allCases.flatMap { axis in [
            BlockReferencePerspectiveMatchLine(axis: axis, start: .init(x: 0, y: 0), end: .init(x: 500, y: 100)),
            BlockReferencePerspectiveMatchLine(axis: axis, start: .init(x: 0, y: 50), end: .init(x: 500, y: 150.01))
        ] }
        let result = blockReferenceMatchLineCondition(lines: lines, canvasSize: .init(width: 1000, height: 1000))
        #expect(result.quality == .poor)
        #expect(result.warning != nil)
    }

    @Test func curveQualityRoundTripsWithoutChangingLegacyObjects() throws {
        var object = box(); object.kind = .cylinder
        let oldCount = blockObjectFaces(object).count
        object.radialSegments = 24
        #expect(blockObjectFaces(object).count > oldCount)
        let data = try JSONEncoder().encode(object)
        #expect(try JSONDecoder().decode(BlockReferenceObject.self, from: data).radialSegments == 24)
        var legacy = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "radialSegments")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        #expect(try JSONDecoder().decode(BlockReferenceObject.self, from: legacyData).radialSegments == 8)
    }

    @Test func cancelExitsPrimitivePlacementAndUnrelatedPivotDoesNotMove() throws {
        let vm = try model(); vm.selectTool(.blockReference)
        vm.blockReferenceEditorState.mode = .box
        vm.cancelBlockReferenceInteraction()
        #expect(vm.blockReferenceEditorState.mode == .select)
        var object = box(); object.position.z = 100
        install(object, in: vm)
        _ = vm.updateBlockReferenceDocument { $0?.pivotMode = .custom; $0?.customPivot.x = 777 }
        vm.landSelectedBlockReferenceObjects(onGround: true)
        #expect(vm.blockReferenceScene?.customPivot == .init(x: 777, y: 0, z: 0))
    }

    @Test func humanJointResetKeepsOtherPoseValues() {
        var pose = BlockHumanPose.standing
        pose.leftShoulderDegrees = 80; pose.leftShoulderFlexionDegrees = 90
        pose.rightShoulderDegrees = 70; pose.leftElbowDegrees = 100
        let reset = blockReferenceResetHumanJoint(.leftShoulder, in: pose)
        #expect(reset.leftShoulderDegrees == BlockHumanPose.standing.leftShoulderDegrees)
        #expect(reset.leftShoulderFlexionDegrees == BlockHumanPose.standing.leftShoulderFlexionDegrees)
        #expect(reset.rightShoulderDegrees == 70)
        #expect(reset.leftElbowDegrees == 100)
    }

    @Test func newDocumentDiscardsOnlyTransientBlockPreview() throws {
        let vm = try model(); install(box(), in: vm)
        vm.beginBlockReferencePreview(operation: "blockReference.move")
        _ = vm.updateBlockReferenceDocument { $0?.objects[0].position.x = 400 }
        vm.createNewCanvasDiscardingUnsavedChanges(name: "测试新画布", canvasSize: .init(width: 200, height: 200), resolutionDPI: 72)
        #expect(vm.workspace.document.blockReferenceScene == nil)
        #expect(vm.blockReferenceWorkflow.interactionPreview == nil)
        #expect(vm.blockReferenceEditorState.placementObjects.isEmpty)
    }

    @Test func undoDuringDragCancelsPreviewBeforeTouchingHistory() throws {
        let vm = try model(); vm.selectTool(.blockReference); install(box(), in: vm)
        let original = vm.workspace.document.blockReferenceScene
        vm.beginBlockReferencePreview(operation: "blockReference.move")
        _ = vm.updateBlockReferenceDocument { $0?.objects[0].position.x = 400 }
        vm.undo()
        #expect(vm.blockReferenceWorkflow.interactionPreview == nil)
        #expect(vm.workspace.document.blockReferenceScene == original)
    }

    @Test func coveringCameraBookmarkKeepsItsNameAndHonorsLock() throws {
        let vm = try model(); install(box(), in: vm)
        vm.storeBlockReferenceCameraSlot(1)
        vm.renameBlockReferenceCameraSlot(1, name: "侧面构图")
        vm.setBlockReferenceStandardView(yaw: 0, pitch: 10)
        vm.storeBlockReferenceCameraSlot(1)
        let slot = try #require(vm.blockReferenceScene?.cameraSlots.first)
        #expect(slot.name == "侧面构图")
        #expect(slot.camera.yawDegrees == 0)
        vm.setBlockReferenceCameraSlotLocked(1, locked: true)
        vm.setBlockReferenceStandardView(yaw: 45, pitch: 20)
        vm.storeBlockReferenceCameraSlot(1)
        vm.clearBlockReferenceCameraSlot(1)
        #expect(vm.blockReferenceScene?.cameraSlots.first?.camera == slot.camera)
    }
}
