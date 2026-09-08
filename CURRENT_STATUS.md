# ArtFlex 当前状态

最后更新：2026-05-23

## 2026-09-08 专项进度补记

以下正文为既有阶段快照，并非 9 月全部功能的完整盘点。本次只补充已验证专项入口：

- [右侧面板空间适配](Docs/INSPECTOR_LAYOUT_ACCEPTANCE_20260908.md)。
- [真实鼠标／数位笔中键路由修复](Docs/BLOCK_REFERENCE_MIDDLE_MOUSE_20260908.md)。
- [调色预览及保存计数回归稳定性](Docs/PREVIEW_SAVE_REGRESSION_20260908.md)：构建 `20260908.18`，三轮全量各 913 项通过，并完成界面调色／保存重开验收。
- [磁盘辅助撤销](Docs/DISK_UNDO_ACCEPTANCE_20260908.md)：构建 `20260908.19`，历史上限 128 步（受预算约束），旧像素分块压缩落盘；修复落笔立即撤销／重做丢输入。最终全量 927 项通过，已完成 30 笔磁盘历史、取消预览、分支及保存重开界面验收。此前颜色缓存用例仍需独立排查；稀疏图层、增量恢复尚未实施。
- [调色缓存生命周期与回归隔离](Docs/COLOR_CACHE_ACCEPTANCE_20260908.md)：构建 `20260908.20`，缓存测试隔离、淘汰后正确重建、取消旧 HUD 作业不覆盖显示；三轮全量各 931 项通过。主调色面板已做界面验收；Shift+Z 持续按住 HUD 的手测已请求，尚未确认，不能称完整界面验收。

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

另外，当前应用图标的真实实现仍然是：

- 单资源文件：[Platform/macOS/Resources/AppIcon.png](Platform/macOS/Resources/AppIcon.png)
- 运行时由 [Platform/macOS/App/ArtFlexApp.swift](Platform/macOS/App/ArtFlexApp.swift) 设置 `NSApp.applicationIconImage`
- 当前图标最近一次是替换内部 artwork，并保留现有图标的整体大小和圆角轮廓
- 如果后续继续调整，默认先改这张资源图，而不是假设项目已经有 `.appiconset` / `.icns` 主链

### 2.3 当前已接入主链的工具

以 [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift) 为准，当前工具集合包括：

- 画笔
- 橡皮擦
- 涂抹
- 色彩调整（painted mask + 选区 / 整层直调）
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
- `色彩调整` 当前已经接通参数面板、正式写回、selection / whole-layer 直调与对应 history 链

### 2.4 当前已可确认的核心产品能力

从代码和测试可以确认，当前主工程已经具备：

- 多图层基础系统：新建、删除、复制、重命名、排序、显示隐藏、锁定、透明度、合并
- 历史系统：撤销 / 重做、图层状态与像素历史恢复
- 选区系统：套索 / 多边形 / 矩形 / 椭圆选区，选区填充与删除
- 自由变形：有选区和无选区两条路径
- 画布控制：缩放、平移、重置视角、画布旋转
- 笔刷系统：基础笔刷、橡皮、涂抹、直线、渐变
- 色彩调整：painted mask、参数面板、选区 / 整层直调、确认应用、undo / redo
- 自定义笔尖设计：绘制、图片导入、旋转、翻转、预览
- 画笔库：持久化、导入导出、快捷键槽位、启动默认笔刷对齐、重复自动保存项清理
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

另外，`大小压感 / 透明压感` 当前已经不再是“3 条滑块 + 只读示意曲线”。

当前真实状态是：

- 已升级成真实曲线编辑器
- 实际出笔、右侧预览和 HUD 预览已统一到同一套曲线采样
- 仍兼容旧 `low / mid / high` 三值存档
- 弹窗顶部预设条当前已经恢复可见，当前这条线的剩余问题不再集中在预设区 UI 可见性

当前画笔库网格的正式语义还包括：

- 第一排是“最近使用”，但它只记录第三排及之后的正式库画笔
- 第二排 `1/2/3/4` 快捷槽位不进入最近使用首行
- `Shift+Z` HUD 里的 4 个快捷笔刷仍然对应第二排 `1/2/3/4` 正式槽位，不对应最近使用首行
- 软件启动时默认使用的是第二排第一个正式画笔（`slot 0`），不是最近使用首行

当前画笔库持久化的真实状态还包括：

- 用户真实持久化文件是 `~/Library/Application Support/ArtFlex/brush-library.json`
- 当前 archive 格式包含 `library`、`tipImageLibrary`、`tipImageAssets`
- 启动时会加载持久化画笔库，清理疑似自动保存重复项，并把当前画笔同步到启动默认快捷槽位
- `BrushLibraryPersistenceController` 支持注入 `rootDirectoryURL`
- `AppBootstrap` 在 XCTest 环境下会把画笔库 / 图案库持久化根目录默认重定向到临时目录
- 后续测试不允许再隐式写真实用户 Application Support 目录
- 本机这次已确认的真实用户画笔库状态是：`13` 个 preset、`53` 个 tip image library item、`53` 个 tip image asset

单独状态文档见：

- [Docs/reference/PRESSURE_CURVE_STATUS.md](Docs/reference/PRESSURE_CURVE_STATUS.md)

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

另外，`Shift+Z` HUD 当前还正式挂着一条已接通的“最近笔触调整组”：

- 只作用于 `brush` 工具
- 默认针对最近 `1` 笔，可回溯到最近 `20` 笔
- 当前支持：
  - 透明度
  - 明度
  - 饱和度
