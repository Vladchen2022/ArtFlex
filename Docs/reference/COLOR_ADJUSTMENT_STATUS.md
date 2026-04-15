# 色彩调整当前状态

最后更新：2026-04-15

## 1. 产品目标

`色彩调整` 的完整产品目标保持为：

- 左侧提供 `色彩调整` 工具
- 右侧参数区提供 `色彩调整参数` 面板
- 用户可以通过三种来源创建调整范围：
  - 当前画笔绘制的影响蒙版
  - 已提交选区
  - 当前图层整层
- 参数面板提供：
  - 色相
  - 强度
  - 亮度
  - 对比度
  - 纯度
- 支持：
  - `E` 蒙版擦除
  - `B` 回到蒙版涂抹
  - `Esc` 丢弃当前 session
  - `确认应用`
  - `恢复默认`
  - `按住预览`
  - undo / redo

## 2. 当前真实进度

当前已经不再停留在“只有阶段 A 蓝色蒙版绘制”的状态。

当前主链已经具备：

- 阶段 A 的 painted-mask 绘制与蓝色 overlay 预览
- 参数面板驱动的正式色彩预览
- `确认应用` 与正式写回
- `selection / wholeLayer` 直调
- `undo / redo` 弹窗处理后自动继续原历史导航
- `selection / wholeLayer` session 根据当前上下文自动重建
- 与正式写回对应的单图层 undo / redo
- 切工具 / 切图层 / 打开新文档 / 关闭 / history navigation 前的确认弹窗

这意味着当前仓库里的 `色彩调整` 已经是可确认、可回退、可跨 source 使用的一条正式编辑链。

结合最近一轮针对：

- `undo / redo` 自动继续
- `selection / wholeLayer` 自动重建
- whole-layer 局部 redraw

的专项测试结果，当前这部分可以视为阶段性稳定，可先告一段落。

## 3. 当前已经实现的行为

### 3.1 工具与面板入口

- `ToolKind.brightnessAdjust`
- 显示名称：`色彩调整`
- 左侧工具栏已接入
- 默认快捷键：`O`
- 右侧参数区现在有独立的 `色彩调整参数` 选项卡

### 3.2 Painted Mask 工作流

当前 painted-mask 路径为：

1. 选择左侧 `色彩调整`
2. 在当前活动可编辑图层上绘制影响蒙版
3. 参数为中性时，画布显示蓝色 overlay 预览
4. 调整参数后，preview texture 显示正式色彩预览
5. 可以使用 `确认应用` 正式写回，也可以 `Esc` 丢弃当前 session

已接通的工具内语义：

- `E` 切到蒙版擦除
- `B` 切回蒙版涂抹
- `Esc` 丢弃当前色彩调整 session
- 在色彩调整工具内切换画笔预设时，工具保持 `色彩调整`

### 3.3 Selection / Whole-Layer 直调工作流

当前不再要求“必须切到色彩调整工具才能调参数”。

当前行为是：

- 如果当前图层可编辑，且存在 committed selection：
  - 直接拖动色彩调整参数，会懒创建 `.selection` session
  - 当前工具可以继续保持为选区工具
- 如果当前图层可编辑，且没有 committed selection：
  - 直接拖动色彩调整参数，会懒创建 `.wholeLayer` session
  - 不需要切到 `brightnessAdjust`
- 以上两条路径都支持：
  - 实时预览
  - `确认应用`
  - undo / redo

### 3.4 当前参数面板与联动

当前参数面板已经具备：

- 色相条
- 强度 / 亮度 / 对比 / 纯度滑块
- `确认应用`
- `恢复默认`
- `按住预览`

当前参数区与其他选项卡的联动规则是：

- 软件启动时默认显示：
  - `导航器`
  - `色彩调整参数`
- 选择以下工具时，参数区会自动切到 `色彩调整参数`：
  - `色彩调整`
  - `套索选区`
  - `矩形选区`
  - `椭圆选区`
- 离开这些工具时，参数区会回到进入前的 tab
- 顶部切到 `笔尖形状设计` 时，如果参数区当前停在 `色彩调整参数`，会自动切回 `画笔参数`

### 3.5 当前快捷键语义

- `O`
  - 进入 `色彩调整` 工具
- `E`
  - 在色彩调整工具的 painted-mask 路径里切到蒙版擦除
- `B`
  - 在色彩调整工具的 painted-mask 路径里切回蒙版涂抹
- `Esc`
  - 丢弃当前色彩调整 session

