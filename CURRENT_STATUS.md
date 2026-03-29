# ArtFlex 当前状态

- 当前阶段：Dual Tip 已完成到 Phase 2 第一刀（`subtract`）
- 当前代码状态：`multiply`、`subtract` 已可用，当前基线和主绘制路径未被打坏
- 当前编辑/保存状态：主笔尖单一真相源已接通；次笔尖来源已接通，且自定义次笔尖可编辑、可保存、可进入当前真实绘制
- 当前支持：
  1. 主笔尖：圆形
  2. 次笔尖：圆形、自定义笔尖
  3. 模式：`multiply`、`subtract`
  4. 当前真正会影响绘制的参数：`strength`、`secondary size ratio`
  5. 当次笔尖是自定义笔尖时：`customTipMaskData / softness / roundness / angle`
- 当前已接通的来源/说明能力：
  1. `组合笔尖…` 面板里的主笔尖摘要 + 跳转
  2. 次笔尖摘要
  3. `编辑次笔尖…` 子面板
  4. 次笔尖自定义遮罩与 `softness / roundness / angle` 的 preset / project 保存
  5. 自定义次笔尖的三格示意已与真实形状对齐
- 当前未支持：
  1. `intersect`
  2. `scatter / angle offset / invert`
  3. `secondary image tip`
  4. 更复杂的 preview 同步
  5. `smudge` 路径
- 当前策略：先收口，不自动进入下一阶段；先不做 `scatter`，是否继续做 `intersect`，后续再决定

如果要恢复上下文，先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
