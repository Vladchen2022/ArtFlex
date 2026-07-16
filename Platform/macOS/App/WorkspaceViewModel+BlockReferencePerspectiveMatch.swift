import Foundation

extension WorkspaceViewModel {
    var blockReferencePerspectiveMatchAssessment: BlockReferencePerspectiveMatchAssessment? {
        guard let scene = blockReferenceScene else { return nil }
        return makeBlockReferencePerspectiveMatchAssessment(
            state: blockReferenceEditorState.perspectiveMatch,
            currentCamera: scene.camera,
            canvasSize: workspace.document.canvasSize
        )
    }

    var blockReferencePerspectiveMatchCameraCandidate: BlockReferenceCamera? {
        blockReferencePerspectiveMatchAssessment?.camera
    }

    func startBlockReferencePerspectiveMatch() {
        guard blockReferenceScene != nil else { return }
        cancelBlockReferenceInteraction()
        blockReferenceEditorState.mode = .select
        blockReferenceEditorState.perspectiveMatch.isActive = true
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
        if BlockReferenceAxis.allCases.allSatisfy({
            blockReferenceEditorState.perspectiveMatch.lineCount(for: $0) >= 2
        }) {
            blockReferenceEditorState.perspectiveMatch.activeAxis = .x
        } else if let incomplete = BlockReferenceAxis.allCases.first(where: {
            blockReferenceEditorState.perspectiveMatch.lineCount(for: $0) < 2
        }) {
            blockReferenceEditorState.perspectiveMatch.activeAxis = incomplete
        }
        blockReferenceEditorState.instruction = perspectiveMatchInstruction
    }

    func stopBlockReferencePerspectiveMatch() {
        blockReferenceEditorState.perspectiveMatch.isActive = false
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
        blockReferenceEditorState.instruction = blockReferenceEditorState.perspectiveMatch.hasAnyLines
            ? "已退出画面匹配；标定线仍保留，可继续或清空。"
            : "已退出画面匹配。"
    }

    func setBlockReferencePerspectiveMatchAxis(_ axis: BlockReferenceAxis) {
        blockReferenceEditorState.perspectiveMatch.activeAxis = axis
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
        blockReferenceEditorState.instruction = perspectiveMatchInstruction
    }

    func pickBlockReferencePerspectiveMatchPlaneAnchor() {
        guard blockReferenceEditorState.perspectiveMatch.lineCount(for: .x) >= 2,
              blockReferenceEditorState.perspectiveMatch.lineCount(for: .y) >= 2 else {
            blockReferenceEditorState.instruction = "先完成 X/Y 两组参考线，再拾取工作面中心。"
            return
        }
        blockReferenceEditorState.perspectiveMatch.isActive = true
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = true
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.instruction = "点击目标桌面或地面区域的中心，定位活动工作面。"
    }

    func useAutomaticBlockReferencePerspectiveMatchPlaneAnchor() {
        blockReferenceEditorState.perspectiveMatch.planeAnchor = nil
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
        blockReferenceEditorState.instruction = "已恢复自动工作面中心：使用 X/Y 参考线交点区域的中心。"
    }

    func beginBlockReferencePerspectiveMatchLine(at point: CanvasPoint) {
        guard blockReferenceEditorState.perspectiveMatch.isActive,
              perspectiveMatchCanvasContains(point) else { return }
        let clamped = clampedPerspectiveMatchPoint(point)
        if blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor {
            blockReferenceEditorState.perspectiveMatch.planeAnchor = clamped
            blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
            blockReferenceEditorState.instruction = String(
                format: "工作面中心已定位到画布 %.0f / %.0f；可应用到相机。",
                clamped.x,
                clamped.y
            )
            return
        }
        blockReferenceEditorState.perspectiveMatch.draftLine = .init(
            axis: blockReferenceEditorState.perspectiveMatch.activeAxis,
            start: clamped,
            end: clamped
        )
    }

    func updateBlockReferencePerspectiveMatchLine(to point: CanvasPoint) {
        guard var line = blockReferenceEditorState.perspectiveMatch.draftLine else { return }
        line.end = clampedPerspectiveMatchPoint(point)
        blockReferenceEditorState.perspectiveMatch.draftLine = line
    }

    func endBlockReferencePerspectiveMatchLine() {
        guard let line = blockReferenceEditorState.perspectiveMatch.draftLine else { return }
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        let canvas = workspace.document.canvasSize
        let minimumLength = max(8, Double(min(canvas.width, canvas.height)) * 0.01)
        guard line.length >= minimumLength else {
            blockReferenceEditorState.instruction = "参考线过短；请沿画面中的真实直边拖出更长线段。"
            return
        }

        var lines = blockReferenceEditorState.perspectiveMatch.lines
        let axisIndices = lines.indices.filter { lines[$0].axis == line.axis }
        if axisIndices.count >= 6, let oldest = axisIndices.first {
            lines.remove(at: oldest)
        }
        lines.append(line)
        blockReferenceEditorState.perspectiveMatch.lines = lines
        advancePerspectiveMatchAxisIfNeeded(after: line.axis)
        blockReferenceEditorState.instruction = perspectiveMatchInstruction
    }

