# ArtFlex 当前状态

## 1. 项目概况

ArtFlex 是旧版 `BrushCanvas` 的 **Metal-first** 重构版 macOS 绘图软件。  
产品层仍保留成熟桌面绘图软件的主结构：

- 顶部工具栏
- 左侧工具栏
- 中央视图画布
- 右侧参数 / 颜色 / 笔刷 / 生成器 / 参考图区域
- 图层面板

当前工作基线是：**Git 回退后的稳定版本**。  
此前那轮“复杂笔尖工作台 / 双通道运行时 / 主次迁移曲线”的实验改动已经回退，不是当前活动基线。

## 2. 当前代码真实状态

### 2.1 构建状态

- 当前工作树已清理为干净状态
- `swift build` 通过
- `swift test --filter WorkspaceViewModelSafetyTests` 通过

当前仍有现存 warning，但不阻塞构建：

- `Package.swift` 的 `exclude/unhandled files` warning
- `OptimizedSliders.swift` 的 `onChange` 弃用 warning
- `TimelapseRecorderController.swift` 的 Sendable warning

### 2.2 画笔系统当前真实基线

当前 `Dual Tip / 组合笔尖` 仍是**旧 flat-field + stamp-based runtime**：

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)
  - 当前活动真相源仍包含：
    - `secondarySizeRatio`
    - `secondarySpacingPhase`
    - `secondarySpacingPhaseJitter`
    - `secondaryScatter`
    - `secondaryScatterJitter`
    - `secondaryInvert`
    - 以及相关 jitter / offset 字段
- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
  - 当前活动接线仍通过旧 setter 写入运行时
- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)
  - 当前真实绘制仍是 stamp-based 合成
  - 次笔尖仍不是整条笔迹连续纹理场
- [StageOneBrushPreviewRasterizer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushPreviewRasterizer.swift)
  - 当前预览仍跟随旧 dual-tip 语义
  - 不是新的双通道 pressure-aware 运行时镜像

### 2.3 当前 active Dual Tip UI

当前活动 UI 在：

- [RightInspectorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RightInspectorView.swift)

当前 active 交互仍是旧的 compact popover，而不是独立“复杂笔尖工作台”。

当前 active 参数仍主要包括：

- `强度`
- `次笔尖大小比例`
- `大小抖动`
- `角度抖动`
- `角度偏移`
- `节距错相`
- `错相抖动`
- `散布`
- `散布抖动`
- `反相`

当前 active 组合模式：

- `调制`
- `减去`
- `相交`

### 2.4 不再属于当前基线的内容

以下内容**不是当前活动代码基线**：

- `ComplexBrushBuilderSheet`
- `TipChannelEditorView`
- `TipPreviewStrip`
- 基于 `primaryTipChannel / secondaryTipChannel / dualTipPressureBlend` 的活动 runtime 主路径
- 新版“主通道 / 次通道 / 压力迁移”工作台 UI

这些文件和思路此前是试验性改动，现已回退，不应再写进当前状态文档里当成已落地能力。

## 3. 当前已接受的功能 / UX 基线

- 右侧顶部 `笔尖形状设计 / 导航器` 默认打开 `导航器`
- `涂抹` 会独立记住自己的 brush 设置
- `参考图` 面板当前冻结：
  - 默认打开 `参考图`
  - 小窗只负责固定 fit 预览与取色
  - 放大后使用独立浮窗浏览与取色
  - 关闭浮窗不再弹出保存工程确认
- `颜色` 面板默认收起高级区，通过底部细把手展开

## 4. 当前 brush / dual-tip 的真实问题

当前最重要的问题不是参数，而是运行时骨架仍然是旧模型：

- 仍容易出现图章串珠感 / 管状连续截面
- 轻压时不会明显体现次笔尖纹理
- 重压时不会明显回到主笔尖包络
- 结果层面仍不符合“轻压偏次、重压偏主”的目标

也就是说，当前问题是**runtime 模型问题**，不是单纯调参问题。

## 5. 当前如果要继续做 Dual Tip，正确方向

当前文档基线已明确：

- 不应继续在旧 dual-tip runtime 上打补丁
- 后续如果重开这条线，应该按**硬重构**重新开始：
  - runtime 真相源收敛
  - 旧 flat 字段退出活动路径
  - 新 preview/runtime 同公式

在没有重新立项之前，当前仓库应继续按“已回退的稳定版本”理解。

恢复上下文时，先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
