# 色彩调整当前状态

最后更新：2026-04-15

## 1. 产品目标

`色彩调整` 的完整产品目标仍然保持为：

- 左侧提供 `色彩调整` 工具
- 右侧提供 `色彩调整参数` 面板
- 用户可以先用当前画笔在当前图层上涂出影响蒙版
- 然后通过参数面板调整：
  - 色相
  - 强度
  - 亮度
  - 对比度
  - 纯度
- 支持：
  - `E` 蒙版擦除
  - `B` 回到蒙版涂抹
  - `Esc` 取消
  - 后续阶段再接确认、预览、恢复默认、参数面板联动

## 2. 当前真实进度

当前只完成了 **阶段 A**。  
**阶段 B 尚未开始。**

这意味着当前仓库里的 `色彩调整` 不是完整功能，而是一个已经能稳定工作的“蒙版绘制阶段”。

## 3. 当前已经实现的行为

### 3.1 工具入口

- `ToolKind.brightnessAdjust`
- 显示名称：`色彩调整`
- 左侧工具栏已接入
- 默认快捷键：`O`

### 3.2 当前可用流程

当前实际可用流程只有：

1. 选择左侧 `色彩调整`
2. 在当前活动可编辑图层上绘制蒙版
3. 画布上出现蓝色蒙版预览
4. 按 `E` 切到蒙版擦除
5. 按 `B` 切回蒙版涂抹
6. 按 `Esc` 丢弃当前色彩调整会话

### 3.3 当前蒙版绘制语义

- 使用当前画笔库里选中的画笔
- 保留当前画笔大小、压感和透明度表现
- 蒙版绘制使用当前图层内容作为 alpha lock
- 只有在当前图层已有像素区域上才能画出有效蒙版
- 当前蓝色效果只是阶段 A 的蒙版可视化预览，不是正式色彩调整结果

### 3.4 当前工具内按键语义

- `O`
  - 进入 `色彩调整` 工具
- `E`
  - 在 `色彩调整` 工具内切到蒙版擦除模式
  - 不应切到普通橡皮工具
- `B`
  - 在 `色彩调整` 工具内切回蒙版涂抹模式
  - 不应切到普通画笔工具
- `Esc`
  - 丢弃当前色彩调整 session 和蓝色蒙版预览

### 3.5 当前与笔刷库的关系

当前 `色彩调整` 工具内允许切换画笔预设。

已确认的现状要求：

- 点击画笔库格子切换预设时，当前工具应保持 `色彩调整`
- 使用数字快捷键 `1...4` 切换画笔预设时，当前工具也应保持 `色彩调整`
- 切换画笔后，已存在的蒙版 session 不应因为工具被切回普通画笔而消失

## 4. 当前明确未实现的内容

以下内容 **当前仓库里还没有接通**：

- 右侧 `色彩调整参数` 面板
- 色相 / 强度 / 亮度 / 对比度 / 纯度滑块
- 直接拖参数面板创建色彩调整会话
- 选区直调
- 整层直调
- `确认`
- `恢复默认`
- `按住预览前后对比`
- 正式色彩调整应用到图层
- 与色彩调整正式应用对应的 undo / redo

因此，新线程不要把当前状态误判成“参数面板已经完成，只是在修 bug”。  
当前现实是：**只有阶段 A 的蒙版绘制链已经完成并稳定。**

## 5. 当前技术边界

当前 `ColorAdjustmentSession` 域模型已经包含：

- `painted`
- `selection`
- `wholeLayer`
- `ColorAdjustmentParameters`

但当前主路径只实际使用：

- `painted`
- `ColorAdjustmentBrushMode`
- `overlayOnly` 预览

`selection / wholeLayer / parameters` 目前只是阶段 B 以后会继续使用的骨架，不代表已接通。

## 6. 当前最关键的代码文件

### 6.1 域模型

- [Core/Application/ColorAdjustmentDomain.swift](../../Core/Application/ColorAdjustmentDomain.swift)

### 6.2 阶段 A 主逻辑

- [Platform/macOS/App/WorkspaceViewModel+ColorAdjustment.swift](../../Platform/macOS/App/WorkspaceViewModel+ColorAdjustment.swift)

当前阶段 A 的关键入口：

- `beginColorAdjustmentStrokeIfNeeded()`
- `applyColorAdjustmentStroke(samples:)`
- `endColorAdjustmentStroke()`
- `handleColorAdjustmentKeyDown(_:modifiers:)`
- `activeColorAdjustmentPreviewTexture(for:)`

### 6.3 接线入口

- [Platform/macOS/App/WorkspaceViewModel.swift](../../Platform/macOS/App/WorkspaceViewModel.swift)

关键接线点：

- `handleKeyDown(_:)`
- `applyStroke(samples:)`
- `beginStrokeIfNeeded()`
- `endStroke()`
- `applyBrushPreset(_:, showFeedback:)`
- `activateBrushPresetShortcut(slotIndex:)`
- `brushDisplayTexture(for:)`

### 6.4 工具与画布输入

- [Core/Tools/ToolKind.swift](../../Core/Tools/ToolKind.swift)
- [Platform/macOS/Canvas/MetalCanvasHost.swift](../../Platform/macOS/Canvas/MetalCanvasHost.swift)

### 6.5 阶段 A 预览 renderer

- [Rendering/Canvas/ColorAdjustmentRenderer.swift](../../Rendering/Canvas/ColorAdjustmentRenderer.swift)

当前它只负责蓝色蒙版 overlay preview。

## 7. 当前测试覆盖

当前最关键的阶段 A 回归测试在：

- [Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift](../../Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift)
- [Tests/ArtFlexTests/BrushInputDispatchTests.swift](../../Tests/ArtFlexTests/BrushInputDispatchTests.swift)

已覆盖的行为包括：

- 第一笔能创建蓝色蒙版预览
- `E` 切换到擦除模式
- `B` 切回涂抹模式
- `Esc` 丢弃 session 和 preview
- 切换到擦除模式时已有 preview 不直接消失
- 色彩调整工具显示十字与笔尖大小圈
- `E/B` 在色彩调整工具中优先走本地逻辑
- 点击画笔预设或使用数字快捷键切预设时，工具保持 `色彩调整`

## 8. 新线程接手时必须记住的结论

1. 当前色彩调整不是完整功能，只是阶段 A 已完成。
2. 当前仓库里没有正式的 `色彩调整参数` 面板实现。
3. 下一步如果继续开发，应该从 **阶段 B** 开始，不要回头重开旧的混合状态机方案。
4. 阶段 B 必须建立在“阶段 A 已稳定可用”的前提上继续往前接。
