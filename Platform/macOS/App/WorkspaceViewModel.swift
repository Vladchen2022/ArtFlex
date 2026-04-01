import AppKit
import SwiftUI
import os
@preconcurrency import Metal

private func emitSelectionTraceViewModel(_ message: String) {
    appendSelectionTrace(message)
}

private typealias SelectionPolygonShape = [[CGPoint]]

private struct SelectionGeometryOptions {
    var constrainsProportions: Bool
    var drawsFromCenter: Bool
}

private struct SelectionInputShape {
    var polygonShapes: [SelectionPolygonShape]
    var preferredDisplayShape: SelectionShape?
}

private struct WholeLayerInteractionBoundsKey: Equatable {
    let surfaceID: LayerSurfaceID
    let canvasContentRevision: UInt64
}

private enum WholeLayerInteractionBoundsCacheEntry: Equatable {
    case ready(CanvasRect)
    case empty
}

@MainActor
final class WorkspaceViewModel: ObservableObject {
    struct TipImageLibraryReferenceSummary: Equatable {
        var currentBrushUsesPrimary = false
        var currentBrushUsesSecondary = false
        var presetPrimaryNames: [String] = []
        var presetSecondaryNames: [String] = []

        var currentBrushPrimaryCount: Int {
            currentBrushUsesPrimary ? 1 : 0
        }

        var currentBrushSecondaryCount: Int {
            currentBrushUsesSecondary ? 1 : 0
        }

        var presetPrimaryCount: Int {
            presetPrimaryNames.count
        }

        var presetSecondaryCount: Int {
            presetSecondaryNames.count
        }

        var currentBrushCount: Int {
            currentBrushPrimaryCount + currentBrushSecondaryCount
        }

        var presetCount: Int {
            presetPrimaryCount + presetSecondaryCount
        }

        var totalCount: Int {
            currentBrushCount + presetCount
        }

        var isReferenced: Bool {
            totalCount > 0
        }
    }

    private static let runSamePathCommitTest = false
    private static let runSamplingTruthTest = false
    private static let brushTipMaskResolution = 256
    private static let maxSavedSnapshotCount = 6
    private static let savedSnapshotThumbnailDimension = 92
    private static let snapshotComparePreviewDimension = 960

    private static func normalizedAvailableTool(_ tool: ToolKind) -> ToolKind {
        tool
    }

    @Published private(set) var workspace: WorkspaceState
    @Published private(set) var sceneSnapshot: CanvasSceneSnapshot
    @Published private(set) var status: WorkspaceStatus?
    @Published private(set) var isPanModeActive = false
    @Published private(set) var isCanvasViewportLocked = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var hasUnsavedChanges = false
    @Published var isNewCanvasSheetPresented = false
    @Published private(set) var isTransformingSelection = false
    @Published private(set) var canMergeDown = false
    @Published private(set) var canMergeVisible = false
    @Published private(set) var strokeResetToken = 0
    @Published private(set) var isGeneratorRegionSelectionArmed = false
    @Published private(set) var isGeneratorStrokeModeEnabled = false
    @Published private(set) var straightLineState = StraightLineInteractionState()
    @Published private(set) var linearGradientState = LinearGradientInteractionState()
    @Published private(set) var sectorGradientState = SectorGradientInteractionState()
    @Published private(set) var polygonSelectionState = PolygonSelectionInteractionState()
    @Published private(set) var toolGroupSurfaceTools = ToolSidebarGroup.defaultSurfaceTools
    @Published private(set) var transformPreviewOffset = CanvasPoint(x: 0, y: 0)
    @Published private(set) var freeTransformPreview = FreeTransformPreview.identity
    @Published private(set) var isApplyingGradientCommit = false
    @Published private(set) var isFreeTransformDragging = false
    @Published private(set) var activeFreeTransformInteractionMode: FreeTransformInteractionMode?
    @Published private(set) var isBrushTipCanvasFocused = false
    @Published private(set) var isColorBlocksPanelFocused = false
    private(set) var lassoSamplingDebugPoints: [CanvasPoint] = []
    private(set) var samePathCommittedDebugShape: SelectionShape?
    private(set) var samePathPreviewDebugShape: SelectionShape?

    private let bootstrap: AppBootstrap
    var ideationBranchActivityHandler: (() -> Void)?
    var ideationOperationHandler: ((IdeationCanvasOperation) -> Void)?
    var ideationUndoHandler: (() -> Bool)?
    var ideationRedoHandler: (() -> Bool)?
    private var isApplyingMirroredIdeationOperation = false
    private var statusDismissTask: Task<Void, Never>?
    private var isAdjustingLayerOpacity = false
    private var transformState = TransformInteractionState()
    private var layerThumbnailCache: [LayerID: CGImage] = [:]
    private var generatorStrokeSession = GeneratorStrokeSessionState()
    private var activeLassoRawPoints: [CanvasPoint] = []
    private var activeLassoBounds: CanvasRect?
    private var lassoRefreshCounter = 0  // 套索拖动时的刷新节流计数器
    private var freeTransformUsesImplicitSelection = false
    private var implicitFreeTransformSelectionShape: SelectionShape?
    @Published private(set) var isApplyingTransformCommit = false
    @Published private(set) var canvasContentRevision: UInt64 = 0
    @Published private(set) var selectionRevision: UInt64 = 0
    @Published private(set) var viewportRevision: UInt64 = 0
    @Published private(set) var transformPreviewRevision: UInt64 = 0
    @Published private(set) var savedSnapshots: [CanvasSavedSnapshot] = []
    @Published private(set) var ideationSession: IdeationSessionState?
    @Published private(set) var snapshotCompareSession: SnapshotCompareSessionState?
    private var currentProjectURL: URL?
    private var shouldResumeTimelapseAfterIdeation = false
    private var shouldResumeTimelapseAfterSnapshotCompare = false
    private var snapshotPreviewPreparationTasks: [UUID: Task<Void, Never>] = [:]
    private var frozenSnapshotPreviewPreparationTask: Task<Void, Never>?
    private var deferredGradientAction: DeferredGradientAction?
    private let selectionTraceLogger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
    private let brushStrokeLogger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private let transformLogger = Logger(subsystem: "ArtFlex", category: "Transform")
    private var latestCanvasViewportSize: CGSize = .zero
    private var lastCanvasHoverPoint: CanvasPoint?
    private var documentChangeRevision: UInt64 = 0
    private var strokePacketCount = 0
#if DEBUG
    var debugPixelOperationHistoryCaptureModeOverride: HistoryCaptureMode?
    var debugFillAtPointHistoryCaptureModeOverride: HistoryCaptureMode?
#endif
    private var freeTransformMoveLogCount = 0
    private var wholeLayerInteractionBoundsCacheKey: WholeLayerInteractionBoundsKey?
    private var wholeLayerInteractionBoundsCacheEntry: WholeLayerInteractionBoundsCacheEntry?
    private var wholeLayerInteractionBoundsBuildingKey: WholeLayerInteractionBoundsKey?
    private var wholeLayerInteractionBoundsTask: Task<WholeLayerInteractionBoundsCacheEntry?, Never>?
    private var lastLoggedWholeLayerOverlayUsesInteractionBounds: Bool?
    private lazy var transformPreviewSessionBuilder = TransformPreviewSessionBuilder(device: bootstrap.metalContext.device)
    private lazy var transformGPUCompositorResult: Result<TransformGPUCompositor, Error> = Result {
        try TransformGPUCompositor(device: bootstrap.metalContext.device)
    }
    init(
        bootstrap: AppBootstrap,
        installsZoomKeyboardMonitor: Bool = true,
        preparesInitialTextures: Bool = true
    ) {
        self.bootstrap = bootstrap
        resetSelectionTraceLog()
        Self.restorePersistedBrushLibraryIfAvailable(in: bootstrap)
        Self.normalizeLegacySelectionIfNeeded(in: bootstrap.workspaceStore)
        Self.normalizeDisabledToolsIfNeeded(in: bootstrap.workspaceStore)
        let state = bootstrap.workspaceStore.state
        if preparesInitialTextures {
            bootstrap.layerSurfaceStore.prepareTextures(
                for: state.document,
                metal: bootstrap.metalContext
            )
        }
        self.workspace = state
        self.sceneSnapshot = WorkspaceViewModel.makeSceneSnapshot(
            workspace: state,
            bootstrap: bootstrap,
            canvasContentRevision: 0,
            selectionRevision: 0,
            viewportRevision: 0
        )
        if let group = ToolSidebarGroup.group(containing: state.toolSession.activeTool) {
            toolGroupSurfaceTools[group.id] = state.toolSession.activeTool
        }
        if preparesInitialTextures {
            seedDefaultBackgroundLayerIfNeeded(for: state.document)
        }
        syncTimelapseDocumentContext()
        if installsZoomKeyboardMonitor {
            setupZoomKeyboardMonitor()
        }
    }

