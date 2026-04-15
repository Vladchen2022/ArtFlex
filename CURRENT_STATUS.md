# ArtFlex 当前状态

最后更新：2026-04-15

## 1. 一句话概览

ArtFlex 当前已经是一个功能面明显超出最小 MVP 的 macOS Metal 绘图应用原型；当前主线不是“基础壳层补齐”，而是围绕组合笔刷参数语义、颜色工作流和局部交互一致性继续迭代。

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
- 色彩调整（当前仅阶段 A）
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
- `色彩调整` 当前只完成了工具态蓝色蒙版绘制阶段，参数面板和正式调整尚未接通

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

### 2.7 当前画笔参数区的真实语义

右侧画笔参数区不要再简单理解成“所有参数都等于主笔尖参数”。

当前真实语义是：

- 偏主笔尖 / 结构类参数：
  - `间距`
  - `散布`
  - `旋转`
  - `抖动`
- 偏整体画笔 / 最终表现类参数：
  - `杂色`
  - `杂色对比`
  - `大小压感`
  - `透明压感`
  - `透明修正`

其中：

- 普通笔刷时，上述参数都直接作用于这支笔刷本身
- 组合笔刷时，右侧参数区里的“整体表现类参数”不再等于主笔尖内部参数，而是作用于整支组合笔刷
- `透明修正` 是笔刷级 `buildUp` 透明叠加修正参数，会随笔刷保存到画笔库

### 2.8 当前颜色面板 / HUD 拾色器的真实状态

当前颜色系统里有两套需要区分的东西：

- 颜色面板的 `blocks` / `grayscale` 模式
- 颜色面板的 `picker` 模式与 `Shift+Z` HUD 快速拾色器

当前约束是：

- HUD 快速拾色器和右侧颜色面板拾色器必须保持显示一致
- 任何后续修改都不应只改显示、不改实际取色结果
- `光色 / 明度 / 纯度` 这些拾色器相关滑块仍然属于活动产品语义，后续线程不要擅自删减或重定义
- 如果未来继续重做拾色器，必须同时统一：
  - 色立方显示
  - 点选取色结果
  - 当前颜色反推拾色器坐标
  - `光色 / 明度 / 纯度` 的接入语义

### 2.9 当前色彩调整的真实状态

当前仓库里已经重新接入 `色彩调整` 工具，但只到 **阶段 A**。

当前真实可用的是：

- 左侧 `色彩调整` 工具
- 快捷键 `O`
- 使用当前画笔在当前活动图层上绘制蓝色蒙版预览
- `E` 切蒙版擦除
- `B` 回蒙版涂抹
- `Esc` 丢弃当前色彩调整 session
- 切换画笔预设时保持工具不切回普通画笔

当前尚未接通的是：

- 右侧 `色彩调整参数` 面板
- 色相 / 强度 / 亮度 / 对比度 / 纯度滑块
- 确认 / 恢复默认 / 按住预览
- 选区直调 / 整层直调
- 正式色彩调整写回与对应 history 链

单独状态文档见：

- [Docs/reference/COLOR_ADJUSTMENT_STATUS.md](Docs/reference/COLOR_ADJUSTMENT_STATUS.md)

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
- 颜色面板、HUD 拾色器、黑白模式、色标与画笔库联动

### 4.2 当前工作区状态

截至 2026-04-14，这个仓库不应再被默认理解成“长期挂着一批历史性的性能 dirty tree”。

当前接手前的正确做法是：

- 先执行 `git status --short`
- 如果是 dirty，再看 `git diff --stat`
- 不要沿用“仓库默认带着旧性能 patch 尚未提交”的过期叙事

## 5. 构建与验证状态

2026-04-14 本地确认：

- `swift build` 通过
- `swift test --filter WorkspaceViewModelSafetyTests` 通过
- `swift test --filter BrushStrokeSamplingTests` 通过
- `swift test --filter HistoryControllerTests` 通过
- `swift test --filter ColorStandardTests` 通过

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
