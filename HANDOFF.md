# ArtFlex Handoff

## 1. 项目一句话说明

ArtFlex 是旧版 `BrushCanvas` 的 Metal-first 重构版 macOS 绘图软件；当前一轮性能主线与小范围 UX/perf follow-up 已经收尾，项目已转入新功能开发。当前最新已完成的新功能节点是 Dual Tip / 复合笔尖到 `invert`，并继续补齐了主/次笔尖来源语义、三格示意同源性收口，以及最近一轮“普通画笔卡顿 / 偶发不出笔 / 导入笔尖白边”修复；当前下一阶段范围已经确认，将继续推进共享 `tip image library` / `secondary image tip` 资产系统、`renderer-backed preview`、更复杂随机 / `spacing`、以及更宽真实绘制 gate，`smudge` 明确不在本轮范围内。`secondary image tip` 目前已完成三步：archive-backed 资产边界、imported-image 来源说明与 preview fit 的 model-driven 收口，以及共享 `tip image library` 当前基线。

本轮三个定点 follow-up 的最终状态是：

1. history retention policy：先接受
2. brush size indicator 的最小 fast-path 修复：先接受
3. `selection.fill / lasso.fill`：两轮最小优化先接受，hotspot 基本收口

当前这一轮性能优化与小范围 UX/perf follow-up 已收尾。下一阶段默认转入新功能开发，不要回头重开旧性能项目；如果未来必须重开 `selection/lasso fill`，唯一允许优先检查的点仍然是 `mutateSelectionPixels(...)`。

## 1.1 Dual Tip / 复合笔尖当前状态

### 已完成到 `invert` 并通过手测

- Phase 0 已完成：
  - 数据层 / UI 占位 / preset 与 project round-trip 已打通
  - 关闭时不影响旧绘制
- Phase 0.5 已完成：
  - UI 可读性、参数说明和可见性问题已修正
- Phase 1 已完成：
  - 真实绘制的最小闭环已接入：
    - 主笔尖：圆形
    - 次笔尖：圆形
    - 模式：`multiply`
    - 当前真正会影响绘制的参数：`strength`、`secondary size ratio`
- Phase 2 第一刀已完成：
  - `subtract` 已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- Phase 2 第二刀已完成：
  - `intersect` 已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- `scatter` 已完成：
  - 次笔尖相对主笔尖的稳定偏移已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- `angle offset` 已完成：
  - 次笔尖相对自身基准角度的额外旋转已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- `invert` 已完成：
  - 次笔尖反相已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏

### 当前真实已支持的范围

- 当前真实已支持的组合模式：
  - `multiply`
  - `subtract`
  - `intersect`
- 当前真实已支持的附加参数 / 变换：
  - `scatter`
  - `angle offset`
  - `invert`
- 它们当前只在窄 gate 下真实生效：
  - 工具：`brush`、`eraser`
  - 主笔尖：`硬边圆`、`柔边圆`、`自定义笔尖`
  - 次笔尖：`硬边圆`、`柔边圆`、`自定义笔尖`
- 当前真正会影响绘制的参数包括：
  - `strength`
  - `secondary size ratio`
  - `secondary scatter`
  - `secondary angle offset`
  - `secondary invert`
  - 当主笔尖是 `自定义笔尖` 时：
    - `customTipMaskData`
    - `customTipSoftness`
    - `customTipRoundness`
    - `customTipAngleDegrees`
  - 当次笔尖是 `自定义笔尖` 时：
    - `customTipMaskData`
    - `customTipSoftness`
    - `customTipRoundness`
    - `customTipAngleDegrees`

### 当前来源编辑 / 保存层状态

- 主笔尖单一真相源接通已完成：
  - `组合笔尖…` 面板里的主笔尖现在只做“真实摘要 + 编辑入口”
  - `编辑主笔尖…` 会直接把用户带回现有 `笔尖形状设计` 主入口
  - 不存在第二套独立主笔尖状态
  - 当前自定义主笔尖已经进入 `multiply / subtract / intersect + scatter + angle offset + invert` 的真实绘制