    // Cmd+= / Cmd+- 完全绕过菜单系统，直接本地拦截
    // 菜单快捷键会在系统事件队列里积压，松开按键后仍持续触发
    // addLocalMonitorForEvents 在事件到达菜单前拦截，返回 nil 消费掉事件
    private func setupZoomKeyboardMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers == .command else { return event }
            let chars = event.charactersIgnoringModifiers
            if chars == "=" || chars == "+" {
                self.zoomIn()
                return nil
            }
            if chars == "-" {
                self.zoomOut()
                return nil
            }
            return event
        }
    }

    func selectTool(_ tool: ToolKind) {
        ideationBranchActivityHandler?()
        let normalizedTool = Self.normalizedAvailableTool(tool)
        if shouldAutoApplyGradientBeforeSelectingTool(normalizedTool) {
            deferredGradientAction = .toolSwitch(normalizedTool)
            transformLogger.debug("[gradient] autoApplyOnToolSwitch=true sessionState=\(self.gradientSessionStateDescription(), privacy: .public)")
            transformLogger.debug("[gradient] deferredToolSwitch=true sessionTool=\(String(describing: self.activeGradientTool()), privacy: .public)")
            guard !isApplyingGradientCommit else { return }
            applyActiveGradientSession()
            return
        }
        let currentTool = workspace.toolSession.activeTool
        if isBrushLikeTool(currentTool) && !isBrushLikeTool(normalizedTool) {
            _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        }
        performToolSelection(normalizedTool)
    }

    private func performToolSelection(_ tool: ToolKind) {
        let tool = Self.normalizedAvailableTool(tool)
        let previousTool = workspace.toolSession.activeTool
        if workspace.toolSession.activeTool != tool {
            resolveTransformSession(reason: .toolChange)
        }
        if previousTool == .freeTransform, tool != .freeTransform, freeTransformUsesImplicitSelection {
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
        }
        isGeneratorRegionSelectionArmed = false
        isGeneratorStrokeModeEnabled = false
        generatorStrokeSession = .init()
        activeLassoRawPoints = []
        lassoSamplingDebugPoints = []
        samePathCommittedDebugShape = nil
        samePathPreviewDebugShape = nil
        straightLineState = .init()
        linearGradientState = .init()
        sectorGradientState = .init()
        polygonSelectionState = .init()
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = tool
        }
        if let group = ToolSidebarGroup.group(containing: tool) {
            toolGroupSurfaceTools[group.id] = tool
        }
        if tool == .freeTransform {
            primeWholeLayerFreeTransformIdleStateIfNeeded(for: bootstrap.workspaceStore.state)
            refreshLightweight()
        } else {
            setFreeTransformPreview(.identity)
        }
        if tool == .freeTransform {
            refreshLightweight()
        } else {
            refresh()
        }
    }

    func presentNewCanvasSheet() {
        isNewCanvasSheetPresented = true
    }

    func dismissNewCanvasSheet() {
        isNewCanvasSheetPresented = false
    }

    var timelapseRecorder: TimelapseRecorderController {
        bootstrap.timelapseRecorder
    }

    var savedSnapshotCount: Int {
        savedSnapshots.count
    }

    var isSnapshotCompareActive: Bool {
        snapshotCompareSession != nil
    }

    func chooseTimelapseOutputDirectory() {
        guard let url = bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择录像数据文件夹",
            prompt: "选择文件夹"
        ) else {
            showStatus(.init(kind: .info, message: "已取消选择录像目录"))
            return
        }

        timelapseRecorder.outputDirectory = url
        syncTimelapseDocumentContext()
        showStatus(.init(kind: .success, message: "已设置录像目录：\(url.lastPathComponent)"))
    }

    func toggleTimelapseRecording() {
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比期间录像已暂停"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间录像已暂停"))
            return
        }

        if timelapseRecorder.isRecording {
            timelapseRecorder.stopRecording()
            showStatus(.init(kind: .info, message: "已停止录制"))
            return
        }

        if timelapseRecorder.outputDirectory == nil {
            chooseTimelapseOutputDirectory()
            if timelapseRecorder.outputDirectory == nil { return }
            if timelapseRecorder.isRecording { return }
        }

        do {
            let sessionDirectory = try timelapseRecorder.startRecording(
                documentName: workspace.document.metadata.name,
                documentFileURL: currentProjectURL
            )
            showStatus(.init(kind: .success, message: "已开始录制：\(sessionDirectory.lastPathComponent)"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportTimelapseVideo(fps: Int) {
        syncTimelapseDocumentContext()
        guard timelapseRecorder.canExportVideo else {
            showStatus(.init(kind: .info, message: "当前没有可导出的视频帧"))
            return
        }

        let defaultName = "\(workspace.document.metadata.name)-timelapse"
        guard let outputURL = bootstrap.filePanelService.presentVideoExportPanel(defaultName: defaultName) else {
            showStatus(.init(kind: .info, message: "已取消导出视频"))
            return
        }

        timelapseRecorder.exportCurrentSessionVideo(
            to: outputURL,
            fps: fps,
            leadInSeconds: timelapseRecorder.exportLeadInSeconds,
            tailHoldSeconds: timelapseRecorder.exportTailHoldSeconds
        ) { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let url):
                    self.showStatus(.init(kind: .success, message: "已导出视频：\(url.lastPathComponent)"))
                case .failure(let error):
                    self.showStatus(.init(kind: .error, message: error.localizedDescription))
                }
            }
        }
    }

    func revealTimelapseSessionInFinder() {
        syncTimelapseDocumentContext()
        guard let url = timelapseRecorder.currentSessionDirectory else {
            showStatus(.init(kind: .info, message: "当前还没有录像目录"))
            return
        }
        bootstrap.filePanelService.revealInFinder(url)
    }

    func openLastExportedTimelapseVideo() {
        guard let url = timelapseRecorder.lastExportedVideoURL else {
            showStatus(.init(kind: .info, message: "当前没有可打开的导出视频"))
            return
        }
        _ = bootstrap.filePanelService.openURL(url)
    }

    func displayedTool(for group: ToolSidebarGroup) -> ToolKind {
        toolGroupSurfaceTools[group.id] ?? group.defaultTool
    }

    func isSelected(group: ToolSidebarGroup) -> Bool {
        group.contains(workspace.toolSession.activeTool)
    }

    func activateSidebarGroup(_ group: ToolSidebarGroup) {
        selectTool(displayedTool(for: group))
    }

    func cycleSidebarGroup(_ group: ToolSidebarGroup) {
        guard group.tools.count > 1 else {
            activateSidebarGroup(group)
            return
        }

        let current = displayedTool(for: group)
        let currentIndex = group.tools.firstIndex(of: current) ?? 0
        let nextIndex = (currentIndex + 1) % group.tools.count
        selectTool(group.tools[nextIndex])
    }

    func handleToolShortcutKey(_ key: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        guard normalized.isDisjoint(with: [.command, .option, .control]) else { return false }
        guard let group = ToolSidebarGroup.group(forShortcutKey: key) else { return false }

        if normalized.contains(.shift), group.tools.count > 1 {
            cycleSidebarGroup(group)
        } else {
            activateSidebarGroup(group)
        }
        return true
    }

    func setBrushSize(_ size: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.size = max(1, size)
        }
        refresh()
    }

    func adjustBrushSize(by delta: Float) {
        let currentSize = workspace.toolSession.brush.size
        let direction: Float = delta == 0 ? 0 : (delta > 0 ? 1 : -1)
        let step = brushSizeShortcutStep(for: currentSize)
        setBrushSize(currentSize + (direction * step))
    }

    private func brushSizeShortcutStep(for size: Float) -> Float {
        if size <= 10 { return 1 }
        if size <= 50 { return 5 }
        if size <= 100 { return 10 }
        if size <= 200 { return 25 }
        if size <= 300 { return 50 }
        return 100
    }

    func setBrushOpacity(_ opacity: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.opacity = min(max(0, opacity), 1)
        }
        refresh()
    }

    func setBrushBuildMode(_ mode: BrushBuildMode) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.buildMode = mode
        }
        refresh()
    }

    func setBrushSpacingPercent(_ percent: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.spacingPercent = min(max(percent, 5), 150)
        }
        refresh()
    }

    func setBrushScatterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.scatterAmount = min(max(amount, 0), 5)
        }
        refresh()
    }

    func setBrushJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.jitterAmount = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setBrushColorJitterAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.colorJitterAmount = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setBrushStampRotationDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            var normalized = angleDegrees.truncatingRemainder(dividingBy: 360)
            if normalized < 0 {
                normalized += 360
            }
            session.brush.stampRotationDegrees = normalized
        }
        refresh()
    }

    func setBrushFollowsStrokeDirection(_ follows: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.followsStrokeDirection = follows
        }
        refresh()
    }

    func setPressureSensitivity(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.pressureSensitivity = min(max(amount, 0), 2)
        }
        refresh()
    }

    func setSizeLowerBound(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.sizeLowerBound = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setPressureSizeAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.pressureSizeAmount = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setPressureOpacityAmount(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.pressureOpacityAmount = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setSizeCurveLow(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.sizeCurveLow = min(max(value, 0), 0.85)
            session.brush.sizeCurveMid = max(session.brush.sizeCurveMid, session.brush.sizeCurveLow)
            session.brush.sizeCurveHigh = max(session.brush.sizeCurveHigh, session.brush.sizeCurveMid)
        }
        refresh()
    }

    func setSizeCurveMid(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(value, 0), 0.95)
            session.brush.sizeCurveMid = clamped
            session.brush.sizeCurveLow = min(session.brush.sizeCurveLow, session.brush.sizeCurveMid)
            session.brush.sizeCurveHigh = max(session.brush.sizeCurveHigh, session.brush.sizeCurveMid)
        }
        refresh()
    }

    func setSizeCurveHigh(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(value, 0), 1)
            session.brush.sizeCurveHigh = clamped
            session.brush.sizeCurveMid = min(session.brush.sizeCurveMid, session.brush.sizeCurveHigh)
            session.brush.sizeCurveLow = min(session.brush.sizeCurveLow, session.brush.sizeCurveMid)
        }
        refresh()
    }

    func setOpacityCurveLow(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.opacityCurveLow = min(max(value, 0), 0.85)
            session.brush.opacityCurveMid = max(session.brush.opacityCurveMid, session.brush.opacityCurveLow)
            session.brush.opacityCurveHigh = max(session.brush.opacityCurveHigh, session.brush.opacityCurveMid)
        }
        refresh()
    }

    func setOpacityCurveMid(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(value, 0), 0.95)
            session.brush.opacityCurveMid = clamped
            session.brush.opacityCurveLow = min(session.brush.opacityCurveLow, session.brush.opacityCurveMid)
            session.brush.opacityCurveHigh = max(session.brush.opacityCurveHigh, session.brush.opacityCurveMid)
        }
        refresh()
    }

    func setOpacityCurveHigh(_ value: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            let clamped = min(max(value, 0), 1)
            session.brush.opacityCurveHigh = clamped
            session.brush.opacityCurveMid = min(session.brush.opacityCurveMid, session.brush.opacityCurveHigh)
            session.brush.opacityCurveLow = min(session.brush.opacityCurveLow, session.brush.opacityCurveMid)
        }
        refresh()
    }

    func applyOpacityCurvePreset(_ preset: PressureCurvePreset) {
        let values = preset.opacityValues
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.opacityCurveLow = values.low
            session.brush.opacityCurveMid = values.mid
            session.brush.opacityCurveHigh = values.high
        }
        refresh()
    }

    func resetOpacityCurveToDefault() {
        let defaults = BrushSettings.stageOneDefault
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.opacityCurveLow = defaults.opacityCurveLow
            session.brush.opacityCurveMid = defaults.opacityCurveMid
            session.brush.opacityCurveHigh = defaults.opacityCurveHigh
        }
        refresh()
    }

    func applySizeCurvePreset(_ preset: PressureCurvePreset) {
        let values = preset.sizeValues
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.sizeCurveLow = values.low
            session.brush.sizeCurveMid = values.mid
            session.brush.sizeCurveHigh = values.high
        }
        refresh()
    }

    func resetSizeCurveToDefault() {
        let defaults = BrushSettings.stageOneDefault
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.sizeCurveLow = defaults.sizeCurveLow
            session.brush.sizeCurveMid = defaults.sizeCurveMid
            session.brush.sizeCurveHigh = defaults.sizeCurveHigh
        }
        refresh()
    }

    func setBrushTipShape(_ tipShape: BrushTipShape) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = tipShape
        }
        refresh()
    }

    func reactivatePrimaryCustomTipSourceIfAvailable() {
        bootstrap.workspaceStore.updateToolSession { session in
            let hasDormantCustomTip =
                session.brush.customTipMaskData != nil ||
                (session.brush.customTipSourceSemantic == .importedImage && session.brush.customTipAssetID != nil)
            guard hasDormantCustomTip else { return }
            session.brush.tipShape = .customRound
        }
        refresh()
    }

    func setDualTipEnabled(_ enabled: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.dualTipEnabled = enabled
            if enabled && session.brush.secondarySizeRatio >= 0.95 {
                session.brush.secondarySizeRatio = 0.65
            }
        }
        refresh()
    }

    func setDualTipCombineMode(_ mode: DualTipCombineMode) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.dualTipCombineMode = mode
        }
        refresh()
    }

    func setDualTipStrength(_ strength: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.dualTipStrength = min(max(strength, 0), 1)
        }
        refresh()
    }

    func setSecondaryTipShape(_ tipShape: BrushTipShape) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryTipDescriptor.tipShape = tipShape
        }
        refresh()
    }

    func reactivateSecondaryCustomTipSourceIfAvailable() {
        bootstrap.workspaceStore.updateToolSession { session in
            let secondary = session.brush.secondaryTipDescriptor
            let hasDormantCustomTip =
                secondary.customTipMaskData != nil ||
                (secondary.sourceSemantic == .importedImage && secondary.tipAssetID != nil)
            guard hasDormantCustomTip else { return }
            session.brush.secondaryTipDescriptor.tipShape = .customRound
        }
        refresh()
    }

    func setSecondaryTipSoftness(_ softness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryTipDescriptor.customTipSoftness = min(max(softness, 0), 1)
        }
        refresh()
    }

    func setSecondaryTipRoundness(_ roundness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryTipDescriptor.customTipRoundness = min(max(roundness, 0.25), 1)
        }
        refresh()
    }

    func setSecondaryTipSourceAngleDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            var normalized = angleDegrees.truncatingRemainder(dividingBy: 180)
            if normalized < 0 {
                normalized += 180
            }
            session.brush.secondaryTipDescriptor.customTipAngleDegrees = normalized
        }
        refresh()
    }

    func updateSecondaryTipMask(_ data: Data?) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryTipDescriptor.tipShape = .customRound
            session.brush.secondaryTipDescriptor.sourceSemantic = data == nil ? .procedural : .customMask
            session.brush.secondaryTipDescriptor.tipAssetID = nil
            session.brush.secondaryTipDescriptor.importedSourceInfo = nil
            session.brush.secondaryTipDescriptor.customTipMaskData = data
        }
        refresh()
    }

    func clearSecondaryTipMask() {
        updateSecondaryTipMask(nil)
    }

    func setSecondarySizeRatio(_ ratio: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondarySizeRatio = min(max(ratio, 0.25), 0.95)
        }
        refresh()
    }

    func setSecondarySizeJitter(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondarySizeJitter = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setSecondaryAngleJitterDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryAngleJitterDegrees = min(max(angleDegrees, 0), 180)
        }
        refresh()
    }

    func setSecondaryAngleOffsetDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryAngleOffsetDegrees = min(max(angleDegrees, -180), 180)
        }
        refresh()
    }

    func setSecondarySpacingPhase(_ phase: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondarySpacingPhase = min(max(phase, -0.5), 0.5)
        }
        refresh()
    }

    func setSecondarySpacingPhaseJitter(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondarySpacingPhaseJitter = min(max(amount, 0), 0.5)
        }
        refresh()
    }

    func setSecondaryScatter(_ scatter: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryScatter = min(max(scatter, 0), 5)
        }
        refresh()
    }

    func setSecondaryScatterJitter(_ amount: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryScatterJitter = min(max(amount, 0), 1)
        }
        refresh()
    }

    func setSecondaryInvert(_ invert: Bool) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryInvert = invert
        }
        refresh()
    }

    func setCustomTipSoftness(_ softness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.customTipSoftness = min(max(softness, 0), 1)
        }
        refresh()
    }

    func setCustomTipRoundness(_ roundness: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.customTipRoundness = min(max(roundness, 0.25), 1)
        }
        refresh()
    }

    func setCustomTipAngleDegrees(_ angleDegrees: Float) {
        bootstrap.workspaceStore.updateToolSession { session in
            var normalized = angleDegrees.truncatingRemainder(dividingBy: 180)
            if normalized < 0 {
                normalized += 180
            }
            session.brush.customTipAngleDegrees = normalized
        }
        refresh()
    }

    func updateCustomTipMask(_ data: Data?) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = data == nil ? .procedural : .customMask
            session.brush.customTipAssetID = nil
            session.brush.customTipImportedSourceInfo = nil
            session.brush.customTipMaskData = data
        }
        refresh()
    }

    func clearCustomTipMask() {
        updateCustomTipMask(nil)
    }

    func setBrushTipCanvasFocused(_ focused: Bool) {
        isBrushTipCanvasFocused = focused
        if focused {
            isColorBlocksPanelFocused = false
        }
    }

    func setColorBlocksPanelFocused(_ focused: Bool) {
        isColorBlocksPanelFocused = focused
        if focused {
            isBrushTipCanvasFocused = false
        }
    }

    func importBrushTipImageFromDisk() {
        guard let url = bootstrap.filePanelService.presentImageOpenPanel() else {
            showStatus(.init(kind: .info, message: "已取消选择图片"))
            return
        }

        importBrushTipImage(from: url)
    }

    @discardableResult
    func importBrushTipImage(fromPasteboard pasteboard: NSPasteboard = .general) -> Bool {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return importBrushTipImage(from: image, sourceDescription: "剪贴板")
        }

        if let item = pasteboard.pasteboardItems?.first {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = item.data(forType: type), let image = NSImage(data: data) {
                    return importBrushTipImage(from: image, sourceDescription: "剪贴板")
                }
            }
        }

        showStatus(.init(kind: .info, message: "剪贴板中没有可用图片"))
        return false
    }

    @discardableResult
    func importBrushTipImage(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            showStatus(.init(kind: .error, message: "无法读取图片"))
            return false
        }
        return importBrushTipImage(from: image, sourceDescription: url.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    func importBrushTipImage(from image: NSImage, sourceDescription: String = "图片") -> Bool {
        guard let libraryItem = importTipImageLibraryItem(from: image, sourceDescription: sourceDescription) else {
            showStatus(.init(kind: .error, message: "无法将图片转换为笔尖"))
            return false
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = .importedImage
            session.brush.customTipAssetID = libraryItem.id
            session.brush.customTipImportedSourceInfo = libraryItem.sourceInfo
            session.brush.customTipMaskData = libraryItem.maskData
        }
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已从\(sourceDescription)导入笔尖"))
        return true
    }

    @discardableResult
    func importSecondaryTipImageFromDisk() -> Bool {
        guard let url = bootstrap.filePanelService.presentImageOpenPanel() else {
            showStatus(.init(kind: .info, message: "已取消选择图片"))
            return false
        }

        return importSecondaryTipImage(from: url)
    }

    @discardableResult
    func importSecondaryTipImage(from url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            showStatus(.init(kind: .error, message: "无法读取图片"))
            return false
        }
        return importSecondaryTipImage(from: image, sourceDescription: url.deletingPathExtension().lastPathComponent)
    }

    @discardableResult
    func importSecondaryTipImage(from image: NSImage, sourceDescription: String = "图片") -> Bool {
        guard let libraryItem = importTipImageLibraryItem(from: image, sourceDescription: sourceDescription) else {
            showStatus(.init(kind: .error, message: "无法将图片转换为次笔尖"))
            return false
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryTipDescriptor.tipShape = .customRound
            session.brush.secondaryTipDescriptor.sourceSemantic = .importedImage
            session.brush.secondaryTipDescriptor.tipAssetID = libraryItem.id
            session.brush.secondaryTipDescriptor.importedSourceInfo = libraryItem.sourceInfo
            session.brush.secondaryTipDescriptor.customTipMaskData = libraryItem.maskData
        }
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已从\(sourceDescription)导入次笔尖"))
        return true
    }

    func importTipImageLibraryItemsFromDisk() -> [BrushTipImageAssetID]? {
        guard let urls = bootstrap.filePanelService.presentImageOpenPanelURLs(allowsMultipleSelection: true),
              urls.isEmpty == false else {
            showStatus(.init(kind: .info, message: "已取消选择图片"))
            return nil
        }

        return importTipImageLibraryItems(from: urls)
    }

    @discardableResult
    func importTipImageLibraryItems(from urls: [URL]) -> [BrushTipImageAssetID] {
        var importedItems: [TipImageLibraryItem] = []
        var failedCount = 0

        for url in urls {
            guard let image = NSImage(contentsOf: url),
                  let item = importTipImageLibraryItem(
                    from: image,
                    sourceDescription: url.deletingPathExtension().lastPathComponent
                  ) else {
                failedCount += 1
                continue
            }
            importedItems.append(item)
        }

        guard importedItems.isEmpty == false else {
            let message = urls.count == 1 ? "无法导入所选图片" : "所选图片都无法导入到资料库"
            showStatus(.init(kind: .error, message: message))
            return []
        }

        persistBrushLibrary()
        refresh()

        let successCount = importedItems.count
        let message: String
        if failedCount == 0 {
            message = successCount == 1 ? "已导入 1 张笔尖图片" : "已导入 \(successCount) 张笔尖图片"
            showStatus(.init(kind: .success, message: message))
        } else {
            message = "已导入 \(successCount) 张笔尖图片，\(failedCount) 张失败"
            showStatus(.init(kind: .info, message: message))
        }

        return importedItems.map(\.id)
    }

    private func makeBrushTipMaskData(from image: NSImage) -> Data? {
        let resolution = Self.brushTipMaskResolution
        let targetSize = CGSize(width: resolution, height: resolution)
        guard
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        let bytesPerPixel = 4
        let bytesPerRow = resolution * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: resolution * resolution * bytesPerPixel)

        guard let context = CGContext(
            data: &rgba,
            width: resolution,
            height: resolution,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(origin: .zero, size: targetSize))

        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let scale = min(targetSize.width / max(imageSize.width, 1), targetSize.height / max(imageSize.height, 1))
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: (targetSize.width - drawSize.width) / 2,
            y: (targetSize.height - drawSize.height) / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.interpolationQuality = CGInterpolationQuality.high
        context.draw(cgImage, in: drawRect)

        var mask = [UInt8](repeating: 0, count: resolution * resolution)
        for index in 0..<(resolution * resolution) {
            let offset = index * bytesPerPixel
            let red = Double(rgba[offset])
            let green = Double(rgba[offset + 1])
            let blue = Double(rgba[offset + 2])
            let alpha = Double(rgba[offset + 3]) / 255.0
            let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
            let darkness = (255.0 - luminance) * alpha
            mask[index] = UInt8(clamping: Int(darkness.rounded()))
        }

        return Data(mask)
    }

    private func makeImportedTipSourceInfo(from image: NSImage, sourceDescription: String) -> ImportedTipSourceInfo {
        let pixelSize = resolvedPixelSize(for: image)
        return ImportedTipSourceInfo(
            sourceLabel: sourceDescription,
            pixelWidth: pixelSize.width,
            pixelHeight: pixelSize.height
        )
    }

    private func resolvedPixelSize(for image: NSImage) -> (width: Int, height: Int) {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return (max(cgImage.width, 1), max(cgImage.height, 1))
        }

        if let representation = image.representations.first {
            return (max(representation.pixelsWide, 1), max(representation.pixelsHigh, 1))
        }

        return (
            max(Int(image.size.width.rounded()), 1),
            max(Int(image.size.height.rounded()), 1)
        )
    }

    private func importTipImageLibraryItem(
        from image: NSImage,
        sourceDescription: String
    ) -> TipImageLibraryItem? {
        guard let maskData = makeBrushTipMaskData(from: image) else {
            return nil
        }
        let importedSourceInfo = makeImportedTipSourceInfo(from: image, sourceDescription: sourceDescription)
        return upsertTipImageLibraryItem(maskData: maskData, sourceInfo: importedSourceInfo)
    }

    @discardableResult
    private func upsertTipImageLibraryItem(
        maskData: Data,
        sourceInfo: ImportedTipSourceInfo
    ) -> TipImageLibraryItem {
        let assetID = BrushTipImageAssetID(maskData: maskData)
        var resolvedItem = TipImageLibraryItem(
            id: assetID,
            sourceInfo: sourceInfo,
            maskData: maskData
        )

        bootstrap.workspaceStore.updateTipImageLibrary { library in
            resolvedItem = library.upsertImportedItem(
                id: assetID,
                sourceInfo: sourceInfo,
                maskData: maskData
            )
        }

        return resolvedItem
    }

    func applyPrimaryTipImageLibraryItem(_ assetID: BrushTipImageAssetID) {
        guard let item = workspace.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            showStatus(.init(kind: .error, message: "无法读取该笔尖图片"))
            return
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.tipShape = .customRound
            session.brush.customTipSourceSemantic = .importedImage
            session.brush.customTipAssetID = item.id
            session.brush.customTipImportedSourceInfo = item.sourceInfo
            session.brush.customTipMaskData = maskData
        }
        refresh()
        showStatus(.init(kind: .success, message: "已应用共享笔尖图片"))
    }

    func applySecondaryTipImageLibraryItem(_ assetID: BrushTipImageAssetID) {
        guard let item = workspace.tipImageLibrary.item(id: assetID),
              let maskData = item.maskData else {
            showStatus(.init(kind: .error, message: "无法读取该笔尖图片"))
            return
        }

        bootstrap.workspaceStore.updateToolSession { session in
            session.brush.secondaryTipDescriptor.tipShape = .customRound
            session.brush.secondaryTipDescriptor.sourceSemantic = .importedImage
            session.brush.secondaryTipDescriptor.tipAssetID = item.id
            session.brush.secondaryTipDescriptor.importedSourceInfo = item.sourceInfo
            session.brush.secondaryTipDescriptor.customTipMaskData = maskData
        }
        refresh()
        showStatus(.init(kind: .success, message: "已应用共享次笔尖图片"))
    }

    func moveTipImageLibraryItem(_ assetID: BrushTipImageAssetID, to targetIndex: Int) {
        var moved = false
        bootstrap.workspaceStore.updateTipImageLibrary { library in
            moved = library.moveItem(id: assetID, to: targetIndex)
        }
        guard moved else { return }
        persistBrushLibrary()
        refresh()
    }

    @discardableResult
    func deleteTipImageLibraryItem(_ assetID: BrushTipImageAssetID) -> Bool {
        let referenceSummary = tipImageLibraryReferenceSummary(for: assetID)
        let referenceCount = referenceSummary.totalCount
        guard referenceCount == 0 else {
            showStatus(.init(kind: .info, message: tipImageLibraryBlockedDeleteMessage(for: referenceSummary)))
            return false
        }

        var didDelete = false
        bootstrap.workspaceStore.updateTipImageLibrary { library in
            didDelete = library.deleteItem(id: assetID)
        }
        guard didDelete else {
            showStatus(.init(kind: .info, message: "未找到该笔尖图片"))
            return false
        }

        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已删除笔尖图片"))
        return true
    }

    func tipImageLibraryReferenceSummary(for assetID: BrushTipImageAssetID) -> TipImageLibraryReferenceSummary {
        var summary = TipImageLibraryReferenceSummary()
        let state = bootstrap.workspaceStore.state

        let currentBrush = state.toolSession.brush
        if currentBrush.customTipSourceSemantic == .importedImage, currentBrush.customTipAssetID == assetID {
            summary.currentBrushUsesPrimary = true
        }
        if currentBrush.secondaryTipDescriptor.sourceSemantic == .importedImage,
           currentBrush.secondaryTipDescriptor.tipAssetID == assetID {
            summary.currentBrushUsesSecondary = true
        }

        for preset in state.brushLibrary.presets {
            if preset.brush.customTipSourceSemantic == .importedImage,
               preset.brush.customTipAssetID == assetID {
                summary.presetPrimaryNames.append(preset.name)
            }
            if preset.brush.secondaryTipDescriptor.sourceSemantic == .importedImage,
               preset.brush.secondaryTipDescriptor.tipAssetID == assetID {
                summary.presetSecondaryNames.append(preset.name)
            }
        }

        return summary
    }

    private func tipImageLibraryBlockedDeleteMessage(
        for summary: TipImageLibraryReferenceSummary
    ) -> String {
        guard summary.isReferenced else {
            return "该笔尖图片未被引用"
        }

        var parts: [String] = []
        if summary.currentBrushUsesPrimary {
            parts.append("当前主笔尖")
        }
        if summary.currentBrushUsesSecondary {
            parts.append("当前次笔尖")
        }
        if summary.presetCount > 0 {
            let previewNames = Array((summary.presetPrimaryNames + summary.presetSecondaryNames).prefix(3))
            let suffix = summary.presetCount > previewNames.count ? " 等 \(summary.presetCount) 个预设" : ""
            parts.append("预设 \(previewNames.joined(separator: "、"))\(suffix)")
        }
        return "该笔尖图片仍被\(parts.joined(separator: "、"))引用，无法删除"
    }

    func setGeneratorKind(_ kind: GeneratorKind) {
        bootstrap.strokeEngine.endStroke()
        strokeResetToken &+= 1
        isGeneratorStrokeModeEnabled = true
        isGeneratorRegionSelectionArmed = false
        generatorStrokeSession = .init()
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.kind = kind
        }
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = .brush
        }
        refresh()
        showStatus(.init(kind: .info, message: "已切换到\(kind.displayName)，可直接在画布绘制或使用区域生成"))
    }

    func setGeneratorScale(_ scale: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.density = min(max(scale, 0), 1)
        }
        refresh()
    }

    func setGeneratorOpacity(_ opacity: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.opacity = min(max(opacity, 0.05), 1)
        }
        refresh()
    }

    func setGeneratorDensity(_ density: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.density = min(max(density, 0), 1)
        }
        refresh()
    }

    func setGeneratorDrift(_ drift: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.drift = min(max(drift, 0), 1)
        }
        refresh()
    }

    func setGeneratorBranch(_ branch: Float) {
        bootstrap.workspaceStore.updateGenerator { generator in
            generator.branch = min(max(branch, 0), 1)
        }
        refresh()
    }

    func beginGeneratorRegionSelection() {
        isGeneratorRegionSelectionArmed = true
        isGeneratorStrokeModeEnabled = true
        generatorStrokeSession = .init()
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = .lassoSelection
        }
        refresh()
        showStatus(.init(kind: .info, message: "请在画布上圈选区域以生成\(workspace.generator.kind.displayName)"))
    }

    func setSelectedColor(_ color: RGBAColor) {
        ideationBranchActivityHandler?()
        bootstrap.workspaceStore.updateToolSession { session in
            session.selectedColor = color
        }
        refreshLightweight()
    }

    func setColorPanelMode(_ mode: ColorPanelMode) {
        let selectedColor = workspace.toolSession.selectedColor
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.mode = mode
            if mode == .blocks, panel.basePaletteHSV == nil {
                panel.baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)
                panel.baseSource = .synced
                panel.baseName = ""
                panel.basePaletteHSV = ColorBlocksEngine.defaultBasePalette(baseHSV: panel.baseHSV)
            }
        }
        refreshLightweight()
    }

    func toggleColorPanelMode() {
        setColorPanelMode(workspace.colorPanel.mode == .picker ? .blocks : .picker)
    }

    func syncColorPanelFromSelectedColor() {
        let selectedColor = workspace.toolSession.selectedColor
        let baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)

        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.baseHSV = baseHSV
            panel.baseSource = .synced
            panel.baseName = ""
            panel.basePaletteHSV = ColorBlocksEngine.defaultBasePalette(baseHSV: baseHSV)
            ColorBlocksEngine.syncPicker(to: selectedColor, state: &panel)
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已同步当前颜色"))
    }

    func refreshColorPanelBlocks() {
        bootstrap.workspaceStore.updateColorPanel { panel in
            guard panel.baseSource != .image else { return }
            panel.basePaletteHSV = ColorBlocksEngine.makeRandomBasePalette(
                baseHSV: panel.baseHSV,
                state: panel
            )
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已刷新色块"))
    }

    func loadColorPanelPaletteFromImage() {
        guard let url = bootstrap.filePanelService.presentImageOpenPanel() else {
            showStatus(.init(kind: .info, message: "已取消选择图片"))
            return
        }

        _ = importColorPanelPalette(from: url)
    }

    @discardableResult
    func importColorPanelPalette(fromPasteboard pasteboard: NSPasteboard = .general) -> Bool {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage {
            return importColorPanelPalette(from: image, sourceDescription: "剪贴板图片")
        }

        if let item = pasteboard.pasteboardItems?.first {
            for type in [NSPasteboard.PasteboardType.png, .tiff] {
                if let data = item.data(forType: type), let image = NSImage(data: data) {
                    return importColorPanelPalette(from: image, sourceDescription: "剪贴板图片")
                }
            }

            if let fileURLString = item.string(forType: .fileURL),
               let fileURL = URL(string: fileURLString) {
                return importColorPanelPalette(from: fileURL)
            }
        }

        showStatus(.init(kind: .info, message: "剪贴板中没有可用图片"))
        return false
    }

    @discardableResult
    func importColorPanelPalette(from url: URL) -> Bool {
        do {
            let colors = try bootstrap.imagePaletteExtractor.extractPalette(from: url)
            return applyImportedColorPanelPalette(colors, sourceName: url.deletingPathExtension().lastPathComponent)
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    func importColorPanelPalette(from image: NSImage, sourceDescription: String = "图片") -> Bool {
        do {
            let colors = try bootstrap.imagePaletteExtractor.extractPalette(from: image)
            return applyImportedColorPanelPalette(colors, sourceName: sourceDescription)
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    @discardableResult
    private func applyImportedColorPanelPalette(_ colors: [RGBAColor], sourceName: String) -> Bool {
        let paletteHSV = ColorBlocksEngine.paletteFromImageColors(colors)
        let baseHSV = paletteHSV.first ?? .black

        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.mode = .blocks
            panel.baseSource = .image
            panel.baseName = sourceName
            panel.baseHSV = baseHSV
            panel.basePaletteHSV = paletteHSV
        }
        refreshLightweight()
        showStatus(.init(kind: .success, message: "已从图片提取色块"))
        return true
    }

    func setColorPanelLightness(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            let snapped = ColorBlocksEngine.snapValue(value, enabled: panel.snapThreeStops)
            if panel.mode == .picker {
                panel.pickerLightness = min(max(snapped, 0), 100)
            } else {
                panel.blocksLightness = min(max(snapped, 0), 100)
            }
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelSaturation(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            let snapped = ColorBlocksEngine.snapValue(value, enabled: panel.snapThreeStops)
            if panel.mode == .picker {
                panel.pickerSaturation = min(max(snapped, 0), 100)
            } else {
                panel.blocksSaturation = min(max(snapped, 0), 100)
            }
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelContrast(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.contrast = min(max(value, 0), 100)
        }
        refreshColorPanelOnly()
    }

    func setColorPanelContrastHue(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.contrastHue = min(max(value, 0), 100)
        }
        refreshColorPanelOnly()
    }

    func setColorPanelLightingHue(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.lightingHue = ColorBlocksEngine.wrapHue(value)
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelLightingStrength(_ value: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.lightingStrength = min(max(value, 0), 100)
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPanelSnapThreeStops(_ enabled: Bool) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.snapThreeStops = enabled
            panel.pickerLightness = ColorBlocksEngine.snapValue(panel.pickerLightness, enabled: enabled)
            panel.pickerSaturation = ColorBlocksEngine.snapValue(panel.pickerSaturation, enabled: enabled)
            panel.blocksLightness = ColorBlocksEngine.snapValue(panel.blocksLightness, enabled: enabled)
            panel.blocksSaturation = ColorBlocksEngine.snapValue(panel.blocksSaturation, enabled: enabled)
        }
        if workspace.colorPanel.mode == .picker {
            applyPickerColorFromPanel()
        } else {
            refreshColorPanelOnly()
        }
    }

    func setColorPickerHue(_ hue: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.pickerHue = ColorBlocksEngine.wrapHue(hue)
        }
        applyPickerColorFromPanel()
    }

    func setColorPickerPoint(x: Float, y: Float) {
        bootstrap.workspaceStore.updateColorPanel { panel in
            panel.pickerX = min(max(x, 0), 1)
            panel.pickerY = min(max(y, 0), 1)
        }
        applyPickerColorFromPanel()
    }

    func resetColorPanel() {
        bootstrap.workspaceStore.updateColorPanel { state in
            if state.mode == .picker {
                let selectedColor = workspace.toolSession.selectedColor
                var panel = ColorPanelState.stageOneDefault
                ColorBlocksEngine.syncPicker(to: selectedColor, state: &panel)
                panel.baseHSV = ColorBlocksEngine.rgbToHsv(selectedColor)
                panel.mode = .picker
                state = panel
            } else {
                state.blocksLightness = 50
                state.blocksSaturation = 50
                state.contrast = 50
                state.contrastHue = 0
                state.lightingHue = 0
                state.lightingStrength = 0
            }
        }
        refreshColorPanelOnly()
        showStatus(.init(kind: .success, message: "已重置色彩面板"))
    }

    func selectColorBlock(at index: Int) {
        let palette = ColorBlocksEngine.renderPalette(for: workspace.colorPanel)
        guard palette.indices.contains(index) else { return }
        bootstrap.workspaceStore.updateToolSession { session in
            session.selectedColor = palette[index]
        }
        refreshColorPanelOnly(includeSelectedColor: true)
    }

    func sampleColor(at point: CanvasPoint) {
        ideationBranchActivityHandler?()
        do {
            let sampledColor = try bootstrap.eyedropperSampler.sampleVisibleColor(
                at: point,
                document: workspace.document,
                layerSurfaceStore: bootstrap.layerSurfaceStore
            )
            bootstrap.workspaceStore.updateToolSession { session in
                session.selectedColor = sampledColor
            }
            bootstrap.workspaceStore.updateColorPanel { panel in
                ColorBlocksEngine.syncPicker(to: sampledColor, state: &panel)
                if panel.mode == .picker {
                    panel.baseHSV = ColorBlocksEngine.rgbToHsv(sampledColor)
                    panel.baseSource = .synced
                    panel.baseName = ""
                }
            }
            refreshColorPanelOnly(includeSelectedColor: true)
            showStatus(.init(kind: .success, message: "已吸取颜色"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func applyBrushPreset(_ presetID: String) {
        applyBrushPreset(presetID, showFeedback: true)
    }

    private func applyBrushPreset(_ presetID: String, showFeedback: Bool) {
        ideationBranchActivityHandler?()
        guard let preset = workspace.brushLibrary.preset(id: presetID) else {
            if showFeedback {
                showStatus(.init(kind: .info, message: "未找到画笔预设"))
            }
            return
        }

        bootstrap.strokeEngine.endStroke()
        strokeResetToken &+= 1
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush = preset.brush
        }
        bootstrap.workspaceStore.updateBrushLibrary { library in
            library.selectPreset(id: presetID)
        }
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: true)
        refresh()
        if showFeedback {
            showStatus(.init(kind: .success, message: "已应用 \(preset.name)"))
        }
    }

    func saveCurrentBrushPreset() {
        bootstrap.workspaceStore.updateBrushLibrary { library in
            _ = library.saveCurrentPreset(
                brush: workspace.toolSession.brush
            )
        }
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
        persistBrushLibrary()
        refresh()
        showStatus(.init(kind: .success, message: "已保存画笔"))
    }

    @discardableResult
    func prepareTipImageLibraryForBrowser() -> Bool {
        let restored = restorePersistedTipImageLibraryIfAvailable()
        let synchronized = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: true)
        let changed = restored || synchronized
        if changed {
            refreshLightweight()
        }
        return changed
    }

    func deleteBrushPreset(_ presetID: String) {
        var deletedName: String?
        var didDelete = false
        let previousSelectedPresetID = bootstrap.workspaceStore.state.brushLibrary.selectedPresetID
        bootstrap.workspaceStore.updateBrushLibrary { library in
            deletedName = library.preset(id: presetID)?.name
            didDelete = library.deletePreset(id: presetID)
        }
        if didDelete {
            _ = synchronizeCurrentBrushToSelectedPresetIfNeeded(
                previousSelectedPresetID: previousSelectedPresetID
            )
            persistBrushLibrary()
        }
        refresh()
        if didDelete, let deletedName {
            showStatus(.init(kind: .success, message: "已删除 \(deletedName)"))
        } else {
            showStatus(.init(kind: .info, message: "无法删除该预设"))
        }
    }

    func moveBrushPreset(_ presetID: String, toSlot targetSlotIndex: Int) {
        var moved = false
        bootstrap.workspaceStore.updateBrushLibrary { library in
            moved = library.movePreset(id: presetID, toSlot: targetSlotIndex)
        }
        if moved {
            persistBrushLibrary()
            refresh()
        }
    }

    func exportBrushLibrary() {
        let defaultName = workspace.document.metadata.name.isEmpty ? "ArtFlex-BrushLibrary" : workspace.document.metadata.name
        guard let url = bootstrap.filePanelService.presentBrushLibraryExportPanel(defaultName: defaultName) else {
            showStatus(.init(kind: .info, message: "已取消导出画笔库"))
            return
        }

        do {
            try bootstrap.brushLibraryPersistenceController.exportLibrary(
                workspace.brushLibrary,
                tipImageLibrary: workspace.tipImageLibrary,
                to: url
            )
            showStatus(.init(kind: .success, message: "已导出画笔库"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func importBrushLibraryReplacing() {
        importBrushLibrary(mode: .replace)
    }

    func importBrushLibraryAppending() {
        importBrushLibrary(mode: .append)
    }

    func fillAtPoint(_ point: CanvasPoint) {
        ideationBranchActivityHandler?()
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        let fillAtPointCaptureMode: HistoryCaptureMode
#if DEBUG
        fillAtPointCaptureMode = debugFillAtPointHistoryCaptureModeOverride ?? .inPlaceChangedLayers([layerID])
#else
        fillAtPointCaptureMode = .inPlaceChangedLayers([layerID])
#endif

        checkpointHistoryIfPossible(
            operationKind: "fillAtPoint",
            candidateChangedLayerIDs: [layerID],
            captureMode: fillAtPointCaptureMode
        )

        do {
            try bootstrap.bucketFillEngine.fill(
                layerID: layerID,
                at: point,
                color: workspace.toolSession.selectedColor,
                selectionShape: workspace.selection.committedShape,
                layerSurfaceStore: bootstrap.layerSurfaceStore
            )
            layerThumbnailCache.removeValue(forKey: layerID)
            bootstrap.strokeEngine.resetBrushPipelineState()
            refresh(invalidatedLayerIDs: [layerID])
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已填充区域"))
            relayIdeationOperation(.fillAtPoint(point))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func resetViewport() {
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport = .stageOneDefault
        }
        refresh()
    }

    func setCanvasViewportLocked(_ isLocked: Bool) {
        guard isCanvasViewportLocked != isLocked else { return }
        isCanvasViewportLocked = isLocked
        if isLocked {
            isPanModeActive = false
        }
    }

    func updateCanvasViewportSize(_ size: CGSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        latestCanvasViewportSize = size
    }

    func zoomIn() {
        setViewportZoomScale(workspace.viewport.zoomScale * 1.2)
    }

    func zoomOut() {
        setViewportZoomScale(workspace.viewport.zoomScale / 1.2)
    }

    func adjustViewportZoom(byScaleMultiplier multiplier: Double) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        setViewportZoomScale(workspace.viewport.zoomScale * multiplier)
    }

    private func setViewportZoomScale(_ newZoomScale: Double) {
        guard !isCanvasViewportLocked else { return }
        let anchorPoint = lastCanvasHoverPoint
        let canvasSize = workspace.document.canvasSize
        let viewportSize = latestCanvasViewportSize
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.setZoomScale(
                newZoomScale,
                anchoredAt: anchorPoint,
                canvasSize: canvasSize,
                availableWidth: viewportSize.width,
                availableHeight: viewportSize.height
            )
        }
        refreshLightweight()
    }

    func panViewport(deltaX: Double, deltaY: Double) {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.contentOffset.x += deltaX
            viewport.contentOffset.y += deltaY
        }
        refreshLightweight()
    }

    func setViewportOffset(x: Double, y: Double) {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.contentOffset = CanvasPoint(x: x, y: y)
        }
        refreshLightweight()
    }

    func setViewportRotation(_ angleDegrees: Double) {
        guard !isCanvasViewportLocked else { return }
        bootstrap.workspaceStore.updateViewport { viewport in
            viewport.rotationDegrees = Self.normalizedViewportRotation(angleDegrees)
        }
        refreshLightweight()
    }

    func setPanModeActive(_ isActive: Bool) {
        guard !isCanvasViewportLocked || !isActive else { return }
        isPanModeActive = isActive
        if isActive {
            showStatus(.init(kind: .info, message: "已开启平移模式"))
        } else {
            showStatus(.init(kind: .info, message: "已关闭平移模式"))
        }
    }

    func addLayer() {
        checkpointHistoryIfPossible()
        bootstrap.workspaceStore.updateDocument { document in
            _ = document.addLayer()
        }
        refresh()
        noteCanvasContentChanged()
        showStatus(.init(kind: .success, message: "已新增图层"))
    }

    func removeActiveLayer() {
        checkpointHistoryIfPossible()
        let initialCount = workspace.document.layers.count
        bootstrap.workspaceStore.updateDocument { document in
            document.removeActiveLayer()
        }
        refresh()

        if workspace.document.layers.count < initialCount {
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已删除当前图层"))
        } else {
            showStatus(.init(kind: .info, message: "至少需要保留一个图层"))
        }
    }

    func duplicateActiveLayer() {
        checkpointHistoryIfPossible()

        let sourceLayerID = workspace.document.activeLayerID
        var duplicatedLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            duplicatedLayerID = document.duplicateActiveLayer()?.id
        }
        refresh()

        if let duplicatedLayerID {
            bootstrap.layerSurfaceStore.copyTexture(
                from: sourceLayerID,
                to: duplicatedLayerID,
                metal: bootstrap.metalContext
            )
            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已复制图层"))
        } else {
            showStatus(.init(kind: .error, message: "无法复制图层"))
        }
    }

    func mergeActiveLayerDown() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        guard let context = workspace.document.activeMergeDownContext else {
            showStatus(.init(kind: .info, message: "没有可向下合并的图层"))
            return
        }

        guard !context.source.isLocked, !context.destination.isLocked else {
            showStatus(.init(kind: .info, message: "锁定图层无法合并"))
            return
        }

        guard
            let sourceSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: context.source.id),
            let destinationSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: context.destination.id),
            let sourceTexture = bootstrap.layerSurfaceStore.texture(for: sourceSurfaceID),
            let destinationTexture = bootstrap.layerSurfaceStore.texture(for: destinationSurfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问合并纹理"))
            return
        }

        checkpointHistoryIfPossible()

        do {
            try bootstrap.layerMergeController.merge(
                sourceTexture: sourceTexture,
                sourceOpacity: context.source.opacity,
                sourceVisible: context.source.isVisible,
                into: destinationTexture,
                destinationOpacity: context.destination.opacity,
                destinationVisible: context.destination.isVisible
            )

            bootstrap.workspaceStore.updateDocument { document in
                _ = document.completeMergeDown(
                    using: context,
                    mergedVisibility: context.source.isVisible || context.destination.isVisible,
                    mergedOpacity: 1
                )
            }

            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已向下合并图层"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func mergeVisibleLayers() {
        guard !isTransformingSelection else {
            showStatus(.init(kind: .info, message: "请先应用或取消变形"))
            return
        }

        guard let context = workspace.document.mergeVisibleContext else {
            showStatus(.init(kind: .info, message: "至少需要两个可见图层"))
            return
        }

        guard context.visibleLayers.allSatisfy({ !$0.isLocked }) else {
            showStatus(.init(kind: .info, message: "锁定图层无法合并"))
            return
        }

        let textureEntries: [(texture: MTLTexture, opacity: Float, isVisible: Bool)] = context.visibleLayers.compactMap { layer in
            guard
                let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
                let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
            else {
                return nil
            }

            return (texture: texture, opacity: layer.opacity, isVisible: layer.isVisible)
        }

        guard
            textureEntries.count == context.visibleLayers.count,
            let targetSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: context.target.id),
            let targetTexture = bootstrap.layerSurfaceStore.texture(for: targetSurfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问合并纹理"))
            return
        }

        checkpointHistoryIfPossible()

        do {
            try bootstrap.layerMergeController.mergeVisible(
                layers: textureEntries,
                into: targetTexture
            )

            bootstrap.workspaceStore.updateDocument { document in
                _ = document.completeMergeVisible(
                    using: context,
                    mergedVisibility: true,
                    mergedOpacity: 1
                )
            }

            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已合并可见图层"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func selectLayer(_ layerID: LayerID) {
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        if workspace.document.activeLayerID != layerID {
            resolveTransformSession(reason: .layerChange)
        }
        bootstrap.workspaceStore.updateDocument { document in
            document.setActiveLayer(layerID)
        }
        refresh()
    }

    func setLayerVisibility(_ layerID: LayerID, isVisible: Bool) {
        checkpointHistoryIfPossible()
        bootstrap.workspaceStore.updateDocument { document in
            document.setLayerVisibility(layerID, isVisible: isVisible)
        }
        refresh()
        noteCanvasContentChanged()
    }

    func toggleLayerLock(_ layerID: LayerID) {
        checkpointHistoryIfPossible()
        bootstrap.workspaceStore.updateDocument { document in
            document.toggleLayerLock(layerID)
        }
        refresh()
    }

    func setActiveLayerOpacity(_ opacity: Float) {
        _ = flushBrushEditingBoundary(reason: "setActiveLayerOpacity")
        let activeLayerID = workspace.document.activeLayerID
        bootstrap.workspaceStore.updateDocument { document in
            document.setLayerOpacity(activeLayerID, opacity: opacity)
        }
        refresh()
        noteCanvasContentChanged()
    }

    func beginActiveLayerOpacityChange() {
        guard !isAdjustingLayerOpacity else { return }
        isAdjustingLayerOpacity = true
        checkpointHistoryIfPossible()
    }

    func endActiveLayerOpacityChange() {
        isAdjustingLayerOpacity = false
    }

    func moveActiveLayerUp() {
        checkpointHistoryIfPossible()
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            moved = document.moveActiveLayerUp()
        }
        refresh()
        showStatus(
            .init(
                kind: .info,
                message: moved ? "已上移图层" : "图层已经在最上方"
            )
        )
        if moved {
            noteCanvasContentChanged()
        }
    }

    func moveActiveLayerDown() {
        checkpointHistoryIfPossible()
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            moved = document.moveActiveLayerDown()
        }
        refresh()
        showStatus(
            .init(
                kind: .info,
                message: moved ? "已下移图层" : "图层已经在最下方"
            )
        )
        if moved {
            noteCanvasContentChanged()
        }
    }

    func moveLayer(_ layerID: LayerID, toDisplayIndex displayIndex: Int) {
        checkpointHistoryIfPossible()
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            let targetDocumentIndex = max(0, min(document.layers.count - 1, (document.layers.count - 1) - displayIndex))
            moved = document.moveLayer(layerID, toIndex: targetDocumentIndex)
        }
        refresh()
        if moved {
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已调整图层顺序"))
        }
    }

    func moveLayer(_ layerID: LayerID, toDisplayInsertionIndex insertionIndex: Int) {
        checkpointHistoryIfPossible()
        var moved = false
        bootstrap.workspaceStore.updateDocument { document in
            moved = document.moveLayer(layerID, toDisplayInsertionIndex: insertionIndex)
        }
        refresh()
        if moved {
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已调整图层顺序"))
        }
    }

    func renameLayer(_ layerID: LayerID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            return
        }

        checkpointHistoryIfPossible()
        var renamed = false
        bootstrap.workspaceStore.updateDocument { document in
            renamed = document.renameLayer(layerID, to: trimmedName)
        }
        refresh()
        if renamed {
            showStatus(.init(kind: .success, message: "已重命名图层"))
        }
    }

    func layerThumbnail(for layerID: LayerID, maxDimension: Int = 40) -> CGImage? {
        if let cached = layerThumbnailCache[layerID] {
            return cached
        }

        guard
            let layer = workspace.document.layers.first(where: { $0.id == layerID }),
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else {
            return nil
        }

        do {
            let snapshot = try bootstrap.textureSerializer.snapshot(texture: texture)
            let image = Self.snapshotImage(
                from: snapshot,
                maxDimension: maxDimension,
                colorSpace: colorSpace
            )
            if let image {
                layerThumbnailCache[layerID] = image
            }
            return image
        } catch {
            return nil
        }
    }

    func savedSnapshot(with id: UUID) -> CanvasSavedSnapshot? {
        savedSnapshots.first { $0.id == id }
    }

    func savedSnapshotDisplayIndex(for id: UUID) -> Int? {
        guard let index = savedSnapshots.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return index + 1
    }

    func beginSelection(kind: SelectionShapeKind, at start: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        let combineMode = selectionCombineMode(for: kind, modifiers: modifiers)
        if kind == .lasso {
            let message = "[beginSelection] kind=lasso start=(\(start.x),\(start.y)) combine=\(combineMode.rawValue)"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
        }
        if kind == .lasso {
            activeLassoRawPoints = [start]
            activeLassoBounds = CanvasRect(origin: start, size: .init(x: 0, y: 0))
            lassoSamplingDebugPoints = [start]
            lassoRefreshCounter = 0
            samePathCommittedDebugShape = nil
            samePathPreviewDebugShape = nil
        } else {
            activeLassoRawPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            lassoRefreshCounter = 0
            samePathCommittedDebugShape = nil
            samePathPreviewDebugShape = nil
        }
        bootstrap.workspaceStore.updateSelection { selection in
            selection.anchorPoint = start
            selection.activeKind = kind
            selection.activeCombineMode = combineMode
            selection.inProgressShape = selectionPreviewShape(
                kind: kind,
                start: start,
                currentPoint: start,
                existingPoints: nil,
                modifiers: modifiers,
                combineMode: combineMode
            )
        }
        refreshSelectionOverlayOnly()
        relayIdeationOperation(.beginSelection(kind: kind, start: start, modifiers: .init(flags: modifiers)))
    }

    private var fillToolOpacity: Float {
        min(max(workspace.toolSession.brush.opacity, 0), 1)
    }

    private func resolvedFillToolColor(from color: RGBAColor) -> RGBAColor {
        let resolvedColor = resolvedGeneratorColor(from: color)
        return resolvedColor.withAlpha(resolvedColor.alpha * fillToolOpacity)
    }

    var gradientPreviewColor: RGBAColor {
        resolvedFillToolColor(from: workspace.toolSession.selectedColor)
    }

    func updateLinearGradientHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .linearGradient else { return }
        mutateLinearGradientState { state in
            state.hoverPoint = point
        }
    }

    private func mutateLinearGradientState(
        _ mutate: (inout LinearGradientInteractionState) -> Void
    ) {
        var state = linearGradientState
        mutate(&state)
        linearGradientState = state
    }

    private func mutateSectorGradientState(
        _ mutate: (inout SectorGradientInteractionState) -> Void
    ) {
        var state = sectorGradientState
        mutate(&state)
        sectorGradientState = state
    }

    private func activeGradientTool() -> ToolKind? {
        switch workspace.toolSession.activeTool {
        case .linearGradient, .sectorGradient:
            return workspace.toolSession.activeTool
        default:
            return nil
        }
    }

    private func gradientSessionStateDescription() -> String {
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            return String(describing: linearGradientState.phase)
        case .sectorGradient:
            return String(describing: sectorGradientState.phase)
        default:
            return "idle"
        }
    }

    private func shouldAutoApplyGradientBeforeSelectingTool(_ tool: ToolKind) -> Bool {
        guard tool != workspace.toolSession.activeTool else { return false }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: linearGradientState.phase)
        case .sectorGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: sectorGradientState.phase)
        default:
            return false
        }
    }

    private func handleDeferredGradientActionIfNeeded() {
        guard let deferredGradientAction else { return }
        self.deferredGradientAction = nil
        switch deferredGradientAction {
        case .toolSwitch(let tool):
            performToolSelection(tool)
        case .gradientDrag(let drag):
            performDeferredGradientDrag(drag)
        }
    }

    private func performDeferredGradientDrag(_ drag: DeferredGradientDrag) {
        bootstrap.workspaceStore.updateToolSession { session in
            session.activeTool = drag.tool
        }
        switch drag.tool {
        case .linearGradient, .sectorGradient:
            break
        default:
            return
        }
        guard let firstPoint = drag.points.first else { return }
        beginGradientDrag(at: firstPoint, modifiers: drag.modifiers)
        if drag.points.count >= 2 {
            let updatePoints = drag.didEnd ? Array(drag.points.dropFirst().dropLast()) : Array(drag.points.dropFirst())
            for point in updatePoints {
                updateGradientDrag(to: point, modifiers: drag.modifiers)
            }
            if drag.didEnd, let endPoint = drag.points.last {
                endGradientDrag(at: endPoint, modifiers: drag.modifiers)
            }
        }
    }

    private func queueDeferredGradientDragPoint(
        tool: ToolKind,
        point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags,
        didEnd: Bool
    ) {
        guard tool == .linearGradient || tool == .sectorGradient else { return }
        if case .gradientDrag(var drag)? = deferredGradientAction, drag.tool == tool {
            if drag.points.last != point {
                drag.points.append(point)
            }
            drag.modifiers = modifiers
            drag.didEnd = drag.didEnd || didEnd
            deferredGradientAction = .gradientDrag(drag)
            return
        }
        deferredGradientAction = .gradientDrag(
            DeferredGradientDrag(
                tool: tool,
                points: [point],
                modifiers: modifiers,
                didEnd: didEnd
            )
        )
    }

    private func shouldAutoApplyGradientBeforeNewDrag(hitExistingEditorTarget: Bool) -> Bool {
        guard !hitExistingEditorTarget else { return false }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: linearGradientState.phase)
        case .sectorGradient:
            return shouldAutoApplyGradientForToolSwitch(phase: sectorGradientState.phase)
        default:
            return false
        }
    }

    func enterGradientEditingViaShift() {
        guard !isApplyingGradientCommit else { return }
        relayIdeationOperation(.enterGradientEditing)
    }

    func updateCanvasToolHover(to point: CanvasPoint) {
        lastCanvasHoverPoint = point
        switch workspace.toolSession.activeTool {
        case .straightLine:
            updateStraightLineHover(to: point)
        case .linearGradient:
            updateLinearGradientHover(to: point)
        case .sectorGradient:
            updateSectorGradientHover(to: point)
        case .polygonSelection:
            updatePolygonSelectionHover(to: point)
        default:
            break
        }
    }

    func beginGradientDrag(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        if isApplyingGradientCommit {
            if let tool = activeGradientTool() {
                queueDeferredGradientDragPoint(tool: tool, point: point, modifiers: modifiers, didEnd: false)
            }
            return
        }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            beginLinearGradientDrag(at: point, modifiers: modifiers)
        case .sectorGradient:
            beginSectorGradientDrag(at: point, modifiers: modifiers)
        default:
            break
        }
        relayIdeationOperation(.beginGradientDrag(point: point, modifiers: .init(flags: modifiers)))
    }

    func updateGradientDrag(to point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        if isApplyingGradientCommit {
            if let tool = activeGradientTool() {
                queueDeferredGradientDragPoint(tool: tool, point: point, modifiers: modifiers, didEnd: false)
            }
            return
        }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            updateLinearGradientDrag(to: point)
        case .sectorGradient:
            updateSectorGradientDrag(to: point)
        default:
            break
        }
        relayIdeationOperation(.updateGradientDrag(point: point, modifiers: .init(flags: modifiers)))
    }

    func endGradientDrag(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        if isApplyingGradientCommit {
            if let tool = activeGradientTool() {
                queueDeferredGradientDragPoint(tool: tool, point: point, modifiers: modifiers, didEnd: true)
            }
            return
        }
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            endLinearGradientDrag(at: point)
        case .sectorGradient:
            endSectorGradientDrag(at: point)
        default:
            break
        }
        relayIdeationOperation(.endGradientDrag(point: point, modifiers: .init(flags: modifiers)))
    }

    func applyActiveGradientSession() {
        guard !isApplyingGradientCommit else { return }
        relayIdeationOperation(.applyGradientSession)
        switch workspace.toolSession.activeTool {
        case .linearGradient:
            guard let geometry = linearGradientState.geometry else {
                showStatus(.init(kind: .info, message: "当前没有可应用的直线渐变"))
                return
            }
            applyLinearGradient(geometry: geometry)
        case .sectorGradient:
            guard let geometry = sectorGradientState.geometry else {
                showStatus(.init(kind: .info, message: "当前没有可应用的扇形渐变"))
                return
            }
            applySectorGradient(geometry: geometry)
        default:
            break
        }
    }

    func cancelLinearGradientInteraction() {
        guard workspace.toolSession.activeTool == .linearGradient else { return }
        guard linearGradientState.phase != .idle else { return }
        deferredGradientAction = nil
        linearGradientState = .init()
        relayIdeationOperation(.cancelGradientSession)
        showStatus(.init(kind: .info, message: "已取消直线渐变"))
    }

    func cancelCanvasToolInteraction() {
        switch workspace.toolSession.activeTool {
        case .straightLine:
            cancelStraightLineInteraction()
        case .linearGradient:
            cancelLinearGradientInteraction()
        case .sectorGradient:
            cancelSectorGradientInteraction()
        case .polygonSelection:
            cancelPolygonSelectionInteraction()
        default:
            break
        }
    }

    private func beginLinearGradientDrag(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags) {
        linearGradientState = LinearGradientInteractionState(
            phase: .drawingLeg1,
            pointA: point,
            pointB: point,
            pointC: nil,
            dragStartPoint: point,
            dragReferenceGeometry: nil,
            leg1CandidatePoint: point,
            hoverPoint: point
        )
    }

    private func updateLinearGradientDrag(to point: CanvasPoint) {
        mutateLinearGradientState { state in
            state.hoverPoint = point

            switch state.phase {
        case .idle:
            break
        case .drawingLeg1:
            state.pointB = point
            state.pointC = nil
        case .drawingLeg2:
            state.pointB = point
            state.pointC = nil
        case .draggingHandle(let handle):
            guard let reference = state.dragReferenceGeometry else { return }
            switch handle {
            case .pointA:
                state.pointA = point
                state.pointB = reference.pointB
                state.pointC = reference.pointC
            case .pointB:
                state.pointA = reference.pointA
                state.pointB = point
                state.pointC = reference.pointC
            case .pointC:
                state.pointA = reference.pointA
                state.pointB = reference.pointB
                state.pointC = point
            }
        case .movingWholeGradient:
            guard
                let reference = state.dragReferenceGeometry,
                let dragStartPoint = state.dragStartPoint
            else { return }
            let delta = CanvasPoint(x: point.x - dragStartPoint.x, y: point.y - dragStartPoint.y)
            state.pointA = CanvasPoint(x: reference.pointA.x + delta.x, y: reference.pointA.y + delta.y)
            state.pointB = CanvasPoint(x: reference.pointB.x + delta.x, y: reference.pointB.y + delta.y)
            state.pointC = CanvasPoint(x: reference.pointC.x + delta.x, y: reference.pointC.y + delta.y)
        case .editing, .pendingPreview:
            break
        }
        }
    }

    private func endLinearGradientDrag(at point: CanvasPoint) {
        let pointA = linearGradientState.pointA
        let pointB = linearGradientState.pointB ?? point
        guard let pointA else {
            linearGradientState = .init()
            return
        }
        guard distanceBetween(pointA, pointB) > 0.5 else {
            linearGradientState = .init()
            return
        }

        let pointC = defaultLinearGradientPointC(
            pointA: pointA,
            pointB: pointB,
            canvasSize: workspace.document.canvasSize
        )
        linearGradientState.pointB = pointB
        linearGradientState.pointC = pointC
        linearGradientState.dragStartPoint = nil
        linearGradientState.dragReferenceGeometry = nil
        linearGradientState.hoverPoint = point
        linearGradientState.phase = .drawingLeg1
        applyLinearGradient(
            geometry: LinearGradientGeometry(
                pointA: pointA,
                pointB: pointB,
                pointC: pointC
            )
        )
    }

    func updateStraightLineHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .straightLine else { return }
        guard straightLineState.phase == .pickedA else { return }
        straightLineState.hoverPoint = point
    }

    func cancelStraightLineInteraction() {
        guard workspace.toolSession.activeTool == .straightLine else { return }
        guard straightLineState.phase != .idle else { return }
        straightLineState = .init()
        showStatus(.init(kind: .info, message: "已取消直线"))
    }

    func handleStraightLineClick(at point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .straightLine else { return }

        switch straightLineState.phase {
        case .idle:
            straightLineState.phase = .pickedA
            straightLineState.pointA = point
            straightLineState.hoverPoint = point
            showStatus(.init(kind: .info, message: "已设置 A 点，请点击 B 点完成直线"))
        case .pickedA:
            guard let pointA = straightLineState.pointA, distanceBetween(pointA, point) > 0.05 else {
                showStatus(.init(kind: .info, message: "A 与 B 需要拉开一点距离"))
                return
            }
            let didApply = applyStraightLine(pointA: pointA, pointB: point)
            if didApply {
                straightLineState = .init()
            } else {
                straightLineState.hoverPoint = point
            }
        }
    }

    func updateSectorGradientHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .sectorGradient else { return }
        mutateSectorGradientState { state in
            state.hoverPoint = point
        }
    }

    func cancelSectorGradientInteraction() {
        guard workspace.toolSession.activeTool == .sectorGradient else { return }
        guard sectorGradientState.phase != .idle else { return }
        deferredGradientAction = nil
        sectorGradientState = .init()
        relayIdeationOperation(.cancelGradientSession)
        showStatus(.init(kind: .info, message: "已取消扇形渐变"))
    }

    func handleCanvasToolClick(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1) {
        ideationBranchActivityHandler?()
        switch workspace.toolSession.activeTool {
        case .straightLine:
            handleStraightLineClick(at: point)
        case .polygonSelection:
            handlePolygonSelectionClick(at: point, modifiers: modifiers, clickCount: clickCount)
        default:
            break
        }
        relayIdeationOperation(.handleCanvasToolClick(point: point, modifiers: .init(flags: modifiers), clickCount: clickCount))
    }

    private func beginSectorGradientDrag(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags) {
        sectorGradientState = SectorGradientInteractionState(
            phase: .drawing,
            center: point,
            pathPoints: [point],
            hoverPoint: point
        )
    }

    private func updateSectorGradientDrag(to point: CanvasPoint) {
        mutateSectorGradientState { state in
            state.hoverPoint = point
            switch state.phase {
            case .idle:
                break
            case .drawing:
                appendSectorGradientPoint(point, to: &state.pathPoints)
            }
        }
    }

    private func endSectorGradientDrag(at point: CanvasPoint) {
        guard sectorGradientState.phase == .drawing else { return }
        guard let center = sectorGradientState.center else {
            sectorGradientState = .init()
            return
        }

        var rawPoints = sectorGradientState.pathPoints
        appendSectorGradientPoint(point, to: &rawPoints)
        let finalizedPoints = smoothedSectorGradientPoints(rawPoints: rawPoints, closingTo: center)
        sectorGradientState.hoverPoint = point

        guard let geometry = resolvedSectorGradientGeometry(center: center, pathPoints: finalizedPoints) else {
            sectorGradientState = .init()
            return
        }

        sectorGradientState = .init()
        applySectorGradient(geometry: geometry)
    }

    private func appendSectorGradientPoint(_ point: CanvasPoint, to points: inout [CanvasPoint]) {
        guard let last = points.last else {
            points = [point]
            return
        }

        let interpolated = interpolatedLassoPoints(from: last, to: point)
        if interpolated.isEmpty {
            if last != point {
                points.append(point)
            }
            return
        }

        for interpolatedPoint in interpolated where points.last != interpolatedPoint {
            points.append(interpolatedPoint)
        }
    }

    func updatePolygonSelectionHover(to point: CanvasPoint) {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }
        guard polygonSelectionState.phase == .building else { return }
        polygonSelectionState.hoverPoint = point
    }

    func cancelPolygonSelectionInteraction() {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }
        guard polygonSelectionState.phase != .idle else { return }
        polygonSelectionState = .init()
        showStatus(.init(kind: .info, message: "已取消多边形选区"))
    }

    func handlePolygonSelectionClick(
        at point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags,
        clickCount: Int
    ) {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }

        switch polygonSelectionState.phase {
        case .idle:
            let combineMode = selectionCombineMode(for: .lasso, modifiers: modifiers)
            if combineMode == .replace {
                bootstrap.workspaceStore.updateSelection { selection in
                    selection.committedShape = nil
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                refreshLightweight()
            }
            polygonSelectionState.phase = .building
            polygonSelectionState.vertices = [point]
            polygonSelectionState.hoverPoint = point
            polygonSelectionState.combineMode = combineMode
            showStatus(.init(kind: .info, message: "已设置起点，继续点击添加拐点；点回起点或双击可闭合"))
        case .building:
            let normalizedPoint = point
            let vertices = polygonSelectionState.vertices
            guard let first = vertices.first else {
                polygonSelectionState = .init()
                return
            }

            let closesToFirst = vertices.count >= 3 && distanceBetween(first, normalizedPoint) <= 12
            if closesToFirst {
                commitPolygonSelection(points: vertices + [first], combineMode: polygonSelectionState.combineMode)
                return
            }

            if clickCount >= 2, vertices.count >= 2 {
                var finalPoints = vertices
                if distanceBetween(vertices.last ?? normalizedPoint, normalizedPoint) > 0.05 {
                    finalPoints.append(normalizedPoint)
                }
                commitPolygonSelection(points: finalPoints, combineMode: polygonSelectionState.combineMode)
                return
            }

            guard distanceBetween(vertices.last ?? normalizedPoint, normalizedPoint) > 0.05 else {
                return
            }
            polygonSelectionState.vertices.append(normalizedPoint)
            polygonSelectionState.hoverPoint = normalizedPoint
            let actionName: String = switch polygonSelectionState.combineMode {
            case .replace: "新建"
            case .add: "增选"
            case .subtract: "减选"
            }
            showStatus(.init(kind: .info, message: "已添加顶点，继续点击或双击闭合（当前：\(actionName)）"))
        }
    }

    private func commitPolygonSelection(points: [CanvasPoint], combineMode: SelectionCombineMode) {
        let canvasSize = workspace.document.canvasSize
        var clampedPoints = points.map {
            CanvasPoint(
                x: min(max($0.x, 0), Double(canvasSize.width)),
                y: min(max($0.y, 0), Double(canvasSize.height))
            )
        }
        if let first = clampedPoints.first, let last = clampedPoints.last, distanceBetween(first, last) > 0.05 {
            clampedPoints.append(first)
        }
        guard clampedPoints.count >= 3 else {
            polygonSelectionState = .init()
            showStatus(.init(kind: .info, message: "多边形至少需要 3 个点"))
            return
        }

        let preferredShape = SelectionShape(
            kind: .lasso,
            bounds: CanvasRect.bounding(points: clampedPoints),
            pathPoints: clampedPoints
        )
        let input = SelectionInputShape(
            polygonShapes: [[clampedPoints.map { CGPoint(x: $0.x, y: $0.y) }]],
            preferredDisplayShape: preferredShape
        )
        let previousCommittedShape = workspace.selection.committedShape?.clamped(to: canvasSize)
        let nextCommittedShape = committedSelectionShape(
            input: input,
            canvasSize: canvasSize,
            mode: combineMode,
            baseShape: previousCommittedShape
        )

        if combineMode == .replace, nextCommittedShape != previousCommittedShape {
            checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
        }

        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = nextCommittedShape
            selection.inProgressShape = nil
            selection.anchorPoint = nil
            selection.activeKind = nil
            selection.activeCombineMode = .replace
        }
        polygonSelectionState = .init()
        refresh()

        if nextCommittedShape == nil {
            showStatus(.init(kind: .info, message: "选区为空"))
        } else {
            let actionName: String = switch combineMode {
            case .replace: "已创建多边形选区"
            case .add: "已增选多边形区域"
            case .subtract: "已减选多边形区域"
            }
            showStatus(.init(kind: .success, message: actionName))
        }
    }

    private func undoLastPolygonSelectionPoint() {
        guard workspace.toolSession.activeTool == .polygonSelection else { return }
        guard polygonSelectionState.phase == .building else { return }

        if !polygonSelectionState.vertices.isEmpty {
            polygonSelectionState.vertices.removeLast()
        }

        if polygonSelectionState.vertices.isEmpty {
            polygonSelectionState = .init()
            showStatus(.init(kind: .info, message: "已取消多边形选区"))
            return
        }

        polygonSelectionState.hoverPoint = polygonSelectionState.vertices.last
        showStatus(.init(kind: .info, message: "已撤回上一个顶点"))
    }

    func updateSelection(to point: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        let storeSelection = bootstrap.workspaceStore.state.selection
        let currentStart = storeSelection.anchorPoint ?? point
        let currentKind = storeSelection.activeKind ?? .rectangle
        var nextPreviewShape: SelectionShape?
        bootstrap.workspaceStore.updateSelection { selection in
            if currentKind == .lasso {
                if activeLassoRawPoints.isEmpty {
                    activeLassoRawPoints = [currentStart]
                    activeLassoBounds = CanvasRect(origin: currentStart, size: .init(x: 0, y: 0))
                }
                if Self.runSamplingTruthTest {
                    if activeLassoRawPoints.last != point {
                        activeLassoRawPoints.append(point)
                        activeLassoBounds = expandedBounds(activeLassoBounds, including: point)
                    }
                } else {
                    if activeLassoRawPoints.last != point {
                        activeLassoRawPoints.append(point)
                        activeLassoBounds = expandedBounds(activeLassoBounds, including: point)
                    }
                }
                // lassoSamplingDebugPoints 只在 debug overlay 开启时才需要每帧更新
                // 否则每帧把整个点数组赋给 @Published 属性会触发额外重绘
                // showsSelectionDebugOverlay は CanvasContainerView のデバッグフラグ
                // 通常は false なのでここでは更新しない（毎フレームの @Published 通知を避ける）
                if false {
                    lassoSamplingDebugPoints = activeLassoRawPoints
                }
                #if DEBUG
                if activeLassoRawPoints.count == 2 || activeLassoRawPoints.count % 24 == 0 {
                    let firstPoint = activeLassoRawPoints.first ?? point
                    let lastPoint = activeLassoRawPoints.last ?? point
                    let bounds = activeLassoBounds ?? CanvasRect.bounding(points: activeLassoRawPoints)
                    let message = "[updateSelection] rawPointCount=\(self.activeLassoRawPoints.count) firstRaw=(\(firstPoint.x),\(firstPoint.y)) lastRaw=(\(lastPoint.x),\(lastPoint.y)) current=(\(point.x),\(point.y)) boundsOrigin=(\(bounds.origin.x),\(bounds.origin.y)) boundsSize=(\(bounds.size.x),\(bounds.size.y))"
                    selectionTraceLogger.debug("\(message, privacy: .public)")
                    emitSelectionTraceViewModel(message)
                }
                #endif
            }
            let previewShape = selectionPreviewShape(
                kind: currentKind,
                start: currentStart,
                currentPoint: point,
                existingPoints: currentKind == .lasso ? activeLassoRawPoints : selection.inProgressShape?.pathPoints,
                modifiers: modifiers,
                combineMode: selection.activeCombineMode,
                precomputedBounds: currentKind == .lasso ? activeLassoBounds : nil
            )
            selection.inProgressShape = previewShape
            nextPreviewShape = previewShape
        }
        if currentKind == .lasso {
            samePathPreviewDebugShape = nextPreviewShape
        }
        refreshSelectionOverlayOnly()
        relayIdeationOperation(.updateSelection(point: point, modifiers: .init(flags: modifiers)))
    }

    func commitSelection(at end: CanvasPoint, modifiers: NSEvent.ModifierFlags = []) {
        ideationBranchActivityHandler?()
        let storeSelection = bootstrap.workspaceStore.state.selection
        let currentStart = storeSelection.anchorPoint ?? end
        let currentKind = storeSelection.activeKind ?? .rectangle
        let previousCommittedShape = storeSelection.committedShape
        let canvasSize = workspace.document.canvasSize
        if currentKind == .lasso {
            let lastRaw = activeLassoRawPoints.last ?? end
            let firstRaw = activeLassoRawPoints.first ?? end
            let rawBounds = activeLassoBounds ?? CanvasRect.bounding(points: activeLassoRawPoints)
            let message = "[commitSelection:begin] kind=lasso end=(\(end.x),\(end.y)) rawPointCount=\(self.activeLassoRawPoints.count) firstRaw=(\(firstRaw.x),\(firstRaw.y)) lastRaw=(\(lastRaw.x),\(lastRaw.y)) rawBoundsOrigin=(\(rawBounds.origin.x),\(rawBounds.origin.y)) rawBoundsSize=(\(rawBounds.size.x),\(rawBounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
        }
        if Self.runSamePathCommitTest,
           currentKind == .lasso,
           workspace.selection.activeCombineMode == .replace,
           let previewShape = workspace.selection.inProgressShape,
           previewShape.kind == .lasso,
           previewShape.pathPoints.count >= 3 {
            let committedShape = SelectionShape(
                kind: .lasso,
                bounds: previewShape.bounds,
                pathPoints: previewShape.pathPoints
            )
            let message = "[samePathCommitTest] committedDirectly pointCount=\(committedShape.pathPoints.count) boundsOrigin=(\(committedShape.bounds.origin.x),\(committedShape.bounds.origin.y)) boundsSize=(\(committedShape.bounds.size.x),\(committedShape.bounds.size.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = committedShape
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            samePathPreviewDebugShape = previewShape
            samePathCommittedDebugShape = committedShape
            activeLassoRawPoints = []
            activeLassoBounds = nil
            refresh()
            return
        }
        let combineMode: SelectionCombineMode
        if let savedMode = pendingCombineMode {
            combineMode = savedMode
            pendingCombineMode = nil
        } else {
            combineMode = storeSelection.activeCombineMode
        }
        let input = selectionInput(
            kind: currentKind,
            currentStart: currentStart,
            end: end,
            inProgressShape: storeSelection.inProgressShape,
            modifiers: modifiers,
            combineMode: combineMode
        )
        guard !input.polygonShapes.isEmpty else {
            activeLassoRawPoints = []
            activeLassoBounds = nil
            bootstrap.workspaceStore.updateSelection { selection in
                if combineMode == .replace {
                    selection.committedShape = nil
                }
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            refresh()
            showStatus(.init(kind: .info, message: "选区太小"))
            return
        }
        if workspace.toolSession.activeTool == .lassoFill,
           let preferredShape = input.preferredDisplayShape {
            let operation: SelectionPixelOperation = combineMode == .subtract
                ? .clear
                : .fill(premultipliedPixel(from: workspace.toolSession.selectedColor))
            let successMessage = combineMode == .subtract ? "已删除套索区域像素" : "已填充套索区域"
            let didApplyPixelOperation: Bool
            if combineMode == .subtract {
                didApplyPixelOperation = applyPixelOperation(
                    to: preferredShape,
                    operation: operation,
                    historyOperationKind: "lasso.erase",
                    successMessage: successMessage
                )
            } else {
                didApplyPixelOperation = applyLassoFill(
                    to: preferredShape,
                    historyOperationKind: "lasso.fill",
                    successMessage: successMessage
                )
            }
            activeLassoRawPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = nil
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            refreshLightweight()
            if didApplyPixelOperation {
                relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            }
            return
        }
        // 对于 lasso 且 replace 模式：直接提交平滑后的 lasso 形状。
        // 同时在后台预栅格化成 mask，避免后续自由变形/像素操作再临时现算。
        if currentKind == .lasso, combineMode == .replace, let preferredShape = input.preferredDisplayShape {
            let immediateShape = SelectionShape(
                kind: .lasso,
                bounds: preferredShape.bounds,
                pathPoints: preferredShape.pathPoints
            )

            if combineMode == .replace, immediateShape != previousCommittedShape {
                checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
            }

            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = immediateShape
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            activeLassoRawPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            refreshLightweight()
            showStatus(.init(kind: .success, message: "已更新选区"))

            let polygonShapes = input.polygonShapes
            let capturedPreferredShape = preferredShape
            let capturedCanvasSize = canvasSize
            selectionEpoch += 1
            let capturedEpoch = selectionEpoch
            cancelActiveRasterizationTask()
            activeRasterizationTask = Task { [weak self] in
                guard let self else { return }
                let rasterized = await Task.detached(priority: .userInitiated) {
                    self.selectionMaskShape(
                        from: polygonShapes,
                        canvasSize: capturedCanvasSize,
                        preferredDisplayShape: capturedPreferredShape
                    )
                }.value
                guard self.selectionEpoch == capturedEpoch else { return }
                self.bootstrap.workspaceStore.updateSelection { selection in
                    if selection.committedShape == immediateShape {
                        selection.committedShape = rasterized
                    }
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                self.refreshLightweight()
            }
            relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            return
        }

        // 同步路径：非 lasso 工具（rectangle/ellipse），直接同步处理
        // lasso 的 add/subtract 也做两步异步
        if currentKind == .lasso, let preferredShape = input.preferredDisplayShape {
            // 增减选时用保存的 base 选区（在 handleSelectionMouseDown 时保存）
            let baseShapeForCombine = (combineMode != .replace) ? pendingCombineBaseShape : nil
            pendingCombineBaseShape = nil
            let capturedCombineMode = combineMode

            let immediateShape: SelectionShape?
            if combineMode == .replace {
                immediateShape = SelectionShape(
                    kind: .lasso,
                    bounds: preferredShape.bounds,
                    pathPoints: preferredShape.pathPoints
                )
            } else {
                // add/subtract 时先保持旧选区显示，等异步完成再更新
                immediateShape = baseShapeForCombine
            }

            if combineMode == .replace, immediateShape != previousCommittedShape {
                checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
            }

            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = immediateShape
                selection.inProgressShape = preferredShape
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = capturedCombineMode
            }
            activeLassoRawPoints = []
            activeLassoBounds = nil
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            refreshLightweight()
            showStatus(.init(kind: .success, message: "已更新选区"))

            let polygonShapes = input.polygonShapes
            let capturedPreferredShape = preferredShape
            let capturedCanvasSize = canvasSize
            let capturedBaseShape = baseShapeForCombine?.clamped(to: canvasSize)
            selectionEpoch += 1
            let capturedEpoch = selectionEpoch
            cancelActiveRasterizationTask()
            activeRasterizationTask = Task { [weak self] in
                guard let self else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    self.committedSelectionShape(
                        input: SelectionInputShape(
                            polygonShapes: polygonShapes,
                            preferredDisplayShape: capturedPreferredShape
                        ),
                        canvasSize: capturedCanvasSize,
                        mode: capturedCombineMode,
                        baseShape: capturedBaseShape
                    )
                }.value
                guard self.selectionEpoch == capturedEpoch else { return }
                self.bootstrap.workspaceStore.updateSelection { selection in
                    if capturedCombineMode == .add {
                        selection.committedShape = result ?? capturedBaseShape
                    } else {
                        selection.committedShape = result
                    }
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                self.refresh()
            }
            relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))
            return
        }

        // 非 lasso 工具：同步处理
        let nextCommittedShape = committedSelectionShape(
            input: input,
            canvasSize: canvasSize,
            mode: combineMode,
            baseShape: previousCommittedShape?.clamped(to: canvasSize)
        )
        if currentKind == .lasso {
            if let nextCommittedShape {
                let message = "[commitSelection:result] committedKind=\(nextCommittedShape.kind.rawValue) boundsOrigin=(\(nextCommittedShape.bounds.origin.x),\(nextCommittedShape.bounds.origin.y)) boundsSize=(\(nextCommittedShape.bounds.size.x),\(nextCommittedShape.bounds.size.y)) pathPointCount=\(nextCommittedShape.pathPoints.count)"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceViewModel(message)
            } else {
                let message = "[commitSelection:result] committedShape=nil"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceViewModel(message)
            }
        }

        if combineMode == .replace, nextCommittedShape != previousCommittedShape {
            checkpointSelectionChangeIfPossible(previousCommittedShape: previousCommittedShape)
        }

        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = nextCommittedShape
            selection.inProgressShape = nil
            selection.anchorPoint = nil
            selection.activeKind = nil
            selection.activeCombineMode = .replace
        }
        activeLassoRawPoints = []
        lassoSamplingDebugPoints = []
        samePathPreviewDebugShape = nil
        samePathCommittedDebugShape = nil

        refresh()
        relayIdeationOperation(.commitSelection(end: end, modifiers: .init(flags: modifiers)))

        if isGeneratorRegionSelectionArmed, nextCommittedShape != nil {
            isGeneratorRegionSelectionArmed = false
            applyGeneratorToActiveLayer(clearSelectionAfterApply: true)
            return
        }

        if nextCommittedShape == nil {
            showStatus(.init(kind: .info, message: "选区为空"))
        } else {
            showStatus(.init(kind: .success, message: "已更新选区"))
        }
    }

    // MARK: - 选区鼠标交互

    // 每次开始新选区操作时递增，用于让过期的异步栅格化任务自动丢弃结果
    private var selectionEpoch: Int = 0
    private var activeRasterizationTask: Task<Void, Never>?

    private func cancelActiveRasterizationTask() {
        activeRasterizationTask?.cancel()
        activeRasterizationTask = nil
    }

    func handleSelectionMouseDown(at point: CanvasPoint, modifiers: NSEvent.ModifierFlags) -> SelectionMouseDownAction {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        let hasModifier = normalized.contains(.shift) || normalized.contains(.option)

        if workspace.toolSession.activeTool == .polygonSelection {
            if polygonSelectionState.phase == .building {
                return .idle
            }

            if hasModifier {
                return .idle
            }

            if let committed = bootstrap.workspaceStore.state.selection.committedShape, committed.contains(point) {
                cancelActiveRasterizationTask()
                selectionEpoch += 1
                pendingCombineMode = nil
                selectionMoveBaseShape = committed
                selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
                selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
                return .beginMoving
            }

            return .idle
        }

        if workspace.toolSession.activeTool == .lassoFill {
            cancelActiveRasterizationTask()
            selectionEpoch += 1
            pendingCombineMode = selectionCombineMode(for: .lasso, modifiers: normalized)
            pendingCombineBaseShape = nil
            activeLassoRawPoints = []
            lassoSamplingDebugPoints = []
            samePathPreviewDebugShape = nil
            samePathCommittedDebugShape = nil
            selectionMoveBaseShape = nil
            selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
            bootstrap.workspaceStore.updateSelection { selection in
                selection.committedShape = nil
                selection.inProgressShape = nil
                selection.anchorPoint = nil
                selection.activeKind = nil
                selection.activeCombineMode = .replace
            }
            beginSelection(kind: .lasso, at: point, modifiers: modifiers)
            return .beginDrawing
        }

        if hasModifier {
            // 增减选：保存当前选区作为 base，开始画新选区
            cancelActiveRasterizationTask()
            selectionMoveBaseShape = nil
            pendingCombineBaseShape = bootstrap.workspaceStore.state.selection.committedShape
            let kind = selectionKindForActiveTool()
            // 在 beginSelection 之前计算并保存 combineMode，因为 commitSelection 时 modifiers 可能已松开
            pendingCombineMode = selectionCombineMode(for: kind, modifiers: normalized)
            beginSelection(kind: kind, at: point, modifiers: modifiers)
            return .beginDrawing
        }

        if let committed = bootstrap.workspaceStore.state.selection.committedShape {
            if committed.contains(point) {
                cancelActiveRasterizationTask()
                selectionEpoch += 1
                pendingCombineMode = nil
                selectionMoveBaseShape = committed
                selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
                selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
                return .beginMoving
            } else {
                cancelActiveRasterizationTask()
                selectionEpoch += 1
                pendingCombineMode = nil
                pendingCombineBaseShape = nil
                activeLassoRawPoints = []
                lassoSamplingDebugPoints = []
                samePathPreviewDebugShape = nil
                samePathCommittedDebugShape = nil
                selectionMoveBaseShape = nil
                selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
                selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
                bootstrap.workspaceStore.updateSelection { selection in
                    selection.committedShape = nil
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.activeCombineMode = .replace
                }
                let kind = selectionKindForActiveTool()
                beginSelection(kind: kind, at: point, modifiers: modifiers)
                return .beginDrawing
            }
        }

        pendingCombineMode = nil
        pendingCombineBaseShape = nil
        selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
        let kind = selectionKindForActiveTool()
        beginSelection(kind: kind, at: point, modifiers: modifiers)
        return .beginDrawing
    }

    // 增减选时保存的 base 选区，避免异步任务完成前状态被覆盖
    private var pendingCombineBaseShape: SelectionShape?
    // 增减选时保存的 combineMode，避免 commitSelection 时 activeCombineMode 已被重置
    private var pendingCombineMode: SelectionCombineMode?

    private func selectionKindForActiveTool() -> SelectionShapeKind {
        switch workspace.toolSession.activeTool {
        case .ellipseSelection: return .ellipse
        case .lassoSelection, .lassoFill: return .lasso
        default: return .rectangle
        }
    }

    private var selectionMoveBaseShape: SelectionShape?
    private var selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
    private(set) var selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)

    func moveSelectionPreview(by deltaX: Double, deltaY: Double) {
        ideationBranchActivityHandler?()
        guard let base = selectionMoveBaseShape else { return }
        selectionMoveAccumulatedDelta.x += deltaX
        selectionMoveAccumulatedDelta.y += deltaY
        let dx = selectionMoveAccumulatedDelta.x
        let dy = selectionMoveAccumulatedDelta.y
        _ = base
        selectionMovePreviewOffset = CanvasPoint(x: dx, y: dy)
        refreshSelectionOverlayOnly()
        relayIdeationOperation(.moveSelectionPreview(deltaX: deltaX, deltaY: deltaY))
    }

    func commitSelectionMove() {
        ideationBranchActivityHandler?()
        guard
            let base = selectionMoveBaseShape,
            selectionMoveAccumulatedDelta.x != 0 || selectionMoveAccumulatedDelta.y != 0
        else {
            selectionMoveBaseShape = nil
            selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
            selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
            return
        }
        let dx = selectionMoveAccumulatedDelta.x
        let dy = selectionMoveAccumulatedDelta.y
        selectionMoveBaseShape = nil
        selectionMoveAccumulatedDelta = CanvasPoint(x: 0, y: 0)
        selectionMovePreviewOffset = CanvasPoint(x: 0, y: 0)
        let moved = base.translatedBy(x: dx, y: dy)
        bootstrap.workspaceStore.updateSelection { selection in
            selection.committedShape = moved
        }
        refreshLightweight()
        relayIdeationOperation(.commitSelectionMove)
    }

    func clearSelection() {
        switch transformState.clearBehavior() {
        case .apply:
            applySelectionTransform(clearSelectionAfterApply: true)
            return
        case .cancel:
            cancelSelectionTransform(clearSelectionAfterCancel: true)
            return
        case .none:
            break
        }

        let hadSelection = workspace.selection.displayRect != nil
        if hadSelection {
            checkpointHistoryIfPossible()
        }
        activeLassoRawPoints = []
        lassoSamplingDebugPoints = []
        samePathPreviewDebugShape = nil
        samePathCommittedDebugShape = nil
        bootstrap.workspaceStore.updateSelection { selection in
            selection = .empty
        }

        refresh()
        showStatus(.init(kind: .info, message: "已清除选区"))
    }

    func beginSelectionTransform(at start: CanvasPoint) {
        beginSelectionTransform(at: start, mode: .move)
    }

    func beginSelectionTransform(at start: CanvasPoint, mode: FreeTransformInteractionMode) {
        beginSelectionTransform(at: start, mode: mode, modifiers: [])
    }

    func beginSelectionTransform(
        at start: CanvasPoint,
        mode: FreeTransformInteractionMode,
        modifiers: NSEvent.ModifierFlags
    ) {
        ideationBranchActivityHandler?()
        ensureWholeLayerInteractionBoundsAvailableIfNeeded(for: bootstrap.workspaceStore.state)
        activateImplicitFreeTransformSelectionIfNeeded()
        guard effectiveTransformOperationShape != nil else { return }

        if transformState.isActive {
            // 已经激活（freeTransform 工具多次拖动）：只开始新的拖动，不重置 accumulated offset
            transformState.beginDrag(at: start, mode: mode)
        } else {
            transformState.beginSession(at: start, mode: mode)
        }
        _ = modifiers
        isFreeTransformDragging = true
        activeFreeTransformInteractionMode = mode
        freeTransformMoveLogCount = 0
        if mode == .move {
            transformLogger.debug("[transform] overlayHiddenDuringMove=true")
        }
        setFreeTransformPreview(transformState.preview)
        isTransformingSelection = transformState.isActive
        relayIdeationOperation(.beginSelectionTransform(start: start, mode: mode))
    }

    func updateSelectionTransform(to point: CanvasPoint) {
        updateSelectionTransform(to: point, modifiers: [])
    }

    func updateSelectionTransform(
        to point: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        ideationBranchActivityHandler?()
        guard
            isTransformingSelection,
            let dragStartPoint = transformState.dragStartPoint
        else {
            return
        }

        switch transformState.interactionMode {
        case .move:
            let nextPreview = freeTransformTranslatedPreview(
                dragStartPoint: dragStartPoint,
                currentPoint: point,
                startPreview: transformState.dragStartPreview
            )
            transformState.preview = nextPreview
            transformState.accumulatedOffset = nextPreview.translation
            if freeTransformMoveLogCount < 10 {
                transformLogger.debug(
                    "[transform] moveTranslation x=\(nextPreview.translation.x, privacy: .public) y=\(nextPreview.translation.y, privacy: .public)"
                )
                freeTransformMoveLogCount += 1
            }
            setFreeTransformPreview(nextPreview)
        case .scale(let handle):
            guard let shape = effectiveTransformInteractionShape else { return }
            let uniformScaleEnabled = modifiers.contains(.command)
            let nextPreview = freeTransformScaledPreview(
                bounds: shape.bounds,
                handle: handle,
                dragStartPoint: dragStartPoint,
                currentPoint: point,
                startPreview: transformState.dragStartPreview,
                uniformScale: uniformScaleEnabled
            )
            transformState.preview = nextPreview
            transformState.accumulatedOffset = nextPreview.translation
            transformLogger.debug(
                "[transform] uniformScaleEnabled=\(uniformScaleEnabled, privacy: .public) scaleX=\(nextPreview.scaleX, privacy: .public) scaleY=\(nextPreview.scaleY, privacy: .public)"
            )
            setFreeTransformPreview(nextPreview)
        case .rotate:
            guard let shape = effectiveTransformInteractionShape else { return }
            let nextPreview = rotatedPreview(
                for: shape.bounds,
                dragStartPoint: dragStartPoint,
                currentPoint: point,
                startPreview: transformState.dragStartPreview
            )
            transformState.preview = nextPreview
            transformState.accumulatedOffset = nextPreview.translation
            setFreeTransformPreview(nextPreview)
        }
        relayIdeationOperation(.updateSelectionTransform(point: point))
    }

    /// Coordinator가 GPU offset을 직접 계산한 경우 사용 (선택 없는 전체 레이어 이동)
    func setTransformPreviewOffset(_ offset: CanvasPoint) {
        ideationBranchActivityHandler?()
        let nextPreview = FreeTransformPreview(
            translation: offset,
            scaleX: freeTransformPreview.scaleX,
            scaleY: freeTransformPreview.scaleY,
            rotationRadians: freeTransformPreview.rotationRadians
        )
        transformState.preview = nextPreview
        transformState.accumulatedOffset = nextPreview.translation
        setFreeTransformPreview(nextPreview)
        relayIdeationOperation(.setTransformPreviewOffset(offset))
    }

    func commitSelectionTransform(at end: CanvasPoint) {
        commitSelectionTransform(at: end, modifiers: [])
    }

    func commitSelectionTransform(
        at end: CanvasPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        ideationBranchActivityHandler?()
        _ = modifiers
        guard
            isTransformingSelection,
            transformState.dragStartPoint != nil
        else {
            return
        }

        if workspace.toolSession.activeTool == .freeTransform {
            transformState.endInteraction()
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            transformLogger.debug("[transform] overlayHiddenDuringMove=false")
            setFreeTransformPreview(transformState.preview)
        } else {
            let delta = transformState.finishDrag(at: end)
            transformPreviewOffset = transformState.accumulatedOffset
            guard delta.x != 0 || delta.y != 0 else {
                cancelSelectionTransform(clearSelectionAfterCancel: freeTransformUsesImplicitSelection)
                return
            }
            applySelectionTransform(clearSelectionAfterApply: freeTransformUsesImplicitSelection)
        }
        relayIdeationOperation(.commitSelectionTransform(end: end))
    }

    func applySelectionTransform() {
        ideationBranchActivityHandler?()
        if workspace.toolSession.activeTool == .freeTransform {
            applySelectionTransform(clearSelectionAfterApply: true)
        } else {
            applySelectionTransform(clearSelectionAfterApply: true)
        }
        relayIdeationOperation(.applySelectionTransform)
    }

    private func applySelectionTransform(clearSelectionAfterApply: Bool) {
        guard
            isTransformingSelection,
            let selectionShape = effectiveTransformOperationShape
        else {
            showStatus(.init(kind: .info, message: "当前没有活动变形"))
            return
        }

        guard !isApplyingTransformCommit else { return }

        let isFreeTransform = workspace.toolSession.activeTool == .freeTransform
        let preview = isFreeTransform ? freeTransformPreview : transformState.preview
        let pixelDeltaX = Int(preview.translation.x.rounded())
        let pixelDeltaY = Int(preview.translation.y.rounded())
        let shouldClearSelection = clearSelectionAfterApply || freeTransformUsesImplicitSelection
        let capturedFreeTransformUsesImplicit = freeTransformUsesImplicitSelection
        let canvasSize = workspace.document.canvasSize
        let applyStart = DispatchTime.now().uptimeNanoseconds

        guard !preview.isIdentity else {
            transformState.reset()
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            freeTransformMoveLogCount = 0
            transformLogger.debug("[transform] overlayHiddenDuringMove=false")
            setFreeTransformPreview(.identity)
            isTransformingSelection = false
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            refresh()
            showStatus(.init(kind: .info, message: "没有变形"))
            return
        }

        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            transformState.reset()
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            freeTransformMoveLogCount = 0
            transformLogger.debug("[transform] overlayHiddenDuringMove=false")
            setFreeTransformPreview(.identity)
            isTransformingSelection = false
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            refresh()
            return
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            transformState.reset()
            isFreeTransformDragging = false
            activeFreeTransformInteractionMode = nil
            freeTransformMoveLogCount = 0
            setFreeTransformPreview(.identity)
            isTransformingSelection = false
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            refresh()
            return
        }

        let historyCheckpointStart = DispatchTime.now().uptimeNanoseconds
        checkpointHistoryIfPossible()
        let historyCheckpointDurationMs = Double(DispatchTime.now().uptimeNanoseconds - historyCheckpointStart) / 1_000_000
        transformLogger.debug("[apply] historyCheckpointMs=\(historyCheckpointDurationMs, privacy: .public)")
        isApplyingTransformCommit = true
        let capturedPreview = preview
        let buildStart = DispatchTime.now().uptimeNanoseconds

        transformPreviewSessionBuilder.makeSession(
            activeLayerSurfaceID: surfaceID,
            sourceTexture: texture,
            canvasSize: canvasSize,
            selectionShape: selectionShape,
            interactionBounds: effectiveTransformInteractionShape?.bounds,
            selectionRevision: selectionRevision,
            canvasContentRevision: canvasContentRevision,
            metal: bootstrap.metalContext
        ) { [weak self] session in
            guard let self else { return }

            let buildDurationMs = Double(DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000
            self.transformLogger.debug(
                "[apply] sessionBuildMs=\(buildDurationMs, privacy: .public) success=\(session != nil, privacy: .public)"
            )

            guard let session else {
                self.isApplyingTransformCommit = false
                self.transformState.reset()
                self.isFreeTransformDragging = false
                self.activeFreeTransformInteractionMode = nil
                self.freeTransformMoveLogCount = 0
                self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                self.setFreeTransformPreview(.identity)
                self.isTransformingSelection = false
                self.freeTransformUsesImplicitSelection = false
                self.implicitFreeTransformSelectionShape = nil
                self.refresh()
                self.showStatus(.init(kind: .error, message: "无法准备变形预览"))
                return
            }

            let compositor: TransformGPUCompositor
            do {
                compositor = try self.transformGPUCompositorResult.get()
            } catch {
                self.isApplyingTransformCommit = false
                self.transformState.reset()
                self.isFreeTransformDragging = false
                self.activeFreeTransformInteractionMode = nil
                self.freeTransformMoveLogCount = 0
                self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                self.setFreeTransformPreview(.identity)
                self.isTransformingSelection = false
                self.freeTransformUsesImplicitSelection = false
                self.implicitFreeTransformSelectionShape = nil
                self.refresh()
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
                return
            }

            let composeStart = DispatchTime.now().uptimeNanoseconds
            compositor.composeTransformedTexture(
                session: session,
                preview: capturedPreview,
                canvasSize: canvasSize,
                metal: self.bootstrap.metalContext
            ) { [weak self] targetTexture in
                guard let self else { return }

                let composeDurationMs = Double(DispatchTime.now().uptimeNanoseconds - composeStart) / 1_000_000
                self.transformLogger.debug(
                    "[apply] gpuComposeMs=\(composeDurationMs, privacy: .public) success=\(targetTexture != nil, privacy: .public)"
                )

                guard let targetTexture else {
                    self.isApplyingTransformCommit = false
                    self.transformState.reset()
                    self.isFreeTransformDragging = false
                    self.activeFreeTransformInteractionMode = nil
                    self.freeTransformMoveLogCount = 0
                    self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                    self.setFreeTransformPreview(.identity)
                    self.isTransformingSelection = false
                    self.freeTransformUsesImplicitSelection = false
                    self.implicitFreeTransformSelectionShape = nil
                    self.refresh()
                    self.showStatus(.init(kind: .error, message: "GPU 合成失败"))
                    return
                }

                self.bootstrap.layerSurfaceStore.swapTexture(for: surfaceID, with: targetTexture)

                self.isApplyingTransformCommit = false
                self.transformState.reset()
                self.isFreeTransformDragging = false
                self.activeFreeTransformInteractionMode = nil
                self.freeTransformMoveLogCount = 0
                self.transformLogger.debug("[transform] overlayHiddenDuringMove=false")
                self.setFreeTransformPreview(.identity)
                self.isTransformingSelection = false
                self.freeTransformUsesImplicitSelection = false
                self.implicitFreeTransformSelectionShape = nil

                self.bootstrap.workspaceStore.updateSelection { selection in
                    if shouldClearSelection {
                        selection.committedShape = nil
                    } else if !capturedFreeTransformUsesImplicit,
                              abs(capturedPreview.scaleX - 1) < 0.0001,
                              abs(capturedPreview.scaleY - 1) < 0.0001,
                              abs(capturedPreview.rotationRadians) < 0.0001 {
                        selection.committedShape = selection.committedShape?
                            .translatedBy(x: Double(pixelDeltaX), y: Double(pixelDeltaY))
                            .clamped(to: canvasSize)
                    }
                    selection.inProgressShape = nil
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                }

                self.noteCanvasContentChanged()
                if isFreeTransform && capturedFreeTransformUsesImplicit {
                    let latestState = self.bootstrap.workspaceStore.state
                    self.primeWholeLayerFreeTransformIdleStateIfNeeded(for: latestState)
                    self.refreshLightweight()
                } else {
                    self.refresh()
                }

                let totalDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStart) / 1_000_000
                self.transformLogger.debug("[apply] totalMs=\(totalDurationMs, privacy: .public)")
                self.showStatus(.init(
                    kind: .success,
                    message: (
                        abs(capturedPreview.scaleX - 1) < 0.0001 &&
                        abs(capturedPreview.scaleY - 1) < 0.0001 &&
                        abs(capturedPreview.rotationRadians) < 0.0001
                    ) ? "已移动" : "已应用变形"
                ))
            }
        }
    }

    func cancelSelectionTransform() {
        ideationBranchActivityHandler?()
        cancelSelectionTransform(clearSelectionAfterCancel: false)
        relayIdeationOperation(.cancelSelectionTransform)
    }

    private func cancelSelectionTransform(clearSelectionAfterCancel: Bool) {
        transformState.reset()
        isFreeTransformDragging = false
        activeFreeTransformInteractionMode = nil
        freeTransformMoveLogCount = 0
        transformLogger.debug("[transform] overlayHiddenDuringMove=false")
        setFreeTransformPreview(.identity)
        isTransformingSelection = transformState.isActive
        let shouldClearSelection = clearSelectionAfterCancel || freeTransformUsesImplicitSelection

        if shouldClearSelection {
            bootstrap.workspaceStore.updateSelection { selection in
                selection = .empty
            }
        }
        freeTransformUsesImplicitSelection = false
        implicitFreeTransformSelectionShape = nil

        refresh()
        showStatus(.init(kind: .info, message: "已取消变形"))
    }

    private func setFreeTransformPreview(_ preview: FreeTransformPreview) {
        freeTransformPreview = preview
        transformPreviewOffset = preview.translation
        transformPreviewRevision &+= 1
    }

    private func rotatedPreview(
        for bounds: CanvasRect,
        dragStartPoint: CanvasPoint,
        currentPoint: CanvasPoint,
        startPreview: FreeTransformPreview
    ) -> FreeTransformPreview {
        let center = CanvasPoint(
            x: bounds.origin.x + (bounds.size.x / 2) + startPreview.translation.x,
            y: bounds.origin.y + (bounds.size.y / 2) + startPreview.translation.y
        )
        let startAngle = atan2(dragStartPoint.y - center.y, dragStartPoint.x - center.x)
        let currentAngle = atan2(currentPoint.y - center.y, currentPoint.x - center.x)

        return FreeTransformPreview(
            translation: startPreview.translation,
            scaleX: startPreview.scaleX,
            scaleY: startPreview.scaleY,
            rotationRadians: startPreview.rotationRadians + (currentAngle - startAngle)
        )
    }


    private func activateImplicitFreeTransformSelectionIfNeeded() {
        let currentState = bootstrap.workspaceStore.state
        guard currentState.toolSession.activeTool == .freeTransform else { return }
        guard currentState.selection.committedShape == nil else {
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            return
        }
        if implicitFreeTransformSelectionShape != nil {
            freeTransformUsesImplicitSelection = true
            return
        }
        guard let implicitSelection = implicitFreeTransformSelectionShape(from: currentState) else {
            freeTransformUsesImplicitSelection = false
            implicitFreeTransformSelectionShape = nil
            return
        }
        implicitFreeTransformSelectionShape = implicitSelection
        freeTransformUsesImplicitSelection = true
    }

    private func primeWholeLayerFreeTransformIdleStateIfNeeded(for state: WorkspaceState) {
        guard state.toolSession.activeTool == .freeTransform else { return }
        ensureWholeLayerInteractionBoundsAvailableIfNeeded(for: state)
        activateImplicitFreeTransformSelectionIfNeeded()
        guard effectiveTransformOperationShape != nil else {
            isTransformingSelection = transformState.isActive
            return
        }
        if !transformState.isActive {
            transformState.beginSession(at: .init(x: 0, y: 0))
            transformState.dragStartPoint = nil // 只激活，不开始拖动
            setFreeTransformPreview(.identity)
        }
        isTransformingSelection = transformState.isActive
    }

    var hidesImplicitFreeTransformSelectionOverlay: Bool {
        bootstrap.workspaceStore.state.toolSession.activeTool == .freeTransform && freeTransformUsesImplicitSelection
    }

    var effectiveTransformOperationShape: SelectionShape? {
        workspace.selection.committedShape ?? implicitFreeTransformSelectionShape
    }

    var effectiveTransformInteractionShape: SelectionShape? {
        if let committed = workspace.selection.committedShape {
            return committed
        }
        guard workspace.toolSession.activeTool == .freeTransform else {
            return nil
        }
        guard let bounds = currentWholeLayerInteractionBounds(for: workspace) else {
            return nil
        }
        return SelectionShape(
            kind: .rectangle,
            bounds: bounds,
            pathPoints: []
        )
    }

    var transformPreparationSelectionShape: SelectionShape? {
        if let committed = workspace.selection.committedShape {
            return committed
        }
        guard workspace.toolSession.activeTool == .freeTransform else {
            return nil
        }
        return implicitFreeTransformSelectionShape(from: workspace)
    }

    private func implicitFreeTransformSelectionShape(from state: WorkspaceState) -> SelectionShape? {
        guard
            bootstrap.interactionController.activeEditableLayerID() != nil
        else {
            return nil
        }
        return SelectionShape(
            kind: .rectangle,
            bounds: CanvasRect(
                origin: .init(x: 0, y: 0),
                size: .init(
                    x: Double(state.document.canvasSize.width),
                    y: Double(state.document.canvasSize.height)
                )
            ),
            pathPoints: []
        )
    }

    private func wholeLayerInteractionBoundsKey(for state: WorkspaceState) -> WholeLayerInteractionBoundsKey? {
        guard state.toolSession.activeTool == .freeTransform else { return nil }
        guard state.selection.committedShape == nil else { return nil }
        guard
            let activeLayerID = bootstrap.interactionController.activeEditableLayerID(),
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: activeLayerID)
        else {
            return nil
        }
        return WholeLayerInteractionBoundsKey(
            surfaceID: surfaceID,
            canvasContentRevision: canvasContentRevision
        )
    }

    private func currentWholeLayerInteractionBounds(for state: WorkspaceState) -> CanvasRect? {
        guard let key = wholeLayerInteractionBoundsKey(for: state) else {
            return nil
        }
        guard wholeLayerInteractionBoundsCacheKey == key else {
            return nil
        }
        guard case .ready(let bounds) = wholeLayerInteractionBoundsCacheEntry else {
            return nil
        }
        return bounds
    }

    private func scheduleWholeLayerInteractionBoundsRefreshIfNeeded(for state: WorkspaceState) {
        guard let key = wholeLayerInteractionBoundsKey(for: state) else {
            wholeLayerInteractionBoundsTask?.cancel()
            wholeLayerInteractionBoundsTask = nil
            wholeLayerInteractionBoundsBuildingKey = nil
            logWholeLayerOverlayUsesInteractionBounds(false)
            return
        }

        if wholeLayerInteractionBoundsCacheKey == key {
            switch wholeLayerInteractionBoundsCacheEntry {
            case .ready(let bounds):
                transformLogger.debug(
                    "[transform] wholeLayerContentBoundsReady=true rect=\(String(describing: bounds), privacy: .public)"
                )
                logWholeLayerOverlayUsesInteractionBounds(true)
            case .empty:
                transformLogger.debug("[transform] wholeLayerContentBoundsEmpty=true")
                logWholeLayerOverlayUsesInteractionBounds(false)
            case nil:
                break
            }
            return
        }

        if wholeLayerInteractionBoundsBuildingKey == key {
            return
        }

        guard
            let texture = bootstrap.layerSurfaceStore.texture(for: key.surfaceID)
        else {
            return
        }

        wholeLayerInteractionBoundsTask?.cancel()
        wholeLayerInteractionBoundsTask = nil
        wholeLayerInteractionBoundsBuildingKey = key

        final class TextureBox: @unchecked Sendable {
            let texture: MTLTexture
            init(_ texture: MTLTexture) { self.texture = texture }
        }
        final class SerializerBox: @unchecked Sendable {
            let serializer: LayerTextureSerializer
            init(_ serializer: LayerTextureSerializer) { self.serializer = serializer }
        }

        let textureBox = TextureBox(texture)
        let serializerBox = SerializerBox(bootstrap.textureSerializer)
        let task = Task.detached(priority: .utility) { () -> WholeLayerInteractionBoundsCacheEntry? in
            guard let snapshot = try? serializerBox.serializer.snapshot(texture: textureBox.texture) else {
                return nil
            }
            return Self.wholeLayerInteractionBounds(from: snapshot)
        }
        wholeLayerInteractionBoundsTask = task

        Task { @MainActor [weak self] in
            guard let self else { return }
            let entry = await task.value
            guard !Task.isCancelled else { return }
            guard self.wholeLayerInteractionBoundsKey(for: self.workspace) == key else { return }
            self.wholeLayerInteractionBoundsBuildingKey = nil
            self.wholeLayerInteractionBoundsTask = nil
            guard let entry else { return }
            self.wholeLayerInteractionBoundsCacheKey = key
            self.wholeLayerInteractionBoundsCacheEntry = entry
            switch entry {
            case .ready(let bounds):
                self.transformLogger.debug(
                    "[transform] wholeLayerContentBoundsReady=true rect=\(String(describing: bounds), privacy: .public)"
                )
                self.logWholeLayerOverlayUsesInteractionBounds(true)
            case .empty:
                self.transformLogger.debug("[transform] wholeLayerContentBoundsReady=false rect=nil")
                self.transformLogger.debug("[transform] wholeLayerContentBoundsEmpty=true")
                self.logWholeLayerOverlayUsesInteractionBounds(false)
            }
            self.sceneSnapshot = self.currentSceneSnapshot(for: self.workspace)
            self.syncSelectionOverlayProxy()
        }
    }

    private func ensureWholeLayerInteractionBoundsAvailableIfNeeded(for state: WorkspaceState) {
        guard let key = wholeLayerInteractionBoundsKey(for: state) else {
            return
        }
        if wholeLayerInteractionBoundsCacheKey == key,
           case .ready = wholeLayerInteractionBoundsCacheEntry {
            return
        }
        guard
            let texture = bootstrap.layerSurfaceStore.texture(for: key.surfaceID),
            let snapshot = try? bootstrap.textureSerializer.snapshot(texture: texture)
        else {
            return
        }

        wholeLayerInteractionBoundsTask?.cancel()
        wholeLayerInteractionBoundsTask = nil
        wholeLayerInteractionBoundsBuildingKey = nil

        let entry = Self.wholeLayerInteractionBounds(from: snapshot)
        wholeLayerInteractionBoundsCacheKey = key
        wholeLayerInteractionBoundsCacheEntry = entry
        switch entry {
        case .ready(let bounds):
            transformLogger.debug(
                "[transform] wholeLayerContentBoundsSyncReady=true rect=\(String(describing: bounds), privacy: .public)"
            )
            logWholeLayerOverlayUsesInteractionBounds(true)
        case .empty:
            transformLogger.debug("[transform] wholeLayerContentBoundsSyncReady=false rect=nil")
            logWholeLayerOverlayUsesInteractionBounds(false)
        }
    }

    nonisolated private static func wholeLayerInteractionBounds(from snapshot: LayerTextureSnapshot) -> WholeLayerInteractionBoundsCacheEntry {
        let width = snapshot.width
        let height = snapshot.height
        guard width > 0, height > 0 else {
            return .empty
        }

        let bytes = [UInt8](snapshot.pixelData)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            let rowStart = y * snapshot.bytesPerRow
            for x in 0..<width {
                let alphaIndex = rowStart + (x * 4) + 3
                if bytes[alphaIndex] > 0 {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return .empty
        }

        return .ready(
            CanvasRect(
                origin: .init(x: Double(minX), y: Double(minY)),
                size: .init(
                    x: Double((maxX - minX) + 1),
                    y: Double((maxY - minY) + 1)
                )
            )
        )
    }

    private func logWholeLayerOverlayUsesInteractionBounds(_ usesInteractionBounds: Bool) {
        guard workspace.toolSession.activeTool == .freeTransform else { return }
        guard workspace.selection.committedShape == nil else { return }
        guard lastLoggedWholeLayerOverlayUsesInteractionBounds != usesInteractionBounds else { return }
        lastLoggedWholeLayerOverlayUsesInteractionBounds = usesInteractionBounds
        transformLogger.debug(
            "[transform] wholeLayerUsesInteractionBoundsForOverlay=\(usesInteractionBounds, privacy: .public)"
        )
    }

    func deleteSelectionContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可删除的选区"))
            return
        }
        _ = applyPixelOperation(
            to: selectionShape,
            operation: .clear,
            historyOperationKind: "selection.erase",
            successMessage: "已删除选区内容"
        )
    }

    func fillSelectionContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可填充的选区"))
            return
        }
        _ = applyPixelOperation(
            to: selectionShape,
            operation: .fill(premultipliedPixel(from: workspace.toolSession.selectedColor)),
            historyOperationKind: "selection.fill",
            successMessage: "已填充选区"
        )
    }

    func fillLassoContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可填充的选区"))
            return
        }

        guard selectionShape.containsLassoContent else {
            showStatus(.init(kind: .info, message: "当前选区不是套索"))
            return
        }

        _ = applyLassoFill(
            to: selectionShape,
            historyOperationKind: "lasso.fill",
            successMessage: "已填充选区"
        )
    }

    private func fillCurrentSelectionWithForegroundColorShortcut() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可填充的选区"))
            return
        }

        if selectionShape.containsLassoContent {
            fillLassoContents()
        } else {
            fillSelectionContents()
        }
    }

    func applyGeneratorToActiveLayer(clearSelectionAfterApply: Bool = false) {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        guard
            let texture = bootstrap.layerSurfaceStore.surfaceID(for: layerID).flatMap(bootstrap.layerSurfaceStore.texture(for:))
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        checkpointHistoryIfPossible()

        do {
            let generator = workspace.generator
            guard generator.kind == .automaticLines else {
                showStatus(.init(kind: .info, message: "\(generator.kind.displayName) 还未接通真实生成逻辑"))
                return
            }

            let canvasSize = CanvasSize(width: texture.width, height: texture.height)
            let targetShape = workspace.selection.committedShape?.clamped(to: canvasSize)
            let bounds = targetShape?.bounds ?? CanvasRect(
                origin: CanvasPoint(x: 0, y: 0),
                size: CanvasPoint(
                    x: Double(texture.width),
                    y: Double(texture.height)
                )
            )

            let minX = max(Int(bounds.minX.rounded(.down)), 0)
            let minY = max(Int(bounds.minY.rounded(.down)), 0)
            let maxX = min(Int(bounds.maxX.rounded(.up)), texture.width)
            let maxY = min(Int(bounds.maxY.rounded(.up)), texture.height)

            guard minX < maxX, minY < maxY else {
                showStatus(.init(kind: .info, message: "生成区域为空"))
                return
            }

            let snapshot = try bootstrap.textureSerializer.snapshot(
                texture: texture,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            var bytes = [UInt8](snapshot.pixelData)
            let selectedColor = workspace.toolSession.selectedColor
            let generatorColor = resolvedGeneratorColor(from: selectedColor)
            applyAutomaticLineGenerator(
                to: &bytes,
                snapshotWidth: snapshot.width,
                snapshotHeight: snapshot.height,
                bytesPerRow: snapshot.bytesPerRow,
                originX: minX,
                originY: minY,
                targetShape: targetShape,
                color: generatorColor,
                settings: generator
            )

            let updatedSnapshot = LayerTextureSnapshot(
                width: snapshot.width,
                height: snapshot.height,
                bytesPerRow: snapshot.bytesPerRow,
                pixelData: Data(bytes)
            )
            try bootstrap.textureSerializer.restore(
                snapshot: updatedSnapshot,
                into: texture,
                destinationX: minX,
                destinationY: minY
            )
            if clearSelectionAfterApply {
                bootstrap.workspaceStore.updateSelection { selection in
                    selection.anchorPoint = nil
                    selection.activeKind = nil
                    selection.committedShape = nil
                    selection.inProgressShape = nil
                }
            }
            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: "已应用\(generator.kind.displayName)生成器"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    private func applyLinearGradient(geometry: LinearGradientGeometry) {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        guard
            let texture = bootstrap.layerSurfaceStore.surfaceID(for: layerID).flatMap(bootstrap.layerSurfaceStore.texture(for:))
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        let pointA = geometry.pointA
        let pointB = geometry.pointB
        let pointC = geometry.pointC
        let vectorU = CanvasPoint(x: pointB.x - pointA.x, y: pointB.y - pointA.y)
        let vectorV = CanvasPoint(x: pointC.x - pointB.x, y: pointC.y - pointB.y)
        let determinant = (vectorU.x * vectorV.y) - (vectorU.y * vectorV.x)
        guard abs(determinant) > 0.0001 else {
            showStatus(.init(kind: .info, message: "渐变长度和宽度不能共线"))
            return
        }

        checkpointHistoryIfPossible(
            operationKind: "linearGradient.apply",
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        let pointD = geometry.pointD
        let minCanvasX = min(min(pointA.x, pointB.x), min(pointC.x, pointD.x))
        let minCanvasY = min(min(pointA.y, pointB.y), min(pointC.y, pointD.y))
        let maxCanvasX = max(max(pointA.x, pointB.x), max(pointC.x, pointD.x))
        let maxCanvasY = max(max(pointA.y, pointB.y), max(pointC.y, pointD.y))
        let minX = max(Int(floor(minCanvasX)), 0)
        let minY = max(Int(floor(minCanvasY)), 0)
        let maxX = min(Int(ceil(maxCanvasX)), texture.width)
        let maxY = min(Int(ceil(maxCanvasY)), texture.height)

        guard minX < maxX, minY < maxY else {
            showStatus(.init(kind: .info, message: "渐变区域为空"))
            return
        }

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建渐变命令缓冲"))
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        let applyStart = DispatchTime.now().uptimeNanoseconds
        bootstrap.linearGradientRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: workspace.document.canvasSize,
            pointA: pointA,
            pointB: pointB,
            pointC: pointC,
            color: gradientPreviewColor,
            colorJitterAmount: workspace.toolSession.brush.colorJitterAmount,
            selectionShape: workspace.selection.committedShape
        )

        isApplyingGradientCommit = true
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let gpuMs = Double(DispatchTime.now().uptimeNanoseconds - applyStart) / 1_000_000
        layerThumbnailCache.removeValue(forKey: layerID)
        linearGradientState = .init()
        bootstrap.strokeEngine.resetBrushPipelineState()
        noteCanvasContentChanged()
        refresh(invalidatedLayerIDs: [layerID])
        isApplyingGradientCommit = false
        transformLogger.debug("[gradient] applyGpuMs=\(gpuMs, privacy: .public) sessionTool=linear")
        showStatus(.init(kind: .success, message: "已应用直线渐变"))
        handleDeferredGradientActionIfNeeded()
    }

    func applyStraightLine(pointA: CanvasPoint, pointB: CanvasPoint) -> Bool {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        checkpointHistoryIfPossible()

        let stroke = StrokeDescriptor(
            tool: .brush,
            color: workspace.toolSession.selectedColor,
            brush: workspace.toolSession.brush,
            points: [
                StrokePoint(x: pointA.x, y: pointA.y, pressure: 1),
                StrokePoint(x: pointB.x, y: pointB.y, pressure: 1)
            ],
            selectionShape: workspace.selection.committedShape
        )

        bootstrap.strokeEngine.beginStrokeIfNeeded(
            toolSession: ToolSessionState(
                activeTool: .brush,
                brush: workspace.toolSession.brush,
                selectedColor: workspace.toolSession.selectedColor
            ),
            layerID: layerID
        )
        bootstrap.strokeEngine.applyStroke(stroke, to: layerID)
        bootstrap.strokeEngine.endStroke()
        refresh(invalidatedLayerIDs: [layerID])
        noteCanvasContentChanged()
        showStatus(.init(kind: .success, message: "已应用直线"))
        return true
    }

    private func applySectorGradient(geometry: SectorGradientGeometry) {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return
        }

        guard geometry.maxRadius > 1, geometry.pathPoints.count >= 3 else {
            showStatus(.init(kind: .info, message: "区域太小，无法生成扇形渐变"))
            return
        }

        checkpointHistoryIfPossible(
            operationKind: "sectorGradient.apply",
            candidateChangedLayerIDs: [layerID],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建渐变命令缓冲"))
            return
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.sectorGradientRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: workspace.document.canvasSize,
            center: geometry.center,
            pathPoints: geometry.pathPoints,
            maxRadius: geometry.maxRadius,
            color: gradientPreviewColor,
            colorJitterAmount: workspace.toolSession.brush.colorJitterAmount,
            maskQuality: .commit,
            selectionShape: workspace.selection.committedShape
        )

        isApplyingGradientCommit = true
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layerThumbnailCache.removeValue(forKey: layerID)
        sectorGradientState = .init()
        bootstrap.strokeEngine.resetBrushPipelineState()
        noteCanvasContentChanged()
        refresh(invalidatedLayerIDs: [layerID])
        isApplyingGradientCommit = false
        showStatus(.init(kind: .success, message: "已应用扇形渐变"))
        handleDeferredGradientActionIfNeeded()
    }

    func eraseLassoContents() {
        guard let selectionShape = workspace.selection.committedShape else {
            showStatus(.init(kind: .info, message: "没有可擦除的选区"))
            return
        }

        guard selectionShape.containsLassoContent else {
            showStatus(.init(kind: .info, message: "当前选区不是套索"))
            return
        }

        _ = applyPixelOperation(
            to: selectionShape,
            operation: .clear,
            historyOperationKind: "lasso.erase",
            successMessage: "已删除选区内容"
        )
    }

    func handleKeyDown(_ event: NSEvent) -> Bool {
        let normalizedModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .straightLine,
           straightLineState.phase != .idle {
            cancelStraightLineInteraction()
            return true
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .linearGradient,
           linearGradientState.phase != .idle {
            cancelLinearGradientInteraction()
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           workspace.toolSession.activeTool == .linearGradient,
           linearGradientState.isActiveSession {
            applyActiveGradientSession()
            return true
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .sectorGradient,
           sectorGradientState.phase != .idle {
            cancelSectorGradientInteraction()
            return true
        }

        if (event.keyCode == 36 || event.keyCode == 76),
           workspace.toolSession.activeTool == .sectorGradient,
           sectorGradientState.isActiveSession {
            applyActiveGradientSession()
            return true
        }

        if event.keyCode == 53,
           workspace.toolSession.activeTool == .polygonSelection,
           polygonSelectionState.phase != .idle {
            cancelPolygonSelectionInteraction()
            return true
        }

        if (event.keyCode == 51 || event.keyCode == 117),
           workspace.toolSession.activeTool == .polygonSelection,
           polygonSelectionState.phase == .building {
            undoLastPolygonSelectionPoint()
            return true
        }

        if workspace.toolSession.activeTool == .freeTransform {
            if event.keyCode == 36 || event.keyCode == 76 { // Enter
                applySelectionTransform()
                return true
            }
            if event.keyCode == 53 { // ESC
                cancelSelectionTransform()
                return true
            }
        }

        if isTransformingSelection && workspace.toolSession.activeTool != .freeTransform {
            if event.keyCode == 36 || event.keyCode == 76 { // Enter
                applySelectionTransform()
                return true
            }
            if event.keyCode == 53 { // ESC
                cancelSelectionTransform()
                return true
            }
        }

        if isBrushTipCanvasFocused,
           normalizedModifiers.intersection([.command, .control]).isEmpty == false,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            return importBrushTipImage(fromPasteboard: .general)
        }

        if isColorBlocksPanelFocused,
           workspace.colorPanel.mode == .blocks,
           normalizedModifiers.intersection([.command, .control]).isEmpty == false,
           event.charactersIgnoringModifiers?.lowercased() == "v" {
            return importColorPanelPalette(fromPasteboard: .general)
        }

        if normalizedModifiers.intersection([.command, .control, .option]).isEmpty,
           let digit = event.charactersIgnoringModifiers,
           let shortcut = Int(digit),
           (1...4).contains(shortcut),
           activateBrushPresetShortcut(slotIndex: shortcut - 1) {
            return true
        }

        if event.keyCode == 49 {
            if !isPanModeActive {
                setPanModeActive(true)
            }
            return true
        }

        if event.keyCode == 53 {
            guard workspace.selection.displayRect != nil else { return false }
            clearSelection()
            return true
        }

        if (event.keyCode == 51 || event.keyCode == 117),
           workspace.toolSession.activeTool == .bucket,
           normalizedModifiers == [.option] {
            fillCurrentSelectionWithForegroundColorShortcut()
            return true
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            guard workspace.selection.displayRect != nil else { return false }
            deleteSelectionContents()
            return true
        }

        if normalizedModifiers.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "d" {
            guard workspace.selection.displayRect != nil else { return true }
            clearSelection()
            return true
        }

        if let shortcutKey = event.charactersIgnoringModifiers?.uppercased(),
           handleToolShortcutKey(shortcutKey, modifiers: normalizedModifiers) {
            return true
        }

        if event.charactersIgnoringModifiers == "[" {
            adjustBrushSize(by: -1)
            return true
        }

        if event.charactersIgnoringModifiers == "]" {
            adjustBrushSize(by: 1)
            return true
        }

        return false
    }

    func handleKeyUp(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49 else { return false }
        if isPanModeActive {
            setPanModeActive(false)
        }
        return true
    }

    private func refresh(
        invalidatedLayerIDs: Set<LayerID>? = nil,
        reason: StaticString = "unspecified"
    ) {
        Self.normalizeDisabledToolsIfNeeded(in: bootstrap.workspaceStore)
        let state = bootstrap.workspaceStore.state
        if workspace.selection != state.selection {
            selectionRevision &+= 1
        }
        if workspace.viewport != state.viewport {
            viewportRevision &+= 1
        }
        bootstrap.layerSurfaceStore.prepareTextures(
            for: state.document,
            metal: bootstrap.metalContext
        )
        if let invalidatedLayerIDs {
            for layerID in invalidatedLayerIDs {
                layerThumbnailCache.removeValue(forKey: layerID)
            }
        } else {
            layerThumbnailCache.removeAll()
        }
        workspace = state
        sceneSnapshot = currentSceneSnapshot(for: state)
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
        canMergeDown = state.document.activeMergeDownContext != nil
        canMergeVisible = state.document.mergeVisibleContext != nil
        syncSelectionOverlayProxy()
        scheduleWholeLayerInteractionBoundsRefreshIfNeeded(for: state)
    }

    private func refreshLightweight(reason: StaticString = "unspecified") {
        Self.normalizeDisabledToolsIfNeeded(in: bootstrap.workspaceStore)
        let state = bootstrap.workspaceStore.state
        if workspace.selection != state.selection {
            selectionRevision &+= 1
        }
        if workspace.viewport != state.viewport {
            viewportRevision &+= 1
        }
        workspace = state
        sceneSnapshot = currentSceneSnapshot(for: state)
        canUndo = bootstrap.historyController.canUndo
        canRedo = bootstrap.historyController.canRedo
        canMergeDown = state.document.activeMergeDownContext != nil
        canMergeVisible = state.document.mergeVisibleContext != nil
        colorPanelProxy.colorPanel = state.colorPanel
        colorPanelProxy.selectedColor = state.toolSession.selectedColor
        syncSelectionOverlayProxy()
        scheduleWholeLayerInteractionBoundsRefreshIfNeeded(for: state)
    }

    private func refreshSelectionOverlayOnly() {
        syncSelectionOverlayProxy()
    }

    var metalContext: MetalDeviceContext {
        bootstrap.metalContext
    }

    var layerSurfaceStore: StageOneLayerSurfaceStore {
        bootstrap.layerSurfaceStore
    }

    func applyStroke(samples: [CanvasStrokeSample]) {
        let applyStartNs = DispatchTime.now().uptimeNanoseconds
        ideationBranchActivityHandler?()
        let packetIndex = strokePacketCount
        let skipLeadingStamp = packetIndex > 0
        guard let strokePayload = bootstrap.interactionController.makeStrokeDescriptor(
            samples: samples,
            skipLeadingStamp: skipLeadingStamp
        ) else {
            let applyDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000
            brushStrokeLogger.debug("[brush-feel] applyStrokeMainThreadMs=\(applyDurationMs, privacy: .public)")
            return
        }

        if isGeneratorStrokeModeEnabled,
           strokePayload.stroke.tool == .brush,
           applyGeneratorStroke(samples: samples, layerID: strokePayload.layerID, baseStroke: strokePayload.stroke) {
            strokePacketCount += 1
            let applyDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000
            brushStrokeLogger.debug("[brush-feel] applyStrokeMainThreadMs=\(applyDurationMs, privacy: .public)")
            return
        }

        let livePathMetric = bootstrap.strokeEngine.applyStroke(
            strokePayload.stroke,
            to: strokePayload.layerID
        )
        brushStrokeLogger.debug(
            "[packet] index=\(packetIndex, privacy: .public) skipLeadingStamp=\(skipLeadingStamp, privacy: .public) incomingPoints=\(samples.count, privacy: .public) livePathMetric=\(livePathMetric, privacy: .public)"
        )
        let applyDurationMs = Double(DispatchTime.now().uptimeNanoseconds - applyStartNs) / 1_000_000
        brushStrokeLogger.debug("[brush-feel] applyStrokeMainThreadMs=\(applyDurationMs, privacy: .public)")
        strokePacketCount += 1
        relayIdeationOperation(.applyStroke(samples))
    }

    func beginStrokeIfNeeded() {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.beginStrokeIfNeeded", ms: ms)
        }
        ideationBranchActivityHandler?()
        strokePacketCount = 0

        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            return
        }
        if isGeneratorStrokeModeEnabled,
           workspace.toolSession.activeTool == .brush,
           workspace.generator.kind != .automaticLines {
            showStatus(.init(kind: .info, message: "\(workspace.generator.kind.displayName) 的直接绘制还未接通"))
            return
        }

        if !isBrushLikeTool(workspace.toolSession.activeTool) {
            checkpointHistoryIfPossible()
        }

        bootstrap.strokeEngine.beginStrokeIfNeeded(
            toolSession: workspace.toolSession,
            layerID: layerID
        )
        relayIdeationOperation(.beginStroke)
    }

    func endStroke() {
        ideationBranchActivityHandler?()
        bootstrap.strokeEngine.endStroke()
        strokePacketCount = 0
        generatorStrokeSession = .init()
        noteCanvasContentChanged()
        relayIdeationOperation(.endStroke)
    }

    @discardableResult
    func flushPendingBrushWork(into commandBuffer: MTLCommandBuffer) -> BrushFlushMetrics? {
        bootstrap.strokeEngine.flushPendingStrokePackets(into: commandBuffer)
    }

    var hasPendingBrushWork: Bool {
        bootstrap.strokeEngine.hasPendingBrushWork
    }

    func brushDisplayTexture(for layerID: LayerID) -> MTLTexture? {
        bootstrap.strokeEngine.displayTexture(for: layerID)
    }

    func opportunisticallyDrainBrushCommits(hadLiveBrushWorkThisFrame: Bool) {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.opportunisticallyDrainBrushCommits", ms: ms)
        }
        guard bootstrap.strokeEngine.hasPendingBrushCommitJobs else {
            return
        }

        do {
            let result = try bootstrap.strokeEngine.opportunisticDrainPendingBrushCommitJobs(
                hadLiveBrushWorkThisFrame: hadLiveBrushWorkThisFrame,
                maxJobs: 1,
                maxCpuMs: 0.75
            ) { [self] job in
                try captureBrushCommitCheckpoint(for: job)
                hasUnsavedChanges = true
            }

            if result.drainedJobs > 0 {
                canUndo = bootstrap.historyController.canUndo
                canRedo = bootstrap.historyController.canRedo
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func undo() {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.undo", ms: ms)
        }
        ideationBranchActivityHandler?()
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        if ideationUndoHandler?() == true {
            return
        }
        performUndoLocally()
    }

    private func performUndoLocally() {
        if resolveTransformSession(reason: .historyNavigation) {
            return
        }
        do {
            let didUndo = try bootstrap.historyController.undo()
            refresh()
            showStatus(
                .init(
                    kind: .info,
                    message: didUndo ? "Undo" : "Nothing to undo"
                )
            )
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func redo() {
        let startNs = DispatchTime.now().uptimeNanoseconds
        defer {
            let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.redo", ms: ms)
        }
        ideationBranchActivityHandler?()
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        if ideationRedoHandler?() == true {
            return
        }
        performRedoLocally()
    }

    private func performRedoLocally() {
        if resolveTransformSession(reason: .historyNavigation) {
            return
        }
        do {
            let didRedo = try bootstrap.historyController.redo()
            refresh()
            showStatus(
                .init(
                    kind: .info,
                    message: didRedo ? "Redo" : "Nothing to redo"
                )
            )
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportPNG() {
        let documentName = workspace.document.metadata.name

        guard let url = bootstrap.filePanelService.presentPNGExportPanel(defaultName: documentName) else {
            showStatus(.init(kind: .info, message: "已取消 PNG 导出"))
            return
        }

        do {
            try exportPNG(to: url)
            showStatus(.init(kind: .success, message: "已导出 PNG：\(url.lastPathComponent)"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportPNG(to fileURL: URL) throws {
        _ = flushBrushEditingBoundary(reason: "exportPNG")
        try bootstrap.exportController.exportPNG(
            request: ExportRequest(fileURL: fileURL)
        )
    }

    var ideationActiveBranchViewModel: WorkspaceViewModel? {
        ideationSession?.activeBranchViewModel
    }

    func handleSnapshotSavePrimaryAction() {
        guard snapshotCompareSession == nil else { return }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间不可使用快照保存"))
            return
        }

        if savedSnapshots.count >= Self.maxSavedSnapshotCount {
            openSnapshotCompare()
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "handleSnapshotSavePrimaryAction")
            let snapshot = try makeVisibleCompositeSnapshot()
            let savedSnapshot = makeSavedCanvasSnapshot(from: snapshot, includesPreviewImage: false)
            savedSnapshots.append(savedSnapshot)
            prepareSavedSnapshotPreviewIfNeeded(for: savedSnapshot.id)

            if savedSnapshots.count >= Self.maxSavedSnapshotCount {
                openSnapshotCompare(frozenSnapshotOverride: savedSnapshot)
            } else {
                showStatus(.init(kind: .success, message: "已保存快照（\(savedSnapshots.count)/\(Self.maxSavedSnapshotCount)）"))
            }
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func openSnapshotCompare(frozenSnapshotOverride: CanvasSavedSnapshot? = nil) {
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比已开启"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探期间不可进入快照对比"))
            return
        }
        guard !savedSnapshots.isEmpty else {
            showStatus(.init(kind: .info, message: "当前还没有已保存的快照"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "openSnapshotCompare")
            suspendTimelapseForSnapshotCompareIfNeeded()
            let frozenSnapshot: CanvasSavedSnapshot
            if let frozenSnapshotOverride {
                frozenSnapshot = frozenSnapshotOverride
            } else {
                frozenSnapshot = makeSavedCanvasSnapshot(
                    from: try makeVisibleCompositeSnapshot(),
                    includesPreviewImage: false
                )
            }
            snapshotCompareSession = SnapshotCompareSessionState(frozenCurrentSnapshot: frozenSnapshot)
            for savedSnapshot in savedSnapshots {
                prepareSavedSnapshotPreviewIfNeeded(for: savedSnapshot.id)
            }
            prepareFrozenSnapshotPreviewIfNeeded(for: frozenSnapshot)
            showStatus(.init(kind: .success, message: "已进入快照对比"))
        } catch {
            resumeTimelapseAfterSnapshotCompareIfNeeded()
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func cancelSnapshotCompare() {
        guard snapshotCompareSession != nil else { return }
        cancelSnapshotPreviewPreparationTasks()
        snapshotCompareSession = nil
        resumeTimelapseAfterSnapshotCompareIfNeeded()
        showStatus(.init(kind: .info, message: "已退出快照对比"))
    }

    func clearSavedSnapshots() {
        guard !savedSnapshots.isEmpty else {
            showStatus(.init(kind: .info, message: "当前没有可清空的快照"))
            return
        }

        savedSnapshots.removeAll()
        cancelSnapshotPreviewPreparationTasks()
        if snapshotCompareSession != nil {
            snapshotCompareSession = nil
            resumeTimelapseAfterSnapshotCompareIfNeeded()
        }
        showStatus(.init(kind: .info, message: "已清空全部快照"))
    }

    func deleteSavedSnapshot(_ id: UUID) {
        guard let index = savedSnapshots.firstIndex(where: { $0.id == id }) else {
            return
        }
        savedSnapshots.remove(at: index)
        cancelSavedSnapshotPreviewPreparationTask(for: id)
        snapshotCompareSession?.removeSnapshot(id)

        if savedSnapshots.isEmpty, snapshotCompareSession != nil {
            snapshotCompareSession = nil
            resumeTimelapseAfterSnapshotCompareIfNeeded()
            showStatus(.init(kind: .info, message: "已删除最后一张快照，并退出快照对比"))
        } else {
            showStatus(.init(kind: .info, message: "已删除快照"))
        }
    }

    func selectSavedSnapshotForCompare(_ id: UUID?) {
        snapshotCompareSession?.selectedSnapshotID = id
    }

    func assignSavedSnapshot(_ id: UUID, to slot: SnapshotCompareSlot) {
        guard savedSnapshot(with: id) != nil else { return }
        snapshotCompareSession?.assignSnapshot(id, to: slot)
        prepareSavedSnapshotPreviewIfNeeded(for: id)
    }

    func clearSavedSnapshotCompareSlot(_ slot: SnapshotCompareSlot) {
        snapshotCompareSession?.clearSlot(slot)
    }

    func applySelectedSavedSnapshotToMainCanvas() {
        guard
            let session = snapshotCompareSession,
            let selectedSnapshotID = session.selectedSnapshotID,
            let savedSnapshot = savedSnapshot(with: selectedSnapshotID)
        else {
            showStatus(.init(kind: .info, message: "请先选择一个快照"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "applySelectedSavedSnapshotToMainCanvas")
            let labelIndex = savedSnapshotDisplayIndex(for: selectedSnapshotID) ?? savedSnapshots.count
            try appendCompositeSnapshotAsNewLayer(
                savedSnapshot.snapshot,
                named: "快照 \(labelIndex)"
            )
            cancelSnapshotPreviewPreparationTasks()
            snapshotCompareSession = nil
            resumeTimelapseAfterSnapshotCompareIfNeeded(recordCurrentCanvas: true)
            showStatus(.init(kind: .success, message: "已将快照 \(labelIndex) 应用于主画布"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportSavedSnapshotsToDisk() {
        guard !savedSnapshots.isEmpty else {
            showStatus(.init(kind: .info, message: "当前没有可导出的快照"))
            return
        }

        let defaultDirectoryName = "\(workspace.document.metadata.name)-快照"
        guard let directoryURL = bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择快照导出文件夹",
            prompt: "导出"
        ) else {
            showStatus(.init(kind: .info, message: "已取消导出快照"))
            return
        }

        let exportEntries = savedSnapshots.enumerated().map { index, entry in
            (index: index, snapshot: entry.snapshot)
        }
        let boxedExporter = WorkspaceUncheckedBox(bootstrap.pngExporter)
        showStatus(.init(kind: .info, message: "正在导出 \(exportEntries.count) 个快照..."))

        Task { [weak self] in
            guard let self else { return }
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for entry in exportEntries {
                        let outputURL = directoryURL
                            .appendingPathComponent("\(defaultDirectoryName)-\(entry.index + 1).png")
                        group.addTask(priority: .userInitiated) {
                            try boxedExporter.value.export(snapshot: entry.snapshot, to: outputURL)
                        }
                    }
                    try await group.waitForAll()
                }

                self.showStatus(.init(kind: .success, message: "已导出 \(exportEntries.count) 个快照"))
            } catch {
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    func startIdeationSession() {
        guard snapshotCompareSession == nil else {
            showStatus(.init(kind: .info, message: "快照对比期间不可进入方案试探"))
            return
        }
        guard ideationSession == nil else {
            showStatus(.init(kind: .info, message: "方案试探已开启"))
            return
        }

        do {
            _ = flushBrushEditingBoundary(reason: "startIdeationSession")
            suspendTimelapseForIdeationIfNeeded()
            let sourceWorkspace = bootstrap.workspaceStore.state
            let baseCompositeTexture = try makeVisibleCompositeTexture()
            ideationSession = try IdeationSessionState(
                hostViewModel: self,
                sourceWorkspace: sourceWorkspace,
                sourceLayerSurfaceStore: bootstrap.layerSurfaceStore,
                baseCompositeTexture: baseCompositeTexture,
                metalContext: bootstrap.metalContext,
                sharedMetalServices: bootstrap.sharedMetalServices
            )
            showStatus(.init(kind: .success, message: "已进入方案试探"))
        } catch {
            resumeTimelapseAfterIdeationIfNeeded()
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func cancelIdeationSession() {
        ideationSession = nil
        resumeTimelapseAfterIdeationIfNeeded()
        showStatus(.init(kind: .info, message: "已退出方案试探"))
    }

    func applySelectedIdeationVariantToMainCanvas() {
        guard let ideationSession else { return }

        do {
            _ = ideationSession.activeBranchViewModel.flushBrushEditingBoundary(
                reason: "applySelectedIdeationVariantToMainCanvas.ideationBranch"
            )
            let snapshot = try ideationSession.activeBranchViewModel.makeVisibleCompositeTexture()
            guard let deltaSnapshot = try ideationDeltaSnapshot(
                variantTexture: snapshot,
                baseTexture: ideationSession.baseCompositeTexture
            ) else {
                showStatus(.init(kind: .info, message: "当前方案没有可附加到新图层的可见差异"))
                return
            }
            let slotIndex = ideationSession.selectedBranchIndex + 1
            self.ideationSession = nil
            try appendCompositeSnapshotAsNewLayer(
                deltaSnapshot,
                named: "方案试探 \(slotIndex)"
            )
            resumeTimelapseAfterIdeationIfNeeded(recordCurrentCanvas: true)
            showStatus(.init(kind: .success, message: "已将方案 \(slotIndex) 应用于主画布"))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func exportIdeationVariantsToDisk() {
        guard let ideationSession else { return }
        let defaultDirectoryName = "\(workspace.document.metadata.name)-方案试探"

        guard let directoryURL = bootstrap.filePanelService.presentDirectorySelectionPanel(
            title: "选择草图导出文件夹",
            prompt: "导出"
        ) else {
            showStatus(.init(kind: .info, message: "已取消导出草图"))
            return
        }
        let boxedExporter = WorkspaceUncheckedBox(bootstrap.pngExporter)

        showStatus(.init(kind: .info, message: "正在导出 4 个草图..."))

        Task { [weak self] in
            guard let self else { return }
            do {
                var snapshots: [(index: Int, snapshot: LayerTextureSnapshot)] = []
                snapshots.reserveCapacity(ideationSession.branches.count)

                for (index, branch) in ideationSession.branches.enumerated() {
                    let snapshot = try await MainActor.run {
                        _ = branch.viewModel.flushBrushEditingBoundary(
                            reason: "exportIdeationVariantsToDisk.branch\(index)"
                        )
                        return try branch.viewModel.makeVisibleCompositeSnapshot()
                    }
                    snapshots.append((index, snapshot))
                    await Task.yield()
                }

                try await withThrowingTaskGroup(of: Void.self) { group in
                    for entry in snapshots {
                        let outputURL = directoryURL
                            .appendingPathComponent("\(defaultDirectoryName)-\(entry.index + 1).png")
                        group.addTask(priority: .userInitiated) {
                            try boxedExporter.value.export(snapshot: entry.snapshot, to: outputURL)
                        }
                    }
                    try await group.waitForAll()
                }

                self.showStatus(.init(kind: .success, message: "已导出 4 个草图"))
            } catch {
                self.showStatus(.init(kind: .error, message: error.localizedDescription))
            }
        }
    }

    @discardableResult
    func saveProject() -> Bool {
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: false)
        let documentName = workspace.document.metadata.name
        let url: URL
        if let existingURL = currentProjectURL {
            url = existingURL
        } else {
            guard let selectedURL = bootstrap.filePanelService.presentProjectSavePanel(defaultName: documentName) else {
                showStatus(.init(kind: .info, message: "已取消工程保存"))
                return false
            }
            url = selectedURL
        }

        do {
            try bootstrap.persistenceController.saveProject(to: url)
            currentProjectURL = url
            hasUnsavedChanges = false
            persistBrushLibrary()
            syncTimelapseDocumentContext()
            showStatus(.init(kind: .success, message: "已保存工程：\(url.lastPathComponent)"))
            return true
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    func openProject() {
        _ = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        resolveTransformSession(reason: .documentOpen)
        timelapseRecorder.stopRecording()
        guard let url = bootstrap.filePanelService.presentProjectOpenPanel() else {
            showStatus(.init(kind: .info, message: "已取消打开工程"))
            return
        }

        do {
            resetSnapshotToolState(resumeTimelapseIfNeeded: false)
            let result = try bootstrap.persistenceController.openProject(from: url)
            let existingTipImageLibrary = bootstrap.workspaceStore.state.tipImageLibrary
            var openedWorkspace = result.workspace
            openedWorkspace.tipImageLibrary = Self.mergeTipImageLibraries(
                base: existingTipImageLibrary,
                imported: Self.normalizeImportedTipImageLibrary(result.workspace.tipImageLibrary)
            )
            bootstrap.workspaceStore.replaceState(openedWorkspace)
            _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
            Self.normalizeLegacySelectionIfNeeded(in: bootstrap.workspaceStore)
            bootstrap.layerSurfaceStore.reset()
            bootstrap.layerSurfaceStore.prepareTextures(
                for: bootstrap.workspaceStore.state.document,
                metal: bootstrap.metalContext
            )

            for layerSnapshot in result.layerSnapshots {
                guard
                    let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerSnapshot.layerID),
                    let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
                else {
                    continue
                }

                try bootstrap.textureSerializer.restore(snapshot: layerSnapshot.texture, into: texture)
            }
            bootstrap.textureSerializer.purgeStagingTextures(
                exceeding: bootstrap.workspaceStore.state.document.canvasSize
            )

            bootstrap.historyController.resetHistory()
            currentProjectURL = url
            hasUnsavedChanges = false
            persistBrushLibrary()
            syncTimelapseDocumentContext()
            showStatus(.init(kind: .success, message: "已打开工程：\(url.lastPathComponent)"))
            refresh()
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    func createNewCanvas(
        name: String = "未命名",
        canvasSize: CanvasSize,
        resolutionDPI: Int
    ) {
        createNewCanvas(
            name: name,
            canvasSize: canvasSize,
            resolutionDPI: resolutionDPI,
            decisionOverride: nil
        )
    }

    func createNewCanvasDiscardingUnsavedChanges(
        name: String = "未命名",
        canvasSize: CanvasSize,
        resolutionDPI: Int
    ) {
        createNewCanvas(
            name: name,
            canvasSize: canvasSize,
            resolutionDPI: resolutionDPI,
            decisionOverride: .discard
        )
    }

    private func createNewCanvas(
        name: String,
        canvasSize: CanvasSize,
        resolutionDPI: Int,
        decisionOverride: NewCanvasCreationDecision?
    ) {
        resolveTransformSession(reason: .documentOpen)
        timelapseRecorder.stopRecording()

        switch decisionOverride ?? confirmNewCanvasCreationIfNeeded() {
        case .cancel:
            return
        case .save:
            guard saveProject() else { return }
        case .discard:
            _ = flushBrushEditingBoundary(reason: "createNewCanvas.discard")
            break
        }

        resetSnapshotToolState(resumeTimelapseIfNeeded: false)

        let now = Date()
        let layers = ArtDocument.stageOneDefaultLayers()
        var resetToolSession = workspace.toolSession
        resetToolSession.brush.opacity = BrushSettings.stageOneDefault.opacity
        let document = ArtDocument(
            metadata: DocumentMetadata(
                name: name,
                createdAt: now,
                updatedAt: now,
                resolutionDPI: resolutionDPI
            ),
            canvasSize: canvasSize,
            layers: layers,
            activeLayerID: layers.last?.id ?? layers[0].id
        )

        let newWorkspace = WorkspaceState(
            document: document,
            toolSession: resetToolSession,
            colorPanel: workspace.colorPanel,
            brushLibrary: workspace.brushLibrary,
            tipImageLibrary: workspace.tipImageLibrary,
            generator: workspace.generator,
            viewport: .stageOneDefault,
            selection: .empty
        )

        bootstrap.workspaceStore.replaceState(newWorkspace)
        bootstrap.layerSurfaceStore.reset()
        bootstrap.layerSurfaceStore.prepareTextures(
            for: newWorkspace.document,
            metal: bootstrap.metalContext
        )
        seedDefaultBackgroundLayerIfNeeded(for: newWorkspace.document)
        bootstrap.textureSerializer.purgeStagingTextures(exceeding: newWorkspace.document.canvasSize)
        bootstrap.historyController.resetHistory()

        currentProjectURL = nil
        hasUnsavedChanges = true
        isNewCanvasSheetPresented = false
        syncTimelapseDocumentContext()
        showStatus(.init(kind: .success, message: "已创建新画布：\(canvasSize.width)×\(canvasSize.height)"))
        refresh()
    }

    private func seedDefaultBackgroundLayerIfNeeded(for document: ArtDocument) {
        guard
            let backgroundLayer = document.layers.first(where: { $0.name == LayerRecord.defaultBackgroundLayerName }),
            backgroundLayer.name == LayerRecord.defaultBackgroundLayerName,
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: backgroundLayer.id),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            return
        }

        let snapshot = Self.solidColorSnapshot(
            width: document.canvasSize.width,
            height: document.canvasSize.height,
            blue: 255,
            green: 255,
            red: 255,
            alpha: 255
        )

        do {
            try bootstrap.textureSerializer.restore(snapshot: snapshot, into: texture)
            layerThumbnailCache.removeValue(forKey: backgroundLayer.id)
        } catch {
            return
        }
    }

    private static func solidColorSnapshot(
        width: Int,
        height: Int,
        blue: UInt8,
        green: UInt8,
        red: UInt8,
        alpha: UInt8
    ) -> LayerTextureSnapshot {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = blue
            pixels[offset + 1] = green
            pixels[offset + 2] = red
            pixels[offset + 3] = alpha
        }

        return LayerTextureSnapshot(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixelData: Data(pixels)
        )
    }

    private static func makeSceneSnapshot(
        workspace: WorkspaceState,
        bootstrap: AppBootstrap,
        canvasContentRevision: UInt64,
        selectionRevision: UInt64,
        viewportRevision: UInt64
    ) -> CanvasSceneSnapshot {
        let surfaces = bootstrap.layerSurfaceStore.surfaceRecords(for: workspace.document)
        let activeSurface = surfaces.first { $0.layerID == workspace.document.activeLayerID }

        return CanvasSceneSnapshot(
            renderSnapshot: CanvasRenderSnapshot(
                document: workspace.document,
                viewport: workspace.viewport,
                canvasContentRevision: canvasContentRevision,
                viewportRevision: viewportRevision
            ),
            layerSurfaces: surfaces,
            activeLayerSurfaceID: activeSurface?.surfaceID,
            selectionShape: workspace.selection.committedShape,
            selectionRevision: selectionRevision
        )
    }

    private enum NewCanvasCreationDecision {
        case save
        case discard
        case cancel
    }

    enum UnsavedChangesDecision {
        case save
        case discard
        case cancel
    }

    private func confirmNewCanvasCreationIfNeeded() -> NewCanvasCreationDecision {
        switch confirmUnsavedChangesIfNeeded(
            messageText: "当前画布有未保存内容",
            informativeText: "创建新画布前，要先保存当前内容吗？"
        ) {
        case .save:
            return .save
        case .discard:
            return .discard
        case .cancel:
            return .cancel
        }
    }

    private enum BrushLibraryImportMode {
        case replace
        case append
    }

    private func importBrushLibrary(mode: BrushLibraryImportMode) {
        guard let url = bootstrap.filePanelService.presentBrushLibraryImportPanel() else {
            showStatus(.init(kind: .info, message: "已取消导入画笔库"))
            return
        }

        do {
            let imported = try bootstrap.brushLibraryPersistenceController.importLibrary(from: url)
            _ = applyImportedBrushLibraryResources(
                imported,
                replacingExistingLibrary: mode == .replace
            )
            persistBrushLibrary()
            refresh()
            let message = mode == .replace ? "已替换画笔库" : "已追加导入画笔库"
            showStatus(.init(kind: .success, message: message))
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    @discardableResult
    func applyImportedBrushLibraryResources(
        _ imported: PersistedBrushResources,
        replacingExistingLibrary: Bool
    ) -> Bool {
        let previousSelectedPresetID = bootstrap.workspaceStore.state.brushLibrary.selectedPresetID
        let normalizedLibrary = Self.normalizeImportedBrushLibrary(imported.library)
        let normalizedTipImageLibrary = Self.normalizeImportedTipImageLibrary(imported.tipImageLibrary)

        bootstrap.workspaceStore.updateBrushLibrary { library in
            if replacingExistingLibrary {
                library = normalizedLibrary.removingLegacyDualTipPhaseOneDemoPresets()
            } else {
                library = Self.mergeBrushLibraries(base: library, imported: normalizedLibrary)
                    .removingLegacyDualTipPhaseOneDemoPresets()
            }
            if library.selectedPresetID == nil {
                library.selectedPresetID = library.presets.first?.id
            }
        }
        bootstrap.workspaceStore.updateTipImageLibrary { tipImageLibrary in
            if replacingExistingLibrary {
                tipImageLibrary = normalizedTipImageLibrary
            } else {
                tipImageLibrary = Self.mergeTipImageLibraries(
                    base: tipImageLibrary,
                    imported: normalizedTipImageLibrary
                )
            }
        }

        let didRealignCurrentBrush = synchronizeCurrentBrushToSelectedPresetIfNeeded(
            previousSelectedPresetID: previousSelectedPresetID,
            force: replacingExistingLibrary
        )
        _ = synchronizeTipImageLibraryFromWorkspace(persistIfChanged: false)
        return didRealignCurrentBrush
    }

    private static func normalizeImportedBrushLibrary(_ library: BrushLibraryState) -> BrushLibraryState {
        var seen = Set<String>()
        var presets: [BrushPreset] = []

        for preset in library.presets {
            var normalized = preset
            if seen.contains(normalized.id) {
                normalized = BrushPreset(
                    id: UUID().uuidString,
                    name: normalized.name,
                    brush: normalized.brush,
                    isBuiltIn: false,
                    slotIndex: normalized.slotIndex
                )
            } else {
                normalized.isBuiltIn = false
            }
            seen.insert(normalized.id)
            presets.append(normalized)
        }

        let selectedPresetID = presets.contains(where: { $0.id == library.selectedPresetID }) ? library.selectedPresetID : presets.first?.id
        return BrushLibraryState(presets: presets, selectedPresetID: selectedPresetID)
    }

    private static func mergeBrushLibraries(base: BrushLibraryState, imported: BrushLibraryState) -> BrushLibraryState {
        var merged = base
        var existingIDs = Set(merged.presets.map(\.id))

        for preset in imported.presets {
            let normalizedID = existingIDs.contains(preset.id) ? UUID().uuidString : preset.id
            let normalized = BrushPreset(
                id: normalizedID,
                name: preset.name,
                brush: preset.brush,
                isBuiltIn: false,
                slotIndex: preset.slotIndex
            )
            existingIDs.insert(normalized.id)
            merged.presets.append(normalized)
        }

        if merged.selectedPresetID == nil {
            merged.selectedPresetID = imported.selectedPresetID ?? merged.presets.first?.id
        }
        return merged
    }

    private static func normalizeImportedTipImageLibrary(_ library: TipImageLibraryState) -> TipImageLibraryState {
        library.normalizedMergingDuplicates()
    }

    private static func mergeTipImageLibraries(
        base: TipImageLibraryState,
        imported: TipImageLibraryState
    ) -> TipImageLibraryState {
        var merged = base
        _ = merged.mergeItems(from: imported.normalizedMergingDuplicates())
        return merged
    }

    @discardableResult
    private func restorePersistedTipImageLibraryIfAvailable() -> Bool {
        guard let restored = bootstrap.brushLibraryPersistenceController.loadResources() else {
            return false
        }

        let normalizedTipImageLibrary = Self.normalizeImportedTipImageLibrary(restored.tipImageLibrary)
        var changed = false
        bootstrap.workspaceStore.updateTipImageLibrary { tipImageLibrary in
            let merged = Self.mergeTipImageLibraries(
                base: tipImageLibrary,
                imported: normalizedTipImageLibrary
            )
            if merged != tipImageLibrary {
                tipImageLibrary = merged
                changed = true
            }
        }
        return changed
    }

    @discardableResult
    private func synchronizeTipImageLibraryFromWorkspace(
        persistIfChanged: Bool
    ) -> Bool {
        let state = bootstrap.workspaceStore.state
        let currentBrush = state.toolSession.brush
        let presetBrushes = state.brushLibrary.presets.map(\.brush)

        var changed = false
        bootstrap.workspaceStore.updateTipImageLibrary { library in
            changed = library.upsertImportedTips(from: currentBrush)
            for brush in presetBrushes {
                changed = library.upsertImportedTips(from: brush) || changed
            }
        }

        if changed, persistIfChanged {
            persistBrushLibrary()
        }
        return changed
    }

    private func persistBrushLibrary() {
        do {
            try bootstrap.brushLibraryPersistenceController.saveResources(
                library: bootstrap.workspaceStore.state.brushLibrary,
                tipImageLibrary: bootstrap.workspaceStore.state.tipImageLibrary
            )
        } catch {
            showStatus(.init(kind: .error, message: "保存画笔库失败：\(error.localizedDescription)"))
        }
    }

    private static func restorePersistedBrushLibraryIfAvailable(in bootstrap: AppBootstrap) {
        guard let restored = bootstrap.brushLibraryPersistenceController.loadResources() else { return }
        let restoredSelectionID = restored.library.selectedPresetID
        let normalizedLibrary = Self.normalizeImportedBrushLibrary(restored.library)
            .removingLegacyDualTipPhaseOneDemoPresets()
        let resolvedSelectedBrush = restoredSelectionID.flatMap { selectedPresetID in
            normalizedLibrary.preset(id: selectedPresetID)?.brush
        }
        bootstrap.workspaceStore.updateBrushLibrary { library in
            library = normalizedLibrary
            if library.selectedPresetID == nil {
                library.selectedPresetID = library.presets.first?.id
            }
        }
        bootstrap.workspaceStore.updateTipImageLibrary { tipImageLibrary in
            tipImageLibrary = Self.normalizeImportedTipImageLibrary(restored.tipImageLibrary)
        }
        if let resolvedSelectedBrush {
            bootstrap.workspaceStore.updateToolSession { session in
                session.brush = resolvedSelectedBrush
            }
        }
    }

    @discardableResult
    private func synchronizeCurrentBrushToSelectedPresetIfNeeded(
        previousSelectedPresetID: String?,
        force: Bool = false
    ) -> Bool {
        let state = bootstrap.workspaceStore.state
        let selectedPresetID = state.brushLibrary.selectedPresetID
        guard force || selectedPresetID != previousSelectedPresetID else {
            return false
        }
        guard
            let selectedPresetID,
            let selectedPreset = state.brushLibrary.preset(id: selectedPresetID)
        else {
            return false
        }
        guard state.toolSession.brush != selectedPreset.brush else {
            return false
        }

        bootstrap.strokeEngine.endStroke()
        strokeResetToken &+= 1
        bootstrap.workspaceStore.updateToolSession { session in
            session.brush = selectedPreset.brush
        }
        return true
    }

    private func activateBrushPresetShortcut(slotIndex: Int) -> Bool {
        guard let preset = workspace.brushLibrary.preset(atSlot: slotIndex) else {
            return false
        }
        selectTool(.brush)
        applyBrushPreset(preset.id, showFeedback: false)
        return true
    }

    func confirmCloseOrQuitIfNeeded() -> Bool {
        switch confirmUnsavedChangesIfNeeded(
            messageText: "当前画布有未保存内容",
            informativeText: "退出前，要先保存当前内容吗？"
        ) {
        case .save:
            return saveProject()
        case .discard:
            return true
        case .cancel:
            return false
        }
    }

    private func confirmUnsavedChangesIfNeeded(
        messageText: String,
        informativeText: String
    ) -> UnsavedChangesDecision {
        guard hasUnsavedChanges else {
            return .discard
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = messageText
        alert.informativeText = informativeText
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "放弃")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private static func normalizeDisabledToolsIfNeeded(in store: WorkspaceStore) {
        let activeTool = store.state.toolSession.activeTool
        let normalizedTool = normalizedAvailableTool(activeTool)
        guard normalizedTool != activeTool else { return }
        store.updateToolSession { session in
            session.activeTool = normalizedTool
        }
    }

    private static func normalizedViewportRotation(_ angleDegrees: Double) -> Double {
        var normalized = angleDegrees.truncatingRemainder(dividingBy: 360)
        if normalized > 180 {
            normalized -= 360
        } else if normalized <= -180 {
            normalized += 360
        }
        return normalized
    }

    private func currentSceneSnapshot(for state: WorkspaceState) -> CanvasSceneSnapshot {
        var snapshot = WorkspaceViewModel.makeSceneSnapshot(
            workspace: state,
            bootstrap: bootstrap,
            canvasContentRevision: canvasContentRevision,
            selectionRevision: selectionRevision,
            viewportRevision: viewportRevision
        )
        if state.toolSession.activeTool == .freeTransform {
            snapshot.selectionShape = effectiveTransformInteractionShape.map {
                SelectionShape(
                    kind: .rectangle,
                    bounds: $0.bounds,
                    pathPoints: []
                )
            }
        }
        return snapshot
    }

    @discardableResult
    private func resolveTransformSession(reason: TransformResolutionReason) -> Bool {
        switch transformState.resolutionAction(for: reason) {
        case .none:
            return false
        case .applyAndClearSelection:
            applySelectionTransform(clearSelectionAfterApply: true)
        case .cancelAndClearSelection:
            cancelSelectionTransform(clearSelectionAfterCancel: true)
        case .cancelAndPreserveSelection:
            cancelSelectionTransform(clearSelectionAfterCancel: false)
        }

        return true
    }

    private func showStatus(_ status: WorkspaceStatus) {
        self.status = status
        statusDismissTask?.cancel()

        statusDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.status = nil
        }
    }

    func showIdeationSyncError(_ error: Error) {
        showStatus(.init(kind: .error, message: "方案同步失败：\(error.localizedDescription)"))
    }

    func applyIdeationOperation(_ operation: IdeationCanvasOperation) {
        let savedActivityHandler = ideationBranchActivityHandler
        ideationBranchActivityHandler = nil
        isApplyingMirroredIdeationOperation = true
        defer {
            isApplyingMirroredIdeationOperation = false
            ideationBranchActivityHandler = savedActivityHandler
        }

        switch operation {
        case .beginStroke:
            beginStrokeIfNeeded()
        case .applyStroke(let samples):
            applyStroke(samples: samples)
        case .endStroke:
            endStroke()
        case .beginGradientDrag(let point, let modifiers):
            beginGradientDrag(at: point, modifiers: modifiers.eventFlags)
        case .updateGradientDrag(let point, let modifiers):
            updateGradientDrag(to: point, modifiers: modifiers.eventFlags)
        case .endGradientDrag(let point, let modifiers):
            endGradientDrag(at: point, modifiers: modifiers.eventFlags)
        case .enterGradientEditing:
            enterGradientEditingViaShift()
        case .applyGradientSession:
            applyActiveGradientSession()
        case .cancelGradientSession:
            cancelCanvasToolInteraction()
        case .fillAtPoint(let point):
            fillAtPoint(point)
        case .handleCanvasToolClick(let point, let modifiers, let clickCount):
            handleCanvasToolClick(at: point, modifiers: modifiers.eventFlags, clickCount: clickCount)
        case .beginSelection(let kind, let start, let modifiers):
            beginSelection(kind: kind, at: start, modifiers: modifiers.eventFlags)
        case .updateSelection(let point, let modifiers):
            updateSelection(to: point, modifiers: modifiers.eventFlags)
        case .commitSelection(let end, let modifiers):
            commitSelection(at: end, modifiers: modifiers.eventFlags)
        case .moveSelectionPreview(let deltaX, let deltaY):
            moveSelectionPreview(by: deltaX, deltaY: deltaY)
        case .commitSelectionMove:
            commitSelectionMove()
        case .beginSelectionTransform(let start, let mode):
            beginSelectionTransform(at: start, mode: mode)
        case .updateSelectionTransform(let point):
            updateSelectionTransform(to: point)
        case .commitSelectionTransform(let end):
            commitSelectionTransform(at: end)
        case .setTransformPreviewOffset(let offset):
            setTransformPreviewOffset(offset)
        case .applySelectionTransform:
            applySelectionTransform()
        case .cancelSelectionTransform:
            cancelSelectionTransform()
        }
    }

    func makeIdeationEditingContext() -> IdeationEditingContext {
        IdeationEditingContext(
            toolSession: workspace.toolSession,
            colorPanel: workspace.colorPanel,
            brushLibrary: workspace.brushLibrary,
            tipImageLibrary: workspace.tipImageLibrary,
            generator: workspace.generator
        )
    }

    func applyIdeationEditingContext(_ context: IdeationEditingContext) {
        bootstrap.workspaceStore.updateToolSession { $0 = context.toolSession }
        bootstrap.workspaceStore.updateColorPanel { $0 = context.colorPanel }
        bootstrap.workspaceStore.updateBrushLibrary { $0 = context.brushLibrary }
        bootstrap.workspaceStore.updateTipImageLibrary { $0 = context.tipImageLibrary }
        bootstrap.workspaceStore.updateGenerator { $0 = context.generator }
        refreshLightweight()
    }

    private func relayIdeationOperation(_ operation: IdeationCanvasOperation) {
        guard !isApplyingMirroredIdeationOperation else { return }
        ideationOperationHandler?(operation)
    }

    private func suspendTimelapseForIdeationIfNeeded() {
        shouldResumeTimelapseAfterIdeation = timelapseRecorder.isRecording
        guard shouldResumeTimelapseAfterIdeation else { return }
        timelapseRecorder.stopRecording()
    }

    private func resumeTimelapseAfterIdeationIfNeeded(recordCurrentCanvas: Bool = false) {
        guard shouldResumeTimelapseAfterIdeation else { return }
        shouldResumeTimelapseAfterIdeation = false

        syncTimelapseDocumentContext()
        do {
            _ = try timelapseRecorder.startRecording(
                documentName: workspace.document.metadata.name,
                documentFileURL: currentProjectURL
            )
            if recordCurrentCanvas {
                timelapseRecorder.noteCanvasChanged(
                    revision: documentChangeRevision,
                    documentName: workspace.document.metadata.name,
                    documentFileURL: currentProjectURL
                )
            }
        } catch {
            showStatus(.init(kind: .error, message: "恢复录像失败：\(error.localizedDescription)"))
        }
    }

    private func suspendTimelapseForSnapshotCompareIfNeeded() {
        shouldResumeTimelapseAfterSnapshotCompare = timelapseRecorder.isRecording
        guard shouldResumeTimelapseAfterSnapshotCompare else { return }
        timelapseRecorder.stopRecording()
    }

    private func resumeTimelapseAfterSnapshotCompareIfNeeded(recordCurrentCanvas: Bool = false) {
        guard shouldResumeTimelapseAfterSnapshotCompare else { return }
        shouldResumeTimelapseAfterSnapshotCompare = false

        syncTimelapseDocumentContext()
        do {
            _ = try timelapseRecorder.startRecording(
                documentName: workspace.document.metadata.name,
                documentFileURL: currentProjectURL
            )
            if recordCurrentCanvas {
                timelapseRecorder.noteCanvasChanged(
                    revision: documentChangeRevision,
                    documentName: workspace.document.metadata.name,
                    documentFileURL: currentProjectURL
                )
            }
        } catch {
            showStatus(.init(kind: .error, message: "恢复录像失败：\(error.localizedDescription)"))
        }
    }

    private func resetSnapshotToolState(resumeTimelapseIfNeeded: Bool) {
        savedSnapshots.removeAll()
        cancelSnapshotPreviewPreparationTasks()
        snapshotCompareSession = nil
        if resumeTimelapseIfNeeded {
            resumeTimelapseAfterSnapshotCompareIfNeeded()
        } else {
            shouldResumeTimelapseAfterSnapshotCompare = false
        }
    }

    private func makeSavedCanvasSnapshot(
        from snapshot: LayerTextureSnapshot,
        includesPreviewImage: Bool
    ) -> CanvasSavedSnapshot {
        CanvasSavedSnapshot(
            id: UUID(),
            snapshot: snapshot,
            thumbnailImage: Self.snapshotImage(from: snapshot, maxDimension: Self.savedSnapshotThumbnailDimension),
            previewImage: includesPreviewImage
                ? Self.snapshotImage(from: snapshot, maxDimension: Self.snapshotComparePreviewDimension)
                : nil
        )
    }

    private func prepareSavedSnapshotPreviewIfNeeded(for id: UUID) {
        guard snapshotPreviewPreparationTasks[id] == nil else { return }
        guard let snapshot = savedSnapshot(with: id), snapshot.previewImage == nil else { return }

        let sourceSnapshot = snapshot.snapshot
        let previewDimension = Self.snapshotComparePreviewDimension
        snapshotPreviewPreparationTasks[id] = Task.detached(priority: .userInitiated) { [sourceSnapshot] in
            let image = WorkspaceViewModel.snapshotImage(
                from: sourceSnapshot,
                maxDimension: previewDimension
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let updatedIndex = self.savedSnapshots.firstIndex(where: { $0.id == id }) else {
                    self.snapshotPreviewPreparationTasks[id] = nil
                    return
                }

                var updatedSnapshots = self.savedSnapshots
                if updatedSnapshots[updatedIndex].previewImage == nil {
                    updatedSnapshots[updatedIndex].previewImage = image
                    self.savedSnapshots = updatedSnapshots
                }
                self.snapshotPreviewPreparationTasks[id] = nil
            }
        }
    }

    private func prepareFrozenSnapshotPreviewIfNeeded(for snapshot: CanvasSavedSnapshot) {
        guard snapshot.previewImage == nil else { return }

        frozenSnapshotPreviewPreparationTask?.cancel()
        let snapshotID = snapshot.id
        let sourceSnapshot = snapshot.snapshot
        let previewDimension = Self.snapshotComparePreviewDimension

        frozenSnapshotPreviewPreparationTask = Task.detached(priority: .userInitiated) { [sourceSnapshot] in
            let image = WorkspaceViewModel.snapshotImage(
                from: sourceSnapshot,
                maxDimension: previewDimension
            )

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let session = self.snapshotCompareSession else {
                    self.frozenSnapshotPreviewPreparationTask = nil
                    return
                }
                guard session.frozenCurrentSnapshot.id == snapshotID else {
                    self.frozenSnapshotPreviewPreparationTask = nil
                    return
                }

                var updatedSnapshot = session.frozenCurrentSnapshot
                if updatedSnapshot.previewImage == nil {
                    updatedSnapshot.previewImage = image
                    session.updateFrozenCurrentSnapshot(updatedSnapshot)
                }
                self.frozenSnapshotPreviewPreparationTask = nil
            }
        }
    }

    private func cancelSavedSnapshotPreviewPreparationTask(for id: UUID) {
        snapshotPreviewPreparationTasks[id]?.cancel()
        snapshotPreviewPreparationTasks[id] = nil
    }

    private func cancelSnapshotPreviewPreparationTasks() {
        for task in snapshotPreviewPreparationTasks.values {
            task.cancel()
        }
        snapshotPreviewPreparationTasks.removeAll()

        frozenSnapshotPreviewPreparationTask?.cancel()
        frozenSnapshotPreviewPreparationTask = nil
    }

    nonisolated private static func snapshotImage(
        from snapshot: LayerTextureSnapshot,
        maxDimension: Int?,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) -> CGImage? {
        let (targetWidth, targetHeight) = fittedSnapshotPreviewSize(
            width: snapshot.width,
            height: snapshot.height,
            maxDimension: maxDimension
        )
        let bytesPerPixel = 4
        let targetBytesPerRow = targetWidth * bytesPerPixel
        let sourceBytes = [UInt8](snapshot.pixelData)
        var rgba = [UInt8](repeating: 0, count: targetHeight * targetBytesPerRow)

        for targetY in 0..<targetHeight {
            let sourceY = Swift.min((targetY * snapshot.height) / targetHeight, snapshot.height - 1)
            for targetX in 0..<targetWidth {
                let sourceX = Swift.min((targetX * snapshot.width) / targetWidth, snapshot.width - 1)
                let sourceOffset = (sourceY * snapshot.bytesPerRow) + (sourceX * bytesPerPixel)
                let targetOffset = (targetY * targetBytesPerRow) + (targetX * bytesPerPixel)
                rgba[targetOffset] = sourceBytes[sourceOffset + 2]
                rgba[targetOffset + 1] = sourceBytes[sourceOffset + 1]
                rgba[targetOffset + 2] = sourceBytes[sourceOffset]
                rgba[targetOffset + 3] = sourceBytes[sourceOffset + 3]
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }

        return CGImage(
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: targetBytesPerRow,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    nonisolated private static func fittedSnapshotPreviewSize(
        width: Int,
        height: Int,
        maxDimension: Int?
    ) -> (width: Int, height: Int) {
        guard
            let maxDimension,
            maxDimension > 0,
            max(width, height) > maxDimension
        else {
            return (max(1, width), max(1, height))
        }

        let scale = Double(maxDimension) / Double(max(width, height))
        let targetWidth = max(1, Int((Double(width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(height) * scale).rounded()))
        return (targetWidth, targetHeight)
    }

    private static func normalizeLegacySelectionIfNeeded(in workspaceStore: WorkspaceStore) {
        let selection = workspaceStore.state.selection
        let hasLegacyCommittedSelection = selection.committedShape?.kind == .composite
        let hasLegacyInProgressSelection = selection.inProgressShape?.kind == .mask || selection.inProgressShape?.kind == .composite
        guard hasLegacyCommittedSelection || hasLegacyInProgressSelection else {
            return
        }

        workspaceStore.updateSelection { state in
            state = .empty
        }
    }

    private func checkpointHistoryIfPossible(
        operationKind: String = "generic.checkpoint",
        candidateChangedLayerIDs: [LayerID] = [],
        topologyOperation: Bool = false,
        additionalOperationKinds: [String] = [],
        captureMode: HistoryCaptureMode = .full
    ) {
        _ = flushBrushEditingBoundary(reason: "checkpointHistoryIfPossible")
        do {
            try bootstrap.historyController.captureCheckpoint(
                captureMode: captureMode,
                auditContext: HistoryEligibilityAuditContext(
                    operationKind: operationKind,
                    candidateChangedLayerIDs: candidateChangedLayerIDs,
                    candidateChangedLayerIDsKnown: !candidateChangedLayerIDs.isEmpty,
                    comparisonWorkspace: captureHistoryEligibilityComparisonWorkspace(),
                    topologyOperation: topologyOperation,
                    additionalOperationKinds: additionalOperationKinds
                )
            )
            hasUnsavedChanges = true
            canUndo = bootstrap.historyController.canUndo
            canRedo = bootstrap.historyController.canRedo
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    private func noteCanvasContentChanged() {
        hasUnsavedChanges = true
        documentChangeRevision &+= 1
        canvasContentRevision = documentChangeRevision
        syncTimelapseDocumentContext()
        timelapseRecorder.noteCanvasChanged(
            revision: documentChangeRevision,
            documentName: workspace.document.metadata.name,
            documentFileURL: currentProjectURL
        )
    }

    func captureWorkspaceSnapshot() throws -> WorkspaceHistoryEntry {
        _ = flushBrushEditingBoundary(reason: "captureWorkspaceSnapshot")
        return try bootstrap.historyController.captureCurrentEntry()
    }

    func restoreWorkspaceSnapshot(_ entry: WorkspaceHistoryEntry) throws {
        _ = flushBrushEditingBoundary(reason: "restoreWorkspaceSnapshot")
        try bootstrap.historyController.restoreExact(entry: entry)
        refresh()
    }

    func cloneWorkspaceForIdeation(
        from sourceWorkspace: WorkspaceState,
        sourceLayerSurfaceStore: StageOneLayerSurfaceStore
    ) {
        bootstrap.workspaceStore.replaceState(sourceWorkspace)
        bootstrap.layerSurfaceStore.reset()
        bootstrap.layerSurfaceStore.prepareTextures(
            for: sourceWorkspace.document,
            metal: bootstrap.metalContext
        )

        for layer in sourceWorkspace.document.layers {
            guard
                let sourceSurfaceID = sourceLayerSurfaceStore.surfaceID(for: layer.id),
                let sourceTexture = sourceLayerSurfaceStore.texture(for: sourceSurfaceID),
                let destinationSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
                let destinationTexture = bootstrap.layerSurfaceStore.texture(for: destinationSurfaceID)
            else {
                continue
            }

            bootstrap.layerSurfaceStore.copyTexture(
                from: sourceTexture,
                to: destinationTexture,
                metal: bootstrap.metalContext
            )
        }

        bootstrap.historyController.resetHistory()
        refresh()
    }

    @discardableResult
    func flushBrushEditingBoundary(reason: String) -> Bool {
        _ = reason
        let hadPendingWork = flushPendingBrushWorkAtEditingBoundaryIfNeeded()
        let hadPendingCommits = drainPendingBrushCommitsIfNeeded(resetLiveSession: true)
        return hadPendingWork || hadPendingCommits
    }

    @discardableResult
    private func flushPendingBrushWorkAtEditingBoundaryIfNeeded() -> Bool {
        guard bootstrap.strokeEngine.hasPendingBrushWork else {
            return false
        }
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法刷新待提交的笔刷内容"))
            return false
        }

        let didFlushLiveWork = flushPendingBrushWork(into: commandBuffer) != nil
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return didFlushLiveWork
    }

    private func drainPendingBrushCommitsIfNeeded(resetLiveSession: Bool) -> Bool {
        let hadPendingCommits = bootstrap.strokeEngine.hasPendingBrushCommitJobs

        if hadPendingCommits {
            do {
                try bootstrap.strokeEngine.drainPendingBrushCommitJobs { [self] job in
                    try captureBrushCommitCheckpoint(for: job)
                    hasUnsavedChanges = true
                }
                canUndo = bootstrap.historyController.canUndo
                canRedo = bootstrap.historyController.canRedo
                refresh()
            } catch {
                showStatus(.init(kind: .error, message: error.localizedDescription))
                return false
            }
        }

        if resetLiveSession {
            bootstrap.strokeEngine.resetBrushPipelineState()
        }

        return hadPendingCommits
    }

    private func isBrushLikeTool(_ tool: ToolKind) -> Bool {
        tool == .brush || tool == .eraser || tool == .smudge
    }

    private func captureBrushCommitCheckpoint(for job: BrushCommitJob) throws {
        let operationKind: String
        let captureMode: HistoryCaptureMode
        switch job.packets.last?.tool {
        case .brush:
            operationKind = "brush.commit"
            captureMode = .inPlaceChangedLayers([job.layerID])
        case .eraser:
            operationKind = "eraser.commit"
            captureMode = .inPlaceChangedLayers([job.layerID])
        case .smudge:
            operationKind = "smudge.commit"
            captureMode = .full
        default:
            operationKind = "brushLike.commit"
            captureMode = .full
        }
        try bootstrap.historyController.captureCheckpoint(
            captureMode: captureMode,
            auditContext: HistoryEligibilityAuditContext(
                operationKind: operationKind,
                candidateChangedLayerIDs: [job.layerID],
                candidateChangedLayerIDsKnown: true,
                comparisonWorkspace: captureHistoryEligibilityComparisonWorkspace()
            )
        )
    }

    func makeVisibleCompositeTexture() throws -> MTLTexture {
        let state = bootstrap.workspaceStore.state
        bootstrap.layerSurfaceStore.prepareTextures(
            for: state.document,
            metal: bootstrap.metalContext
        )

        let visibleLayers = state.document.layers.filter(\.isVisible)
        guard let firstLayer = visibleLayers.first,
              let firstSurfaceID = bootstrap.layerSurfaceStore.surfaceID(for: firstLayer.id),
              let firstTexture = bootstrap.layerSurfaceStore.texture(for: firstSurfaceID)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let textureEntries: [(texture: MTLTexture, opacity: Float)] = visibleLayers.compactMap { layer in
            guard
                let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layer.id),
                let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
            else {
                return nil
            }

            return (texture: texture, opacity: layer.opacity)
        }

        guard textureEntries.count == visibleLayers.count else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: firstTexture.pixelFormat,
            width: firstTexture.width,
            height: firstTexture.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        descriptor.storageMode = .private

        guard let targetTexture = bootstrap.metalContext.device.makeTexture(descriptor: descriptor) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = targetTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            throw CocoaError(.fileWriteUnknown)
        }
        bootstrap.canvasPresenter.encode(
            layerTextures: textureEntries,
            into: renderPassDescriptor,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return targetTexture
    }

    func makeVisibleCompositeSnapshot() throws -> LayerTextureSnapshot {
        let targetTexture = try makeVisibleCompositeTexture()
        return try bootstrap.textureSerializer.snapshot(texture: targetTexture)
    }

    func appendCompositeSnapshotAsNewLayer(
        _ snapshot: LayerTextureSnapshot,
        named layerName: String
    ) throws {
        checkpointHistoryIfPossible()
        var createdLayerID: LayerID?
        bootstrap.workspaceStore.updateDocument { document in
            createdLayerID = document.addLayer(named: layerName).id
        }

        let state = bootstrap.workspaceStore.state
        bootstrap.layerSurfaceStore.prepareTextures(
            for: state.document,
            metal: bootstrap.metalContext
        )

        guard
            let createdLayerID,
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: createdLayerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        try bootstrap.textureSerializer.restore(snapshot: snapshot, into: texture)
        refresh(invalidatedLayerIDs: [createdLayerID])
        noteCanvasContentChanged()
    }

    private func ideationDeltaSnapshot(
        variantTexture: MTLTexture,
        baseTexture: MTLTexture
    ) throws -> LayerTextureSnapshot? {
        guard
            variantTexture.width == baseTexture.width,
            variantTexture.height == baseTexture.height,
            variantTexture.pixelFormat == baseTexture.pixelFormat
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        guard let deltaTexture = bootstrap.layerSurfaceStore.makeTexture(
            width: variantTexture.width,
            height: variantTexture.height,
            pixelFormat: variantTexture.pixelFormat,
            metal: bootstrap.metalContext
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = deltaTexture
        renderPassDescriptor.colorAttachments[0].loadAction = .clear
        renderPassDescriptor.colorAttachments[0].storeAction = .store
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 0
        )
        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            throw CocoaError(.fileWriteUnknown)
        }
        bootstrap.visibleDeltaRenderer.encode(
            variantTexture: variantTexture,
            baseTexture: baseTexture,
            into: renderPassDescriptor,
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        let snapshot = try bootstrap.textureSerializer.snapshot(texture: deltaTexture)
        let bytes = [UInt8](snapshot.pixelData)
        let hasVisibleDelta = stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
        return hasVisibleDelta ? snapshot : nil
    }

    private func syncTimelapseDocumentContext() {
        timelapseRecorder.syncCurrentDocument(
            documentName: workspace.document.metadata.name,
            documentFileURL: currentProjectURL
        )
    }

    private func checkpointSelectionChangeIfPossible(previousCommittedShape: SelectionShape?) {
        var workspaceSnapshot = workspace
        workspaceSnapshot.selection.committedShape = previousCommittedShape
        workspaceSnapshot.selection.inProgressShape = nil
        workspaceSnapshot.selection.anchorPoint = nil
        workspaceSnapshot.selection.activeKind = nil

        do {
            try bootstrap.historyController.captureCheckpoint(workspaceOverride: workspaceSnapshot)
            canUndo = bootstrap.historyController.canUndo
            canRedo = bootstrap.historyController.canRedo
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
        }
    }

    private func premultipliedPixel(from color: RGBAColor) -> EditablePixel {
        let premultiplied = color.premultiplied
        return EditablePixel(
            blue: UInt8(clamping: Int((premultiplied.blue * 255).rounded())),
            green: UInt8(clamping: Int((premultiplied.green * 255).rounded())),
            red: UInt8(clamping: Int((premultiplied.red * 255).rounded())),
            alpha: UInt8(clamping: Int((premultiplied.alpha * 255).rounded()))
        )
    }

    private enum SelectionPixelOperation {
        case clear
        case fill(EditablePixel)
    }

    @discardableResult
    private func applyLassoFill(
        to selectionShape: SelectionShape,
        historyOperationKind: String,
        successMessage: String
    ) -> Bool {
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return false
        }

        let clampedSelection = selectionShape.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        guard !clampedSelection.isEmpty else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
        let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
        let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), texture.width)
        let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), texture.height)
        guard minX < maxX, minY < maxY else {
            showStatus(.init(kind: .info, message: "选区为空"))
            return false
        }

        let selectionMaskRegion = selectionMaskRegion(
            for: clampedSelection,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            originX: minX,
            originY: minY,
            width: maxX - minX,
            height: maxY - minY
        )
        let lassoFillCenter: CanvasPoint = {
            if let firstPoint = clampedSelection.pathPoints.first {
                return firstPoint
            }
            for component in clampedSelection.flattenedComponents() {
                if let firstPoint = component.shape.pathPoints.first {
                    return firstPoint
                }
            }
            return CanvasPoint(
                x: clampedSelection.bounds.origin.x + (clampedSelection.bounds.size.x * 0.5),
                y: clampedSelection.bounds.origin.y + (clampedSelection.bounds.size.y * 0.5)
            )
        }()

        checkpointHistoryIfPossible(
            operationKind: historyOperationKind,
            candidateChangedLayerIDs: [layerID],
            additionalOperationKinds: ["lassoFillRenderer"],
            captureMode: .inPlaceChangedLayers([layerID])
        )

        guard let commandBuffer = bootstrap.metalContext.commandQueue.makeCommandBuffer() else {
            showStatus(.init(kind: .error, message: "无法创建填充命令缓冲"))
            return false
        }

        let renderPassDescriptor = MTLRenderPassDescriptor()
        renderPassDescriptor.colorAttachments[0].texture = texture
        renderPassDescriptor.colorAttachments[0].loadAction = .load
        renderPassDescriptor.colorAttachments[0].storeAction = .store

        bootstrap.selectionFillRenderer.encode(
            into: renderPassDescriptor,
            commandBuffer: commandBuffer,
            canvasSize: CanvasSize(width: texture.width, height: texture.height),
            selectionMaskOriginX: selectionMaskRegion.originX,
            selectionMaskOriginY: selectionMaskRegion.originY,
            selectionMaskWidth: selectionMaskRegion.width,
            selectionMaskHeight: selectionMaskRegion.height,
            selectionMaskAlphaBytes: selectionMaskRegion.alphaBytes,
            fillCenter: lassoFillCenter,
            color: resolvedFillToolColor(from: workspace.toolSession.selectedColor),
            colorJitterAmount: workspace.toolSession.brush.colorJitterAmount
        )

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        layerThumbnailCache.removeValue(forKey: layerID)
        bootstrap.strokeEngine.resetBrushPipelineState()
        noteCanvasContentChanged()
        refresh(invalidatedLayerIDs: [layerID])
        showStatus(.init(kind: .success, message: successMessage))
        return true
    }

    @discardableResult
    private func applyPixelOperation(
        to selectionShape: SelectionShape,
        operation: SelectionPixelOperation,
        historyOperationKind: String,
        successMessage: String
    ) -> Bool {
        let totalStartNs = DispatchTime.now().uptimeNanoseconds
        guard let layerID = bootstrap.interactionController.activeEditableLayerID() else {
            showStatus(.init(kind: .info, message: "当前图层已锁定"))
            return false
        }

        guard
            let surfaceID = bootstrap.layerSurfaceStore.surfaceID(for: layerID),
            let texture = bootstrap.layerSurfaceStore.texture(for: surfaceID)
        else {
            showStatus(.init(kind: .error, message: "无法访问当前图层"))
            return false
        }

        let pixelOperationCaptureMode: HistoryCaptureMode
#if DEBUG
        pixelOperationCaptureMode = debugPixelOperationHistoryCaptureModeOverride ?? .inPlaceChangedLayers([layerID])
#else
        pixelOperationCaptureMode = .inPlaceChangedLayers([layerID])
#endif

        let historyCheckpointStartNs = DispatchTime.now().uptimeNanoseconds
        checkpointHistoryIfPossible(
            operationKind: historyOperationKind,
            candidateChangedLayerIDs: [layerID],
            additionalOperationKinds: ["applyPixelOperation"],
            captureMode: pixelOperationCaptureMode
        )
        let historyCheckpointMs = Double(DispatchTime.now().uptimeNanoseconds - historyCheckpointStartNs) / 1_000_000
        PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.historyCheckpoint", ms: historyCheckpointMs)

        do {
            let clampedSelection = selectionShape.clamped(
                to: CanvasSize(width: texture.width, height: texture.height)
            )
            let minX = max(Int(clampedSelection.bounds.minX.rounded(.down)), 0)
            let minY = max(Int(clampedSelection.bounds.minY.rounded(.down)), 0)
            let maxX = min(Int(clampedSelection.bounds.maxX.rounded(.up)), texture.width)
            let maxY = min(Int(clampedSelection.bounds.maxY.rounded(.up)), texture.height)

            guard minX < maxX, minY < maxY else {
                showStatus(.init(kind: .info, message: "选区为空"))
                return false
            }

            let maskPreparationStartNs = DispatchTime.now().uptimeNanoseconds
            let selectionMaskRegion = selectionMaskRegion(
                for: clampedSelection,
                canvasSize: CanvasSize(width: texture.width, height: texture.height),
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            let maskPreparationMs = Double(DispatchTime.now().uptimeNanoseconds - maskPreparationStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.maskPreparation", ms: maskPreparationMs)

            let snapshotStartNs = DispatchTime.now().uptimeNanoseconds
            let snapshot = try bootstrap.textureSerializer.snapshot(
                texture: texture,
                originX: minX,
                originY: minY,
                width: maxX - minX,
                height: maxY - minY
            )
            let snapshotMs = Double(DispatchTime.now().uptimeNanoseconds - snapshotStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.snapshot", ms: snapshotMs)
            var bytes = [UInt8](snapshot.pixelData)
            let bytesPerPixel = 4

            let mutateStartNs = DispatchTime.now().uptimeNanoseconds
            mutateSelectionPixels(
                bytes: &bytes,
                bytesPerRow: snapshot.bytesPerRow,
                bytesPerPixel: bytesPerPixel,
                selectionMaskRegion: selectionMaskRegion,
                width: snapshot.width,
                height: snapshot.height,
                operation: operation
            )
            let mutateMs = Double(DispatchTime.now().uptimeNanoseconds - mutateStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.pixelMutation", ms: mutateMs)

            let updatedSnapshot = LayerTextureSnapshot(
                width: snapshot.width,
                height: snapshot.height,
                bytesPerRow: snapshot.bytesPerRow,
                pixelData: Data(bytes)
            )
            let restoreStartNs = DispatchTime.now().uptimeNanoseconds
            try bootstrap.textureSerializer.restore(
                snapshot: updatedSnapshot,
                into: texture,
                destinationX: minX,
                destinationY: minY
            )
            let restoreMs = Double(DispatchTime.now().uptimeNanoseconds - restoreStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.restore", ms: restoreMs)
            let uiConfirmStartNs = DispatchTime.now().uptimeNanoseconds
            refresh()
            noteCanvasContentChanged()
            showStatus(.init(kind: .success, message: successMessage))
            let uiConfirmMs = Double(DispatchTime.now().uptimeNanoseconds - uiConfirmStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.uiConfirm", ms: uiConfirmMs)
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - totalStartNs) / 1_000_000
            PerformanceAuditStore.shared.recordDuration("WorkspaceViewModel.applyPixelOperation.total", ms: totalMs)
            return true
        } catch {
            showStatus(.init(kind: .error, message: error.localizedDescription))
            return false
        }
    }

    private func captureHistoryEligibilityComparisonWorkspace() -> WorkspaceState? {
        bootstrap.historyController.latestUndoWorkspaceForAudit
    }

    private func mutateSelectionPixels(
        bytes: inout [UInt8],
        bytesPerRow: Int,
        bytesPerPixel: Int,
        selectionMaskRegion: SelectionMaskRegion,
        width: Int,
        height: Int,
        operation: SelectionPixelOperation
    ) {
        guard
            width == selectionMaskRegion.width,
            height == selectionMaskRegion.height
        else {
            return
        }

        switch operation {
        case .clear:
            for localY in 0..<height {
                let maskRow = localY * selectionMaskRegion.width
                let byteRow = localY * bytesPerRow
                for localX in 0..<width {
                    guard selectionMaskRegion.alphaBytes[maskRow + localX] > 0 else { continue }
                    let index = byteRow + (localX * bytesPerPixel)
                    bytes[index] = 0
                    bytes[index + 1] = 0
                    bytes[index + 2] = 0
                    bytes[index + 3] = 0
                }
            }
        case .fill(let fillPixel):
            for localY in 0..<height {
                let maskRow = localY * selectionMaskRegion.width
                let byteRow = localY * bytesPerRow
                for localX in 0..<width {
                    guard selectionMaskRegion.alphaBytes[maskRow + localX] > 0 else { continue }
                    let index = byteRow + (localX * bytesPerPixel)
                    bytes[index] = fillPixel.blue
                    bytes[index + 1] = fillPixel.green
                    bytes[index + 2] = fillPixel.red
                    bytes[index + 3] = fillPixel.alpha
                }
            }
        }
    }

    private func resolvedGeneratorColor(from color: RGBAColor) -> RGBAColor {
        let luminance = (0.2126 * color.red) + (0.7152 * color.green) + (0.0722 * color.blue)
        if color.alpha < 0.05 || luminance > 0.94 {
            return .black
        }
        return color
    }

    nonisolated private func distanceBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func selectionCombineMode(
        for kind: SelectionShapeKind,
        modifiers: NSEvent.ModifierFlags
    ) -> SelectionCombineMode {
        guard kind == .lasso || kind == .rectangle || kind == .ellipse else {
            return .replace
        }
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        if normalized.contains(.option) {
            return .subtract
        }
        if normalized.contains(.shift) {
            return .add
        }
        return .replace
    }

    private func selectionGeometryOptions(
        modifiers: NSEvent.ModifierFlags,
        combineMode: SelectionCombineMode
    ) -> SelectionGeometryOptions {
        let normalized = modifiers.intersection(.deviceIndependentFlagsMask)
        guard combineMode == .replace else {
            return SelectionGeometryOptions(constrainsProportions: false, drawsFromCenter: false)
        }
        return SelectionGeometryOptions(
            constrainsProportions: normalized.contains(.shift),
            drawsFromCenter: normalized.contains(.control)
        )
    }

    private func selectionPreviewShape(
        kind: SelectionShapeKind,
        start: CanvasPoint,
        currentPoint: CanvasPoint,
        existingPoints: [CanvasPoint]?,
        modifiers: NSEvent.ModifierFlags,
        combineMode: SelectionCombineMode,
        precomputedBounds: CanvasRect? = nil
    ) -> SelectionShape? {
        switch kind {
        case .lasso:
            let points = existingPoints ?? [start]
            guard points.count >= 2 else { return nil }
            if points.count == 2 || points.count % 24 == 0 {
                let lastPoint = points.last ?? currentPoint
                let message = "[selectionPreviewShape] pointCount=\(points.count) current=(\(currentPoint.x),\(currentPoint.y)) previewLast=(\(lastPoint.x),\(lastPoint.y))"
                selectionTraceLogger.debug("\(message, privacy: .public)")
                emitSelectionTraceViewModel(message)
            }
            return SelectionShape(
                kind: .lasso,
                bounds: precomputedBounds ?? CanvasRect.bounding(points: points),
                pathPoints: points
            )
        case .rectangle, .ellipse:
            let bounds = selectionBounds(
                start: start,
                end: currentPoint,
                options: selectionGeometryOptions(
                    modifiers: modifiers,
                    combineMode: combineMode
                )
            )
            return SelectionShape(
                kind: kind,
                bounds: bounds,
                pathPoints: []
            )
        case .mask, .composite:
            return nil
        }
    }

    private func selectionInput(
        kind: SelectionShapeKind,
        currentStart: CanvasPoint,
        end: CanvasPoint,
        inProgressShape: SelectionShape?,
        modifiers: NSEvent.ModifierFlags,
        combineMode: SelectionCombineMode
    ) -> SelectionInputShape {
        switch kind {
        case .lasso:
            let rawPoints = activeLassoRawPoints.isEmpty
                ? (inProgressShape?.pathPoints ?? [currentStart])
                : activeLassoRawPoints
            let points = finalizedLassoPoints(
                rawPoints: rawPoints,
                closingTo: end
            )
            guard points.count >= 3 else {
                return SelectionInputShape(polygonShapes: [], preferredDisplayShape: nil)
            }
            let lastPoint = points.last ?? end
            let message = "[selectionInput] polygonPointCount=\(points.count) end=(\(end.x),\(end.y)) inputLast=(\(lastPoint.x),\(lastPoint.y))"
            selectionTraceLogger.debug("\(message, privacy: .public)")
            emitSelectionTraceViewModel(message)
            return SelectionInputShape(
                polygonShapes: [[points.map { CGPoint(x: $0.x, y: $0.y) }]],
                preferredDisplayShape: SelectionShape(
                    kind: .lasso,
                    bounds: CanvasRect.bounding(points: points),
                    pathPoints: points
                )
            )
        case .rectangle, .ellipse:
            let bounds = selectionBounds(
                start: currentStart,
                end: end,
                options: selectionGeometryOptions(
                    modifiers: modifiers,
                    combineMode: combineMode
                )
            )
            guard !bounds.isEmpty else {
                return SelectionInputShape(polygonShapes: [], preferredDisplayShape: nil)
            }

            let outlinePoints = selectionOutlinePoints(for: kind, bounds: bounds)
            return SelectionInputShape(
                polygonShapes: [outlinePoints],
                preferredDisplayShape: SelectionShape(
                    kind: kind,
                    bounds: bounds,
                    pathPoints: []
                )
            )
        case .mask, .composite:
            return SelectionInputShape(polygonShapes: [], preferredDisplayShape: nil)
        }
    }

    nonisolated private func committedSelectionShape(
        input: SelectionInputShape,
        canvasSize: CanvasSize,
        mode: SelectionCombineMode,
        baseShape: SelectionShape?
    ) -> SelectionShape? {
        let logger = Logger(subsystem: "ArtFlex", category: "SelectionTrace")
        let incomingMaskShape = selectionMaskShape(
            from: input.polygonShapes,
            canvasSize: canvasSize,
            preferredDisplayShape: input.preferredDisplayShape
        )
        let committedMessage = "[committedSelectionShape] incomingBoundsOrigin=(\(incomingMaskShape.bounds.origin.x),\(incomingMaskShape.bounds.origin.y)) incomingBoundsSize=(\(incomingMaskShape.bounds.size.x),\(incomingMaskShape.bounds.size.y)) mode=\(mode.rawValue)"
        logger.debug("\(committedMessage, privacy: .public)")
        emitSelectionTraceViewModel(committedMessage)
        guard let incomingMaskData = incomingMaskShape.maskData else {
            return mode == .replace ? nil : baseShape
        }

        let incomingBytes = [UInt8](incomingMaskData.alphaBytes)
        let resultBytes: [UInt8]
        switch mode {
        case .replace:
            resultBytes = incomingBytes
        case .add, .subtract:
            var mergedBytes = selectionMaskBytes(for: baseShape, canvasSize: canvasSize)
            applyIncomingMask(
                to: &mergedBytes,
                incomingBytes: incomingBytes,
                incomingBounds: incomingMaskShape.bounds,
                canvasSize: canvasSize,
                mode: mode
            )
            resultBytes = mergedBytes
        }

        let maskShape = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: resultBytes
        )
        guard !maskShape.bounds.isEmpty else {
            return nil
        }

        let displayComponents: [SelectionShapeComponent]
        if mode == .replace, let preferredDisplayShape = input.preferredDisplayShape {
            displayComponents = [
                SelectionShapeComponent(operation: .add, shape: preferredDisplayShape.clamped(to: canvasSize))
            ]
        } else {
            let baseDisplayComponents: [SelectionShapeComponent]
            if let baseShape {
                if baseShape.kind == .mask, !baseShape.components.isEmpty {
                    baseDisplayComponents = baseShape.components
                } else {
                    baseDisplayComponents = [
                        SelectionShapeComponent(operation: .add, shape: baseShape.clamped(to: canvasSize))
                    ]
                }
            } else {
                baseDisplayComponents = []
            }

            let incomingDisplayComponents: [SelectionShapeComponent]
            if let preferredDisplayShape = input.preferredDisplayShape {
                incomingDisplayComponents = [
                    SelectionShapeComponent(
                        operation: mode == .subtract ? .subtract : .add,
                        shape: preferredDisplayShape.clamped(to: canvasSize)
                    )
                ]
            } else {
                incomingDisplayComponents = []
            }

            displayComponents = baseDisplayComponents + incomingDisplayComponents
        }

        return SelectionShape(
            kind: .mask,
            bounds: maskShape.bounds,
            pathPoints: [],
            maskData: maskShape.maskData,
            components: displayComponents
        )
    }

    nonisolated private func finalizedLassoPoints(
        rawPoints: [CanvasPoint],
        closingTo endPoint: CanvasPoint
    ) -> [CanvasPoint] {
        smoothedClosedLassoPoints(rawPoints: rawPoints, closingTo: endPoint)
    }

    nonisolated private func interpolatedLassoPoints(from start: CanvasPoint, to end: CanvasPoint) -> [CanvasPoint] {
        let distance = distanceBetween(start, end)
        guard distance > 0 else { return [] }

        let step = 0.75
        let steps = max(Int(distance / step), 1)
        guard steps > 1 else { return [end] }

        return (1...steps).map { index in
            let t = Double(index) / Double(steps)
            return CanvasPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            )
        }
    }

    nonisolated private func deduplicatedLassoPoints(
        _ points: [CanvasPoint],
        minimumDistance: Double
    ) -> [CanvasPoint] {
        guard let first = points.first else { return [] }
        var output: [CanvasPoint] = [first]
        for point in points.dropFirst() {
            if distanceBetween(output[output.count - 1], point) >= minimumDistance {
                output.append(point)
            }
        }
        if let last = points.last, output.last != last {
            output.append(last)
        }
        return output
    }

    nonisolated private func makeSmoothedClosedLassoPath(points: [CanvasPoint]) -> CGMutablePath {
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }

        let lastMidpoint = midpointBetween(points[points.count - 1], points[0])
        path.move(to: CGPoint(x: lastMidpoint.x, y: lastMidpoint.y))

        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let midpoint = midpointBetween(current, next)
            path.addQuadCurve(
                to: CGPoint(x: midpoint.x, y: midpoint.y),
                control: CGPoint(x: current.x, y: current.y)
            )
        }

        path.closeSubpath()
        return path
    }

    nonisolated private func sampledPoints(
        from path: CGPath,
        sampleStep: Double
    ) -> [CanvasPoint] {
        var sampled: [CanvasPoint] = []
        var currentPoint = CGPoint.zero
        var subpathStart = CGPoint.zero

        path.applyWithBlock { elementPointer in
            let element = elementPointer.pointee
            switch element.type {
            case .moveToPoint:
                let point = element.points[0]
                currentPoint = point
                subpathStart = point
                sampled.append(CanvasPoint(x: point.x, y: point.y))
            case .addLineToPoint:
                let end = element.points[0]
                sampled.append(contentsOf: sampleLine(from: currentPoint, to: end, step: sampleStep))
                currentPoint = end
            case .addQuadCurveToPoint:
                let control = element.points[0]
                let end = element.points[1]
                sampled.append(
                    contentsOf: sampleQuadratic(
                        from: currentPoint,
                        control: control,
                        to: end,
                        step: sampleStep
                    )
                )
                currentPoint = end
            case .closeSubpath:
                sampled.append(contentsOf: sampleLine(from: currentPoint, to: subpathStart, step: sampleStep))
                currentPoint = subpathStart
            default:
                break
            }
        }

        return sampled
    }

    nonisolated private func sampleLine(
        from start: CGPoint,
        to end: CGPoint,
        step: Double
    ) -> [CanvasPoint] {
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(Int(ceil(distance / max(step, 0.5))), 1)
        return (1...steps).map { index in
            let t = Double(index) / Double(steps)
            return CanvasPoint(
                x: start.x + ((end.x - start.x) * t),
                y: start.y + ((end.y - start.y) * t)
            )
        }
    }

    nonisolated private func sampleQuadratic(
        from start: CGPoint,
        control: CGPoint,
        to end: CGPoint,
        step: Double
    ) -> [CanvasPoint] {
        let controlPolygonLength =
            hypot(control.x - start.x, control.y - start.y) +
            hypot(end.x - control.x, end.y - control.y)
        let steps = max(Int(ceil(controlPolygonLength / max(step, 0.5))), 2)

        return (1...steps).map { index in
            let t = Double(index) / Double(steps)
            let oneMinusT = 1 - t
            let x =
                (oneMinusT * oneMinusT * start.x) +
                (2 * oneMinusT * t * control.x) +
                (t * t * end.x)
            let y =
                (oneMinusT * oneMinusT * start.y) +
                (2 * oneMinusT * t * control.y) +
                (t * t * end.y)
            return CanvasPoint(x: x, y: y)
        }
    }

    nonisolated private func midpointBetween(_ lhs: CanvasPoint, _ rhs: CanvasPoint) -> CanvasPoint {
        CanvasPoint(
            x: (lhs.x + rhs.x) * 0.5,
            y: (lhs.y + rhs.y) * 0.5
        )
    }

    private func expandedBounds(_ current: CanvasRect?, including point: CanvasPoint) -> CanvasRect {
        guard let current else {
            return CanvasRect(origin: point, size: .init(x: 0, y: 0))
        }

        let minX = min(current.minX, point.x)
        let minY = min(current.minY, point.y)
        let maxX = max(current.maxX, point.x)
        let maxY = max(current.maxY, point.y)
        return CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: maxX - minX, y: maxY - minY)
        )
    }

    private func selectionBounds(
        start: CanvasPoint,
        end: CanvasPoint,
        options: SelectionGeometryOptions
    ) -> CanvasRect {
        var deltaX = end.x - start.x
        var deltaY = end.y - start.y

        if options.constrainsProportions {
            let side = max(abs(deltaX), abs(deltaY))
            deltaX = signedMagnitude(for: deltaX, fallback: deltaY) * side
            deltaY = signedMagnitude(for: deltaY, fallback: deltaX) * side
        }

        if options.drawsFromCenter {
            return CanvasRect(
                origin: CanvasPoint(
                    x: start.x - abs(deltaX),
                    y: start.y - abs(deltaY)
                ),
                size: CanvasPoint(
                    x: abs(deltaX) * 2,
                    y: abs(deltaY) * 2
                )
            )
        }

        return CanvasRect.fromPoints(
            start,
            CanvasPoint(x: start.x + deltaX, y: start.y + deltaY)
        )
    }

    private func signedMagnitude(for value: Double, fallback: Double) -> Double {
        if value > 0 { return 1 }
        if value < 0 { return -1 }
        if fallback > 0 { return 1 }
        if fallback < 0 { return -1 }
        return 1
    }

    nonisolated private func selectionOutlinePoints(
        for kind: SelectionShapeKind,
        bounds: CanvasRect
    ) -> SelectionPolygonShape {
        switch kind {
        case .rectangle:
            return [[
                CGPoint(x: bounds.minX, y: bounds.minY),
                CGPoint(x: bounds.minX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.maxY),
                CGPoint(x: bounds.maxX, y: bounds.minY)
            ]]
        case .ellipse:
            return [ellipsePolygonPoints(for: bounds)]
        case .lasso:
            return []
        case .mask, .composite:
            return []
        }
    }

    nonisolated private func ellipsePolygonPoints(for bounds: CanvasRect, segments: Int = 96) -> [CGPoint] {
        let radiusX = max(bounds.size.x / 2, 0.5)
        let radiusY = max(bounds.size.y / 2, 0.5)
        let centerX = bounds.origin.x + radiusX
        let centerY = bounds.origin.y + radiusY

        return (0..<segments).map { index in
            let angle = (Double(index) / Double(segments)) * .pi * 2
            return CGPoint(
                x: centerX + (cos(angle) * radiusX),
                y: centerY + (sin(angle) * radiusY)
            )
        }
    }

    nonisolated private func selectionMaskShape(
        from polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize,
        preferredDisplayShape: SelectionShape?
    ) -> SelectionShape {
        let components = polygonShapes.flatMap { polygonShape -> [SelectionShapeComponent] in
            polygonShape.compactMap { path in
                let clamped = path.map {
                    CanvasPoint(
                        x: min(max(Double($0.x), 0), Double(canvasSize.width)),
                        y: min(max(Double($0.y), 0), Double(canvasSize.height))
                    )
                }
                guard clamped.count >= 3 else { return nil }
                return SelectionShapeComponent(
                    operation: .add,
                    shape: SelectionShape(
                        kind: .lasso,
                        bounds: CanvasRect.bounding(points: clamped),
                        pathPoints: clamped
                    )
                )
            }
        }

        if components.isEmpty {
            return emptySelectionMaskShape(canvasSize: canvasSize)
        }

        let maskBytes = rasterizedSelectionMaskBytes(
            polygonShapes: polygonShapes,
            canvasSize: canvasSize
        )
        let maskShape = SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: maskBytes
        )
        let maskMessage = "[selectionMaskShape] polygonShapeCount=\(polygonShapes.count) maskBoundsOrigin=(\(maskShape.bounds.origin.x),\(maskShape.bounds.origin.y)) maskBoundsSize=(\(maskShape.bounds.size.x),\(maskShape.bounds.size.y)) preferredDisplayKind=\(preferredDisplayShape?.kind.rawValue ?? "nil")"
        Logger(subsystem: "ArtFlex", category: "SelectionTrace").debug("\(maskMessage, privacy: .public)")
        emitSelectionTraceViewModel(maskMessage)

        return SelectionShape(
            kind: .mask,
            bounds: maskShape.bounds,
            pathPoints: preferredDisplayShape?.pathPoints ?? [],
            maskData: maskShape.maskData,
            components: preferredDisplayShape.map {
                [SelectionShapeComponent(operation: .add, shape: $0.clamped(to: canvasSize))]
            } ?? []
        )
    }

    nonisolated private func emptySelectionMaskShape(canvasSize: CanvasSize) -> SelectionShape {
        SelectionShape.mask(
            canvasWidth: canvasSize.width,
            canvasHeight: canvasSize.height,
            alphaBytes: [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        )
    }

    nonisolated private func selectionMaskBytes(for shape: SelectionShape?, canvasSize: CanvasSize) -> [UInt8] {
        guard let shape else {
            return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        }

        if let maskData = shape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return [UInt8](maskData.alphaBytes)
        }

        let polygonShapes: [SelectionPolygonShape]
        switch shape.kind {
        case .lasso:
            guard shape.pathPoints.count >= 3 else {
                return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            }
            polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
        case .rectangle, .ellipse:
            polygonShapes = [selectionOutlinePoints(for: shape.kind, bounds: shape.bounds)]
        case .mask:
            if shape.components.count == 1,
               let component = shape.components.first,
               component.operation == .add {
                return selectionMaskBytes(for: component.shape, canvasSize: canvasSize)
            }
            if shape.pathPoints.count >= 3 {
                polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
            } else {
                return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            }
        case .composite:
            return [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        }

        return rasterizedSelectionMaskBytes(
            polygonShapes: polygonShapes,
            canvasSize: canvasSize
        )
    }

    nonisolated private func selectionMaskRegion(
        for shape: SelectionShape?,
        canvasSize: CanvasSize,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> SelectionMaskRegion {
        guard width > 0, height > 0 else {
            return SelectionMaskRegion(originX: originX, originY: originY, width: 0, height: 0, alphaBytes: [])
        }

        guard let shape else {
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: [UInt8](repeating: 0, count: width * height)
            )
        }

        if let maskData = shape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: maskRegionBytes(
                    from: maskData.alphaBytes,
                    canvasWidth: canvasSize.width,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            )
        }

        let polygonShapes: [SelectionPolygonShape]
        switch shape.kind {
        case .lasso:
            guard shape.pathPoints.count >= 3 else {
                return SelectionMaskRegion(
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    alphaBytes: [UInt8](repeating: 0, count: width * height)
                )
            }
            polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
        case .rectangle, .ellipse:
            polygonShapes = [selectionOutlinePoints(for: shape.kind, bounds: shape.bounds)]
        case .mask:
            if shape.components.count == 1,
               let component = shape.components.first,
               component.operation == .add {
                return selectionMaskRegion(
                    for: component.shape,
                    canvasSize: canvasSize,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            }
            if shape.pathPoints.count >= 3 {
                polygonShapes = [[shape.pathPoints.map { CGPoint(x: $0.x, y: $0.y) }]]
            } else {
                return SelectionMaskRegion(
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height,
                    alphaBytes: [UInt8](repeating: 0, count: width * height)
                )
            }
        case .composite:
            let fullMask = selectionMaskBytes(for: shape, canvasSize: canvasSize)
            return SelectionMaskRegion(
                originX: originX,
                originY: originY,
                width: width,
                height: height,
                alphaBytes: maskRegionBytes(
                    from: fullMask,
                    canvasWidth: canvasSize.width,
                    originX: originX,
                    originY: originY,
                    width: width,
                    height: height
                )
            )
        }

        return SelectionMaskRegion(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
            alphaBytes: rasterizedSelectionMaskRegionBytes(
                polygonShapes: polygonShapes,
                originX: originX,
                originY: originY,
                width: width,
                height: height
            )
        )
    }

    nonisolated private func maskRegionBytes(
        from alphaBytes: Data,
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBufferPointer { destinationBuffer in
            alphaBytes.withUnsafeBytes { sourceRawBuffer in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    nonisolated private func maskRegionBytes(
        from alphaBytes: [UInt8],
        canvasWidth: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        guard !result.isEmpty else { return result }

        result.withUnsafeMutableBufferPointer { destinationBuffer in
            alphaBytes.withUnsafeBufferPointer { sourceBuffer in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for row in 0..<height {
                    let sourceOffset = ((originY + row) * canvasWidth) + originX
                    let destinationOffset = row * width
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    nonisolated private func applyIncomingMask(
        to result: inout [UInt8],
        incomingBytes: [UInt8],
        incomingBounds: CanvasRect,
        canvasSize: CanvasSize,
        mode: SelectionCombineMode
    ) {
        let minX = max(Int(floor(incomingBounds.minX)), 0)
        let minY = max(Int(floor(incomingBounds.minY)), 0)
        let maxX = min(Int(ceil(incomingBounds.maxX)), canvasSize.width)
        let maxY = min(Int(ceil(incomingBounds.maxY)), canvasSize.height)
        guard minX < maxX, minY < maxY else { return }

        for y in minY..<maxY {
            let rowOffset = y * canvasSize.width
            for x in minX..<maxX {
                let index = rowOffset + x
                let incoming = incomingBytes[index]
                guard incoming > 0 else { continue }

                switch mode {
                case .replace:
                    result[index] = incoming
                case .add:
                    result[index] = max(result[index], incoming)
                case .subtract:
                    let kept = (Int(result[index]) * (255 - Int(incoming))) / 255
                    result[index] = UInt8(clamping: kept)
                }
            }
        }
    }

    nonisolated private func rasterizedSelectionMaskBytes(
        polygonShapes: [SelectionPolygonShape],
        canvasSize: CanvasSize
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
        guard !polygonShapes.isEmpty else { return result }

        let allPoints = polygonShapes.flatMap { polygonShape in
            polygonShape.flatMap { polygon in
                polygon.map { CanvasPoint(x: Double($0.x), y: Double($0.y)) }
            }
        }
        let bounds = CanvasRect.bounding(points: allPoints).clamped(to: canvasSize)
        let minX = max(Int(floor(bounds.minX)) - 1, 0)
        let minY = max(Int(floor(bounds.minY)) - 1, 0)
        let maxX = min(Int(ceil(bounds.maxX)) + 1, canvasSize.width)
        let maxY = min(Int(ceil(bounds.maxY)) + 1, canvasSize.height)
        let rasterMessage = "[rasterizedSelectionMaskBytes] allPointCount=\(allPoints.count) clampedBoundsOrigin=(\(bounds.origin.x),\(bounds.origin.y)) clampedBoundsSize=(\(bounds.size.x),\(bounds.size.y)) localRect=(\(minX),\(minY))-(\(maxX),\(maxY))"
        Logger(subsystem: "ArtFlex", category: "SelectionTrace").debug("\(rasterMessage, privacy: .public)")
        emitSelectionTraceViewModel(rasterMessage)
        guard minX < maxX, minY < maxY else { return result }

        let width = maxX - minX
        let height = maxY - minY
        let bytesPerRow = width
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var localBytes = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(
            data: &localBytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }
        context.translateBy(x: 0, y: Double(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for polygonShape in polygonShapes {
            for polygon in polygonShape {
                guard polygon.count >= 3 else { continue }
                let path = CGMutablePath()
                let localPoints = polygon.map {
                    CGPoint(x: $0.x - Double(minX), y: $0.y - Double(minY))
                }
                path.addLines(between: localPoints)
                path.closeSubpath()

                context.addPath(path)
                context.setBlendMode(.normal)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
            }
        }

        for localY in 0..<height {
            let destinationRow = (localY + minY) * canvasSize.width
            let sourceRow = localY * width
            for localX in 0..<width {
                result[destinationRow + localX + minX] = localBytes[sourceRow + localX]
            }
        }

        return result
    }

    nonisolated private func rasterizedSelectionMaskRegionBytes(
        polygonShapes: [SelectionPolygonShape],
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: width * height)
        guard !polygonShapes.isEmpty, width > 0, height > 0 else { return result }

        let padding = 1
        let paddedWidth = width + (padding * 2)
        let paddedHeight = height + (padding * 2)
        let bytesPerRow = paddedWidth
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var paddedBytes = [UInt8](repeating: 0, count: paddedWidth * paddedHeight)

        guard let context = CGContext(
            data: &paddedBytes,
            width: paddedWidth,
            height: paddedHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return result
        }

        context.translateBy(
            x: Double(-originX + padding),
            y: Double(originY - padding + paddedHeight)
        )
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)

        for polygonShape in polygonShapes {
            for polygon in polygonShape {
                guard polygon.count >= 3 else { continue }
                let path = CGMutablePath()
                path.addLines(between: polygon)
                path.closeSubpath()

                context.addPath(path)
                context.setBlendMode(.normal)
                context.setFillColor(gray: 1, alpha: 1)
                context.fillPath()
            }
        }

        result.withUnsafeMutableBufferPointer { destinationBuffer in
            paddedBytes.withUnsafeBufferPointer { sourceBuffer in
                guard
                    let destinationBase = destinationBuffer.baseAddress,
                    let sourceBase = sourceBuffer.baseAddress
                else {
                    return
                }

                for localY in 0..<height {
                    let destinationOffset = localY * width
                    let sourceOffset = ((localY + padding) * paddedWidth) + padding
                    UnsafeMutableRawPointer(destinationBase.advanced(by: destinationOffset))
                        .copyMemory(
                            from: UnsafeRawPointer(sourceBase.advanced(by: sourceOffset)),
                            byteCount: width
                        )
                }
            }
        }

        return result
    }

    private func applyGeneratorStroke(
        samples: [CanvasStrokeSample],
        layerID: LayerID,
        baseStroke: StrokeDescriptor
    ) -> Bool {
        switch workspace.generator.kind {
        case .automaticLines:
            let transformedStroke = makeAutomaticLineStroke(
                from: baseStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            )
            guard transformedStroke.points.count >= 2 else {
                return true
            }
            bootstrap.strokeEngine.applyStroke(transformedStroke, to: layerID)

            if let branchStroke = makeAutomaticLineBranchStroke(
                from: transformedStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            ) {
                bootstrap.strokeEngine.applyStroke(branchStroke, to: layerID)
            }
            for companionStroke in makeAutomaticLineCompanionStrokes(
                from: transformedStroke,
                settings: workspace.generator,
                session: &generatorStrokeSession
            ) {
                bootstrap.strokeEngine.applyStroke(companionStroke, to: layerID)
            }
            return true
        default:
            return false
        }
    }

    private func makeAutomaticLineStroke(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> StrokeDescriptor {
        guard !stroke.points.isEmpty else {
            return stroke
        }

        var random = session.random
        var lastBasePoint = session.lastBasePoint ?? stroke.points.first
        var lastOutputPoint = session.lastOutputPoint ?? stroke.points.first
        var driftOffset = session.driftOffset
        var angularVelocity = session.angularVelocity
        var fractureImpulse = session.fractureImpulse
        var fractureCountdown = session.fractureCountdown
        let brushSize = Double(max(stroke.brush.size, 1))
        let driftPower = pow(Double(settings.drift), 2.15)
        let densityPower = pow(Double(settings.density), 1.7)
        let branchPower = pow(Double(settings.branch), 1.85)
        let driftDistance = brushSize * (0.18 + (driftPower * 18.0))
        let lagDistance = brushSize * (0.04 + (driftPower * 6.4))
        let densityGain = 0.06 + (densityPower * 2.2)
        var curlPhase = random.double(in: 0...(Double.pi * 2))
        var curlVelocity = random.double(in: -0.35...0.35) * (0.18 + driftPower * 1.6)

        let transformedPoints = stroke.points.map { point -> StrokePoint in
            let base = CanvasPoint(x: point.x, y: point.y)
            let previousBase = CanvasPoint(x: lastBasePoint?.x ?? point.x, y: lastBasePoint?.y ?? point.y)
            let dx = base.x - previousBase.x
            let dy = base.y - previousBase.y
            let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
            let tangent = CanvasPoint(x: dx / distance, y: dy / distance)
            let normal = CanvasPoint(x: -tangent.y, y: tangent.x)

            angularVelocity += random.double(in: -1.85...1.85) * (0.18 + driftPower * 3.4)
            angularVelocity *= max(0.18, 0.62 - (driftPower * 0.34))

            if fractureCountdown <= 0,
               random.double(in: 0...1) < (0.04 + driftPower * 0.3 + branchPower * 0.22) {
                fractureImpulse = random.double(in: -1...1) * driftDistance * (1.2 + driftPower * 3.6)
                fractureCountdown = Int(random.double(in: 2...8))
            } else if fractureCountdown > 0 {
                fractureCountdown -= 1
                fractureImpulse *= 0.72
            } else {
                fractureImpulse *= 0.45
            }

            driftOffset =
                (driftOffset * max(0.08, 0.48 - densityGain * 0.16)) +
                (angularVelocity * driftDistance) +
                random.double(in: -1.8...1.8) * driftDistance * (0.22 + densityGain) +
                fractureImpulse

            curlVelocity += random.double(in: -0.28...0.28) * (0.14 + driftPower * 0.9 + branchPower * 0.45)
            curlVelocity *= 0.92
            curlPhase += curlVelocity

            let lagged = CanvasPoint(
                x: base.x - (tangent.x * lagDistance),
                y: base.y - (tangent.y * lagDistance)
            )
            let rebound = sin(Double(point.pressure) * .pi + angularVelocity * 0.5) * driftDistance * (0.12 + branchPower * 0.55)
            let forwardWhip = tangent.x * fractureImpulse * (0.12 + driftPower * 0.28)
            let forwardWhipY = tangent.y * fractureImpulse * (0.12 + driftPower * 0.28)
            let curlRadius = driftDistance * (0.08 + driftPower * 0.42 + branchPower * 0.16)
            let curlX = cos(curlPhase) * curlRadius
            let curlY = sin(curlPhase) * curlRadius
            let output = CanvasPoint(
                x: lagged.x + (normal.x * (driftOffset + rebound + curlY)) + forwardWhip + (tangent.x * curlX),
                y: lagged.y + (normal.y * (driftOffset + rebound + curlY)) + forwardWhipY + (tangent.y * curlX)
            )

            lastBasePoint = point
            lastOutputPoint = StrokePoint(x: output.x, y: output.y, pressure: point.pressure)
            return StrokePoint(x: output.x, y: output.y, pressure: point.pressure)
        }

        session.random = random
        session.lastBasePoint = lastBasePoint
        session.lastOutputPoint = lastOutputPoint
        session.driftOffset = driftOffset
        session.angularVelocity = angularVelocity
        session.fractureImpulse = fractureImpulse
        session.fractureCountdown = fractureCountdown

        return StrokeDescriptor(
            tool: stroke.tool,
            color: stroke.color,
            brush: stroke.brush,
            points: smoothStrokePoints(transformedPoints),
            selectionShape: stroke.selectionShape
        )
    }

    private func makeAutomaticLineBranchStroke(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> StrokeDescriptor? {
        guard stroke.points.count >= 4 else {
            return nil
        }

        var random = session.random
        let branchPower = pow(Double(settings.branch), 1.75)
        let driftPower = pow(Double(settings.drift), 1.5)
        let probability = min(0.96, 0.08 + (branchPower * 1.05))
        guard random.double(in: 0...1) < probability else {
            session.random = random
            return nil
        }

        let branchStartIndex = min(max(Int(Double(stroke.points.count - 2) * random.double(in: 0.3...0.75)), 1), stroke.points.count - 2)
        let branchBase = stroke.points[branchStartIndex]
        let nextPoint = stroke.points[branchStartIndex + 1]
        let dx = nextPoint.x - branchBase.x
        let dy = nextPoint.y - branchBase.y
        let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
        let tangent = CanvasPoint(x: dx / distance, y: dy / distance)
        let angle = random.double(in: 0.9...2.4) * (random.double(in: 0...1) > 0.5 ? 1 : -1)
        let rotated = CanvasPoint(
            x: (tangent.x * cos(angle)) - (tangent.y * sin(angle)),
            y: (tangent.x * sin(angle)) + (tangent.y * cos(angle))
        )

        let branchPointCount = max(6, Int(Double(stroke.points.count) * random.double(in: 0.6...1.25)))
        let step = Double(max(stroke.brush.size, 1)) * random.double(in: 1.8...3.8)
        var points: [StrokePoint] = [branchBase]
        var current = CanvasPoint(x: branchBase.x, y: branchBase.y)
        for index in 0..<branchPointCount {
            let drift = random.double(in: -2.4...2.4) * (0.15 + driftPower * 1.8) * Double(max(stroke.brush.size, 1))
            let curl = sin(Double(index) * random.double(in: 0.45...1.1)) * Double(max(stroke.brush.size, 1)) * (0.12 + branchPower * 0.95)
            current = CanvasPoint(
                x: current.x + (rotated.x * step) - (rotated.y * drift * 0.55) + (tangent.x * curl),
                y: current.y + (rotated.y * step) + (rotated.x * drift * 0.55) + (tangent.y * curl)
            )
            let taperedPressure = max(0.18, branchBase.pressure * Float(1 - (Double(index + 1) / Double(branchPointCount + 1)) * 0.55))
            points.append(StrokePoint(x: current.x, y: current.y, pressure: taperedPressure))
        }

        session.random = random
        return StrokeDescriptor(
            tool: stroke.tool,
            color: stroke.color.withAlpha(stroke.color.alpha * Float(0.58 + (settings.branch * 0.18))),
            brush: stroke.brush,
            points: smoothStrokePoints(points),
            selectionShape: stroke.selectionShape
        )
    }

    private func makeAutomaticLineCompanionStrokes(
        from stroke: StrokeDescriptor,
        settings: GeneratorSettings,
        session: inout GeneratorStrokeSessionState
    ) -> [StrokeDescriptor] {
        guard stroke.points.count >= 3 else {
            return []
        }

        var random = session.random
        let densityPower = pow(Double(settings.density), 1.8)
        let driftPower = pow(Double(settings.drift), 1.5)
        let branchPower = pow(Double(settings.branch), 1.5)
        let extraStrokeCount = min(5, Int((densityPower * 5.6).rounded(.down)))
        guard extraStrokeCount > 0 else {
            session.random = random
            return []
        }

        let brushSize = Double(max(stroke.brush.size, 1))
        let output: [StrokeDescriptor] = (0..<extraStrokeCount).map { index in
            let lateralSign = index.isMultiple(of: 2) ? 1.0 : -1.0
            let fanAngle = random.double(in: 0.45...1.85) * lateralSign
            let lateralOffset = brushSize * random.double(in: 4.0...15.0) * (0.18 + driftPower * 1.8) * lateralSign
            let forwardLag = brushSize * random.double(in: 0.8...3.4) * (0.12 + driftPower * 0.9)
            let points: [StrokePoint] = stroke.points.enumerated().map { pointIndex, point in
                let previous = pointIndex > 0 ? stroke.points[pointIndex - 1] : point
                let dx = point.x - previous.x
                let dy = point.y - previous.y
                let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
                let tangent = CanvasPoint(x: dx / distance, y: dy / distance)
                let normal = CanvasPoint(x: -tangent.y, y: tangent.x)
                let rotated = CanvasPoint(
                    x: (normal.x * cos(fanAngle)) - (normal.y * sin(fanAngle)),
                    y: (normal.x * sin(fanAngle)) + (normal.y * cos(fanAngle))
                )
                let noise = random.double(in: -2.8...2.8) * brushSize * (0.05 + branchPower * 0.8)
                let hook = sin(Double(pointIndex) * random.double(in: 0.35...0.9)) * brushSize * (0.1 + branchPower * 1.1)
                return StrokePoint(
                    x: point.x + (rotated.x * (lateralOffset + noise)) - (tangent.x * (forwardLag - hook)),
                    y: point.y + (rotated.y * (lateralOffset + noise)) - (tangent.y * (forwardLag - hook)),
                    pressure: max(0.12, point.pressure * Float(0.55 + random.double(in: 0.05...0.18)))
                )
            }

            return StrokeDescriptor(
                tool: stroke.tool,
                color: stroke.color.withAlpha(stroke.color.alpha * Float(0.28 + random.double(in: 0.08...0.18))),
                brush: stroke.brush,
                points: smoothStrokePoints(points),
                selectionShape: stroke.selectionShape
            )
        }

        session.random = random
        return output
    }

    private func smoothStrokePoints(_ points: [StrokePoint]) -> [StrokePoint] {
        guard points.count >= 3 else { return points }

        var output: [StrokePoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = (index + 2) < points.count ? points[index + 2] : p2
            let distance = max(hypot(p2.x - p1.x, p2.y - p1.y), 0.0001)
            let subdivisions = max(Int(distance / 1.8), 4)

            for step in 1...subdivisions {
                let t = Double(step) / Double(subdivisions)
                let t2 = t * t
                let t3 = t2 * t
                let x = 0.5 * (
                    (2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    ((2 * p0.x) - (5 * p1.x) + (4 * p2.x) - p3.x) * t2 +
                    (-p0.x + (3 * p1.x) - (3 * p2.x) + p3.x) * t3
                )
                let y = 0.5 * (
                    (2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    ((2 * p0.y) - (5 * p1.y) + (4 * p2.y) - p3.y) * t2 +
                    (-p0.y + (3 * p1.y) - (3 * p2.y) + p3.y) * t3
                )
                let pressure = Float(
                    0.5 * (
                        (2 * Double(p1.pressure)) +
                        (-Double(p0.pressure) + Double(p2.pressure)) * t +
                        ((2 * Double(p0.pressure)) - (5 * Double(p1.pressure)) + (4 * Double(p2.pressure)) - Double(p3.pressure)) * t2 +
                        (-Double(p0.pressure) + (3 * Double(p1.pressure)) - (3 * Double(p2.pressure)) + Double(p3.pressure)) * t3
                    )
                )
                output.append(
                    StrokePoint(
                        x: x,
                        y: y,
                        pressure: min(max(pressure, 0.05), 1)
                    )
                )
            }
        }
        return output
    }

    private func applyAutomaticLineGenerator(
        to bytes: inout [UInt8],
        snapshotWidth: Int,
        snapshotHeight: Int,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        targetShape: SelectionShape?,
        color: RGBAColor,
        settings: GeneratorSettings
    ) {
        let bounds = targetShape?.bounds ?? CanvasRect(
            origin: CanvasPoint(x: Double(originX), y: Double(originY)),
            size: CanvasPoint(x: Double(snapshotWidth), y: Double(snapshotHeight))
        )
        let boundedWidth = max(bounds.maxX - bounds.minX, 1)
        let boundedHeight = max(bounds.maxY - bounds.minY, 1)
        let area = boundedWidth * boundedHeight
        let baseCount = Int(sqrt(area) * Double(0.18 + (settings.density * 0.45)))
        let strokeCount = min(max(baseCount, 8), 180)
        var random = GeneratorRandom()

        for _ in 0..<strokeCount {
            guard let start = randomPoint(in: bounds, shape: targetShape, random: &random) else {
                continue
            }

            let normalizedLength = 0.18 + (settings.density * 0.52) + random.float(in: -0.08...0.12)
            let length = Float(max(min(boundedWidth, boundedHeight), 1)) * normalizedLength
            let segmentCount = max(6, Int(length / 10))
            let baseAngle = random.float(in: 0...(Float.pi * 2))
            let strokeWidth = random.float(in: 1.2...3.8) * (0.7 + settings.density * 0.8)
            let opacity = min(max(0.18 + random.float(in: 0...0.32), 0.1), 0.55) * settings.opacity
            let points = makeAutomaticLinePoints(
                start: start,
                length: length,
                segmentCount: segmentCount,
                baseAngle: baseAngle,
                drift: settings.drift,
                random: &random
            )
            drawPolyline(
                points,
                width: strokeWidth,
                opacity: opacity,
                color: color,
                bytes: &bytes,
                snapshotWidth: snapshotWidth,
                snapshotHeight: snapshotHeight,
                bytesPerRow: bytesPerRow,
                originX: originX,
                originY: originY,
                targetShape: targetShape
            )

            let branchProbability = 0.06 + (settings.branch * 0.32)
            if points.count > 5 && random.float(in: 0...1) < branchProbability {
                let branchIndex = min(max(Int(Float(points.count - 2) * random.float(in: 0.28...0.82)), 1), points.count - 2)
                let branchStart = points[branchIndex]
                let offsetAngle = random.float(in: -1.45...1.45)
                let branchPoints = makeAutomaticLinePoints(
                    start: branchStart,
                    length: length * random.float(in: 0.28...0.6),
                    segmentCount: max(4, segmentCount / 2),
                    baseAngle: baseAngle + offsetAngle,
                    drift: min(max(settings.drift + 0.18, 0), 1),
                    random: &random
                )
                drawPolyline(
                    branchPoints,
                    width: strokeWidth * random.float(in: 0.42...0.72),
                    opacity: opacity * random.float(in: 0.65...0.92),
                    color: color,
                    bytes: &bytes,
                    snapshotWidth: snapshotWidth,
                    snapshotHeight: snapshotHeight,
                    bytesPerRow: bytesPerRow,
                    originX: originX,
                    originY: originY,
                    targetShape: targetShape
                )
            }
        }
    }

    private func randomPoint(
        in bounds: CanvasRect,
        shape: SelectionShape?,
        random: inout GeneratorRandom
    ) -> CanvasPoint? {
        for _ in 0..<32 {
            let point = CanvasPoint(
                x: random.double(in: bounds.minX...bounds.maxX),
                y: random.double(in: bounds.minY...bounds.maxY)
            )
            if shape?.contains(point) ?? true {
                return point
            }
        }
        return nil
    }

    private func makeAutomaticLinePoints(
        start: CanvasPoint,
        length: Float,
        segmentCount: Int,
        baseAngle: Float,
        drift: Float,
        random: inout GeneratorRandom
    ) -> [CanvasPoint] {
        var points = [start]
        var current = start
        var angle = baseAngle
        var angularVelocity: Float = 0
        var orbitPhase = random.float(in: 0...(Float.pi * 2))
        var orbitVelocity = random.float(in: -0.45...0.45) * (0.18 + drift * 1.4)
        let stepLength = max(length / Float(max(segmentCount, 1)), 2)
        let driftStrength = 0.08 + (drift * 0.42)

        for _ in 0..<segmentCount {
            angularVelocity += random.float(in: -driftStrength...driftStrength)
            angularVelocity *= 0.88 - (drift * 0.18)
            orbitVelocity += random.float(in: -0.22...0.22) * (0.12 + drift * 0.95)
            orbitVelocity *= 0.94
            orbitPhase += orbitVelocity
            angle += angularVelocity + random.float(in: -(driftStrength * 0.75)...(driftStrength * 0.75))

            let orbitRadius = stepLength * (0.12 + drift * 1.1)
            let next = CanvasPoint(
                x: current.x + Double(cos(angle) * stepLength) + Double(cos(orbitPhase + angle * 0.4) * orbitRadius),
                y: current.y + Double(sin(angle) * stepLength) + Double(sin(orbitPhase + angle * 0.4) * orbitRadius)
            )
            points.append(next)
            current = next
        }

        return points
    }

    private func drawPolyline(
        _ points: [CanvasPoint],
        width: Float,
        opacity: Float,
        color: RGBAColor,
        bytes: inout [UInt8],
        snapshotWidth: Int,
        snapshotHeight: Int,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        targetShape: SelectionShape?
    ) {
        guard points.count >= 2 else { return }
        let smoothedPoints = smoothGeneratorPath(points)
        guard smoothedPoints.count >= 2 else { return }

        for index in 1..<smoothedPoints.count {
            let start = smoothedPoints[index - 1]
            let end = smoothedPoints[index]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let distance = max(sqrt((dx * dx) + (dy * dy)), 0.0001)
            let steps = max(Int(distance / Double(max(width * 0.22, 0.35))), 1)

            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let point = CanvasPoint(
                    x: start.x + (dx * t),
                    y: start.y + (dy * t)
                )
                let taper = Float(1 - abs((t * 2) - 1))
                let radius = width * (0.7 + (taper * 0.35))
                stampSoftDisc(
                    at: point,
                    radius: radius,
                    opacity: opacity * (0.72 + (taper * 0.28)),
                    color: color,
                    bytes: &bytes,
                    snapshotWidth: snapshotWidth,
                    snapshotHeight: snapshotHeight,
                    bytesPerRow: bytesPerRow,
                    originX: originX,
                    originY: originY,
                    targetShape: targetShape
                )
            }
        }
    }

    private func smoothGeneratorPath(_ points: [CanvasPoint]) -> [CanvasPoint] {
        guard points.count >= 3 else { return points }

        var output: [CanvasPoint] = [points[0]]
        for index in 0..<(points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = (index + 2) < points.count ? points[index + 2] : p2
            let distance = max(hypot(p2.x - p1.x, p2.y - p1.y), 0.0001)
            let subdivisions = max(Int(distance / 2.2), 3)

            for step in 1...subdivisions {
                let t = Double(step) / Double(subdivisions)
                let t2 = t * t
                let t3 = t2 * t
                let x = 0.5 * (
                    (2 * p1.x) +
                    (-p0.x + p2.x) * t +
                    ((2 * p0.x) - (5 * p1.x) + (4 * p2.x) - p3.x) * t2 +
                    (-p0.x + (3 * p1.x) - (3 * p2.x) + p3.x) * t3
                )
                let y = 0.5 * (
                    (2 * p1.y) +
                    (-p0.y + p2.y) * t +
                    ((2 * p0.y) - (5 * p1.y) + (4 * p2.y) - p3.y) * t2 +
                    (-p0.y + (3 * p1.y) - (3 * p2.y) + p3.y) * t3
                )
                output.append(CanvasPoint(x: x, y: y))
            }
        }
        return output
    }

    private func stampSoftDisc(
        at center: CanvasPoint,
        radius: Float,
        opacity: Float,
        color: RGBAColor,
        bytes: inout [UInt8],
        snapshotWidth: Int,
        snapshotHeight: Int,
        bytesPerRow: Int,
        originX: Int,
        originY: Int,
        targetShape: SelectionShape?
    ) {
        let expandedRadius = max(radius, 0.8)
        let minX = max(Int(floor(center.x - Double(expandedRadius))) - originX, 0)
        let maxX = min(Int(ceil(center.x + Double(expandedRadius))) - originX, snapshotWidth - 1)
        let minY = max(Int(floor(center.y - Double(expandedRadius))) - originY, 0)
        let maxY = min(Int(ceil(center.y + Double(expandedRadius))) - originY, snapshotHeight - 1)

        guard minX <= maxX, minY <= maxY else { return }

        for localY in minY...maxY {
            for localX in minX...maxX {
                let globalPoint = CanvasPoint(
                    x: Double(originX + localX) + 0.5,
                    y: Double(originY + localY) + 0.5
                )
                if let targetShape, !targetShape.contains(globalPoint) {
                    continue
                }

                let distanceX = Float(globalPoint.x - center.x)
                let distanceY = Float(globalPoint.y - center.y)
                let distance = sqrt((distanceX * distanceX) + (distanceY * distanceY))
                if distance > expandedRadius {
                    continue
                }

                let falloff = pow(max(0, 1 - (distance / expandedRadius)), 1.7)
                let localOpacity = min(max(opacity * falloff, 0), 1)
                if localOpacity <= 0.001 {
                    continue
                }

                let index = (localY * bytesPerRow) + (localX * 4)
                let destination = LinearPremultipliedColor(
                    bgraBlue: bytes[index],
                    green: bytes[index + 1],
                    red: bytes[index + 2],
                    alpha: bytes[index + 3]
                )
                let source = LinearPremultipliedColor(
                    srgbPremultiplied: color.withAlpha(color.alpha * localOpacity).premultiplied
                )
                let output = source.composited(over: destination).bgra8PremultipliedBytes
                bytes[index] = output.blue
                bytes[index + 1] = output.green
                bytes[index + 2] = output.red
                bytes[index + 3] = output.alpha
            }
        }
    }

    private func applyPickerColorFromPanel() {
        let color = ColorBlocksEngine.pickerColor(from: bootstrap.workspaceStore.state.colorPanel)
        bootstrap.workspaceStore.updateToolSession { session in
            session.selectedColor = color
        }
        refreshColorPanelOnly(includeSelectedColor: true)
    }

    private func refreshColorPanelOnly(includeSelectedColor: Bool = false) {
        let state = bootstrap.workspaceStore.state
        var updated = workspace
        updated.colorPanel = state.colorPanel
        if includeSelectedColor {
            updated.toolSession.selectedColor = state.toolSession.selectedColor
        }
        workspace = updated
        colorPanelProxy.colorPanel = state.colorPanel
        if includeSelectedColor {
            colorPanelProxy.selectedColor = state.toolSession.selectedColor
        }
    }

    @MainActor
    final class ColorPanelProxy: ObservableObject {
        @Published var colorPanel: ColorPanelState = .stageOneDefault
        @Published var selectedColor: RGBAColor = .init(red: 0, green: 0, blue: 0, alpha: 1)
    }

    private(set) lazy var colorPanelProxy: ColorPanelProxy = {
        let proxy = ColorPanelProxy()
        proxy.colorPanel = workspace.colorPanel
        proxy.selectedColor = workspace.toolSession.selectedColor
        return proxy
    }()

    // 选区 overlay 专用代理
    // CanvasContainerView 里的 SelectionOverlay 只订阅它
    // 选区拖动时只有 overlay 重绘，MetalCanvasHost 完全不受影响
    final class SelectionOverlayProxy: ObservableObject {
        @Published var displayShape: SelectionShape?
        @Published var committedShape: SelectionShape?
        @Published var inProgressShape: SelectionShape?
        @Published var activeCombineMode: SelectionCombineMode = .replace
        @Published var isApplyingTransformCommit: Bool = false
        @Published var isTransformingSelection: Bool = false
        @Published var activeTool: ToolKind = .brush
        @Published var transformPreviewOffset: CanvasPoint = .init(x: 0, y: 0)
        @Published var selectionMovePreviewOffset: CanvasPoint = .init(x: 0, y: 0)
        @Published var hidesImplicitFreeTransformSelectionOverlay: Bool = false
        @Published var isFreeTransformDragging: Bool = false
        @Published var activeFreeTransformInteractionMode: FreeTransformInteractionMode?
    }

    private(set) lazy var selectionOverlayProxy: SelectionOverlayProxy = {
        SelectionOverlayProxy()
    }()

    // 选区变化时同步到 proxy（由 refreshLightweight 调用）
    private func syncSelectionOverlayProxy() {
        let state = bootstrap.workspaceStore.state
        let sel = state.selection
        selectionOverlayProxy.displayShape = sel.displayShape
        selectionOverlayProxy.committedShape = sel.committedShape
        selectionOverlayProxy.inProgressShape = sel.inProgressShape
        selectionOverlayProxy.activeCombineMode = sel.activeCombineMode
        selectionOverlayProxy.isApplyingTransformCommit = isApplyingTransformCommit
        selectionOverlayProxy.isTransformingSelection = isTransformingSelection
        selectionOverlayProxy.activeTool = state.toolSession.activeTool
        selectionOverlayProxy.transformPreviewOffset = transformPreviewOffset
        selectionOverlayProxy.selectionMovePreviewOffset = selectionMovePreviewOffset
        selectionOverlayProxy.hidesImplicitFreeTransformSelectionOverlay = hidesImplicitFreeTransformSelectionOverlay
        selectionOverlayProxy.isFreeTransformDragging = isFreeTransformDragging
        selectionOverlayProxy.activeFreeTransformInteractionMode = activeFreeTransformInteractionMode
    }

}

private struct EditablePixel {
    var blue: UInt8
    var green: UInt8
    var red: UInt8
    var alpha: UInt8
}

private struct SelectionMaskRegion {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
    var alphaBytes: [UInt8]
}

private struct GeneratorStrokeSessionState {
    var lastBasePoint: StrokePoint?
    var lastOutputPoint: StrokePoint?
    var driftOffset: Double = 0
    var angularVelocity: Double = 0
    var fractureImpulse: Double = 0
    var fractureCountdown: Int = 0
    var random = GeneratorRandom()
}

private struct DeferredGradientDrag {
    var tool: ToolKind
    var points: [CanvasPoint]
    var modifiers: NSEvent.ModifierFlags
    var didEnd: Bool
}

private enum DeferredGradientAction {
    case toolSwitch(ToolKind)
    case gradientDrag(DeferredGradientDrag)
}

enum StraightLinePhase: Sendable {
    case idle
    case pickedA
}

struct StraightLinePreview: Sendable {
    let pointA: CanvasPoint
    let pointB: CanvasPoint
}

struct StraightLineInteractionState: Sendable {
    var phase: StraightLinePhase = .idle
    var pointA: CanvasPoint?
    var hoverPoint: CanvasPoint?

    var preview: StraightLinePreview? {
        guard phase == .pickedA, let pointA, let hoverPoint else { return nil }
        return StraightLinePreview(pointA: pointA, pointB: hoverPoint)
    }
}

enum PolygonSelectionPhase: Sendable {
    case idle
    case building
}

struct PolygonSelectionPreview: Sendable {
    let vertices: [CanvasPoint]
    let hoverPoint: CanvasPoint?
    let closesToFirst: Bool
}

struct PolygonSelectionInteractionState: Sendable {
    var phase: PolygonSelectionPhase = .idle
    var vertices: [CanvasPoint] = []
    var hoverPoint: CanvasPoint?
    var combineMode: SelectionCombineMode = .replace

    var preview: PolygonSelectionPreview? {
        guard phase == .building, !vertices.isEmpty else { return nil }
        let closesToFirst: Bool
        if let hoverPoint, let first = vertices.first, vertices.count >= 3 {
            closesToFirst = hypot(hoverPoint.x - first.x, hoverPoint.y - first.y) <= 12
        } else {
            closesToFirst = false
        }
        return PolygonSelectionPreview(
            vertices: vertices,
            hoverPoint: hoverPoint,
            closesToFirst: closesToFirst
        )
    }
}

private struct GeneratorRandom {
    private var state: UInt64 = {
        let now = UInt64(Date().timeIntervalSinceReferenceDate.bitPattern)
        return now ^ 0x9E3779B97F4A7C15
    }()

    mutating func float(in range: ClosedRange<Float>) -> Float {
        let unit = Float(nextUnit())
        return range.lowerBound + ((range.upperBound - range.lowerBound) * unit)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = nextUnit()
        return range.lowerBound + ((range.upperBound - range.lowerBound) * unit)
    }

    private mutating func nextUnit() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let mantissa = state >> 11
        return Double(mantissa) / Double(1 << 53)
    }
}

/// non-Sendable 타입을 DispatchQueue 클로저에서 캡처하기 위한 래퍼
private final class WorkspaceUncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private func bgraToRGBA(_ bytes: [UInt8]) -> [UInt8] {
    guard !bytes.isEmpty else { return bytes }
    var rgba = bytes
    for index in stride(from: 0, to: bytes.count, by: 4) {
        rgba[index] = bytes[index + 2]
        rgba[index + 1] = bytes[index + 1]
        rgba[index + 2] = bytes[index]
        rgba[index + 3] = bytes[index + 3]
    }
    return rgba
}

private func rgbaToBGRA(_ bytes: [UInt8]) -> [UInt8] {
    guard !bytes.isEmpty else { return bytes }
    var bgra = bytes
    for index in stride(from: 0, to: bytes.count, by: 4) {
        bgra[index] = bytes[index + 2]
        bgra[index + 1] = bytes[index + 1]
        bgra[index + 2] = bytes[index]
        bgra[index + 3] = bytes[index + 3]
    }
    return bgra
}

private func rgbaImage(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    rgbaBytes: [UInt8]
) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(rgbaBytes) as CFData) else {
        return nil
    }
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

private func makeRGBAContext(
    width: Int,
    height: Int,
    bytesPerRow: Int,
    bytes: UnsafeMutableRawPointer
) -> CGContext? {
    CGContext(
        data: bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue
    )
}

/// 픽셀 이동 계산 - top-level이라 @MainActor 제약 없이 백그라운드 스레드에서 호출 가능
private func shiftLayerPixels(
    snapshot: LayerTextureSnapshot,
    selection: SelectionShape,
    dx: Int,
    dy: Int
) -> LayerTextureSnapshot {
    let w = snapshot.width; let h = snapshot.height
    let bpr = snapshot.bytesPerRow; let bpp = 4
    let src = [UInt8](snapshot.pixelData)
    var dst = src

    let minX = max(Int(selection.bounds.minX.rounded(.down)), 0)
    let minY = max(Int(selection.bounds.minY.rounded(.down)), 0)
    let maxX = min(Int(selection.bounds.maxX.rounded(.up)), w)
    let maxY = min(Int(selection.bounds.maxY.rounded(.up)), h)

    if selection.kind == .rectangle {
        for y in minY..<maxY {
            for x in minX..<maxX {
                let si = (y * bpr) + (x * bpp)
                dst[si] = 0; dst[si+1] = 0; dst[si+2] = 0; dst[si+3] = 0
            }
        }
        for y in minY..<maxY {
            let ny = y + dy; guard ny >= 0, ny < h else { continue }
            for x in minX..<maxX {
                let nx = x + dx; guard nx >= 0, nx < w else { continue }
                let si = (y * bpr) + (x * bpp)
                let di = (ny * bpr) + (nx * bpp)
                dst[di] = src[si]; dst[di+1] = src[si+1]
                dst[di+2] = src[si+2]; dst[di+3] = src[si+3]
            }
        }
    } else {
        let rw = maxX - minX; let rh = maxY - minY
        var mask = [Bool](repeating: false, count: rw * rh)
        for ly in 0..<rh {
            for lx in 0..<rw {
                mask[ly * rw + lx] = selection.contains(
                    CanvasPoint(x: Double(minX + lx) + 0.5, y: Double(minY + ly) + 0.5)
                )
            }
        }
        for ly in 0..<rh {
            for lx in 0..<rw {
                guard mask[ly * rw + lx] else { continue }
                let si = ((minY+ly) * bpr) + ((minX+lx) * bpp)
                dst[si] = 0; dst[si+1] = 0; dst[si+2] = 0; dst[si+3] = 0
            }
        }
        for ly in 0..<rh {
            for lx in 0..<rw {
                guard mask[ly * rw + lx] else { continue }
                let x = minX+lx; let y = minY+ly
                let si = (y * bpr) + (x * bpp)
                let nx = x + dx; let ny = y + dy
                guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                let di = (ny * bpr) + (nx * bpp)
                dst[di] = src[si]; dst[di+1] = src[si+1]
                dst[di+2] = src[si+2]; dst[di+3] = src[si+3]
            }
        }
    }
    return LayerTextureSnapshot(width: w, height: h, bytesPerRow: bpr, pixelData: Data(dst))
}

private func affineTransformLayerPixels(
    snapshot: LayerTextureSnapshot,
    selection: SelectionShape,
    preview: FreeTransformPreview
) -> LayerTextureSnapshot {
    let width = snapshot.width
    let height = snapshot.height
    let bytesPerRow = snapshot.bytesPerRow
    let bytesPerPixel = 4

    let minX = max(Int(selection.bounds.minX.rounded(.down)), 0)
    let minY = max(Int(selection.bounds.minY.rounded(.down)), 0)
    let maxX = min(Int(selection.bounds.maxX.rounded(.up)), width)
    let maxY = min(Int(selection.bounds.maxY.rounded(.up)), height)
    guard minX < maxX, minY < maxY else { return snapshot }

    let cropWidth = maxX - minX
    let cropHeight = maxY - minY
    let cropBytesPerRow = cropWidth * bytesPerPixel

    var sourceBGRA = [UInt8](snapshot.pixelData)

    // マスクバイト取得
    let fullMaskBytes: [UInt8]
    if selection.kind == .mask, let maskData = selection.maskData {
        fullMaskBytes = [UInt8](maskData.alphaBytes)
    } else if selection.kind == .rectangle {
        fullMaskBytes = []
    } else {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in minY..<maxY {
            for x in minX..<maxX {
                let point = CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                if selection.contains(point) {
                    bytes[(y * width) + x] = 255
                }
            }
        }
        fullMaskBytes = bytes
    }

    // 選択領域のクロップを BGRA のまま抽出し、ソースから消去
    var cropBGRA = [UInt8](repeating: 0, count: cropBytesPerRow * cropHeight)
    for localY in 0..<cropHeight {
        let y = minY + localY
        for localX in 0..<cropWidth {
            let x = minX + localX
            let isSelected: Bool
            if selection.kind == .rectangle {
                isSelected = true
            } else {
                let maskIndex = (y * width) + x
                isSelected = fullMaskBytes.indices.contains(maskIndex) && fullMaskBytes[maskIndex] > 0
            }
            guard isSelected else { continue }
            let si = (y * bytesPerRow) + (x * bytesPerPixel)
            let ci = (localY * cropBytesPerRow) + (localX * bytesPerPixel)
            cropBGRA[ci] = sourceBGRA[si]; cropBGRA[ci+1] = sourceBGRA[si+1]
            cropBGRA[ci+2] = sourceBGRA[si+2]; cropBGRA[ci+3] = sourceBGRA[si+3]
            sourceBGRA[si] = 0; sourceBGRA[si+1] = 0
            sourceBGRA[si+2] = 0; sourceBGRA[si+3] = 0
        }
    }

    // vImage でアフィン変換（BGRA のまま処理、RGBA 変換不要）
    guard let inverseTransform = freeTransformAffineTransform(bounds: selection.bounds, preview: preview).invertedIfPossible else {
        return snapshot
    }

    let transformedCorners = freeTransformCornerPoints(bounds: selection.bounds, preview: preview)
    let transformedBounds = CanvasRect.bounding(points: transformedCorners)
    let outMinX = max(Int(transformedBounds.minX.rounded(.down)) - 1, 0)
    let outMinY = max(Int(transformedBounds.minY.rounded(.down)) - 1, 0)
    let outMaxX = min(Int(transformedBounds.maxX.rounded(.up)) + 1, width)
    let outMaxY = min(Int(transformedBounds.maxY.rounded(.up)) + 1, height)
    guard outMinX < outMaxX, outMinY < outMaxY else {
        return LayerTextureSnapshot(width: width, height: height, bytesPerRow: bytesPerRow, pixelData: Data(sourceBGRA))
    }

    let outWidth = outMaxX - outMinX
    let outHeight = outMaxY - outMinY
    let outBytesPerRow = outWidth * bytesPerPixel
    var transformedBGRA = [UInt8](repeating: 0, count: outBytesPerRow * outHeight)

    // アフィン変換をピクセルループで実行（BGRA のまま、Float 演算で高速化）
    let ia = Float(inverseTransform.a); let ib = Float(inverseTransform.b)
    let ic = Float(inverseTransform.c); let id = Float(inverseTransform.d)
    let itx = Float(inverseTransform.tx); let ity = Float(inverseTransform.ty)
    let cropW = Float(cropWidth); let cropH = Float(cropHeight)
    let fMinX = Float(minX); let fMinY = Float(minY)

    for y in outMinY..<outMaxY {
        let fy = Float(y) + 0.5
        let localY = y - outMinY
        for x in outMinX..<outMaxX {
            let fx = Float(x) + 0.5
            // アフィン逆変換
            let sx = ia * fx + ic * fy + itx - fMinX - 0.5
            let sy = ib * fx + id * fy + ity - fMinY - 0.5

            // バイリニアサンプリング（Float で処理）
            let x0 = Int(sx); let y0 = Int(sy)
            guard x0 >= -1, y0 >= -1, x0 < Int(cropW), y0 < Int(cropH) else { continue }

            let x1 = x0 + 1; let y1 = y0 + 1
            let tx = sx - Float(x0); let ty = sy - Float(y0)

            func sampleByte(_ px: Int, _ py: Int, _ ch: Int) -> Float {
                guard px >= 0, py >= 0, px < cropWidth, py < cropHeight else { return 0 }
                return Float(cropBGRA[(py * cropBytesPerRow) + (px * bytesPerPixel) + ch])
            }

            let a00 = sampleByte(x0,y0,3); let a10 = sampleByte(x1,y0,3)
            let a01 = sampleByte(x0,y1,3); let a11 = sampleByte(x1,y1,3)
            let srcA = (a00*(1-tx) + a10*tx)*(1-ty) + (a01*(1-tx) + a11*tx)*ty
            guard srcA > 0 else { continue }

            let di = (localY * outBytesPerRow) + ((x - outMinX) * bytesPerPixel)
            for ch in 0..<4 {
                let c00 = sampleByte(x0,y0,ch); let c10 = sampleByte(x1,y0,ch)
                let c01 = sampleByte(x0,y1,ch); let c11 = sampleByte(x1,y1,ch)
                let sampled = (c00*(1-tx) + c10*tx)*(1-ty) + (c01*(1-tx) + c11*tx)*ty
                transformedBGRA[di+ch] = UInt8(min(255, max(0, sampled.rounded())))
            }
        }
    }

    // 変換結果をソース画像にコンポジット（プリマルチアルファ合成）
    for localY in 0..<outHeight {
        let y = outMinY + localY
        guard y >= 0, y < height else { continue }
        for localX in 0..<outWidth {
            let x = outMinX + localX
            guard x >= 0, x < width else { continue }
            let si = (localY * outBytesPerRow) + (localX * bytesPerPixel)
            let srcA = Float(transformedBGRA[si+3]) / 255.0
            guard srcA > 0 else { continue }
            let di = (y * bytesPerRow) + (x * bytesPerPixel)
            let dstA = Float(sourceBGRA[di+3]) / 255.0
            let outA = srcA + dstA * (1 - srcA)
            guard outA > 0 else { continue }
            for ch in 0..<3 {
                let srcC = Float(transformedBGRA[si+ch]) / 255.0
                let dstC = Float(sourceBGRA[di+ch]) / 255.0
                sourceBGRA[di+ch] = UInt8(min(255, max(0, ((srcC + dstC * (1-srcA)) / outA * 255).rounded())))
            }
            sourceBGRA[di+3] = UInt8(min(255, (outA * 255).rounded()))
        }
    }

    return LayerTextureSnapshot(width: width, height: height, bytesPerRow: bytesPerRow, pixelData: Data(sourceBGRA))
}

private extension CGAffineTransform {
    var invertedIfPossible: CGAffineTransform? {
        let determinant = a * d - b * c
        guard abs(determinant) > 0.000001 else { return nil }
        return inverted()
    }
}

private func bilinearSamplePremultipliedRGBA(
    bytes: [UInt8],
    width: Int,
    height: Int,
    bytesPerRow: Int,
    x: Double,
    y: Double
) -> (Double, Double, Double, Double) {
    guard width > 0, height > 0 else { return (0, 0, 0, 0) }

    let x0 = Int(floor(x))
    let y0 = Int(floor(y))
    let x1 = x0 + 1
    let y1 = y0 + 1
    let tx = x - Double(x0)
    let ty = y - Double(y0)

    func pixel(_ px: Int, _ py: Int) -> (Double, Double, Double, Double) {
        guard px >= 0, py >= 0, px < width, py < height else { return (0, 0, 0, 0) }
        let index = (py * bytesPerRow) + (px * 4)
        return (
            Double(bytes[index]) / 255.0,
            Double(bytes[index + 1]) / 255.0,
            Double(bytes[index + 2]) / 255.0,
            Double(bytes[index + 3]) / 255.0
        )
    }

    let p00 = pixel(x0, y0)
    let p10 = pixel(x1, y0)
    let p01 = pixel(x0, y1)
    let p11 = pixel(x1, y1)

    func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + ((b - a) * t)
    }

    let top = (
        lerp(p00.0, p10.0, tx),
        lerp(p00.1, p10.1, tx),
        lerp(p00.2, p10.2, tx),
        lerp(p00.3, p10.3, tx)
    )
    let bottom = (
        lerp(p01.0, p11.0, tx),
        lerp(p01.1, p11.1, tx),
        lerp(p01.2, p11.2, tx),
        lerp(p01.3, p11.3, tx)
    )

    return (
        lerp(top.0, bottom.0, ty),
        lerp(top.1, bottom.1, ty),
        lerp(top.2, bottom.2, ty),
        lerp(top.3, bottom.3, ty)
    )
}
