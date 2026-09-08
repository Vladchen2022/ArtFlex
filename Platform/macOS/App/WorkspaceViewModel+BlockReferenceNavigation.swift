import AppKit

extension WorkspaceViewModel {
    /// Navigation is allowed on a frozen reference without moving its saved composition.
    func prepareBlockReferenceObservation() {
        guard let scene = blockReferenceScene, scene.display.isVisible,
              scene.display.isFrozen, blockReferenceWorkflow.inspectionCamera == nil else { return }
        blockReferenceWorkflow.inspectionCamera = scene.camera
        blockReferenceEditorState.instruction = "正在临时观察；原构图已保留。Esc 或“返回原构图”复原。"
    }

    func changeBlockReferenceObservationCamera(
        operationKind: String?, _ change: (inout BlockReferenceCamera) -> Void
    ) {
        if isBlockReferenceCameraNavigating { endBlockReferenceCameraNavigation() }
        prepareBlockReferenceObservation()
        guard var camera = blockReferenceScene?.camera else { return }
        change(&camera)
        camera.normalize()
        if blockReferenceWorkflow.inspectionCamera != nil {
            blockReferenceWorkflow.inspectionCamera = camera
        } else {
            _ = updateBlockReferenceDocument(operationKind: operationKind) { $0?.camera = camera }
        }
    }

    /// Blender default 3D-view navigation. Top-row numbers remain painting shortcuts.
    /// Numeric object transforms are handled by the caller before this method.
    func handleBlockReferenceNavigationKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard flags.isDisjoint(with: [.command, .option]) else { return false }
        let control = flags.contains(.control), shift = flags.contains(.shift)
        switch event.keyCode {
        case let code where [83, 85, 89].contains(code) && !shift: // 1 / 3 / 7 and their opposite views
            let yaw: Double = event.keyCode == 85 ? (control ? 180 : 0) : (control && event.keyCode == 83 ? 90 : -90)
            let pitch: Double = event.keyCode == 89 ? (control ? -89.9 : 89.9) : 0
            setBlockReferenceCameraView(yaw: yaw, pitch: pitch)
        case 84, 86, 88, 91: // 2 / 4 / 6 / 8
            if shift {
                guard !control, event.keyCode == 86 || event.keyCode == 88 else { return false }
                changeBlockReferenceObservationCamera(operationKind: "blockReference.cameraRoll") {
                    $0.rollDegrees += event.keyCode == 86 ? 15 : -15
                }
            } else if control {
                changeBlockReferenceObservationCamera(operationKind: "blockReference.cameraPan") { camera in
                    let basis = blockCameraBasis(camera)
                    let step = camera.distance * tan(camera.fieldOfViewDegrees * .pi / 360) * 0.2
                    switch event.keyCode {
                    case 86: camera.target = camera.target - basis.right * step
                    case 88: camera.target = camera.target + basis.right * step
                    case 84: camera.target = camera.target - basis.up * step
                    default: camera.target = camera.target + basis.up * step
                    }
                }
            } else {
                changeBlockReferenceObservationCamera(operationKind: "blockReference.cameraOrbit") {
                    switch event.keyCode {
                    case 86: $0.yawDegrees -= 15
                    case 88: $0.yawDegrees += 15
                    case 84: $0.pitchDegrees -= 15
                    default: $0.pitchDegrees += 15
                    }
                }
            }
        case 87 where flags.isEmpty: // 5
            setBlockReferenceOrthographic(!(blockReferenceScene?.camera.isOrthographic ?? false))
        case 92 where flags.isEmpty: // 9
            changeBlockReferenceObservationCamera(operationKind: "blockReference.cameraOrbit") { $0.yawDegrees += 180 }
        case let code where [69, 78].contains(code) && !control: // + / -; Shift dollies the camera and orbit center together
            let inward = event.keyCode == 69
            if shift {
                changeBlockReferenceObservationCamera(operationKind: "blockReference.cameraDolly") { camera in
                    camera.target = camera.target + blockCameraBasis(camera).forward * (camera.distance * (inward ? 0.2 : -0.2))
                }
            } else { zoomBlockReferenceCamera(by: inward ? 1 / 1.2 : 1.2) }
        case let code where [24, 27].contains(code) && flags == .control: // Ctrl = / - for compact keyboards
            zoomBlockReferenceCamera(by: event.keyCode == 24 ? 1 / 1.2 : 1.2)
        case 65 where !shift: frameBlockReferenceCamera(selectedOnly: true)
        case 115 where flags.isEmpty: frameBlockReferenceCamera(selectedOnly: false)
        case 8 where flags == .shift: frameBlockReferenceCamera(selectedOnly: false) // Shift C
        case 82 where flags.isEmpty && blockReferenceWorkflow.inspectionCamera != nil:
            returnToBlockReferenceComposition() // ArtFlex's saved drawing composition is its camera view.
        default: return false
        }
        return true
    }
}