- 次笔尖来源接通已完成：
  - `SecondaryTipDescriptor` 现在已扩成 tip-source 安全子集：
    - `tipShape`
    - `customTipMaskData`
    - `customTipSoftness`
    - `customTipRoundness`
    - `customTipAngleDegrees`
  - `组合笔尖…` 面板里现在能看到当前次笔尖摘要
  - `编辑次笔尖…` 会打开独立子面板，复用现有笔尖遮罩编辑画布
  - 次笔尖自定义遮罩和参数已经能保存到 preset / project
  - 当前自定义次笔尖已经进入 `multiply / subtract / intersect + scatter + angle offset + invert` 的真实绘制
  - 当前三格示意也已经按自定义主/次笔尖的真实遮罩关系显示，不再退回柔边圆近似
  - 当前三格示意已调整为高对比显示，默认使用黑底白笔触，更容易辨认主/次/最终组合关系
  - 主/次笔尖当前都已补齐来源语义：
    - `procedural`
    - `customMask`
    - `importedImage`
  - Dual Tip 面板摘要现在能稳定区分“自定义笔尖”和“导入图像笔尖”
- 但要注意：
  - 这不代表所有次笔尖来源都已进入真实绘制
  - `方形` 次笔尖当前仍然只是编辑 / 保存，真实绘制仍会回旧 gate

### 当前仍未支持 / 尚未接入真实绘制

- 共享 `tip image library` 的剩余管理 / 生命周期体验
- 更严格 renderer-backed preview
- 更复杂随机 / spacing 系统
- 更宽真实绘制 gate
- `smudge` 路径

其中除 `smudge` 外，其余四项已确认纳入下一阶段开发范围；`smudge` 继续排除在本轮范围外。需要注意：`secondary image tip` 目前虽然已经接通 project package / brush library archive 的 `tipImageAssets`、来源摘要 / preview fit 的模型语义驱动，以及共享 `tip image library` 第一刀，但完整管理体验和 preview/renderer 终态都还没做完。以上这些现在最多只是局部数据 / UI / persistence 层存在，不代表已经进入最终形态真实绘制。

### 当前用户体验状态

- Dual Tip 的启用开关和当前已接入参数现在已经能真实影响落笔
- `subtract`、`intersect`、`scatter`、`angle offset`、`invert` 现在都已经进入真实绘制
- `组合笔尖…` popover 已补齐可解释性：
  - 主笔尖
  - 次笔尖
  - 最终笔尖
  - `multiply` 当前是“调制 / 压缩”逻辑
  - `subtract` 当前是“挖掉 / 削减”逻辑
  - `intersect` 当前是“只保留交集 / 收口”逻辑
  - `scatter` 当前是“次笔尖相对主笔尖的稳定偏移”逻辑
  - `angle offset` 当前是“次笔尖相对自身基准角度的额外旋转”逻辑
  - `invert` 当前是“次笔尖 coverage 反相后再参与组合”逻辑
- `组合笔尖…` 面板里的主笔尖现在与真实绘制主笔尖保持同一真相源
- 次笔尖现在不再只是形状 picker，而是已经能独立编辑和保存来源
- 自定义主笔尖现在也已经能进入当前 `multiply / subtract / intersect + scatter + angle offset + invert` 真实绘制
- 自定义次笔尖现在不只可编辑 / 可保存，也已经能进入当前 `multiply / subtract / intersect + scatter + angle offset + invert` 真实绘制
- 三格示意现在已经能按自定义主/次笔尖的真实形状示意最终组合结果
- 三格示意的视觉对比已收口到高对比样式，当前默认是黑底白笔触
- 主/次笔尖的 `importedImage / customMask / procedural` 来源语义现在已经能保存、恢复并在 UI 摘要中稳定区分
- imported-image 主/次笔尖现在还会在 UI 中显示当前导入来源和原始像素尺寸摘要
- imported-image preview fit 现在由模型语义驱动，不再依赖“当前会话”临时 flag
- 主笔尖与次笔尖现在共用一套 `tip image library` 入口
- `tip image library` 会跟随 workspace / project / brush library 一起保存和恢复；已保存为画笔的 imported-image 笔刷，重启后再次点击仍会恢复原图片笔尖效果
- `tip image library` 中未被任何画笔引用的图片，现在也会独立保留并在重启后恢复，不会因为“当前没在用”而丢失
- 资料库当前 UI 已切到：
  - 点选卡片后按“完成”应用
  - 拖拽排序
  - 右上角删除图标
  - `Esc` 退出资料库