    func undoLastBlockReferencePerspectiveMatchLine() {
        guard blockReferenceEditorState.perspectiveMatch.lines.popLast() != nil else { return }
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.instruction = perspectiveMatchInstruction
    }

    func clearBlockReferencePerspectiveMatchAxis(_ axis: BlockReferenceAxis) {
        blockReferenceEditorState.perspectiveMatch.lines.removeAll { $0.axis == axis }
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.perspectiveMatch.activeAxis = axis
        blockReferenceEditorState.instruction = perspectiveMatchInstruction
    }

    func clearBlockReferencePerspectiveMatch() {
        blockReferenceEditorState.perspectiveMatch.lines = []
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.perspectiveMatch.planeAnchor = nil
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
        blockReferenceEditorState.perspectiveMatch.activeAxis = .x
        blockReferenceEditorState.instruction = perspectiveMatchInstruction
    }

    func applyBlockReferencePerspectiveMatch() {
        guard let assessment = blockReferencePerspectiveMatchAssessment else {
            blockReferenceEditorState.instruction = "无法得到有效相机：检查每组两条线是否来自同一空间方向，并避免画成完全平行。"
            return
        }
        let canvasSize = workspace.document.canvasSize
        guard let planeAnchor = blockReferenceEditorState.perspectiveMatch.resolvedPlaneAnchor(
            canvasSize: canvasSize
        ) else {
            blockReferenceEditorState.instruction = "无法定位工作面：请让 X/Y 参考线取自同一个桌面或地面，或手动拾取工作面中心。"
            return
        }
        let camera = blockReferenceCamera(
            anchoring: .zero,
            at: planeAnchor,
            camera: assessment.camera,
            canvasSize: canvasSize
        )
        cancelBlockReferenceInteraction()
        blockReferenceCameraPreview = nil
        blockReferenceCameraRenderState.cancelNavigation()
        _ = updateBlockReferenceDocument(operationKind: "blockReference.perspectiveMatch") { scene in
            scene?.camera = camera
            scene?.workingPlane = .ground
        }
        blockReferenceEditorState.perspectiveMatch.isActive = false
        blockReferenceEditorState.perspectiveMatch.draftLine = nil
        blockReferenceEditorState.perspectiveMatch.isPickingPlaneAnchor = false
        let warning = assessment.quality == .poor
            ? "线组偏差较大，当前结果只适合作为粗略起点。"
            : "标定线仍保留，可继续微调。"
        blockReferenceEditorState.instruction = String(
            format: "画面透视与工作面已应用（%@）：工作面中心 %.0f / %.0f，主点 %.0f / %.0f，水平 %.1f°，俯仰 %.1f°，滚转 %.1f°，视场 %.1f°。%@",
            assessment.quality.displayName,
            planeAnchor.x,
            planeAnchor.y,
            camera.principalPointNormalized.x * Double(canvasSize.width),
            camera.principalPointNormalized.y * Double(canvasSize.height),
            camera.yawDegrees,
            camera.pitchDegrees,
            camera.rollDegrees,
            camera.fieldOfViewDegrees,
            warning
        )
    }

    private var perspectiveMatchInstruction: String {
        let state = blockReferenceEditorState.perspectiveMatch
        let axis = state.activeAxis
        let count = state.lineCount(for: axis)
        if let assessment = blockReferencePerspectiveMatchAssessment {
            switch assessment.quality {
            case .stable:
                return "三组方向拟合稳定；可应用到相机，或继续增加参考线。"
            case .approximate:
                return "三组方向近似可用；建议增加更长、间距更大的参考线。"
            case .poor:
                return "线组偏差较大；检查是否选错方向，或增加更可靠的场景直边。"
            }
        }
        let meaning: String
        switch axis {
        case .x: meaning = "第一组水平边"
        case .y: meaning = "与第一组垂直的另一组水平边"
        case .z: meaning = "场景竖直边"
        }
        return "\(axis.displayName) 方向 \(count)/2：沿\(meaning)拖线；同组线在真实空间中应互相平行。"
    }

    private func advancePerspectiveMatchAxisIfNeeded(after axis: BlockReferenceAxis) {
        let state = blockReferenceEditorState.perspectiveMatch
        guard state.lineCount(for: axis) >= 2 else { return }
        let axes = BlockReferenceAxis.allCases
        guard let current = axes.firstIndex(of: axis) else { return }
        for offset in 1...axes.count {
            let candidate = axes[(current + offset) % axes.count]
            if state.lineCount(for: candidate) < 2 {
                blockReferenceEditorState.perspectiveMatch.activeAxis = candidate
                return
            }
        }
    }

    private func perspectiveMatchCanvasContains(_ point: CanvasPoint) -> Bool {
        let canvas = workspace.document.canvasSize
        return point.x >= 0 && point.y >= 0
            && point.x <= Double(canvas.width)
            && point.y <= Double(canvas.height)
    }

    private func clampedPerspectiveMatchPoint(_ point: CanvasPoint) -> CanvasPoint {
        let canvas = workspace.document.canvasSize
        return CanvasPoint(
            x: min(max(point.x, 0), Double(canvas.width)),
            y: min(max(point.y, 0), Double(canvas.height))
        )
    }
}
