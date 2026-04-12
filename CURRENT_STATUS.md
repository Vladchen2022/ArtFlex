# ArtFlex 当前状态

最后更新：2026-04-12

## 1. 一句话概览

ArtFlex 当前已经是一个功能面明显超出最小 MVP 的 macOS Metal 绘图应用原型；当前主线不是“基础壳层补齐”，而是围绕组合笔刷外观、颜色工作流和局部性能收口继续迭代。

## 2. 当前代码真实状态

### 2.1 主工作区已经不止一个 shell

当前主窗口不是只有标准画布模式。

[Platform/macOS/UI/MainWindowView.swift](Platform/macOS/UI/MainWindowView.swift) 里已经存在三套工作区壳：

- `StandardWorkspaceShell`
- `SnapshotCompareWorkspaceShell`
- `IdeationWorkspaceShell`

这意味着：

- 标准绘制工作区是主路径
- 快照对比不是临时实验，而是正式工作流入口
- ideation 分支工作流也已经接进主窗口结构

### 2.2 当前主界面结构

当前主工程仍然保持桌面绘图软件形态：

- 顶部工具栏
- 左侧工具栏
- 中央视图画布
- 右侧两列 inspector
- 图层面板
- 笔尖形状设计 / 导航器区域

右侧 inspector 的真实职责集中在 [Platform/macOS/UI/RightInspectorView.swift](Platform/macOS/UI/RightInspectorView.swift)，目前包含：

- 生成器 / 参考图切换区
- 颜色面板
- 画笔库
- 笔尖形状设计 / 导航器
- 画笔参数
- 图层

### 2.3 当前已接入主链的工具

以 [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift) 为准，当前工具集合包括：

- 画笔
- 橡皮擦
- 涂抹
- 吸管
- 油漆桶
- 套索选区
- 多边形选区
- 矩形选区
- 椭圆选区
- 套索填充
- 直线
- 直线渐变
- 扇形渐变
- 画布旋转
- 自由变形

说明：

- `lasso erase` 目前不是独立 `ToolKind`
- `straightLine / linearGradient / sectorGradient` 已经是正式工具组，而不是临时实验分支

### 2.4 当前已可确认的核心产品能力

从代码和测试可以确认，当前主工程已经具备：

- 多图层基础系统：新建、删除、复制、重命名、排序、显示隐藏、锁定、透明度、合并
- 历史系统：撤销 / 重做、图层状态与像素历史恢复
- 选区系统：套索 / 多边形 / 矩形 / 椭圆选区，选区填充与删除
- 自由变形：有选区和无选区两条路径
- 画布控制：缩放、平移、重置视角、画布旋转
- 笔刷系统：基础笔刷、橡皮、涂抹、直线、渐变
- 自定义笔尖设计：绘制、图片导入、旋转、翻转、预览
- 画笔库：持久化、导入导出、快捷键槽位
- tip image library：导入、引用关系检查、主笔尖 / 次笔尖复用
- 参考图系统：多槽位、浮窗、取色、LAB 黑白参考
- 快照系统：保存快照、对比、导出
- ideation 系统：多分支创作壳
- timelapse：录制与视频导出
- 文件系统：PNG 导出、工程保存 / 打开

### 2.5 当前组合笔刷的真实位置

当前组合笔刷已经是主工程真实路径，不是旧回退基线。

关键入口：

- 数据真相源：
  [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift)
- 状态接线：
  [Platform/macOS/App/WorkspaceViewModel.swift](Platform/macOS/App/WorkspaceViewModel.swift)