- 如果某张资料库图片仍被当前笔刷或某个画笔预设引用，当前规则是阻止删除
- imported-image 主/次笔尖即使暂时切到其他笔尖形状，保存 / 重开后也仍会保留隐藏的图像笔尖资产状态；这现在作为兼容行为保留，但后续主入口将以显式资料库为准
- 最近一轮回归已修复：
  - 编辑组合笔尖后普通画笔卡顿
  - 偶发画不出笔触
  - 导入图像笔尖后的白边
- 当前 Dual Tip 已从概念验证进入“可用阶段”
- 当前已可用来做基础“收口 / 压缩型”“挖空 / 削减型”“交集 / 收口型”笔刷，也能开始体验异形次笔尖的挖空、调制、交集、稳定偏移、角度偏移与反相效果
- 为了便于直接体验，默认画笔库现在附带 3 个 Dual Tip Phase 1 示例预设

### 下一步建议

- 下一阶段范围已经确认，不再停留在“只观察、不继续扩”的状态
- 推荐按以下顺序推进：
  1. 收尾共享 `tip image library` 的管理 / 生命周期体验
  2. 更严格 `renderer-backed preview`
  3. 更复杂随机 / spacing 系统
  4. 更宽真实绘制 gate
- `smudge` 不在当前确认范围
- 其中：
  - 更复杂随机 / 变换能力与更宽 gate 的风险仍然更高，应拆成独立小刀推进

### 风险边界

- 不要重新污染旧绘制路径
- 关闭 Dual Tip 时，必须继续和旧版行为一致
- 开启但不满足当前已接入条件时，必须继续回旧路径
- 不要把“来源接通”和“真实绘制扩范围”绑在一起
- 当前自定义主/次笔尖虽然都已经进入 `multiply / subtract / intersect + scatter + angle offset + invert` 的真实绘制，但当前代码基线的 gate 仍是窄范围；后续即使继续扩大，也必须逐项验证：
  - 当前真实已接入模式是 `multiply / subtract / intersect`
  - 当前真实已接入的附加参数包含 `scatter / angle offset / invert`
  - 主笔尖当前只限圆形与自定义笔尖
  - 工具继续只限 `brush / eraser`
- 不要在未验证前一次性扩很多模式
- 不要把当前 Dual Tip 直接扩成“全家桶”实现

## 2. 当前进展

### 已完成的主线工作

- 多图层文档、图层排序/可见性/锁定/透明度、工程保存/打开主链已建立
- 选区、自由变形、吸管、油漆桶、画笔、橡皮擦、涂抹等主工具链已接通
- history 主干已经从“全量快照 + 高风险 partial fallback”收口到更安全的 dirty history pilot
- serializer / queue / staging 已完成一轮收口，不再到处随手自建 command queue
- smudge 已完成两轮专项治理，已经去掉最大的 full-size copy/allocation 坑

### 已验证通过的优化

- dirty history pilot 已落到：
  - `brush.commit`
  - `eraser.commit`
  - `applyPixelOperation`
  - `fillAtPoint`
