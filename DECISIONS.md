# DECISIONS

最后更新：2026-04-12

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

### 3.3 当前警惕无界增长

虽然项目功能面已经扩大，但继续开发时仍应遵守：

- 决策先行
- 改动聚焦
- 不顺手拉出新主线
- 不把临时优化建议文档当成实施命令
