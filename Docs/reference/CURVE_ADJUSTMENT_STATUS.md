# 曲线调整当前状态

最后更新：2026-04-16

## 1. 产品目标

`曲线调整` 的完整产品目标保持为：

- 右侧参数区提供独立的 `曲线` 面板
- 用户可以编辑：
  - `RGB`
  - `红`
  - `绿`
  - `蓝`
- 曲线编辑器支持：
  - 新增锚点
  - 拖动锚点
  - 删除中间锚点
  - 移动黑场 / 白场端点
- 最终应支持三种影响来源：
  - 当前图层整层
  - 已提交选区
  - painted mask
- 支持：
  - `确认应用`
  - `恢复默认`
  - `按住预览`
  - undo / redo

## 2. 当前真实进度

当前仓库里的 `曲线调整` 已完成 `Phase A + Phase B`，但还没有推进到 `selection` 和 `painted mask`。

当前已经接通的主链包括：

- 右侧参数区 `曲线` 选项卡
- 独立域模型：
  - `CurveChannel`
  - `CurveChannelState`
  - `CurveAdjustmentParameters`
  - `CurveAdjustmentSession`
- 独立曲线编辑器 `CurveEditorView`
- 独立渲染器 `CurveAdjustmentRenderer`
- `CPU 构建 LUT -> GPU 采样 LUT`
- `wholeLayer` 直调
- `确认应用` 与正式写回
- 单图层 undo / redo
- 切工具 / 切图层 / 打开新文档 / 关闭 / history navigation 前的确认 / 放弃 / 取消提示

这意味着当前曲线调整已经不是“只有面板草图”，而是一条可确认、可回退的正式整层调整链。

## 3. 当前已经实现的行为

### 3.1 面板入口

当前入口是右侧参数区的 `曲线` 选项卡。

当前不是：

- 左侧独立工具
- 新的 `ToolKind`

当前行为是：

- 用户点击 `曲线` 选项卡后，会为当前活动可编辑图层懒创建 `wholeLayer` session
- 如果当前已经存在色彩调整 session，曲线 tab 不会强行切进去

### 3.2 当前曲线编辑器语义

当前曲线编辑器已经支持：

- `RGB / 红 / 绿 / 蓝` 四通道切换
- 点击曲线附近新增锚点
- 拖动中间锚点
- 拖动两个端点
- 双击中间锚点删除
- 选中中间锚点后按 `delete / backspace` 删除
- 右键中间锚点弹出小菜单后点 `删除锚点`

当前端点语义为：

- 左端点决定最暗输入值对应的输出
- 右端点决定最亮输入值对应的输出
- 端点移动后，LUT 两端输出会随之变化

当前右侧通道按钮布局已经定稿为：

- 左侧曲线窗
- 右侧纵向 `RGB / 红 / 绿 / 蓝`
- 按钮底边与曲线窗底边对齐

### 3.3 当前 renderer / LUT 语义

当前实现明确采用：

- CPU 侧构建四条 LUT
- GPU shader 只负责采样 LUT 并做合成

当前 `CurveAdjustmentRenderer` 是独立 renderer，不与 `ColorAdjustmentRenderer` 复用 shader。

当前语义包括：

- 先应用 `RGB` 复合曲线
- 再应用 `红 / 绿 / 蓝` 各自通道曲线
- 继续遵守当前项目的 premultiplied alpha / sRGB 规则

### 3.4 当前 source 范围

当前正式可用的 source 只有：

- `.wholeLayer`

当前明确未接通：

- `.selection`
- `.painted`

当前行为是：

- 若存在 committed selection，曲线调整不会直接走选区直调，而是给出“下一阶段接通”的状态提示
- 当前也没有接入和色彩调整共用的 painted-mask 画刷工作台

### 3.5 当前确认 / 历史语义

当前已接通：

- `确认应用`
- `恢复默认`
- `按住预览`
- 正式写回
- 单图层 undo / redo
- 离开编辑态前的 `确认 / 放弃 / 取消` 弹窗

当前确认链和色彩调整类似，但 renderer 仍然独立。

## 4. 当前阶段结论

当前结论是：

- 曲线调整已经有正式主链
- 当前只做到 `Phase A + B`
- 当前可以继续往下做，但不要误判成“已经三条 source 全接通”

下一阶段最自然的推进顺序是：

1. `selection` 直调
2. `painted mask` 路径
3. 与色彩调整共享的蒙版工作台和切换规则

## 5. 当前最关键的代码文件

### 5.1 域模型

- [Core/Application/CurveAdjustmentDomain.swift](../../Core/Application/CurveAdjustmentDomain.swift)

### 5.2 主逻辑

- [Platform/macOS/App/WorkspaceViewModel+CurveAdjustment.swift](../../Platform/macOS/App/WorkspaceViewModel+CurveAdjustment.swift)

关键入口包括：

- `beginCurveAdjustmentFromWholeLayerIfNeeded(showFeedback:)`
- `updateCurveAdjustmentChannelPoints(_:channel:)`
- `confirmCurveAdjustmentIfNeeded(showFeedback:)`
- `resolveCurveAdjustmentSessionIfNeeded(reason:)`
- `activeCurveAdjustmentPreviewTexture(for:)`

### 5.3 曲线编辑器 UI

- [Platform/macOS/UI/CurveEditorView.swift](../../Platform/macOS/UI/CurveEditorView.swift)

### 5.4 参数面板 UI

- [Platform/macOS/UI/RightInspectorView.swift](../../Platform/macOS/UI/RightInspectorView.swift)

### 5.5 Preview / Commit Renderer

- [Rendering/Canvas/CurveAdjustmentRenderer.swift](../../Rendering/Canvas/CurveAdjustmentRenderer.swift)

## 6. 当前测试覆盖

当前最关键的测试在：

- [Tests/ArtFlexTests/CurveAdjustmentDomainTests.swift](../../Tests/ArtFlexTests/CurveAdjustmentDomainTests.swift)
- [Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift](../../Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift)
- [Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift](../../Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift)

当前已覆盖的行为包括：

- 曲线点序与单调约束
- 端点可移动
- 中间锚点新增 / 移动 / 删除
- LUT identity 与端点移动后的两端输出
- `wholeLayer` 预览
- `wholeLayer` 确认应用与 undo / redo

## 7. 新线程接手时必须记住的结论

1. 当前曲线调整已经不是未开始状态。
2. 当前只有 `wholeLayer` 主链，不要误判成 `selection / painted mask` 已接通。
3. 当前 renderer 是独立的 `CurveAdjustmentRenderer`，不要为了图省事并回 `ColorAdjustmentRenderer`。
4. 后续继续开发时，应沿当前 `CurveAdjustmentSession / CurveAdjustmentRenderer / confirm chain` 往下推进。