- `最近` 滑块当前语义是：
  - 最右默认 `1`
  - 往左退回更多笔
- 这组最近笔触在 HUD 里只是“隐藏可调后缀”，不是新图层
- 一旦离开画笔语境，会先无感固化到当前图层像素，再继续后续操作
- 当前已经确认会触发自动固化的边界包括：
  - 切换到任何非画笔工具
  - 切换活动图层
  - 开始下一笔新的正常绘画
  - 进入统一 `flushBrushEditingBoundary(...)` 的其他像素编辑边界
- 这条线当前已经收口到稳定第一版；后续默认不要把它扩成“所有工具共享的最近 20 步系统”

### 2.9 当前色彩调整的真实状态

当前仓库里的 `色彩调整` 已经不是“只有阶段 A 的蓝色蒙版 demo”。

当前已经接通的主链包括：

- 左侧 `色彩调整` 工具
- 快捷键 `O`
- `painted mask` 路径：使用当前画笔在当前活动图层上绘制影响蒙版
- 右侧 `色彩调整参数` 面板：色相 / 强度 / 亮度 / 对比 / 纯度
- `确认应用` / `恢复默认` / `按住预览`
- `selection` 直调：存在 committed selection 时，直接从参数面板创建选区调整 session
- `wholeLayer` 直调：没有选区时，直接从参数面板对当前图层做整层调整
- 正式写回与对应的单图层 undo / redo
- 切工具 / 切图层 / 打开新文档 / 关闭 / undo redo 前的确认 / 放弃 / 取消提示
- `undo / redo` 弹窗处理后自动继续原 history navigation
- `selection / wholeLayer` session 会根据当前上下文自动重建
- whole-layer `effectBounds` 已参与 preview / commit 的局部 redraw

当前阶段结论是：

- 当前这一轮列出的色彩调整收口项已经测试通过，可以阶段性告一段落
- 后续如果重新回到这条线，优先考虑的是进一步的局部优化测量和持续补测试，而不是主链补洞

单独状态文档见：

- [Docs/reference/COLOR_ADJUSTMENT_STATUS.md](Docs/reference/COLOR_ADJUSTMENT_STATUS.md)

### 2.10 当前纹理填充的真实状态

当前仓库里的 `纹理填充 / textureFill` 已经不是占位工具。

当前这条线的真实状态应当理解为：

- 正式工具入口已接通
- 复用现有 `lassoFill` 输入链
- 程序化模式已经跑通到可用基线
- 最终定稿链已经推进到 `phase 4.3`
- imported 模式已经接通共享 `tipImageLibrary`

当前更准确的阶段描述是：

- phase 0：工具入口与参数区占位
- phase 1：独立提交路径
- phase 2：拖动中实时切片
- phase 3：程序化断续纹理
- phase 4.0 / 4.1 / 4.2 / 4.3：final replay + smooth final mask + 状态清理
- imported final field：当前已从 `contain` 改成 `cover`

当前程序化模式的手测结论是：

- 可用
- 有轻微延迟，但目前可接受
- live 边缘仍有多边形感

当前 imported 模式要特别区分：

- 拖动中：已经改成区域映射 live field，默认优先复用 smooth final shape
- 松手后：仍然是区域纹理映射 final field，并且当前不会再留白

当前这条线最重要的结论是：

- 当前不要再把 `textureFill` 当成“未开始主线”
- 当前也不要再从失败的 `densify / open-path smoothing` 路线继续 patch
- imported 模式的 live / final 统一已经接通，后续默认不要再按旧 mismatch 基线接手
- 后续如果继续，优先方向更接近程序化模式的 live 多边形感与残余轻微延迟，而不是回头重做 imported 映射语义

专项状态文档见：

- [Docs/reference/TEXTURE_FILL_STATUS.md](Docs/reference/TEXTURE_FILL_STATUS.md)

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
  - 13580 行
- [Platform/macOS/UI/RightInspectorView.swift](Platform/macOS/UI/RightInspectorView.swift)
  - 5746 行
- [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)
  - 2984 行

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

截至 2026-05-23，这个仓库不应再被默认理解成“长期挂着一批历史性的性能 dirty tree”。

当前接手前的正确做法是：

- 先执行 `git status --short`
- 如果是 dirty，再看 `git diff --stat`
- 不要沿用“仓库默认带着旧性能 patch 尚未提交”的过期叙事

本轮代码侧已知未提交改动集中在：

- `Core/Selection/TextureFillProceduralField.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Platform/macOS/App/AppBootstrap.swift`
- `Platform/macOS/Services/BrushLibraryPersistenceController.swift`

其中后两项是为了阻止测试污染真实用户画笔库。

## 5. 构建与验证状态

2026-05-23 本地确认：

- `swift build` 通过
- `swift test --filter BrushLibraryStateTests` 通过
- 真实用户 `brush-library.json` 在测试后仍是 `13` 个 preset、`53` 个 tip image library item、`53` 个 tip image asset

最近一次仍可参考的 2026-04-14 子集验证：

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
5. [Docs/reference/TEXTURE_FILL_STATUS.md](Docs/reference/TEXTURE_FILL_STATUS.md)

如果任务明确与组合笔刷相关，再继续看：

- [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift)
- [Platform/macOS/App/WorkspaceViewModel.swift](Platform/macOS/App/WorkspaceViewModel.swift)
- [Platform/macOS/UI/CompoundBrushBuilderSheet.swift](Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)
