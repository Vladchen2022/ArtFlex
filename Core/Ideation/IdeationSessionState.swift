import Combine
import Foundation
@preconcurrency import Metal

struct IdeationEditingContext: Equatable {
    var toolSession: ToolSessionState
    var colorPanel: ColorPanelState
    var brushLibrary: BrushLibraryState
    var patternLibrary: PatternLibraryState
    var tipImageLibrary: TipImageLibraryState
    var generator: GeneratorSettings
}

@MainActor
final class IdeationSessionState: ObservableObject {
    enum CanvasDisplayMode {
        case grid
        case focused
    }

    enum ProgressMode: String, CaseIterable {
        case synchronized
        case divergent

        var displayName: String {
            switch self {
            case .synchronized:
                return "同步推进"
            case .divergent:
                return "差异推进"
            }
        }
    }

    struct Branch: Identifiable {
        let id = UUID()
        let index: Int
        let viewModel: WorkspaceViewModel

        var title: String {
            "方案 \(index + 1)"
        }
    }

    @Published var mode: ProgressMode = .synchronized {
        didSet {
            guard mode != oldValue else { return }
            guard mode == .synchronized else { return }
            propagateEditingContext(from: selectedBranchIndex)
        }
    }
    @Published var selectedBranchIndex: Int = 0
    @Published var canvasDisplayMode: CanvasDisplayMode = .grid {
        didSet {
            guard canvasDisplayMode != oldValue else { return }
            applyCanvasDisplayModeToBranches()
        }
    }

    let branches: [Branch]
    let baseCompositeTexture: MTLTexture

    var activeBranchViewModel: WorkspaceViewModel {
        branches[selectedBranchIndex].viewModel
    }

    private weak var hostViewModel: WorkspaceViewModel?
    private var cancellables: [AnyCancellable] = []
    private var isPropagatingOperation = false
    private var isPropagatingContext = false
    private var isPropagatingHistoryNavigation = false

    init(
        hostViewModel: WorkspaceViewModel,
        sourceWorkspace: WorkspaceState,
        sourceLayerSurfaceStore: StageOneLayerSurfaceStore,
        baseCompositeTexture: MTLTexture,
        metalContext: MetalDeviceContext,
        sharedMetalServices: AppSharedMetalServices
    ) throws {
        self.hostViewModel = hostViewModel
        self.baseCompositeTexture = baseCompositeTexture
        var createdBranches: [Branch] = []
        createdBranches.reserveCapacity(4)

        for index in 0..<4 {
            let store = WorkspaceStore(state: sourceWorkspace)
            let surfaceStore = StageOneLayerSurfaceStore()
            let bootstrap = try AppBootstrap(
                workspaceStore: store,
                metalContext: metalContext,
                layerSurfaceStore: surfaceStore,
                sharedMetalServices: sharedMetalServices,
                drawingStatsController: hostViewModel.drawingStatsController
            )
            let branchViewModel = WorkspaceViewModel(
                bootstrap: bootstrap,
                installsZoomKeyboardMonitor: false,
                preparesInitialTextures: false
            )
            branchViewModel.cloneWorkspaceForIdeation(
                from: sourceWorkspace,
                sourceLayerSurfaceStore: sourceLayerSurfaceStore
            )
            createdBranches.append(
                Branch(index: index, viewModel: branchViewModel)
            )
        }

        self.branches = createdBranches
        configureBranches()
        applyCanvasDisplayModeToBranches()
    }

    func selectBranch(_ index: Int) {
        activateBranch(index, adoptingEditingContext: false)
    }

    func focusSelectedBranchCanvas() {
        canvasDisplayMode = .focused
    }

    func returnToGridCanvasLayout() {
        canvasDisplayMode = .grid
    }

    func activateBranch(_ index: Int, adoptingEditingContext: Bool) {
        guard branches.indices.contains(index) else { return }
        guard selectedBranchIndex != index else { return }
        selectedBranchIndex = index
    }

    private func configureBranches() {
        cancellables = []

        for (index, branch) in branches.enumerated() {
            branch.viewModel.ideationBranchActivityHandler = { [weak self] in
                self?.activateBranch(index, adoptingEditingContext: false)
            }
            branch.viewModel.ideationOperationHandler = { [weak self] operation in
                self?.mirror(operation, from: index)
            }
            branch.viewModel.ideationUndoHandler = { [weak self] in
                self?.mirrorUndo(from: index) ?? false
            }
            branch.viewModel.ideationRedoHandler = { [weak self] in
                self?.mirrorRedo(from: index) ?? false
            }

            let cancellable = branch.viewModel.$workspace
                .map { workspace in
                    IdeationEditingContext(
                        toolSession: workspace.toolSession,
                        colorPanel: workspace.colorPanel,
                        brushLibrary: workspace.brushLibrary,
                        patternLibrary: workspace.patternLibrary,
                        tipImageLibrary: workspace.tipImageLibrary,
                        generator: workspace.generator
                    )
                }
                .removeDuplicates()
                .dropFirst()
                .sink { [weak self] context in
                    self?.propagateEditingContext(context, from: index)
                }
            cancellables.append(cancellable)
        }
    }

    private func applyCanvasDisplayModeToBranches() {
        switch canvasDisplayMode {
        case .grid:
            for branch in branches {
                branch.viewModel.resetViewport()
                branch.viewModel.setCanvasViewportLocked(true)
            }
        case .focused:
            for branch in branches {
                branch.viewModel.setCanvasViewportLocked(false)
            }
        }
    }

    private func propagateEditingContext(from index: Int) {
        let context = branches[index].viewModel.makeIdeationEditingContext()
        propagateEditingContext(context, from: index)
    }

    private func propagateEditingContext(_ context: IdeationEditingContext, from index: Int) {
        guard mode == .synchronized, !isPropagatingContext else { return }
        isPropagatingContext = true
        defer { isPropagatingContext = false }

        for otherIndex in branches.indices where otherIndex != index {
            branches[otherIndex].viewModel.applyIdeationEditingContext(context)
        }
    }

    private func mirror(_ operation: IdeationCanvasOperation, from index: Int) {
        activateBranch(index, adoptingEditingContext: false)
        guard mode == .synchronized, !isPropagatingOperation else { return }

        isPropagatingOperation = true
        defer { isPropagatingOperation = false }

        propagateEditingContext(from: index)

        for otherIndex in branches.indices where otherIndex != index {
            branches[otherIndex].viewModel.applyIdeationOperation(operation)
        }
    }

    private func mirrorUndo(from index: Int) -> Bool {
        activateBranch(index, adoptingEditingContext: false)
        guard mode == .synchronized, !isPropagatingHistoryNavigation else { return false }

        isPropagatingHistoryNavigation = true
        defer { isPropagatingHistoryNavigation = false }

        for branch in branches {
            branch.viewModel.undo()
        }
        return true
    }

    private func mirrorRedo(from index: Int) -> Bool {
        activateBranch(index, adoptingEditingContext: false)
        guard mode == .synchronized, !isPropagatingHistoryNavigation else { return false }

        isPropagatingHistoryNavigation = true
        defer { isPropagatingHistoryNavigation = false }

        for branch in branches {
            branch.viewModel.redo()
        }
        return true
    }
}
