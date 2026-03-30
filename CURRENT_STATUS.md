# ArtFlex 当前状态

- 当前阶段：Dual Tip 已完成到 `invert`，并补齐了主/次笔尖来源语义、preview 收口，以及最近一轮普通画笔卡顿 / 偶发不出笔 / 导入笔尖白边修复；下一阶段已开始推进，其中 `secondary image tip` 已完成两刀：第一刀落到 project / brush library archive 持久化链，第二刀把 imported-image 来源说明和 preview fit 收口为 model-driven 行为
- 当前代码状态：`multiply`、`subtract`、`intersect` 已可用；`secondary scatter`、`secondary angle offset`、`secondary invert` 已进入真实绘制；当前基线和主绘制路径未被打坏
- 当前编辑/保存状态：主笔尖单一真相源已接通；次笔尖来源已接通；主/次笔尖的 `procedural / customMask / importedImage` 来源语义已能保存到 preset / project；imported-image 的来源标签与原始像素尺寸也已能保存和恢复
- 当前支持：
  1. 主笔尖：圆形、自定义笔尖
  2. 次笔尖：圆形、自定义笔尖
  3. 组合模式：`multiply`、`subtract`、`intersect`
  4. 当前真正会影响绘制的参数：`strength`、`secondary size ratio`、`secondary scatter`、`secondary angle offset`、`secondary invert`
  5. 当主/次笔尖是自定义笔尖时：`customTipMaskData / softness / roundness / angle`
  6. 主/次笔尖摘要现在都能稳定区分：`procedural / customMask / importedImage`
- 当前已接通的来源/说明能力：
  1. `组合笔尖…` 面板里的主笔尖摘要 + 跳转
  2. 次笔尖摘要
  3. `编辑次笔尖…` 子面板
  4. 主/次笔尖来源语义的 preset / project 保存
  5. 自定义主/次笔尖的三格示意已与真实形状对齐，并已收口为黑底白笔触高对比样式
  6. 预设预览的 Dual Tip 重计算热点已收口，不再拖慢普通画笔输入
  7. 主/次 imported-image 现在会在 UI 中显示当前导入来源与像素尺寸摘要
- 当前新增已落地的资产层能力：
  1. imported-image 主/次笔尖现在会在 project package / brush library archive 中抽成独立 `tipImageAssets`
  2. archive 内的主/次 imported-image 笔尖现在会保存资产引用，再在打开/导入时解析回当前运行态 `maskData`
  3. imported-image 的来源说明和 preview fit 现在由 `TipSourceSemantic + ImportedTipSourceInfo` 决定，不再依赖会话态 flag
  4. 当前 renderer / preview 运行态仍继续直接吃解析后的 `maskData`，这一刀没有改动真实绘制主链
- 当前未完全落地但已确认继续推进：
  1. `secondary image tip` 的完整入口 / 生命周期体验
  2. 更严格 `renderer-backed preview`
  3. 更复杂随机 / spacing 系统
  4. 更宽真实绘制 gate
- 当前明确不在本轮范围：
  1. `smudge` 路径
- 当前策略：下一阶段范围已经确认，但仍按小步分刀和强旁路原则推进，不一次性把 Dual Tip 扩成全家桶

如果要恢复上下文，先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
