import Foundation

struct ProjectReadProgress: Sendable, Equatable {
    enum Phase: String, Sendable {
        case inspecting = "检查工程"
        case extracting = "解包工程"
        case sources = "校验源素材"
        case layers = "读取并准备图层"
        case references = "读取参考图与快照"
        case uploading = "准备画布"
        case materializing = "读取保存资源"
        case writing = "写入工程资源"
        case packaging = "封装工程"
        case committing = "完成保存"
        case cancelling = "正在取消"
    }
    var phase: Phase
    var completed: Int = 0
    var total: Int?
    var previewPNGData: Data?
}

/// Thin, thread-safe observation/cancellation boundary around existing archive APIs.
final class ProjectReadContext: @unchecked Sendable {
    let cancellation: WorkCancellation
    private let lock = NSLock()
    private var state = ProjectReadProgress(phase: .inspecting)
    private var lastDelivery: UInt64 = 0
    private let deliver: @Sendable (ProjectReadProgress) -> Void

    init(cancellation: WorkCancellation = WorkCancellation(), deliver: @escaping @Sendable (ProjectReadProgress) -> Void = { _ in }) {
        self.cancellation = cancellation; self.deliver = deliver
    }
    func check() throws { try cancellation.check() }
    func report(_ phase: ProjectReadProgress.Phase, completed: Int = 0, total: Int? = nil) {
        let snapshot: ProjectReadProgress? = lock.withLock {
            let changedPhase = phase != state.phase
            state.phase = phase; state.completed = completed; state.total = total
            let now = DispatchTime.now().uptimeNanoseconds
            guard changedPhase || completed == total || lastDelivery == 0 || now - lastDelivery >= 50_000_000 else { return nil }
            lastDelivery = now; return state
        }
        if let snapshot { deliver(snapshot) }
    }
    func preview(_ data: Data?) {
        guard let data else { return }
        let snapshot = lock.withLock { state.previewPNGData = data; return state }
        deliver(snapshot)
    }
}
