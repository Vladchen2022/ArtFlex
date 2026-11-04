import AppKit
import SwiftUI

@MainActor
enum PerformanceDiagnosticsWindow {
    private static var window: NSWindow?

    static func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 430),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        created.title = "绘画性能诊断"
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: PerformanceDiagnosticsView())
        window = created
        created.center()
        created.makeKeyAndOrderFront(nil)
    }
}

private struct PerformanceDiagnosticsView: View {
    @State private var recording = PerformanceAuditStore.shared.isRecordingEnabled
    @State private var exportError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("绘画性能诊断").font(.title2)
            Text("输入延迟从应用接收队列开始，结束于系统报告画面呈现；不包含数位板驱动或屏幕响应时间。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(recording ? "停止记录" : "开始记录") {
                    recording.toggle()
                    PerformanceAuditStore.shared.setRecordingEnabled(recording)
                }
                Button("清空并开始") { PerformanceAuditStore.shared.reset(); recording = true }
                Button("导出记录…") { export() }
                Spacer()
                Text(recording ? "正在记录，请返回画布绘画" : "已停止").foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let snapshot = PerformanceAuditStore.shared.snapshot()
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                    GridRow { Text("阶段"); Text("样本"); Text("中位数"); Text("P95"); Text("P99") }
                    Divider()
                    ForEach(metrics, id: \.0) { key, title in
                        let value = snapshot.distributions[key]
                        GridRow {
                            Text(title)
                            Text(value.map { String($0.count) } ?? "0")
                            Text(ms(value?.median)); Text(ms(value?.p95)); Text(ms(value?.p99))
                        }
                    }
                }.monospacedDigit()
            }
            if let exportError { Text(exportError).foregroundStyle(.red) }
            Spacer()
            Text("P95 / P99 用于观察较慢的帧；样本少时不作性能结论。导出文件包含完整采样和构建版本。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 680, minHeight: 370)
    }
    private var metrics: [(String, String)] { [
        ("Canvas.inputToPresented", "输入至呈现"), ("Canvas.inputQueueWait", "输入排队"),
        ("Canvas.frameCPU", "画面 CPU 编码"), ("Canvas.frameGPU", "画面 GPU 执行"),
        ("Canvas.submitToPresented", "提交至呈现")
    ] }
    private func ms(_ value: Double?) -> String { value.map { String(format: "%.2f ms", $0) } ?? "—" }
    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ArtFlex-performance.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let snapshot = PerformanceAuditStore.shared.snapshot()
                let data: [String: Any] = ["schema": 1,
                    "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development",
                    "measurement": "application queue to OS drawable presentation; excludes input hardware and scanout",
                    "durationsMs": snapshot.durationsMs, "integerSamples": snapshot.integerSamples]
                try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
                exportError = nil
            } catch { exportError = error.localizedDescription }
        }
    }
}
