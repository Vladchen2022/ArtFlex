# ArtFlex Handoff

最后更新：2026-04-15

## 1. 先记住这三句话

1. 当前仓库已经不是第一阶段 MVP，也不是“旧 dual-tip 回退基线”。
2. 当前最值得关注的产品主线是组合笔刷参数语义、颜色工作流，以及局部交互一致性。
3. 当前不要再默认假设仓库挂着一批历史性 dirty 性能 patch；接手前先看 `git status` 再判断。

## 2. 推荐阅读顺序

1. [CURRENT_STATUS.md](CURRENT_STATUS.md)
2. [DECISIONS.md](DECISIONS.md)
3. [Docs/reference/REPO_MAP.md](Docs/reference/REPO_MAP.md)
4. [Docs/reference/COLOR_PIXEL_SPEC.md](Docs/reference/COLOR_PIXEL_SPEC.md)
5. [Docs/reference/COLOR_ADJUSTMENT_STATUS.md](Docs/reference/COLOR_ADJUSTMENT_STATUS.md)

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

### 3.4 右侧画笔参数区已经有“主笔尖参数 / 整体画笔参数”分层

当前右侧参数区不要再全部按“主笔尖参数”理解。

更接近真实状态的是：

- 结构类：`间距 / 散布 / 旋转 / 抖动`
  - 当前仍偏主笔尖 / 主体结构
- 整体表现类：`杂色 / 杂色对比 / 大小压感 / 透明压感 / 透明修正`
  - 普通笔刷时作用于当前笔刷
  - 组合笔刷时作用于整支组合笔刷，而不是只等于主笔尖内部参数

### 3.5 颜色面板拾色器和 HUD 快速拾色器不能分开改

当前颜色工作流里，`Shift+Z` HUD 拾色器和右侧颜色面板拾色器必须一起理解。

后续若继续修改这块，必须同步考虑：

- 色立方显示
- 点选实际取色结果
- 当前颜色反推拾色器位置
- `光色 / 明度 / 纯度` 滑块语义

不要只修其中一层。

### 3.6 色彩调整当前只做到阶段 A

当前不要把 `色彩调整` 理解成“参数面板和正式调整已经完成，只是在修 bug”。

当前真实状态是：

- 阶段 A 已完成并手测通过
- 只支持工具态蓝色蒙版绘制
- `E/B/Esc` 已接通
- 参数面板、确认链、正式色彩调整应用还没开始

继续接手这块时，先读：

- [Docs/reference/COLOR_ADJUSTMENT_STATUS.md](Docs/reference/COLOR_ADJUSTMENT_STATUS.md)

## 4. 当前 working tree 状态

当前不要再沿用旧文档里“仓库默认 dirty，且主要是性能 patch”的说法。

接手前建议先执行：

```bash
git status --short
git diff --stat   # 仅在 dirty 时再看
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
