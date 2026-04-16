# 压感曲线当前状态

最后更新：2026-04-16

## 1. 产品目标

右侧画笔参数区里的 `大小压感` 和 `透明压感`，当前目标已经不再是：

- 只保留三条滑块
- 只显示一条示意曲线

当前产品目标是：

- 保留顶部预设按钮
- 提供可直接拖拽锚点的真实曲线编辑器
- 实际出笔、右侧预览、HUD 预览和保存格式尽量共享同一套曲线真相源
- 继续兼容旧笔刷里的 `low / mid / high` 三值存档

## 2. 当前真实状态

当前仓库里的主笔刷 `大小压感 / 透明压感` 已经完成了从“三滑块预览”到“真实曲线状态”的升级。

当前已经接通的内容包括：

- `BrushSettings` 新增：
  - `sizePressureCurve`
  - `opacityPressureCurve`
- 旧字段仍保留并兼容：
  - `sizeCurveLow / Mid / High`
  - `opacityCurveLow / Mid / High`
- 实际出笔采样已切到真实曲线状态
- 右侧主笔刷参数弹窗已改用 `CurveEditorView`
- `QuickColorPickerHUD` 和主画笔预览都已复用同一套曲线采样
- 预览缓存 key 已包含真实曲线点，避免“锚点改了但预览还是旧曲线”

这意味着当前压感曲线已经不是“只改 UI 线条”，而是：

- 数据模型
- 运行时采样
- UI 预览
- 缓存键

四层都已经接到同一条真实曲线链路上。

## 3. 当前数据语义

### 3.1 新旧数据并存

当前 `BrushSettings` 里同时存在两套语义：

- 新语义：`CurveChannelState`
- 旧语义：`low / mid / high`

当前约束是：

- 新存档优先保存真实曲线状态
- 旧存档仍能通过 legacy 转换恢复出一条兼容曲线
- 如果未来继续改这块，不要直接删除旧字段兼容层，除非已经完成完整迁移方案

### 3.2 曲线真相源

当前压感曲线真正的采样入口已经统一到：

- [Core/Tools/ToolKind.swift](../../Core/Tools/ToolKind.swift)

后续线程不要再单独写：

- 一套 UI 预览曲线
- 一套实际出笔曲线
- 一套 HUD 预览曲线

如果后续继续调整压感手感，优先继续沿这一条共享采样链修改。

## 4. 关键文件

### 4.1 数据与采样

- [Core/Tools/ToolKind.swift](../../Core/Tools/ToolKind.swift)

### 4.2 状态接线

- [Platform/macOS/App/WorkspaceViewModel.swift](../../Platform/macOS/App/WorkspaceViewModel.swift)

### 4.3 UI

- [Platform/macOS/UI/RightInspectorView.swift](../../Platform/macOS/UI/RightInspectorView.swift)
- [Platform/macOS/UI/CurveEditorView.swift](../../Platform/macOS/UI/CurveEditorView.swift)
- [Platform/macOS/UI/QuickColorPickerHUD.swift](../../Platform/macOS/UI/QuickColorPickerHUD.swift)

### 4.4 运行时与预览

- [Rendering/Canvas/StageOneBrushRenderer.swift](../../Rendering/Canvas/StageOneBrushRenderer.swift)
- [Rendering/Canvas/StageOneBrushPreviewRasterizer.swift](../../Rendering/Canvas/StageOneBrushPreviewRasterizer.swift)

### 4.5 测试

- [Tests/ArtFlexTests/PressureInputTests.swift](../../Tests/ArtFlexTests/PressureInputTests.swift)

## 5. 当前 UI 状态

压感曲线弹窗顶部的预设条当前已经恢复可见。

当前可以正常看到并使用：

- `轻起笔`
- `均衡`
- `快速增压`
- `恢复默认`

因此当前不要再把这条线按“预设逻辑生效但视觉不可见”的旧问题理解。

更接近真实状态的是：

- 曲线逻辑和采样已经接通
- 预设条也已经恢复到可见可用状态
- 当前后续优化重点更适合放在交互细节和 UI 打磨，而不是继续排查预设区是否被遮挡

## 6. 当前结论

当前压感曲线这条线已经进入“核心链路接通、主交互可用”的阶段。

不要再按旧认知理解成：

- 只有三条滑块
- 只是示意曲线
- 实际出笔还没用上

更准确的理解应当是：

- 主链已经完成升级
- 预设条已经恢复可见
- 当前后续工作更偏交互与视觉打磨，而不是主链补洞
