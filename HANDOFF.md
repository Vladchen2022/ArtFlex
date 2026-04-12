# ArtFlex Handoff

最后更新：2026-04-12

## 1. 先记住这三句话

1. 当前仓库已经不是第一阶段 MVP，也不是“旧 dual-tip 回退基线”。
2. 当前最值得关注的产品主线是组合笔刷外观、颜色工作流，以及一批尚未提交的性能 / 稳定性收口。
3. 当前工作区不是干净状态；接手前先看 diff，再决定是否继续在 pending 改动上工作。

## 2. 推荐阅读顺序

1. [CURRENT_STATUS.md](CURRENT_STATUS.md)
2. [DECISIONS.md](DECISIONS.md)
3. [Docs/reference/REPO_MAP.md](Docs/reference/REPO_MAP.md)
4. [Docs/reference/COLOR_PIXEL_SPEC.md](Docs/reference/COLOR_PIXEL_SPEC.md)

如果任务和组合笔刷直接相关，再看：

- [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift)
- [Platform/macOS/App/WorkspaceViewModel.swift](Platform/macOS/App/WorkspaceViewModel.swift)
- [Platform/macOS/UI/CompoundBrushBuilderSheet.swift](Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)

## 3. 当前最重要的结论

### 3.1 组合笔刷已经接回主工程

不要再按“旧 dual-tip flat 字段 + 回退 patch”理解当前状态。

当前真实路径是：

- 数据：`CompoundBrushSettings`
- 接线：`WorkspaceViewModel`
- UI：`CompoundBrushBuilderSheet`
- runtime：`StageOneBrushRenderer` 的 compound 分支

### 3.2 当前默认不要再重查 plumbing

如果没有新的硬证据，当前不应优先怀疑：

- sample builder
- tip sampling
- 主 / 次 tip 资源接线
- actual canvas vs replay 的基础 plumbing
- display / composite / export 主链

当前主要问题仍在主层外观表达，而不是底层接线重新失效。

### 3.3 项目范围已经明显扩大

不要再把项目理解成“只有画布 + 图层 + 画笔”的基础原型。

当前正式主链还包括：

- 参考图与 LAB 黑白参考
- 画笔库与 tip image library
- 快照对比
- ideation 分支工作流
- timelapse 录制 / 导出
- 线性渐变 / 扇形渐变

## 4. 当前 working tree 状态

截至 2026-04-12，未提交代码改动集中在以下文件：

- `Core/Application/HistoryController.swift`
- `Core/Application/PerformanceAuditStore.swift`
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`
- `Rendering/Canvas/StageOneCanvasPresenter.swift`
- `Rendering/Canvas/StageOneLayerSurfaceStore.swift`

这批改动大多与以下方向有关：

- history / serializer 批处理
- Metal 资源缓存与 presenter 复用
- luminosity preview 临时纹理复用
- brush library 异步持久化
- 右侧 inspector 的近期颜色 / 色标变化

接手前建议先执行：

```bash
git status --short
git diff --stat
```

## 5. 关键入口文件

### 5.1 应用壳与状态中心

- `Platform/macOS/App/ArtFlexApp.swift`
- `Platform/macOS/App/AppBootstrap.swift`
- `Platform/macOS/UI/MainWindowView.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Core/Application/WorkspaceStore.swift`

### 5.2 画布与渲染主链

- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Rendering/Canvas/StageOneCanvasPresenter.swift`
- `Rendering/Canvas/StageOneLayerSurfaceStore.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`
- `Rendering/Canvas/MetalStrokeEngine.swift`
- `Rendering/Canvas/SmudgeEngine.swift`
- `Rendering/Canvas/BucketFillEngine.swift`
- `Rendering/Canvas/EyedropperSampler.swift`

### 5.3 文件 / 导出 / 历史

- `Core/Application/HistoryController.swift`
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
- `Infrastructure/FileFormat/ProjectPackage.swift`
- `Infrastructure/FileFormat/PNGExporter.swift`
- `Core/Application/PersistenceController.swift`

### 5.4 颜色 / 参考图 / 生成器

- `Core/Color/ColorPanelState.swift`
- `Core/Color/QuickColorPickerState.swift`
- `Rendering/Canvas/LABLuminosityPostProcessor.swift`
- `Platform/macOS/UI/ReferenceImagePanelSupport.swift`
- `Core/CreativeShapeGenerator/*`

## 6. 常用验证

```bash
swift build
swift test --filter WorkspaceViewModelSafetyTests
swift test --filter BrushStrokeSamplingTests
swift test --filter HistoryControllerTests
swift test --filter StageOneBrushPreviewRasterizerTests
```

## 7. 不要被这些旧叙事带偏

- 不要再寻找已经删除的阶段计划 / MVP / Stage1 文档，它们已从仓库移除，历史内容请直接查 git。
- 不要默认把当前项目理解成“只有组合笔刷”或“只有性能优化”；现在它已经是多工作流并行的主工程。
- 不要无计划发起 `WorkspaceViewModel` / `RightInspectorView` 的整文件重构，除非任务本身就是明确拆分某个子系统。