另外当前还已确认：

- 在色彩调整工具中，`B/E` 会优先走本地蒙版逻辑
- 一旦当前 session 已确认或已丢弃，`B/E` 会回到正常工具快捷键语义

### 3.6 当前 source 与 renderer 语义

当前 `ColorAdjustmentSession` 已正式使用：

- `.painted`
- `.selection`
- `.wholeLayer`
- `ColorAdjustmentParameters`

当前三条 source 的语义分别为：

- `.painted`
  - 使用独立 mask texture
  - 画笔绘制受当前图层 alpha lock 限制
- `.selection`
  - 使用 committed selection 栅格化后的 mask texture
- `.wholeLayer`
  - 使用 source alpha 作为影响范围

当前 preview 与最终 commit 共享同一条 `ColorAdjustmentRenderer` 渲染路径，不再是“蓝色 overlay 一条链，正式应用另一条链”的分裂状态。

当前 whole-layer 还会复用活动图层的 content bounds 作为 `effectBounds`，用于 preview / commit 的局部 redraw。

## 4. 当前阶段结论

当前结论是：

- 当前主链已接通，且本轮列出的关键收口项已经测试通过
- 当前不再把色彩调整视为“紧急待补洞模块”
- 这条线现在可以阶段性暂停

后续如果重新回到这条线，最值得继续推进的是：

- 持续补充文档与回归测试
- 继续测量 whole-layer `effectBounds` 的局部 redraw / commit 收益

## 5. 当前最关键的代码文件

### 5.1 域模型

- [Core/Application/ColorAdjustmentDomain.swift](../../Core/Application/ColorAdjustmentDomain.swift)

### 5.2 主逻辑

- [Platform/macOS/App/WorkspaceViewModel+ColorAdjustment.swift](../../Platform/macOS/App/WorkspaceViewModel+ColorAdjustment.swift)

关键入口包括：

- `beginColorAdjustmentStrokeIfNeeded()`
- `applyColorAdjustmentStroke(samples:)`
- `endColorAdjustmentStroke()`
- `updateColorAdjustmentParameters(_:)`
- `confirmColorAdjustmentSession()`
- `resolveColorAdjustmentSessionIfNeeded(reason:)`
- `activeColorAdjustmentPreviewTexture(for:)`

### 5.3 接线入口

- [Platform/macOS/App/WorkspaceViewModel.swift](../../Platform/macOS/App/WorkspaceViewModel.swift)

关键接线点包括：

- `selectTool(_:)`
- `undo() / redo()`
- `selectLayer(_:)`
- `createNewCanvasDiscardingUnsavedChanges(...)`
- `brushDisplayTexture(for:)`

### 5.4 参数面板 UI

- [Platform/macOS/UI/RightInspectorView.swift](../../Platform/macOS/UI/RightInspectorView.swift)

### 5.5 Preview / Commit Renderer

- [Rendering/Canvas/ColorAdjustmentRenderer.swift](../../Rendering/Canvas/ColorAdjustmentRenderer.swift)

## 6. 当前测试覆盖

当前最关键的回归测试在：

- [Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift](../../Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift)
- [Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift](../../Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift)
- [Tests/ArtFlexTests/BrushInputDispatchTests.swift](../../Tests/ArtFlexTests/BrushInputDispatchTests.swift)

当前已覆盖的行为包括：

- 第一笔能创建蓝色蒙版预览
- `E / B / Esc` 语义正确
- painted-mask 参数预览
- painted-mask 持续补画时参数持续生效
- `恢复默认`
- `按住预览`
- selection 直调预览
- whole-layer 直调预览
- committed selection 变化后 selection session 自动重建
- 图层像素变化后 whole-layer session 自动重建
- 三条 source 的确认应用与 undo / redo
- `undo / redo` 弹窗选完后自动继续原 history navigation
- 切工具 / 切图层 / 新建画布 / history navigation 前的 session 收口

## 7. 新线程接手时必须记住的结论

1. 当前色彩调整已经不是“阶段 A only”。
2. `brightnessAdjust` 现在主要承担 painted-mask 路径；selection / whole-layer 直调不需要切到该工具。
3. 后续继续开发时，应沿当前统一的 `ColorAdjustmentSession / ColorAdjustmentRenderer / confirm chain` 往前收口，不要回头重开旧混合状态机。
4. 当前最值得继续做的是：
   - 如果没有新产品决策，这条线可以先暂停
   - 重新启动时优先做持续补测试和进一步的局部优化测量
