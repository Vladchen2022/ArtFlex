# DECISIONS

最后更新：2026-04-06

本文件记录：**当前代码和产品层已经确认的关键决策。**  
如果后续改动与这些点冲突，应先重新讨论，而不是直接改代码。

## 0. 当前阶段与红线

### 0.1 当前工作基线以 Git 回退后的稳定版本为准

已确认：

- 当前活动基线是用户用 Git 回退后的版本
- 此前那轮复杂笔尖 / 双通道 brush runtime 实验不再视为当前主路径
- 文档、handoff、后续开发都必须以这条回退后的真实代码为准

### 0.2 回退后的仓库必须保持可编译、可测试、工作树干净

已确认：

- 回退后残留的未跟踪试验文件已经清理
- 当前工作树应保持干净
- 当前最低验证基线是：
  - `swift build`
  - `swift test --filter WorkspaceViewModelSafetyTests`

### 0.3 当前 Dual Tip 仍是旧 flat-field + stamp runtime

已确认：

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift) 当前活动真相源仍包含旧 secondary flat 字段
- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift) 当前仍通过旧 secondary setter 写入运行时
- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift) 当前真实绘制仍是 stamp-based
- [StageOneBrushPreviewRasterizer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushPreviewRasterizer.swift) 当前 preview 仍是旧 dual-tip 语义
- 不允许再把当前代码描述成“主通道 / 次通道 / 压力迁移的新 runtime 已经落地”

### 0.4 后续如果重开 Dual Tip，只能硬重构，不能继续补旧路径

已确认：

- 不允许继续在旧 dual-tip runtime 上打补丁
- 后续如果重开这条线，必须先停用旧主路径，再重建新主路径
- 正确目标必须是：
  - 旧 flat secondary 字段只保留给 legacy decode
  - runtime 真相源收敛
  - 主笔尖包络 + 连续 stroke-space 次纹理场 + 压力迁移混合
  - preview / runtime 同公式

### 0.5 参考图面板当前冻结

已确认：

- 默认打开 `参考图`
- 小窗只负责固定 fit 预览与取色
- 放大后使用独立浮窗浏览与取色
- 参考图浮窗关闭不触发保存确认
- 在没有明确新需求前，不再主动改这块

### 0.6 颜色面板当前默认收起高级区

已确认：

- `光色条 + 光色 / 明度 / 纯度 / 对比 / 补色` 收进底部高级区
- 启动时默认收起
- 通过底部细把手展开 / 收起

### 0.7 右侧顶部 tab 当前默认打开导航器

已确认：

- `笔尖形状设计 / 导航器` 默认打开 `导航器`

### 0.8 涂抹工具当前独立记忆自己的 brush 设置

已确认：

- 第一次切到涂抹时可继承当前普通画笔
- 一旦在涂抹里改过参数，之后必须恢复自己上一次的设置
- 不再永远跟随最新普通画笔

## 1. 当前 brush / dual-tip 不要再误写的内容

以下内容当前都**不是**已落地事实：

- `ComplexBrushBuilderSheet` 是当前活动 UI
- `TipChannelEditorView` 是当前活动 UI
- `TipPreviewStrip` 是当前活动 UI
- `primaryTipChannel / secondaryTipChannel / dualTipPressureBlend` 是当前活动 runtime 真相源
- 当前 preview 已与新的双通道 runtime 严格对齐

如果后续再把这些写进文档，视为文档与当前代码脱节。

## 2. 当前已接受的项目层方向

- 项目仍保持 Metal-first 方向
- 不允许把旧 CPU 画布思路重新带回主链
- brush / dual-tip 的核心问题当前仍被视为**runtime 架构问题**，不是调参问题
- 未来如果继续做 brush runtime，优先级是：
  1. 运行时骨架正确
  2. 预览和运行时一致
  3. 结果符合产品目标
  4. 再谈参数和 UI 扩面
