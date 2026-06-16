# DECISIONS

最后更新：2026-05-23

本文件记录当前代码和产品层已经确认、后续线程不应随意推翻的决策。

## 0. 项目级红线

### 0.1 产品结构继续沿用成熟桌面绘图软件路径

默认保持：

- 顶部工具栏
- 左侧工具栏
- 中央视图画布
- 右侧 inspector
- 图层面板
- 笔尖形状设计区域

除非明确进入产品设计调整阶段，不要为了实现方便重排主 UI 结构。

### 0.2 继续保持 Metal-first

不允许把旧项目的 CPU 画布合成思路重新带回主链，包括：

- 整图 CGContext 合成显示
- 以 CPU bitmap / redraw flag 作为默认真相源
- 用大量整图 CGImage / CGContext 拷贝支撑主交互

### 0.3 显示 / 编辑 / 取样 / 导出必须共享同一套真相源

当前仍然坚持：

- 文档颜色标准：`RGBA8 + premultiplied alpha + sRGB`
- GPU surface / drawable：`bgra8Unorm_srgb`
- 导出和采样不允许再各走一条独立“补格式”链

任何通道交换、颜色补偿、premultiply / unpremultiply 的必要处理，都必须收敛在基础设施层，而不是散落在业务和工具层。

### 0.4 测试不得写入真实用户数据目录

`~/Library/Application Support/ArtFlex` 是用户真实数据目录，不是测试 fixture。

后续任何测试只要会创建 `AppBootstrap`、`WorkspaceViewModel`、画笔库或图案库持久化控制器，都必须满足其中之一：

- 依赖 `AppBootstrap` 在 XCTest 环境下的临时持久化根目录重定向
- 显式注入临时 `BrushLibraryPersistenceController`
- 显式注入临时 `PatternLibraryPersistenceController`

不要再让测试默认写真实 `brush-library.json` 或真实图案库目录。

## 1. 当前真实实现层决策

### 1.1 `WorkspaceViewModel` 目前是状态中心

当前代码现实不是“小而美的完全拆分状态树”，而是：

- `WorkspaceViewModel` 承担大量主工作流接线
- `RightInspectorView` 承担大量右侧 UI

这不是理想终态，但在没有明确切片前，不要发起宽泛的大拆分。  
如需拆分，应按具体子系统小步推进。

### 1.2 快照对比 / ideation / timelapse 都是主工程能力

这些不是临时实验：

- `snapshotCompareSession`
- `ideationSession`
- `TimelapseRecorderController`

后续线程不应把它们当作可以默认删除或忽略的旁支。

### 1.3 组合笔刷已经是正式主路径

当前组合笔刷的活动真相源是：

- `CompoundBrushSettings`
- `WorkspaceViewModel` 中的相关 setter
- `CompoundBrushBuilderSheet`
- `StageOneBrushRenderer` 的 compound 路径

不要再把“旧 dual-tip 回退基线”当作当前状态。

## 2. 当前阶段决策

### 2.1 当前主线是 targeted iteration，不是大范围返工

当前默认工作方式应是：

- 对组合笔刷外观做局部收口
- 对颜色 / 色标 / 黑白参考 / 画笔库工作流做局部打磨
- 对 history / serializer / renderer / presenter 做 targeted 性能与稳定性修正

不应默认重新打开大范围性能项目或全局架构返工。

### 2.2 当前组合笔刷默认不要再重查 plumbing

如果没有新的硬证据，默认冻结：

- sample builder
- 单 stamp tip sampling
- 主 / 次 tip 资源接线
- dominance / opacity 曲线基础结构
- projected / clipped 基本语义
- display / composite / export 主链

当前继续迭代组合笔刷时，优先看主层外观表达。

### 2.3 颜色与像素规范不再回到“边做边补”

当前项目已经具备：

- `ArtColorStandard`
- `LinearPremultipliedColor`
- 统一的 layer texture / serializer / export 基础链

后续新功能接入时，不允许再走“先做功能，之后再修颜色规范”的路线。

### 2.4 右侧画笔参数区继续按“整体表现 vs 内部结构”理解

当前已确认：

- `间距 / 散布 / 旋转 / 抖动`
  - 默认仍按结构类参数理解
- `杂色 / 杂色对比 / 大小压感 / 透明压感 / 透明修正`
  - 默认按整体画笔表现理解

其中在组合笔刷模式下：

- builder 内部主笔尖 / 次笔尖参数负责内部结构
- 右侧参数区中的上述“整体表现类参数”负责整支组合笔刷最终表现

另外：

- `大小压感 / 透明压感` 当前已确定继续按“真实曲线编辑器”方向演进
- 当前不再回到“三滑块 + 独立示意曲线”的旧方案
- 实际出笔采样、右侧曲线编辑器、HUD 预览和笔刷预览应尽量共享同一套曲线真相源
- 旧 `low / mid / high` 字段当前仍作为兼容层保留，不应在没有完整迁移方案前直接删除

后续线程不要再把这些整体表现类参数重新绑回“主笔尖参数 = 外层参数”的旧语义。

### 2.5 拾色器后续修改必须同时保持显示、取色和滑块语义一致

当前已确认：

- 右侧颜色面板拾色器
- `Shift+Z` HUD 快速拾色器

必须作为一个整体来看。

任何继续修改这块的工作，都必须同时保证：

- 色立方显示
- 点选实际取色结果
- 当前颜色反推拾色器位置
- `光色 / 明度 / 纯度` 滑块语义

四者一致。

不要只改其中一层。

