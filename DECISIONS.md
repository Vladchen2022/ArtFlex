# DECISIONS

最后更新：2026-04-10

本文件记录当前代码和产品层已经确认的关键决策。  
如果后续改动与这些点冲突，应先重新讨论，而不是直接改代码。

## 0. 当前阶段与红线

### 0.1 当前组合笔刷已经接回主工程

已确认：

- 当前组合笔刷不是旧回退基线
- 活动 UI 是 [CompoundBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- 活动运行时是 [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift) 的 compound 分支
- 文档、handoff、后续开发都必须以这条主工程真实路径为准

### 0.2 当前工作重点是 look reconstruction，不是 plumbing

已确认：

- sample builder 不再是默认问题来源
- tip sampling 不再是默认问题来源
- 真实手绘 / live replay / display 链的大量对账已经做过
- 当前默认问题来源应视为**主层视觉表达**，不是再去重查接线

### 0.3 当前组合笔刷语义

已确认当前目标路径是：

- 主笔尖定义主体范围 / 包络
- 次笔尖在 stroke-space 形成更大的重复纹理场
- 最终结果被主包络裁剪
- 压力控制主次主导权
- 透明度曲线独立控制整条笔触深浅

### 0.4 当前默认验收模式

已确认：

- 目标 brush 的默认验收模式应优先看 `textureBlend`
- `subtract / intersect` 可以保留为已有模式，但不应继续主导目标刷验收判断

### 0.5 当前不要再随意动的部分

已确认冻结：

- `CompoundBrushSampleBuilder`
- 单 stamp tip sampling 逻辑
- 主/次 tip 资源接线
- dominance / opacity 曲线结构
- projected/clipped 基本语义
- 组合笔刷默认参数的大方向
- display/composite/export 审计链

如果没有新的明确证据，不要再回到这些层反复排错。

## 1. 当前组合笔刷真实实现层决策

### 1.1 数据层

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift) 里的 `CompoundBrushSettings` / `CompoundSecondaryTipSettings` 是当前活动真相源
- 次笔尖活动参数包括：
  - `sizeMode`
  - `size / relativeSizeRatio`
  - `spacingPercent`
  - `pressureSizeAmount`
  - `pressureOpacityAmount`
  - `tileRandomRotation`
  - `customTipMaskData`

### 1.2 交互层

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift) 当前已存在完整组合笔刷 setter
- 不要再把当前状态写成“旧 secondary flat 字段 setter 才是活动路径”

### 1.3 渲染层

- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift) 当前组合笔刷渲染是正式主路径
- 次纹理已使用 per-tile stable random rotation 打散重复感
- 当前组合笔刷 look 更接近“主包络 + 次纹理场裁剪”的单路径外观模型，而不是早期分层实验文档里那种 prototype-only 语义拆解

## 2. 当前 look 阶段的明确结论

### 2.1 已基本正确，优先锁定

- `primary_body_alpha`
- `secondary_clipped_alpha`

### 2.2 当前主要问题

- 主层 modulation 仍容易退化成“模糊过的 primary stamp chain”
- `high` 左端和 `sweep` 左半段容易露出梳齿 / rail

### 2.3 当前允许继续改的范围

只建议继续收：

- 主层 interior mask
- 主层低频 modulation 场
- `primary_visible` 的最终表达方式

### 2.4 当前不建议再回去做的事

- 不要回退到 rows / fill / scatter 旧语义
- 不要再重开 sample / tip / display 排错，除非有新的硬证据
- 不要一边做主层 look，一边顺手改次层和曲线

## 3. 其它仍然成立的项目层决策

- 项目继续保持 Metal-first 方向
- 不允许把旧 CPU 画布思路重新带回主链
- 参考图面板当前冻结
- 颜色面板默认收起高级区
- `笔尖形状设计 / 导航器` 默认打开 `导航器`
- 涂抹工具独立记忆自己的 brush 设置
