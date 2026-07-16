import Foundation

extension WorkspaceViewModel {
    var perspectiveGuideMatchCandidate: PerspectiveGuideState? {
        matchedPerspectiveGuide(
            state: perspectiveGuideMatchState,
            preserving: perspectiveGuide,
            canvasSize: workspace.document.canvasSize
        )
    }

    var perspectiveGuideMatchInstruction: String {
        let state = perspectiveGuideMatchState
        if state.isComplete {
            return perspectiveGuideMatchCandidate == nil
                ? "参考线无法稳定相交；检查同组两条线是否画成了平行线。"
                : "视平线与三个消失点已生成；完成后可继续点击画布添加透视辅助线。"
        }
        let role = state.activeRole
        let count = state.lineCount(for: role)
        let meaning: String
        switch role {
        case .left:
            meaning = "通向画面左侧消失点的两条平行边"
        case .right:
            meaning = "通向画面右侧消失点的两条平行边"
        case .vertical:
            meaning = "通向上方或下方消失点的两条竖向边"
        }
        return role.displayName + " " + String(count) + "/2：沿" + meaning + "分别描边。"
    }

    func startPerspectiveGuideMatch() {
        guard workspace.toolSession.activeTool == .perspective else { return }
        endPerspectiveGuideInteraction()
        perspectiveGuideMatchState.isActive = true
        perspectiveGuideMatchState.draftLine = nil
        if let incomplete = PerspectiveGuideMatchRole.allCases.first(where: {
            perspectiveGuideMatchState.lineCount(for: $0) < 2
        }) {
            perspectiveGuideMatchState.activeRole = incomplete
        }
    }

    func stopPerspectiveGuideMatch() {
        perspectiveGuideMatchState.isActive = false
        perspectiveGuideMatchState.draftLine = nil
    }

    func setPerspectiveGuideMatchRole(_ role: PerspectiveGuideMatchRole) {
        perspectiveGuideMatchState.activeRole = role
        perspectiveGuideMatchState.draftLine = nil
    }

    func beginPerspectiveGuideMatchLine(at point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .perspective,
              perspectiveGuideMatchState.isActive,
              perspectiveGuideMatchCanvasContains(point) else { return }
        let clamped = clampedPerspectiveGuideMatchPoint(point)
        perspectiveGuideMatchState.draftLine = PerspectiveGuideMatchLine(
            role: perspectiveGuideMatchState.activeRole,
            start: clamped,
            end: clamped
        )
    }

    func updatePerspectiveGuideMatchLine(to point: CanvasPoint) {
        guard var line = perspectiveGuideMatchState.draftLine else { return }
        line.end = clampedPerspectiveGuideMatchPoint(point)
        perspectiveGuideMatchState.draftLine = line
    }

    func endPerspectiveGuideMatchLine() {
        guard let line = perspectiveGuideMatchState.draftLine else { return }
        perspectiveGuideMatchState.draftLine = nil
        let canvas = workspace.document.canvasSize
        let minimumLength = max(8, Double(min(canvas.width, canvas.height)) * 0.01)
        guard line.length >= minimumLength else { return }

        var lines = perspectiveGuideMatchState.lines
        let roleIndices = lines.indices.filter { lines[$0].role == line.role }
        if roleIndices.count >= 6, let oldest = roleIndices.first {
            lines.remove(at: oldest)
        }
        lines.append(line)
        perspectiveGuideMatchState.lines = lines
        advancePerspectiveGuideMatchRole(after: line.role)
    }

    func undoLastPerspectiveGuideMatchLine() {
        guard let removed = perspectiveGuideMatchState.lines.popLast() else { return }
        perspectiveGuideMatchState.draftLine = nil
        perspectiveGuideMatchState.activeRole = removed.role
    }

    func clearPerspectiveGuideMatchRole(_ role: PerspectiveGuideMatchRole) {
        perspectiveGuideMatchState.lines.removeAll { $0.role == role }
        perspectiveGuideMatchState.draftLine = nil
        perspectiveGuideMatchState.activeRole = role
    }

    func clearPerspectiveGuideMatch() {
        let wasActive = perspectiveGuideMatchState.isActive
        perspectiveGuideMatchState = PerspectiveGuideMatchState(isActive: wasActive)
    }

    func applyPerspectiveGuideMatch() {
        guard let guide = perspectiveGuideMatchCandidate else { return }
        guard replacePerspectiveGuideFromMatch(guide) else { return }
        perspectiveGuideMatchState.isActive = false
        perspectiveGuideMatchState.draftLine = nil
    }

    private func advancePerspectiveGuideMatchRole(after role: PerspectiveGuideMatchRole) {
        guard perspectiveGuideMatchState.lineCount(for: role) >= 2 else { return }
        let roles = PerspectiveGuideMatchRole.allCases
        guard let current = roles.firstIndex(of: role) else { return }
        for offset in 1...roles.count {
            let candidate = roles[(current + offset) % roles.count]
            if perspectiveGuideMatchState.lineCount(for: candidate) < 2 {
                perspectiveGuideMatchState.activeRole = candidate
                return
            }
        }
    }

    private func perspectiveGuideMatchCanvasContains(_ point: CanvasPoint) -> Bool {
        let canvas = workspace.document.canvasSize
        return point.x >= 0 && point.y >= 0
            && point.x <= Double(canvas.width)
            && point.y <= Double(canvas.height)
    }

    private func clampedPerspectiveGuideMatchPoint(_ point: CanvasPoint) -> CanvasPoint {
        let canvas = workspace.document.canvasSize
        return CanvasPoint(
            x: min(max(point.x, 0), Double(canvas.width)),
            y: min(max(point.y, 0), Double(canvas.height))
        )
    }
}
