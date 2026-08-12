import AppKit
import SwiftUI

struct VisibleHistoryPopover: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scrubPosition = 0.0
    @State private var pendingScrubTask: Task<Void, Never>?

    private var timeline: VisibleHistoryTimeline { viewModel.visibleHistoryTimeline }
    private var previewCount: Int {
        viewModel.visibleHistoryPreviewTargetCount ?? timeline.currentAppliedEntryCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("历史预览")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Text("最多保留 \(HistoryController.defaultMaxEntries) 步")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Text("这里只显示撤销/重做的状态序列，不支持单独删除中间一步。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Divider()

            if timeline.appliedEntries.isEmpty && timeline.redoEntries.isEmpty {
                Text("当前还没有可预览的操作")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 90)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("拖动预览")
                        Spacer()
                        Text("\(Int(scrubPosition.rounded())) / \(timeline.totalEntryCount)")
                            .monospacedDigit()
                    }
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                    HistoryScrubber(
                        value: Binding(
                            get: { scrubPosition },
                            set: { newValue in
                                let target = min(max(Int(newValue.rounded()), 0), timeline.totalEntryCount)
                                scrubPosition = Double(target)
                                guard target != previewCount else { return }
                                scheduleHistoryPreview(target)
                            }
                        ),
                        upperBound: max(timeline.totalEntryCount, 1)
                    )
                }

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(timeline.chronologicalEntries.enumerated().reversed()), id: \.element.id) { index, entry in
                            historyRow(entry, appliedEntryCount: index + 1)
                        }
                        initialStateRow
                    }
                }
                .frame(height: 260)

                HStack(spacing: 8) {
                    Button("取消预览") {
                        viewModel.cancelVisibleHistoryPreview()
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button("应用此状态") {
                        viewModel.applyVisibleHistoryPreview()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            Text("最新操作在上方。点击眼睛或拖动滑块只会临时更新主画布；关闭窗口会恢复，点“应用此状态”才保留。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320)
        .onAppear {
            viewModel.prepareVisibleHistoryPresentation()
            scrubPosition = Double(previewCount)
        }
        .onDisappear {
            pendingScrubTask?.cancel()
            viewModel.cancelVisibleHistoryPreview()
        }
        .onChange(of: previewCount) { _, newValue in
            scrubPosition = Double(newValue)
        }
    }

    private func scheduleHistoryPreview(_ target: Int) {
        pendingScrubTask?.cancel()
        pendingScrubTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            viewModel.previewVisibleHistory(toAppliedEntryCount: target)
        }
    }

    private func historyRow(
        _ entry: VisibleHistoryEntryMetadata,
        appliedEntryCount: Int
    ) -> some View {
        let isPreviewed = appliedEntryCount == previewCount
        return Button {
            viewModel.previewVisibleHistory(toAppliedEntryCount: appliedEntryCount)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: isPreviewed ? "eye.fill" : "eye")
                    .foregroundStyle(isPreviewed ? Color.green : Color.secondary)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    Text(entry.createdAt, style: .time)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)
                if !entry.affectedLayerIDs.isEmpty {
                    Text("\(entry.affectedLayerIDs.count) 层")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isPreviewed ? Color.green.opacity(0.1) : Color.primary.opacity(0.04))
            )
            .overlay {
                if isPreviewed {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.green.opacity(0.5), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .help("预览这一步之后的完整画布状态")
    }

    private var initialStateRow: some View {
        Button {
            viewModel.previewVisibleHistory(toAppliedEntryCount: 0)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: previewCount == 0 ? "eye.fill" : "eye")
                    .foregroundStyle(previewCount == 0 ? Color.green : Color.secondary)
                    .frame(width: 18)
                Text("初始状态")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(previewCount == 0 ? Color.green.opacity(0.1) : Color.primary.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryScrubber: NSViewRepresentable {
    @Binding var value: Double
    let upperBound: Int

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: value,
            minValue: 0,
            maxValue: Double(max(upperBound, 1)),
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.numberOfTickMarks = max(upperBound, 1) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.tickMarkPosition = .below
        slider.isContinuous = true
        slider.controlSize = .small
        slider.setAccessibilityLabel("历史预览时间线")
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.value = $value
        slider.maxValue = Double(max(upperBound, 1))
        slider.numberOfTickMarks = max(upperBound, 1) + 1
        if abs(slider.doubleValue - value) > 0.001 {
            slider.doubleValue = value
        }
    }

    final class Coordinator: NSObject {
        var value: Binding<Double>
        init(value: Binding<Double>) { self.value = value }

        @MainActor @objc func valueChanged(_ sender: NSSlider) {
            value.wrappedValue = sender.doubleValue.rounded()
        }
    }
}
