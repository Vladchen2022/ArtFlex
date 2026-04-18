# 肌理填充当前状态

最后更新：2026-04-18

## 1. 产品目标

`肌理填充 / textureFill` 的完整产品目标当前应理解为：

- 左侧提供正式的 `肌理填充` 工具入口
- 复用现有套索输入主路径，不新造一套输入系统
- 用户从一个锚点 `A` 开始拖动，区域沿拖动方向逐步生成纹理
- 拖动中保留实时反馈
- 松手后得到最终定稿结果
- 支持 `Undo / Redo`
- 后续允许从共享 `tipImageLibrary` 选择图片驱动纹理

当前不要把这条线理解成：

- 只是一种“套索填充改名”
- 或者已经是完整的图片贴图系统

## 2. 当前整体策划与阶段划分

当前这条线实际是按阶段推进的，接手时默认按下面的阶段理解，不要跳着改。

### 2.1 Phase 0

- 正式工具入口
- 复用 `lassoFill` 输入骨架
- 右侧参数区只有占位，不做参数

### 2.2 Phase 1

- `textureFill` 从 `lassoFill` 里拆出独立提交路径
- 结果仍然是 mouse-up 后一次性实心填充

### 2.3 Phase 2

- 不再等到 mouse-up
- 改成拖动中实时写实心扇形切片

### 2.4 Phase 3

- 把实时切片从“实心填充”换成“程序化断断续续纹理”
- 仍然是 direct-to-layer
- 这是当前整体功能真正可用的第一版基线

### 2.5 Phase 4

第四阶段不是重做 live 路线，而是从第三阶段出发，只修“最终定稿”和状态收尾。

#### 4.0

- 把第三阶段的程序化纹理生成抽成独立 helper
- 目标是给后续 end-only 重放复用
- 不改变用户可见行为

#### 4.1

- 在 mouse-up 时，从开始时的图层基底做一次 raw path replay
- 拖动中保持第三阶段现状

#### 4.2

- 在 4.1 replay 结果上，加 closed-lasso smoothing 生成的最终平滑 mask
- 只修 final，不修 live

#### 4.3

- 收尾项
- 包括：
  - `textureFill` 手势状态清理
  - 最终合成改成局部快照/局部恢复
  - 不再动 live 几何

### 2.6 Phase 6

当前没有单独实现“完整 phase 5 文档化路线”，实际继续往前推进的是共享 tip 图库接线。

这一步的目标是：

- 给 `textureFill` 增加独立的 tip 状态
- 接入共享 `tipImageLibrary`
- 允许 imported 模式驱动最终纹理

## 3. 当前真实进度

当前仓库里，`textureFill` 已经至少完成到：

- phase 0
- phase 1
- phase 2
- phase 3
- phase 4.0 / 4.1 / 4.2 / 4.3
- imported 模式的第一版图库接线

而且其中下面这些阶段已经被最近线程手测确认可继续作为基线：

- phase 4.1：通过
- phase 4.2：通过
- phase 4.3：通过
- imported final field `cover` 修正：通过

## 4. 当前真实行为

### 4.1 程序化模式

当前默认程序化模式的行为是：

1. 复用套索输入链
2. 从锚点 `A` 开始拖动
3. 拖动中按 `A -> P_prev -> P_curr` 生成实时切片
4. 切片内部不是实心，而是程序化断断续续纹理
5. mouse-up 时：
   - 先按 raw path replay
   - 再套用 smooth final mask

当前这个模式的手测结论是：

- 手感基本可接受
- 最终结果可接受
- `Undo / Redo` 正常

### 4.2 Imported 模式

当前 imported 模式已经接通共享图库，但必须区分 **live** 和 **final** 两条路径：

#### live

- 拖动中 imported 模式已经改成区域映射 live field
- live 当前优先复用 smooth final shape，而不是继续维持旧的小阵列 tile 语义

#### final

- mouse-up 后，不再用小 tile 阵列定稿
- 会改成对最终区域做一次 imported final field 映射
- 并且当前已经从 `contain` 改成 `cover`
- 所以最终结果不应再留白

也就是说，当前 imported 模式的真实边界是：

- 拖动中：区域映射 live field
- 松手后：区域纹理映射 final field

当前 imported live / final 的主要纹理语义已经统一，剩余差异更多集中在 live 交互时序和边界收尾，而不是旧的 tile-vs-region 逻辑分裂。

## 5. 当前已确认的问题与边界

### 5.1 当前仍存在的问题

1. 拖动中的边缘仍有多边形感
2. `textureFill` 整体仍有轻微延迟，但当前线程已接受为“勉强可接受”
3. 程序化模式 live 仍然比 imported 模式更容易看到 faceted 边界

### 5.2 当前已修掉的问题

1. imported final field 左侧/边缘留白  
   - 之前是 `contain`
   - 现在已改成 `cover`

2. imported 图库删除保护  
   - 当前被 `textureFill` 使用的图库项已接入引用阻止

