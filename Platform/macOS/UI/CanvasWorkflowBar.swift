import SwiftUI

struct CanvasWorkflowBar: View {
    @ObservedObject var viewModel: WorkspaceViewModel

    private var isSelectionTool: Bool {
        [.lassoSelection, .rectangleSelection, .ellipseSelection, .smartSelection, .polygonSelection].contains(viewModel.workspace.toolSession.activeTool)
    }

    var body: some View {
        VStack(spacing: 7) {
            if let draft = viewModel.selectionRefinementDraft {
                HStack(spacing: 8) {
                    Text("\(draft.kind.title)预览").fontWeight(.semibold)
                    Slider(value: Binding(get: { Double(draft.radius) }, set: { viewModel.updateSelectionRefinementPreview(radius: Int($0)) }), in: 0...512, step: 1)
                        .frame(width: 140).accessibilityLabel("选区调整半径")
                    TextField("像素", value: Binding(get: { draft.radius }, set: { viewModel.updateSelectionRefinementPreview(radius: $0) }), format: .number)
                        .frame(width: 45).accessibilityLabel("选区半径像素")
                    Text("px")
                    Toggle("覆盖显示", isOn: Binding(get: { draft.showsOverlay }, set: { _ in viewModel.toggleRefinementOverlay() }))
                    if draft.isComputing { ProgressView().controlSize(.small) }
                    Button("取消") { viewModel.cancelSelectionRefinementPreview() }
                    Button("应用") { viewModel.applySelectionRefinementPreview() }
                        .disabled(draft.isComputing || draft.error != nil).buttonStyle(.borderedProminent)
                }
                .workflowCapsule()
                if let error = draft.error { Text(error).foregroundStyle(.orange).workflowCapsule() }
                if draft.preview == nil && !draft.isComputing { Text("当前预览为空选区").workflowCapsule() }
            } else if let settings = viewModel.textureAdjustmentSettings {
                HStack(spacing: 8) {
                    Text("调整本次填充")
                    textureSlider("尺寸", value: settings.materialScale, range: 0.1...4) { value in
                        var copy = settings; copy.materialScale = value; viewModel.updateRecentTextureAdjustment(settings: copy)
                    }
                    textureSlider("覆盖", value: settings.coverage, range: 0...1) { value in
                        var copy = settings; copy.coverage = value; viewModel.updateRecentTextureAdjustment(settings: copy)
                    }
                    Picker("排列", selection: Binding(get: { settings.arrangement }, set: { value in
                        var copy = settings; copy.arrangement = value; viewModel.updateRecentTextureAdjustment(settings: copy)
                    })) { ForEach(TextureFillArrangement.allCases, id: \.self) { Text($0.displayName).tag($0) } }
                        .frame(width: 115)
                    Button("换一个结果") { viewModel.updateRecentTextureAdjustment(settings: settings, reroll: true) }
                    Button("取消") { viewModel.finishRecentTextureAdjustment(apply: false) }
                    Button("应用") { viewModel.finishRecentTextureAdjustment(apply: true) }.buttonStyle(.borderedProminent)
                }.workflowCapsule()
            } else if viewModel.workspace.toolSession.activeTool == .textureFill {
                HStack(spacing: 8) {
                    Text("纹理填充")
                    textureSlider("尺寸", value: viewModel.workspace.toolSession.textureFillTip.materialScale, range: 0.1...4, set: viewModel.setTextureFillMaterialScale)
                    textureSlider("覆盖", value: viewModel.workspace.toolSession.textureFillTip.coverage, range: 0...1, set: viewModel.setTextureFillCoverage)
                    if viewModel.canAdjustRecentTextureFill {
                        Button("调整本次填充") { viewModel.beginRecentTextureAdjustment() }.buttonStyle(.borderedProminent)
                    }
                }.workflowCapsule()
            } else if isSelectionTool || (viewModel.workspace.selection.committedShape != nil && !viewModel.isTransformingSelection && ![ToolKind.freeTransform, .canvasCrop, .linearGradient, .sectorGradient, .blockReference, .perspective].contains(viewModel.workspace.toolSession.activeTool)) {
                HStack(spacing: 8) {
                    if isSelectionTool {
                        Picker("组合", selection: $viewModel.preferredSelectionCombineMode) {
                            ForEach(SelectionCombineMode.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented).frame(width: 220)
                    }
                    if viewModel.workspace.selection.committedShape != nil {
                        ForEach([SelectionRefinementKind.feather, .expand, .contract], id: \.self) { kind in
                            Button(kind.title) { viewModel.beginSelectionRefinementPreview(kind) }
                        }
                        Button("反选") { viewModel.invertSelection() }
                        Button("取消选区") { viewModel.clearSelection() }
                    }
                }.workflowCapsule()
            }
        }
        .font(.system(size: 11))
        .controlSize(.small)
        .padding(.top, abs(viewModel.workspace.viewport.rotationDegrees) > 0.05 || (viewModel.workspace.toolSession.activeTool == .brush && viewModel.blockReferenceScene?.display.isFrozen == true) ? 48 : 8)
        .padding(.horizontal, 8)
    }

    private func textureSlider(_ title: String, value: Float, range: ClosedRange<Float>, set: @escaping (Float) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title)
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: Double(range.lowerBound)...Double(range.upperBound))
                .frame(width: 90).accessibilityLabel("\(viewModel.textureAdjustmentSettings == nil ? "纹理" : "本次填充")\(title)")
            Text("\(Int(value * 100))%").monospacedDigit().frame(width: 36)
        }
    }
}

struct PaintingTargetFeedback: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let blocker = viewModel.paintingBlocker {
                HStack {
                    Label(blocker.message, systemImage: "exclamationmark.circle")
                    Button(blocker.actionTitle) { viewModel.resolvePaintingBlocker() }.buttonStyle(.borderedProminent)
                    if blocker.action != .newLayer {
                        Button("新建绘画层") { viewModel.addLayer(); viewModel.paintingBlocker = nil }
                    }
                    Button { viewModel.paintingBlocker = nil } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭绘画提示")
                }.workflowCapsule()
            }
            Text(viewModel.editingTargetTitle)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .allowsHitTesting(false)
        }.font(.system(size: 11)).controlSize(.small).padding(10)
    }
}

private extension View {
    func workflowCapsule() -> some View {
        padding(.horizontal, 10).padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.12)))
    }
}

struct MaskThumbnailButton: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let layer: LayerRecord
    @State private var image: CGImage?
    var body: some View {
        Button { viewModel.selectLayerMask(layer.id) } label: {
            Group {
                if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                else { Image(systemName: "circle.lefthalf.filled") }
            }
            .frame(width: 28, height: 28).background(Color.black)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(viewModel.activeMaskEditingLayerID == layer.id ? Color.accentColor : Color.gray, lineWidth: 2))
        }
        .buttonStyle(.plain).accessibilityLabel("编辑\(layer.name)蒙版")
        .help("点击编辑蒙版：白色显示，黑色隐藏")
        .task(id: viewModel.layerThumbnailRevision) { image = await viewModel.loadMaskThumbnail(for: layer.id) }
    }
}
