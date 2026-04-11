# ArtFlex Handoff

## 1. 一句话说明

当前组合笔刷已经接回主工程，当前阶段不是 plumbing 排错，而是**在稳定主工程路径上继续收最终外观**。

## 2. 另一个 AI 接手前必须先知道的结论

### 2.1 不要再回到“旧回退基线”叙事

根目录旧文档里那套“Git 回退后旧 dual-tip flat 字段仍是活动基线”的说法已经过时。  
当前真实状态是：

- 组合笔刷主路径已经在主工程中运行
- 活动 UI 是 [CompoundBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- 活动渲染路径是 [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift) 的 compound 分支

### 2.2 当前不要再默认怀疑 plumbing

此前已经围绕这些层做过大量对账和排错；当前默认不要再把它们当作首要问题来源：

- sample builder
- tip sampling
- 主/次 tip 资源接线
- whole-stroke accumulation
- actual canvas vs replay 的 plumbing
- display/composite/export 审计

如果没有新的硬证据，不要再次把主精力投入这些层。

### 2.3 当前剩余问题集中在主层 look

当前用户认可的大方向：

- `primary_body_alpha` 基本正确
- `secondary_clipped_alpha` 基本正确
- 主次接管关系大方向已成立

当前不满意的部分：

- 主层 modulation 仍太容易露出 primary stamp 的节奏
- `high` 左端仍可能有串珠 / rail
- `sweep` 左半段仍可能出现梳齿感

所以当前阶段只应继续收：

- `bodyInteriorMask`
- `primaryTextureModulation`
- `primaryVisible`

不要顺手动次层和曲线。

## 3. 当前代码里最重要的入口文件

### 3.1 数据与参数

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)
  - `CompoundBrushSettings`
  - `CompoundSecondaryTipSettings`
  - `CompoundPressureMixSettings`

重点注意：

- `tileRandomRotation` 已经是活动参数
- `customTipMaskData` / `customTipEnvelopeMaskData` 是活动 tip 数据来源

### 3.2 状态接线

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)

这里已经有组合笔刷完整 setter，包括：

- 启用 / 关闭
- mode
- 次笔尖尺寸 / 间距 / 跟随笔势
- 压力混合
- 次笔尖随机旋转
- 自定义主/次 tip 的导入与写回

### 3.3 UI

- [CompoundBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CompoundBrushBuilderSheet.swift)

当前活动工作台就是它。  
不要再把“旧 compact dual-tip popover”写成当前主 UI。

### 3.4 运行时

- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)

当前组合笔刷外观核心就在这里：

- `primaryEnvelopeAlpha(...)`
- `compoundSecondaryTipAlpha(...)`
- `compoundFinalAlpha(...)`
- `makeUniforms(...)`

当前实现更接近：

- 主包络定义轮廓
- 次纹理在 stroke-space 里重复
- 次纹理支持稳定随机旋转
- 最终结果由主包络裁剪

## 4. 当前建议的工作边界

### 4.1 可以继续动的

- 主层内部 modulation 的构造方式
- `bodyInteriorMask` 的真实内缩程度
- `primaryVisible` 的最终表达方式

### 4.2 不建议再碰的

- secondary 的基本语义
- sample / tip / contract
- dominance / opacity 曲线结构
- 接线与显示链
- 旧 rows / fill / scatter / invert 路线

## 5. 当前推荐验证方式

如果改的是组合笔刷相关逻辑，先跑：

- `swift build`
- `swift test --filter WorkspaceViewModelSafetyTests`
- `swift test --filter BrushStrokeSamplingTests`
- `swift test --filter StageOneBrushPreviewRasterizerTests`

如果改的是主层外观，手测时优先看：

- `high` 左端是否仍有 rail
- `sweep` 左半段是否仍像梳子
- 次层是否被意外破坏

## 6. 接手顺序建议

1. 先读 [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
2. 再读 [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
3. 再看：
   - [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)
   - [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
   - [CompoundBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
   - [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)

不要先从旧文档里“回退基线 / 旧 dual-tip patch”那条线开始理解。
