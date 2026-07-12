# ArtFlex Repo Map

最后更新：2026-05-23

本文件给后续线程一个“从哪里读、往哪里改、改完怎么验证”的仓库地图。

## 1. 推荐阅读顺序

1. `CURRENT_STATUS.md`
2. `HANDOFF.md`
3. `DECISIONS.md`
4. 本文件
5. `Docs/reference/COLOR_PIXEL_SPEC.md`

## 2. 目录分层

### `Platform/macOS/`

负责：

- App 入口
- SwiftUI / AppKit 界面
- Metal 视图宿主
- 文件面板、参考图浮窗、录像等平台服务

关键文件：

- `App/ArtFlexApp.swift`
- `App/AppBootstrap.swift`
  - 应用依赖装配
  - XCTest 环境下会把画笔库 / 图案库持久化根目录重定向到临时目录
- `App/WorkspaceViewModel.swift`
- `UI/MainWindowView.swift`
- `Canvas/MetalCanvasHost.swift`

### `Core/`

负责：

- 文档、图层、工具、颜色、选区、视口
- 应用层状态与控制逻辑
- 快照、ideation、creative generator 等核心模型

关键文件：

- `Document/ArtDocument.swift`
- `Layer/LayerRecord.swift`
- `Tools/ToolKind.swift`
- `Tools/BrushPreset.swift`
- `Color/ColorPanelState.swift`
- `Application/HistoryController.swift`
- `Application/WorkspaceStore.swift`
- `Application/TransformInteractionState.swift`
- `Selection/SelectionState.swift`

### `Rendering/`

负责：

- Canvas renderer
- 笔刷 / 橡皮 / 涂抹 / 吸管 / 渐变 / 选区填充
- 图层 surface 管理
- 变形预览与 GPU 合成
- 画布最终呈现

关键文件：

- `Canvas/StageOneBrushRenderer.swift`
- `Canvas/MetalStrokeEngine.swift`
- `Canvas/StageOneLayerSurfaceStore.swift`
- `Canvas/StageOneCanvasPresenter.swift`
- `Canvas/SmudgeEngine.swift`
- `Canvas/BucketFillEngine.swift`
- `Canvas/EyedropperSampler.swift`
- `Canvas/TransformGPUCompositor.swift`
- `Canvas/LABLuminosityPostProcessor.swift`

### `Infrastructure/`

负责：

- PNG 导出
- 工程包格式
- layer texture 序列化 / snapshot / restore
- tip image asset 存储

关键文件：

- `FileFormat/PNGExporter.swift`
- `FileFormat/ProjectPackage.swift`
- `FileFormat/LayerTextureSerializer.swift`
- `FileFormat/BrushTipImageAssetSystem.swift`

## 3. 关键工作流入口

### 3.1 应用壳与状态中心

- `Platform/macOS/App/WorkspaceViewModel.swift`
  - 当前最大的状态接线中心
  - 大多数用户操作最终会落到这里
- `Core/Application/WorkspaceStore.swift`
  - 持久状态容器
- `Platform/macOS/UI/MainWindowView.swift`
  - 标准工作区 / 快照对比 / ideation 三套 shell

### 3.2 画布输入与显示

- `Platform/macOS/Canvas/MetalCanvasHost.swift`
  - MTKView 宿主、输入转发、预览绘制、drawable 呈现
- `Core/Viewport/CanvasPresentation.swift`
  - 画布呈现参数
- `Core/Viewport/CanvasViewport.swift`
  - 视口状态

### 3.3 图层、历史与文件

- `Rendering/Canvas/StageOneLayerSurfaceStore.swift`
  - 图层 `MTLTexture` 生命周期与 surface 记录
- `Core/Application/HistoryController.swift`
  - undo / redo 与快照恢复
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
  - texture snapshot / restore / sample
- `Infrastructure/FileFormat/ProjectPackage.swift`
  - 工程保存格式

### 3.4 笔刷与工具

- `Core/Tools/ToolKind.swift`
  - 工具枚举
  - `BrushSettings`
  - `CompoundBrushSettings`
- `Rendering/Canvas/StageOneBrushRenderer.swift`
  - 笔刷、橡皮、涂抹、组合笔刷 runtime 关键点
- `Rendering/Canvas/StageOneBrushPreviewRasterizer.swift`
  - 预览图与笔尖预览
- `Platform/macOS/UI/CompoundBrushBuilderSheet.swift`
  - 组合笔刷工作台

### 3.5 选区与变形

- `Core/Selection/SelectionState.swift`
- `Core/Selection/ClosedPolygonMaskRasterizer.swift`
- `Core/Application/TransformInteractionState.swift`
- `Rendering/Canvas/TransformPreviewSession.swift`
- `Rendering/Canvas/TransformGPUCompositor.swift`

### 3.6 颜色、参考图与快速取色

- `Core/Color/ColorPanelState.swift`
- `Core/Color/QuickColorPickerState.swift`
- `Platform/macOS/UI/ReferenceImagePanelSupport.swift`
- `Rendering/Canvas/LABLuminosityPostProcessor.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
  - 参考图、LAB 黑白参考、色块与当前色同步逻辑

### 3.7 画笔库与 tip image library

- `Core/Tools/BrushPreset.swift`
- `Core/Tools/TipImageLibrary.swift`
- `Platform/macOS/Services/BrushLibraryPersistenceController.swift`
  - 读写 `brush-library.json`
  - archive 包含 `library`、`tipImageLibrary`、`tipImageAssets`
  - 支持测试注入 `rootDirectoryURL`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`

### 3.8 其它正式工作流

- 快照对比：
  `Core/Snapshots/SnapshotCompareSessionState.swift`
- ideation：
  `Core/Ideation/IdeationSessionState.swift`
- timelapse：
  `Platform/macOS/Services/TimelapseRecorderController.swift`

## 4. 当前最该警惕的热点文件

这些文件当前都很大，改动前先收范围：

- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`

如果需求只涉及某一小块能力，优先做局部修改，不要顺手扩展成整文件重构。

## 5. 当前 working tree 关注点

截至 2026-05-23，不要再使用 2026-04-12 的旧 dirty tree 清单。

当前代码侧已知未提交改动集中在：

- `Core/Selection/TextureFillProceduralField.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Platform/macOS/App/AppBootstrap.swift`
- `Platform/macOS/Services/BrushLibraryPersistenceController.swift`

接手时仍以 `git status --short` 为准；文档只能说明最近一次审查时的状态。

## 6. 测试地图

比较常用的测试入口：

- `Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift`
- `Tests/ArtFlexTests/BrushStrokeSamplingTests.swift`
- `Tests/ArtFlexTests/HistoryControllerTests.swift`
- `Tests/ArtFlexTests/ProjectPackageTests.swift`
- `Tests/ArtFlexTests/StageOneBrushPreviewRasterizerTests.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Tests/ArtFlexTests/BrushLibraryStateTests.swift`

涉及 `AppBootstrap()`、画笔库或图案库持久化的测试，必须确认不会写入真实 `~/Library/Application Support/ArtFlex`。

## 7. 常用命令

```bash
swift build
swift test
swift test --filter WorkspaceViewModelSafetyTests
swift test --filter BrushStrokeSamplingTests
swift test --filter HistoryControllerTests
swift test --filter ProjectPackageTests
swift test --filter StageOneBrushPreviewRasterizerTests
swift test --filter BrushLibraryStateTests
```
