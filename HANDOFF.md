# ArtFlex Handoff

## 1. 一句话说明

ArtFlex 是旧版 `BrushCanvas` 的 Metal-first 重构版 macOS 绘图软件；当前仓库已经回到 **Git 回退后的稳定可编译基线**，此前那轮复杂笔尖 / 双通道 brush runtime 实验不再是活动主路径。

## 2. 这轮实际发生了什么

- 用户在 brush / dual-tip 大改后，用 Git 把仓库整体回退
- 回退后编译失败的原因，不是 Git 状态坏了，而是工作区里还残留了几份**未被 Git 管理的试验性文件**
- 这些残留文件已经删除，仓库现已恢复到：
  - 工作树干净
  - `swift build` 可通过
  - 基本 safety test 可通过

这轮清掉的残留文件有：

- [BrushQuickParametersPanel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/BrushQuickParametersPanel.swift)（试验版）
- [BrushTipDesignPanel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/BrushTipDesignPanel.swift)（试验版）
- [ComplexBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/ComplexBrushBuilderSheet.swift)
- [TipChannelEditorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/TipChannelEditorView.swift)
- [TipPreviewStrip.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/TipPreviewStrip.swift)
- [BrushTipMaskSanitizer.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/BrushTipMaskSanitizer.swift)

## 3. 当前 brush / dual-tip 的真实基线

### 3.1 当前 active 真相源

当前 brush / dual-tip 的活动真相源仍是旧 flat 字段模型：

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)
  - `secondarySizeRatio`
  - `secondarySpacingPhase`
  - `secondarySpacingPhaseJitter`
  - `secondaryScatter`
  - `secondaryScatterJitter`
  - `secondaryInvert`
  - 以及相关 jitter / offset 字段

### 3.2 当前 active ViewModel 接线

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)

当前 active setter 仍是旧 dual-tip 路径，包括：

- `setSecondarySizeRatio`
- `setSecondarySpacingPhase`
- `setSecondarySpacingPhaseJitter`
- `setSecondaryScatter`
- `setSecondaryScatterJitter`
- `setSecondaryInvert`
- 以及相关旧 offset / jitter setter

### 3.3 当前 active runtime

- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)

当前真实绘制仍是：

- stamp-based
- 每个 stamp 内局部算主/次笔尖
- 不是新的连续 stroke-space 次纹理场

### 3.4 当前 active preview

- [StageOneBrushPreviewRasterizer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushPreviewRasterizer.swift)

当前 preview 仍跟随旧 dual-tip 语义，不应再把它描述成“已与双通道新 runtime 对齐”。

### 3.5 当前 active UI

- [RightInspectorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RightInspectorView.swift)

当前 active UI 仍是旧 compact popover，不是复杂笔尖工作台。

## 4. 当前 brush 结果层面的真实判断

用户已经多轮手测确认：

- 结果仍有明显图章串珠感 / 管状截面感
- 轻压时没有真正体现次笔尖纹理
- 重压时没有真正切回主笔尖包络

结论是：

- 当前问题不是参数问题
- 当前问题是 runtime 骨架仍然是旧模型

## 5. 当前不要再做的事

- 不要继续在旧 dual-tip runtime 上打补丁
- 不要再把已回退掉的新 UI / 新 runtime 说成当前基线
- 不要再把 `primaryTipChannel / secondaryTipChannel / dualTipPressureBlend` 写成当前活动运行时真相源
- 不要再把 preview 写成“已经 pressure-aware 并与新 runtime 对齐”

## 6. 如果后续重开 Dual Tip，正确入口

如果后续要继续做 Dual Tip / 复杂笔尖，只能按**硬重构**重新开始，不能沿旧路径继续 patch：

1. 让 `BrushSettings` 的 runtime 真相源彻底收敛
2. 让旧 secondary flat 字段只保留给 legacy decode
3. 让 `WorkspaceViewModel` 旧 dual-tip setter 退出活动接线
4. 让 `StageOneBrushRenderer` 真的变成：
   - 主笔尖包络
   - 连续 stroke-space 次纹理场
   - 压力迁移混合
5. 让 `StageOneBrushPreviewRasterizer` 和 runtime 用同一套公式

在没有这一步之前，不要再声称“新的 dual-channel runtime 已经落地”。

## 7. 当前其它已接受的 UX 基线

- `笔尖形状设计 / 导航器` 默认打开 `导航器`
- `涂抹` 独立记住自己的 brush 设置
- `参考图` 面板当前冻结：
  - 默认打开 `参考图`
  - 小窗只负责固定 fit 预览与取色
  - 放大后使用独立浮窗浏览与取色
  - 浮窗关闭不再触发保存确认
- `颜色` 面板默认收起高级区

## 8. 当前验证状态

通过了：

- `swift build`
- `swift test --filter WorkspaceViewModelSafetyTests`

仍有现存 warning，但不是构建阻塞：

- `Package.swift` 的 `exclude/unhandled files`
- `OptimizedSliders.swift` 的 `onChange` 弃用 warning
- `TimelapseRecorderController.swift` 的 Sendable warning

## 9. 新线程建议先看

1. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
