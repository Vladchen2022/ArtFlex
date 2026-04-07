# CURRENT_TASK

## 1. 当前任务

- 当前任务已切换为：**把文档同步到 Git 回退后的真实代码基线，并在这条基线上继续开发**
- 当前仓库已经回到**可编译、可测试**状态；这一轮不再继续沿用之前那套半成品“双通道 / 复杂笔尖工作台”改动
- 当前 `Dual Tip / 组合笔尖` 的真实主路径仍是**旧 flat 字段 + stamp-based runtime**，不是新的 `primary channel / secondary channel / pressure blend` 运行时
- 当前需要默认接受的事实：
  - [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift) 里仍以旧 dual-tip flat 字段作为活动真相源
  - [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift) 里旧 `setSecondarySizeRatio / setSecondarySpacingPhase / setSecondaryScatter / setSecondaryInvert ...` 仍在活动接线
  - [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift) 当前仍是 stamp-based dual-tip 合成
  - [StageOneBrushPreviewRasterizer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushPreviewRasterizer.swift) 当前仍按旧 dual-tip 预览语义工作

## 2. 当前已接受的 UX 基线

- 右侧顶部 `笔尖形状设计 / 导航器` 选项卡默认打开 `导航器`
- `涂抹` 已改成独立记住自己上一次使用的画笔设置，不再永远跟随最新普通画笔
- `参考图` 面板当前冻结：
  - 默认打开 `参考图`
  - 小窗只负责固定 fit 预览与取色
  - 放大后用独立浮窗浏览与取色
  - 关闭参考图浮窗不再弹出保存工程确认
- `颜色` 面板当前默认收起高级区；`光色条 + 光色 / 明度 / 纯度 / 对比 / 补色` 收进底部可展开区域

## 3. 当前 Dual Tip / 组合笔尖真实状态

- 当前 active UI 仍是 [RightInspectorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RightInspectorView.swift) 里的**旧 compact popover**
- 当前真实参数仍包括：
  - `strength`
  - `secondarySizeRatio`
  - `secondarySizeJitter`
  - `secondaryAngleJitterDegrees`
  - `secondaryAngleOffsetDegrees`
  - `secondarySpacingPhase`
  - `secondarySpacingPhaseJitter`
  - `secondaryScatter`
  - `secondaryScatterJitter`
  - `secondaryInvert`
- 当前真实组合模式仍是：
  - `multiply`
  - `subtract`
  - `intersect`
- 当前不存在活动中的：
  - `ComplexBrushBuilderSheet`
  - `TipChannelEditorView`
  - `TipPreviewStrip`
  - `primaryTipChannel / secondaryTipChannel / dualTipPressureBlend` 运行时主路径

## 4. 当前阶段约束

- 不要继续把当前代码误写成“已经完成双通道 hard rebuild”
- 不要再把已回退掉的新 UI / 新运行时方案写进 handoff 文档
- 如果后续要继续做 Dual Tip runtime，必须按**硬重构**思路重新开始，不能继续在旧 stamp runtime 上打补丁
- 在没有明确重新授权之前，不要再主动重启那条大范围 Dual Tip 重构

## 5. 当前推荐顺序

1. 保持当前 Git 回退基线可编译、可测试、可 handoff
2. 文档全部与当前真实代码对齐
3. 如果后续继续做 Dual Tip，只从“硬重构运行时”重新立项，不再从旧 patch 继续扩

## 6. 不要做的事

- 不要再引用已删除的试验性 UI 文件：
  - `BrushQuickParametersPanel.swift`（试验版）
  - `BrushTipDesignPanel.swift`（试验版）
  - `ComplexBrushBuilderSheet.swift`
  - `TipChannelEditorView.swift`
  - `TipPreviewStrip.swift`
  - `BrushTipMaskSanitizer.swift`
- 不要再把旧 flat dual-tip 字段说成“只剩 legacy decode”
- 不要把当前 preview 说成“已与新双通道 runtime 对齐”
- 不要把当前 brush 结果问题继续归因于参数；当前主要问题仍是 runtime 模型

恢复开发时，默认先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
