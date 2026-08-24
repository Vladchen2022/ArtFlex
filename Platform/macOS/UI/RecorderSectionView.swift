import SwiftUI

struct RecorderSectionView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @ObservedObject var recorder: TimelapseRecorderController
    @Binding var exportFPS: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text("录像数据文件夹")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.58))

                HStack(spacing: 8) {
                    Text(recorder.outputDirectoryPath.isEmpty ? "未选择目录" : recorder.outputDirectoryPath)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(recorder.outputDirectoryPath.isEmpty ? 0.45 : 0.82))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    iconButton(systemImage: "folder.badge.gearshape", tooltip: "在 Finder 中打开当前录像目录") {
                        viewModel.revealTimelapseSessionInFinder()
                    }
                    .disabled(recorder.currentSessionDirectory == nil)

                    iconButton(systemImage: "folder", tooltip: "选择录像目录") {
                        viewModel.chooseTimelapseOutputDirectory()
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.16))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
            }

            valueLine(title: "捕获间隔", content: {
                HStack(spacing: 8) {
                    Slider(value: $recorder.captureInterval, in: 1...10, step: 1)
                    Text("\(Int(recorder.captureInterval)) 秒")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 46, alignment: .trailing)
                }
            })

            valueLine(title: "格式", content: {
                Picker("", selection: $recorder.frameFormat) {
                    ForEach(RecorderFrameFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            })

            valueLine(title: "画质", content: {
                HStack(spacing: 8) {
                    Slider(value: $recorder.qualityPercent, in: 20...100, step: 5)
                    Text("\(Int(recorder.qualityPercent))%")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 46, alignment: .trailing)
                }
            })

            valueLine(title: "分辨率", content: {
                Picker("", selection: $recorder.resolutionScale) {
                    ForEach(RecorderResolutionScale.allCases) { scale in
                        Text(scale.displayName).tag(scale)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
            })

            Toggle("自动开始录制", isOn: $recorder.autoStart)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.88))
                .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 4) {
                infoLine("当前会话", recorder.currentSessionName)
                infoLine("状态", recorder.isRecording ? "录制中" : "未录制")
                infoLine("已保存帧", "\(recorder.savedFrameCount)")
                infoLine("待处理", "\(recorder.pendingJobCount)")
                infoLine("已跳过", "\(recorder.droppedFrameCount)")
            }

            if let failure = recorder.lastFailureMessage {
                Text(failure)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                actionButton(recorder.isRecording ? "停止录制" : "开始录制") {
                    viewModel.toggleTimelapseRecording()
                }

                actionButton("导出视频") {
                    viewModel.exportTimelapseVideo(fps: Int(exportFPS.rounded()))
                }
                .disabled(!recorder.canExportVideo)
            }

            if recorder.lastExportedVideoURL != nil {
                actionButton("打开导出视频") {
                    viewModel.openLastExportedTimelapseVideo()
                }
            }

            valueLine(title: "输出 FPS", content: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        fpsPresetButton(12)
                        fpsPresetButton(24)
                        fpsPresetButton(30)
                    }
                    HStack(spacing: 8) {
                        Slider(value: $exportFPS, in: 6...30, step: 1)
                        Text("\(Int(exportFPS.rounded()))")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.88))
                            .frame(width: 32, alignment: .trailing)
                    }
                }
            })

            valueLine(title: "开头停留", content: {
                HStack(spacing: 8) {
                    Slider(value: $recorder.exportLeadInSeconds, in: 0...5, step: 0.5)
                    Text(String(format: "%.1f 秒", recorder.exportLeadInSeconds))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 54, alignment: .trailing)
                }
            })

            valueLine(title: "结尾停留", content: {
                HStack(spacing: 8) {
                    Slider(value: $recorder.exportTailHoldSeconds, in: 0...5, step: 0.5)
                    Text(String(format: "%.1f 秒", recorder.exportTailHoldSeconds))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                        .frame(width: 54, alignment: .trailing)
                }
            })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueLine<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.58))
                .frame(width: 56, alignment: .leading)
            content()
        }
    }

    private func infoLine(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .foregroundStyle(Color.white.opacity(0.58))
            Spacer()
            Text(value)
                .foregroundStyle(Color.white.opacity(0.88))
        }
        .font(.system(size: 12, weight: .semibold))
    }

    private func fpsPresetButton(_ fps: Double) -> some View {
        Button {
            exportFPS = fps
        } label: {
            Text("\(Int(fps))")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(width: 36, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Int(exportFPS.rounded()) == Int(fps) ? Color.accentColor : Color.white.opacity(0.12))
                )
        }
        .buttonStyle(.plain)
        .help("导出为 \(Int(fps)) FPS")
    }

    private func actionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(maxWidth: .infinity, minHeight: 28)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func iconButton(systemImage: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.white.opacity(0.18))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .buttonTooltip(tooltip)
    }
}