- `undo / redo` 的对称 dirty current capture 已对上面这些 dirty entry 生效
- dirty restore 继续 fail-closed
- dirty restore 失败时 `workspace` 与 `undo/redo` 栈保持不变
- 不允许 `full reset + partial snapshots` fallback
- serializer 共享 `MetalDeviceContext.commandQueue` 和 staging pool 的收口已完成
- smudge 不再发生 per-packet full-size source texture allocation / copy
- performance closure audit 已完成，并已固化在 [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- `selection.fill / lasso.fill` 已完成一轮最小优化：
  - `applyPixelOperation` 不再为像素改写先生成整张画布级 mask 副本
  - `mutateSelectionPixels` 已改成局部 mask + 专用 `fill/clear` 内循环
  - `pixelMutation` 已明显下降
- `selection.fill / lasso.fill` 已完成第二轮最小优化：
  - `rasterizedSelectionMaskRegionBytes(...)` 去掉了 Swift 逐像素结果拷贝，改成 row copy
  - 局部 rasterize 不再为每个 polygon 构建一份平移后的点数组
  - `maskPreparation` 已从约 `700 ms` 量级降到约 `16 ms`
- history retention policy 已调整到更贴近当前产品真实场景：
  - `maxEntries = 24`
  - `maxResidentBytes = 768 MiB`
- brush size indicator 延迟已完成最小 fast-path 修复

### 哪些性能主线已经正式收口

以下主线本轮已经明确收口，不要在新线程里默认重开：

- dirty history 主干试点
- `brush.commit`
- `eraser.commit`
- `applyPixelOperation`
- `fillAtPoint`
- `undo / redo` 对称 dirty current capture
- history 事务性失败保护
- smudge 最大的 full-size copy/allocation 问题
- serializer / queue / staging 收口
- performance closure audit

## 3. 已完成并确认有效的内容

### dirty history pilot 当前落地范围

- 入口：
  - [captureBrushCommitCheckpoint(for:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5134)
  - [checkpointHistoryIfPossible(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5048)
  - [fillAtPoint(_:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L1168)
  - [applyPixelOperation(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5266)
- history mode：
  - `full`
  - `inPlaceChangedLayers(topologySignature, changedLayerIDs)`
- 当前 dirty pilot 只覆盖：
  - `brush.commit`
  - `eraser.commit`
  - `applyPixelOperation`
  - `fillAtPoint`
- 不要把它误读成“通用 partial history 已经重新开放”

### smudge 当前状态

- smudge 已不再做 per-packet full-size source texture allocation
- smudge 已不再做 per-packet full-size snapshot blit
- 当前更深层的 smudge 优化是 deferred 项，不是当前任务

### serializer / queue / staging 当前状态

- `LayerTextureSerializer` 已复用共享 `MetalDeviceContext.commandQueue`
- staging pool 已有同步保护、budget、trim/purge
- `copyTextureAsync` 被限制在 live-session 初始化路径使用
- generic `copyTexture / clearTexture` 仍保持同步安全语义

### fail-closed restore / 事务性失败保护

- dirty restore 前必须验证 `topologySignature`
- 不匹配时直接 fail-closed
- 不允许 fallback 到 `full reset + partial snapshots`
- `undo / redo` 不允许先 pop/append 再 restore
- dirty restore 失败时：
  - `workspace` 不变
  - `undoStack` 不变
  - `redoStack` 不变

### performance closure audit

- 已完成
- 已固化文档：
  - [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- 新线程不要再把它当成当前任务重复做一遍

## 4. 手测结果摘要

以下结论基于当前代码树的定向回归测试、最近一轮核心功能手测记录和针对性 profiling。

### 未发现本轮性能优化破坏已有核心功能

- 未发现 dirty history pilot 破坏已有 undo/redo 正确性
- 未发现 dirty restore 破坏未变更图层内容
- 未发现 serializer / queue / staging 收口后引入新的时序错误
- 未发现 smudge 两轮专项优化破坏当前输出一致性
- 核心功能手测未见本轮优化导致的明显功能破坏

### 通过项

- `brush.commit / eraser.commit / applyPixelOperation / fillAtPoint` 的 dirty history pilot 已通过定向测试
- `undo / redo` 对称 dirty current capture 已通过定向测试
- topology fence 前后链条正确
- hidden / locked / opacity 非变更 layer 内容保持正确
- transaction failure 保护测试通过
- brush size local preview 不会被旧 model 值回踩
- `selection.fill / lasso.fill` 两轮热点优化后，确认耗时已由约 `2s` 量级降到约 `1s` 量级

### 存疑项

- 连续撤销的体感仍可能有卡顿，需要继续按真实文档手感观察
- full `swift test` 仍未拿到最终收口结论；`PerformanceAuditFactTests` 长跑不能直接拿来宣称完整通过

### 不适用项

- 多文件同时打开 / 多文档窗口链目前不是当前项目的主要能力，不属于本轮验证范围

## 5. 当前明确存在的问题

当前仍保留但不再作为当前线程主任务的问题是：

1. history retention policy 已按典型 `3000 px` 场景提升，但连续撤销体感仍有卡顿，仍需按真实文档继续验证
2. brush size indicator / 笔头缩放响应仍有延迟风险；这是 UI 指示器延迟，不是笔迹延迟
3. `selection.fill / lasso.fill` 已从约 `2.0s` 降到约 `1.0s`，但仍偏慢；当前接受为 deferred known limitation，不继续优化

### 这三项的当前事实

- history retention 当前默认值已改到：
  - `maxEntries = 24`
  - `maxResidentBytes = 768 MiB`
  - 目标是典型 `3000 px` dirty 文档场景下至少约 `20` 步撤销
- brush size indicator 延迟目前定位在：
  - `updateNSView(...)` 的 brush-size-only 更新仍会走一段主线程重路径
  - 不是笔迹渲染本身慢
- `selection.fill / lasso.fill` 的当前热点分解结果：
  - 第一轮优化前：
    - `selection.fill`: `historyCheckpoint=33.918ms`, `maskPreparation=700.719ms`, `snapshot=29.861ms`, `pixelMutation=1238.055ms`, `restore=9.765ms`, `uiConfirm=0.094ms`, `total=2014.932ms`
    - `lasso.fill`: `historyCheckpoint=30.582ms`, `maskPreparation=697.487ms`, `snapshot=31.106ms`, `pixelMutation=1237.757ms`, `restore=12.771ms`, `uiConfirm=0.100ms`, `total=2011.204ms`
  - 第一轮优化后 / 第二轮优化前：
    - `selection.fill`: `historyCheckpoint=34.109ms`, `maskPreparation=705.433ms`, `snapshot=32.951ms`, `pixelMutation=862.349ms`, `restore=6.470ms`, `uiConfirm=0.095ms`, `total=1644.104ms`
    - `lasso.fill`: `historyCheckpoint=30.638ms`, `maskPreparation=703.275ms`, `snapshot=30.895ms`, `pixelMutation=844.989ms`, `restore=6.350ms`, `uiConfirm=0.099ms`, `total=1617.534ms`
  - 第二轮优化后：
    - `selection.fill`: `historyCheckpoint=33.732ms`, `maskPreparation=16.776ms`, `snapshot=30.829ms`, `pixelMutation=890.757ms`, `restore=9.139ms`, `uiConfirm=0.254ms`, `total=985.899ms`
    - `lasso.fill`: `historyCheckpoint=33.158ms`, `maskPreparation=15.894ms`, `snapshot=31.270ms`, `pixelMutation=877.034ms`, `restore=6.263ms`, `uiConfirm=0.097ms`, `total=964.992ms`
  - 验证收口补充：
    - `swift test --skip PerformanceAuditFactTests`：通过（`107` tests / `18` suites）
    - `swift test --filter PerformanceAuditFactTests/selectionFillProfilingBreakdown`：通过
    - full `swift test`：本轮未拿到最终 passed 结论，不能宣称完整通过
  - 当前结论：
    - `maskPreparation` 已不再是主要剩余热点
    - 当前重新回到 `pixelMutation` 是最大段，但它已经做过一轮最小优化，不应默认立刻重开大改
    - 以当前约 `1.0s` 的确认时间，`selection/lasso fill hotspot` 本轮先按“基本收口”处理
    - 当前问题正式标记为 deferred known limitation

## 6. 下一阶段默认任务

新的对话线程默认不再从性能优化开始，而是先看交接文档后直接进入新功能定义与实现：

1. 新线程默认先看 [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md) 和 [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
2. 当前默认任务应切换到新功能开发，不再回头重打旧性能项目
3. 新功能开发前只需把当前状态作为基线；除非引入新的 P0 / P1 回归，否则不要重开这一轮性能项目

## 7. 这三项任务的硬约束

- 不重开通用 partial history
- 不改 dirty restore fail-closed 语义
- 不引入 `full reset + partial snapshots` fallback
- 不碰 trim / smudge 主线
- 不重复做 performance closure audit
- 不要扩大范围到新的大重构
- `selection.fill / lasso.fill` 慢确认当前视为 deferred known limitation
- 如果未来必须重开，只允许先检查 [mutateSelectionPixels(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5389)

## 8. 关键文件与入口

### history / dirty pilot

- [HistoryController.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift)
  - [captureCheckpoint(...)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97)
  - [undo()](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L121)
  - [redo()](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L141)
  - [restore(entry:)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L258)
  - [restoreWithFullReset(...)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L292)
  - [restoreInPlaceChangedLayers(...)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L313)
  - [currentEntryCaptureMode(for:)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L336)

### brush size indicator

- [WindowKeyboardBridge.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WindowKeyboardBridge.swift)
  - [KeyboardBridgeView.keyDown(with:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WindowKeyboardBridge.swift#L40)
- [MetalCanvasHost.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift)
  - [updateNSView(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift#L129)
  - [StrokeCaptureMTKView.keyDown(with:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift#L1044)
  - [previewAdjustBrushSize(by:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift#L1751)

### selection.fill / lasso.fill

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
  - [fillAtPoint(_:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L1168)
  - [fillSelectionContents()](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L3625)
  - [fillLassoContents()](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L3638)
  - [eraseLassoContents()](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L3974)
  - [applyPixelOperation(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5266)
- 当前 inspection 结论：
  - `selection.fill` 的 profiling 场景里，刚 commit 的 lasso 选区通常还是 `immediateShape(.lasso)`，不会立刻命中 `maskData` 快路径
  - `maskPreparation` 的第二轮热点主要不是 history，也不是 committed `maskData` row copy，而是局部 rasterize 后的 Swift 级结果拷贝和点重映射
  - 当前已把这两块压掉，局部 rasterize 成本已明显下降

### 基线与 profiling

- [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- [PerformanceAuditFactTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift)
- [HistoryControllerTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift)
- [WorkspaceViewModelPixelHistoryTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift)
- [BrushInputDispatchTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/BrushInputDispatchTests.swift)

## 9. 验证方式

后续改动完成后，至少要跑：

- `swift build`
- `swift test --filter HistoryControllerTests`
- `swift test --filter WorkspaceViewModelPixelHistoryTests`
- `swift test --filter BrushInputDispatchTests`
- `swift test --filter PerformanceAuditFactTests`
- 必要时全量 `swift test`

后续手测至少要看：

- 连续 `undo / redo` 体感是否仍卡
- `[` `]` 调笔刷大小时，笔头圈尺寸是否即时变化
- `selection.fill / lasso.fill` 点击确认后的主观等待时间
- dirty history 路径下不同图层交替操作后，未变更图层是否保持正确

## 10. Stop line

- performance 主线已经收口
- 后续只允许做定点 UX/perf follow-up
- 没有新的 P0 / P1 回归，不准重开整轮性能项目