另外当前已确认：

- `Shift+Z` HUD 里的“最近笔触调整组”是正式工作流，不是临时 patch
- 它当前只属于 `brush` 工具，不应默认扩展成全局工具级能力
- 第一版已冻结的交互语义是：
  - 默认选中最近 `1` 笔
  - 最多回溯最近 `20` 笔
  - 当前支持透明度 / 明度 / 饱和度
  - `最近` 滑块最右是 `1`，往左退回更多笔
- 这组最近笔触不是显式新图层，而是隐藏可调后缀
- 一旦离开画笔语境，应先自动固化到当前图层像素，再进入后续操作

后续线程如果继续动这块，默认应保持：

- HUD 入口不变
- “隐藏可调后缀”这个产品定位不变
- 自动固化优先于跨工具悬挂状态

### 2.6 色彩调整已经推进到可确认主链

当前已确认：

- `色彩调整` 工具已经重新接回主工程
- `painted mask`、`selection`、`wholeLayer` 三条 source 都已经接进统一 `ColorAdjustmentSession`
- 参数面板、正式调整写回、确认链、离开编辑态提示和单图层 history 对接都已经接通
- `brightnessAdjust` 现在主要承担 painted-mask 路径；选区 / 整层直调不再要求切到该工具

因此后续线程默认应按以下理解继续：

- 当前不要再把色彩调整误判成“只有阶段 A 蓝色蒙版”
- 当前不要再回到旧的 panel-direct / selection / whole-layer 混合状态机方案
- 后续应继续沿现在这条统一 session / renderer / confirm chain 往前收口，而不是重新发散旧状态机
- 当前这套滑块算法与面板主交互已经冻结；如果没有明确产品决策，不要再随意改手感

### 2.7 肌理填充当前继续沿“套索输入复用 + final-only 修正”理解

当前 `textureFill` 已确认的实现策略是：

- 继续复用 `lassoFill` 的输入骨架
- 程序化模式 live 路径继续沿第三阶段 direct-to-layer 方案
- 第四阶段的修正只允许主要落在 final 定稿链

当前 accepted 基线是：

- `phase 4.3 + imported mapped live/final + final cover`

也就是说：

- 程序化模式：继续保持当前可用基线
- imported 模式：live / final 都已经走区域映射语义，而且 final field 不再留白

当前不要再默认重开这些已失败路线：

- live 路径 densify 修边缘
- 首段 cap + 长段 densify
- 把开放路径平滑直接塞进 live 切片链

如果后续继续开发 `textureFill`，当前优先级应是：

- 默认先看程序化模式的 live 多边形感和残余轻微延迟
- 不要再把 imported live/final 统一当成当前头号缺口

## 3. 当前不要随意改动的地方

### 3.1 参考图与 LAB 黑白参考已经接通

参考图系统、参考图浮窗和 LAB 黑白参考都已是活动主链。  
如果没有明确需求，不要把它们退回占位或只读 demo 状态。

### 3.2 画笔库与 tip image library 已经是正式工作流

当前已经有：

- 画笔库持久化
- 导入 / 导出
- 槽位快捷键
- tip image library 引用关系检查

不要把这条链写回成“临时 UI”。

另外当前已确认的画笔库工作流约束还包括：

- 第一排最近使用首行只记录第三排及之后的正式库画笔
- 第二排 `1/2/3/4` 快捷槽位不进入最近使用首行
- `Shift+Z` HUD 里的 4 个快捷笔刷继续绑定第二排 `1/2/3/4`
- 软件启动默认使用第二排第一个正式画笔（`slot 0`），不是最近使用首行

后续线程不要再按“画笔库数组第一个”或“最近使用首行第一个”理解启动默认画笔。

画笔库持久化的当前决策是：

- 真实用户文件路径保持 `~/Library/Application Support/ArtFlex/brush-library.json`
- archive 同时保存 `library`、`tipImageLibrary`、`tipImageAssets`
- `BrushLibraryPersistenceController` 必须继续支持测试用 `rootDirectoryURL` 注入
- `AppBootstrap` 在 XCTest 环境下默认把画笔库 / 图案库持久化根目录重定向到临时目录
- 任何新增 `AppBootstrap()` 测试都不应再污染真实用户画笔库

### 3.3 当前警惕无界增长

虽然项目功能面已经扩大，但继续开发时仍应遵守：

- 决策先行
- 改动聚焦
- 不顺手拉出新主线
- 不把临时优化建议文档当成实施命令

### 3.4 当前应用图标继续沿单资源链维护

当前已确认：

- 应用图标仍然由 `Platform/macOS/Resources/AppIcon.png` 提供
- 运行时通过 `ArtFlexApp.applyApplicationIconIfAvailable()` 设置到 `NSApp.applicationIconImage`
- 当前不要默认假设项目已经切到 `.appiconset` / `.icns` 主链
- 最近一次应用图标更新是替换内部 artwork，同时保留现有图标的整体大小与圆角轮廓

后续如果只是继续调整应用图标外观，默认先继续修这张 PNG 资源，不要为了小改动就先扩出另一套图标资源体系。

### 3.5 肌理填充专项状态默认看独立文档

当前 `textureFill` 已经有独立状态文档：

- [Docs/reference/TEXTURE_FILL_STATUS.md](Docs/reference/TEXTURE_FILL_STATUS.md)

后续线程如果继续处理：

- `phase 4.x`
- imported 模式
- `tipImageLibrary` 对接

默认先读这份专项文档，不要从零散线程结论重新猜当前 accepted 基线。