- UI 工作台：
  [Platform/macOS/UI/CompoundBrushBuilderSheet.swift](Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- 运行时：
  [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)

当前组合笔刷语义是：

1. 主笔尖先定义笔触包络 / 主体范围
2. 次笔尖沿 stroke-space 形成重复纹理场
3. 最终结果由主包络裁剪
4. 压力通过 `pressureMix` 控制主次主导权
5. 次纹理支持 stable random rotation 打散重复感

当前剩余问题仍主要集中在主层可见外观，不是 sample builder、tip sampling 或 display/export plumbing。

### 2.6 当前颜色与像素底座仍然统一

底层规范在代码里仍然一致，没有出现新的分裂链路：

- 文档颜色标准：
  [Core/Color/ColorStandard.swift](Core/Color/ColorStandard.swift)
  - `RGBA8`
  - `premultiplied alpha`
  - `sRGB`
- GPU layer surface / canvas drawable：
  - `.bgra8Unorm_srgb`
  - 见 [Rendering/Canvas/StageOneLayerSurfaceStore.swift](Rendering/Canvas/StageOneLayerSurfaceStore.swift)
  - 见 [Platform/macOS/Canvas/MetalCanvasHost.swift](Platform/macOS/Canvas/MetalCanvasHost.swift)
  - 见 [Rendering/Canvas/StageOneCanvasPresenter.swift](Rendering/Canvas/StageOneCanvasPresenter.swift)
- PNG 导出：
  [Infrastructure/FileFormat/PNGExporter.swift](Infrastructure/FileFormat/PNGExporter.swift)
  - 从同一套 layer texture 数据读回
  - 在基础设施层集中做 BGRA -> RGBA 扁平化处理
  - 当前导出结果是白底不透明 PNG

## 3. 当前架构现实

### 3.1 分层仍然基本成立

当前目录分层仍然有意义：

- `Core/`：文档、工具、颜色、选区、应用状态
- `Rendering/`：Metal 画布、笔刷、合成、采样、变形
- `Infrastructure/`：工程文件、导出、texture 序列化
- `Platform/macOS/`：App、UI、Canvas host、平台服务

### 3.2 但当前中心化已经非常明显

当前几个最大热点文件：

- [Platform/macOS/App/WorkspaceViewModel.swift](Platform/macOS/App/WorkspaceViewModel.swift)
  - 10378 行
- [Platform/macOS/UI/RightInspectorView.swift](Platform/macOS/UI/RightInspectorView.swift)
  - 4658 行
- [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)
  - 2943 行

这说明：

- 项目能力面已经明显扩大
- 但中心化也很强
- 如果后续要拆分，应该按明确功能切片做小范围分拆，不要无计划发起“大重构”

## 4. 当前主线与近期重点

### 4.1 当前最活跃的产品线

最近提交和当前文档一致，项目最近的高频工作是：

- 组合笔刷面板与外观继续收口
- 蜡笔 / 杂色 / 多工具接线
- 颜色面板、黑白模式、色标与画笔库联动

### 4.2 当前工作区里还有未提交的性能 / 稳定性改动

截至 2026-04-12，working tree 仍是 dirty，未提交改动集中在：

- `Core/Application/HistoryController.swift`
- `Core/Application/PerformanceAuditStore.swift`
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`
- `Rendering/Canvas/StageOneCanvasPresenter.swift`
- `Rendering/Canvas/StageOneLayerSurfaceStore.swift`

这批改动的方向大致是：

- history snapshot / restore 批处理
- serializer staging / batch restore
- Metal buffer / texture 复用
- luminosity preview 临时纹理缓存
- brush library 后台持久化
- performance audit 样本裁剪

后续线程接手前，应该先看 `git diff --stat` 和这几份文件的 diff，而不是假设当前 `HEAD` 就是完整现状。

## 5. 构建与验证状态

2026-04-12 本地确认：

- `swift build` 通过
- `swift test --filter WorkspaceViewModelSafetyTests` 通过
- `swift test --filter BrushStrokeSamplingTests` 通过
- `swift test --filter HistoryControllerTests` 通过

当前仍存在的非阻塞 warning：

- 文档相关的 SwiftPM warning 已经清理干净
- 在完整重编译或相关文件重新编译时，当前代码里仍可能出现若干 `SendableClosureCaptures` warning

这些 warning 当前不阻塞 build / test，但如果后续要做工程清洁度收口，需要单独处理。

## 6. 新线程建议先读

1. [HANDOFF.md](HANDOFF.md)
2. [DECISIONS.md](DECISIONS.md)
3. [Docs/reference/REPO_MAP.md](Docs/reference/REPO_MAP.md)
4. [Docs/reference/COLOR_PIXEL_SPEC.md](Docs/reference/COLOR_PIXEL_SPEC.md)

如果任务明确与组合笔刷相关，再继续看：

- [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift)
- [Platform/macOS/App/WorkspaceViewModel.swift](Platform/macOS/App/WorkspaceViewModel.swift)
- [Platform/macOS/UI/CompoundBrushBuilderSheet.swift](Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)
