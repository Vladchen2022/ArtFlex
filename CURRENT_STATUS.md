# ArtFlex 当前状态

## 1. 项目概况

ArtFlex 是旧版 `BrushCanvas` 的 Metal-first 重构版 macOS 绘图软件。

产品主结构保持桌面绘图软件形态：

- 顶部工具栏
- 左侧工具栏
- 中央视图画布
- 右侧参数 / 颜色 / 笔刷 / 生成器 / 参考图区域
- 图层面板

当前项目已经不再处于“Git 回退后旧 dual-tip 基线”的阶段。  
当前活动基线是：**组合笔刷已经重新接回主工程，接线与运行链已可用，当前主要工作转入 look reconstruction。**

## 2. 当前代码真实状态

### 2.1 构建与常用验证入口

当前常用验证入口是：

- `swift build`
- `swift test --filter WorkspaceViewModelSafetyTests`
- `swift test --filter BrushStrokeSamplingTests`
- `swift test --filter StageOneBrushPreviewRasterizerTests`

项目仍有若干非阻塞 warning，但当前阶段的重点不是 warning 清零，而是保持主工程组合笔刷可迭代。

### 2.2 组合笔刷当前真实基线

当前组合笔刷的活动真相源已经是正式主工程路径，不再是“旧 flat dual-tip UI + 旧 compact popover”那套描述。

当前关键位置：

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)
  - 活动真相源是 `CompoundBrushSettings`
  - 包含：
    - `enabled`
    - `mode`
    - `secondary`
    - `pressureMix`
  - 次笔尖活动参数包括：
    - `sizeMode`
    - `size / relativeSizeRatio`
    - `spacingPercent`
    - `pressureSizeAmount`
    - `pressureOpacityAmount`
    - `tileRandomRotation`
    - `customTipMaskData`

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
  - 当前存在完整的组合笔刷活动 setter
  - 包括主笔尖、次笔尖、压力混合、次笔尖随机旋转等接线

- [CompoundBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
  - 当前活动 UI 是组合笔刷工作台
  - 不是旧 compact dual-tip popover

- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)
  - 当前活动 runtime 就在这里
  - 组合笔刷开启后：
    - 主笔尖包络决定笔触外轮廓
    - 次笔尖沿 stroke-space 形成重复纹理场
    - 最终结果始终被主包络裁剪
    - 压力通过 `pressureMix` 控制主次主导权
    - 次纹理支持 per-tile stable random rotation

### 2.3 当前组合笔刷的外观语义

当前主工程里的目标刷语义可以概括为：

1. 主笔尖先定义主体范围 / 轮廓
2. 次笔尖作为更大的重复纹理场进入内部
3. 最终只显示落在主包络范围内的部分
4. 压力控制“主层更强还是次层更强”
5. 整体透明度曲线独立控制整条笔触深浅

这和此前文档里那套“旧 dual-tip flat 字段 + rows/fill / scatter / invert 基线”已经不是一回事。

### 2.4 当前最需要保持冻结的部分

当前不要随意改这些：

- sample builder
- tip sampling
- 主/次 tip 接线
- dominance / opacity 曲线结构
- projected/clipped 基本语义
- actual-hand-stroke / display 链排错逻辑

这些链路之前已经花大量时间对齐过，不应该再当作默认怀疑对象。

## 3. 当前 look 层面的真实问题

当前剩余问题已经收缩到**主层视觉表达**，不是 plumbing。

当前用户反馈已经明确：

- `primary_body_alpha` 基本正确，应视为锁定
- `secondary_clipped_alpha` 基本正确，应视为锁定
- 问题集中在主层可见结果：
  - 主层仍容易露出 raw primary stamp 的串珠 / rail 感
  - `primary_texture_modulation_alpha` 容易退化成“模糊过的 stamp chain”
  - `high` 和 `sweep` 左半段因此还不够接近目标 brush

所以当前阶段不是去改次层，不是去重查接线，而是继续把主层从“看得见的 stamp chain”收成“连续主体 + 很轻微的内部主纹理调制”。

## 4. 当前推荐工作范围

如果继续做组合笔刷，优先范围是：

1. 只收主层 modulation
2. 优先看：
   - `primary_body_alpha`
   - `body_interior_mask`
   - `primary_texture_modulation_alpha`
   - `primary_visible_alpha`
   - `high`
   - `sweep`
3. 不要顺手再改：
   - 次层语义
   - sample / tip / display 链
   - 工程接线
   - 旧 subtract/intersect 之外的基础模式框架

## 5. 恢复上下文时先看

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
