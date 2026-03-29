# CURRENT_TASK

## 1. 当前任务

- 当前任务不是继续扩 Dual Tip 下一刀
- 当前任务是：Dual Tip 阶段性文档同步已完成，等待决定下一步是否继续做 `intersect`
- 当前不是性能优化阶段
- 新线程默认先看 [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md) 和 [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)

## 2. 当前阶段约束

- 不要把当前线程重新拉回性能优化
- 不要自动进入 `intersect`
- 不要自动进入 `scatter`
- 不要默认把“来源已接通”误读成“所有次笔尖来源都已进入真实绘制”
- 当前不是复杂 `image tip` 阶段
- 没有新的明确需求前，不要继续扩 Dual Tip 模式和参数
- 旧的 `selection.fill / lasso.fill` 慢确认问题暂不处理
- 除非新功能开发中引入新的 P0 / P1 回归，否则不要重开这一轮性能项目

## 3. Deferred Items

- `selection.fill / lasso.fill` 慢确认：deferred known limitation
- 完整 `swift test` 的长跑 perf 项未收口到最终 passed / failed 结论：deferred validation note
- Dual Tip 的 `intersect / scatter / image tip / smudge`：后续再决定；当前不自动继续
- 非圆形 / 更复杂次笔尖来源进入真实绘制：后续再决定；当前仍只放开圆形与自定义次笔尖

## 4. 不要做的事

- 不要再写 performance closure audit
- 不要再复述 [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- 不要扩大到新的 history 结构改造
- 不要碰 `smudge / trim / restore` 主线语义
- 不要重开通用 partial history
- 不要把当前任务扩成新的大范围性能项目
- 不要在没有明确需求前继续扩 Dual Tip 实现边界
- 不要默认进入 `scatter`

恢复开发时，默认先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