3. imported 模式 live / final 主纹理语义  
   - 当前已经统一到区域映射语义
   - live 不再沿旧的小阵列 tile 基线

### 5.3 当前不要再重复尝试的失败路线

下面这些路线最近已经失败，不应默认重复：

1. 只靠 `densify` 修多边形  
   - 结果：更卡，边缘仍 faceted

2. 首段 cap + 长段 densify  
   - 结果：收益有限，性能更差

3. 开放路径平滑直接塞进 live 切片链  
   - 结果：更卡，还破坏断续纹理风格

当前接手时，不要默认继续在这些路线之上 patch。

## 6. 当前实现的关键文件

### 6.1 工具与状态

- [Core/Tools/ToolKind.swift](../../Core/Tools/ToolKind.swift)

关键点：

- `ToolKind.textureFill`
- `TextureFillTipSettings`
- `ToolSessionState.textureFillTip`

### 6.2 主逻辑

- [Platform/macOS/App/WorkspaceViewModel.swift](../../Platform/macOS/App/WorkspaceViewModel.swift)

关键入口包括：

- `handleSelectionMouseDown(...)`
- `updateSelection(...)`
- `commitSelection(...)`
- `beginTextureFillGesture(...)`
- `updateTextureFillGesture(...)`
- `commitTextureFillGesture(...)`
- `renderTextureFillSlices(...)`
- `rebuildTextureFillFinalResult(...)`
- `applyTextureFillSmoothFinalMask(...)`
- `applyTextureFillImportedFinalField(...)`
- `textureFillSmoothFinalSelectionShape(...)`

### 6.3 live / final 纹理生成 helper

- [Core/Selection/TextureFillProceduralField.swift](../../Core/Selection/TextureFillProceduralField.swift)

关键入口包括：

- `sessionSeed(anchorPoint:)`
- `alphaBytes(...)`
- `importedRegionAlphaBytes(...)`

### 6.4 输入链

- [Platform/macOS/Canvas/MetalCanvasHost.swift](../../Platform/macOS/Canvas/MetalCanvasHost.swift)

当前仍然是复用 selection / lasso 输入分支，不要默认重写 host。

### 6.5 参数区与图库入口

- [Platform/macOS/UI/RightInspectorView.swift](../../Platform/macOS/UI/RightInspectorView.swift)

当前这里负责：

- `textureFill` 的最小参数区占位
- `共享图库…`
- `切回程序化`

## 7. 当前测试覆盖

当前与 `textureFill` 最相关的测试集中在：

- [Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift](../../Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift)
- [Tests/ArtFlexTests/TextureFillProceduralFieldTests.swift](../../Tests/ArtFlexTests/TextureFillProceduralFieldTests.swift)
- [Tests/ArtFlexTests/TextureFillPhase0Tests.swift](../../Tests/ArtFlexTests/TextureFillPhase0Tests.swift)

目前至少已经覆盖：

- 工具注册
- 拖动中会有像素
- 断续纹理内部仍有空洞
- `Undo / Redo`
- final replay 不会抹掉纹理空洞
- imported tip 会改变输出
- imported 当前使用项会阻止删除
- imported final field 不再 letterbox
- imported live 不再按固定 tile 间隔重复
- imported final 在远离边界的位置会接近 live 预览

## 8. 当前线程确认通过的点

最近线程已经人工确认通过的结论有：

1. phase 4.1 可以通过
2. phase 4.2 可以通过
3. phase 4.3 可以通过
4. imported final field 从 `contain` 改成 `cover` 后，最终区域铺满可以通过
5. imported live 区域映射可以通过
6. imported final 与 live 在远离边界的位置基本一致可以通过

## 9. 新线程接手时最该先确认的事

接手 `textureFill` 时，先明确下面三件事：

1. 当前基线是 **phase 4.3 + imported mapped live/final + final cover**
2. 当前最明显的未完成项是：
   - 程序化模式 live 多边形感
   - 整体残余轻微延迟
3. 当前不要再无计划重开：
   - live 路径平滑
   - `densify` 修边缘
   - 重新发明一套输入链

## 10. 下一步建议

如果后续继续做 `textureFill`，最合理的下一步不再是 imported live/final 统一，而是：

### 10.1 优先方向

- 观察程序化模式的 live 多边形感是否值得继续收口
- 在真实体感仍明显时，再继续压 live 延迟

### 10.2 暂不建议优先做的事

- 不要优先重开多边形 live 边缘修复
- 不要再回到失败的 densify / open-path smoothing 路线
- 不要在没有新证据前重写 `MetalCanvasHost`

## 11. 一句话结论

当前 `textureFill` 的真实状态是：

- 程序化模式已经跑通到一个可用基线
- 最终定稿链已经有 4.2/4.3 收口
- imported 模式已经能在 live / final 两侧都做区域映射，并且 final 铺满区域
- 当前最值得继续看的更接近：**程序化 live 多边形感与残余轻微延迟**
