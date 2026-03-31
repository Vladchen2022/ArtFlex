# CURRENT_TASK

## 1. 当前任务

- 当前任务已切换为：继续推进 Dual Tip 下一阶段，但按安全顺序分刀实施
- 当前已完成的阶段性刀法：
  - `secondary image tip` 独立资产系统已先落到 archive / persistence 边界
  - imported-image 的来源说明与 preview fit 已改成 model-driven：主/次笔尖现在会保存导入来源信息，preview 不再依赖会话态 flag
  - imported-image 即使当前临时切到其他笔尖形状，也会继续走统一资产归档与恢复链；切回 `customRound` 不会因为保存 / 重开而丢失
  - 共享 `tip image library` 当前基线已落地：主/次笔尖共用一套资料库，已接通 workspace / project / brush library 持久化；未被任何画笔引用的资料库图片也会随重启恢复
- 当前已确认纳入本轮范围：
  - 完整 `secondary image tip` 独立资产系统
  - 更严格 `renderer-backed preview`
  - 更复杂随机 / spacing 系统
  - 更宽真实绘制 gate
- 当前已新增确认的产品规则：
  - 由外部导入图片制作、并已保存为画笔的笔刷，无论是否重启软件，都必须能恢复出此前导入图片的笔尖效果
  - 主笔尖和次笔尖共用一套持久化 `tip image library`
  - `tip image library` 中未被任何画笔引用的图片，也必须独立保留，不能因为未使用而在重启后消失
  - `tip image library` 中已被画笔引用的图片当前禁止删除
- `smudge` 明确不在本轮 Dual Tip 范围
- 当前不是性能优化阶段
- 新线程默认先看 [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md) 和 [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)

## 2. 当前阶段约束

- 不要把当前线程重新拉回性能优化
- 不要把本轮四项范围一次性打成单次大扩展
- 不要默认把“来源已接通”误读成“所有参数和来源都已进入真实绘制”
- 真实绘制 gate 的扩大必须逐项验证，不要一次性放开到所有工具 / 主次笔尖类型 / 模式
- 当前需要继续扩 Dual Tip，但必须按分阶段顺序推进
- `smudge` 继续排除在本轮范围外
- 旧的 `selection.fill / lasso.fill` 慢确认问题暂不处理
- 除非新功能开发中引入新的 P0 / P1 回归，否则不要重开这一轮性能项目

## 3. 当前推荐顺序

1. 收尾共享 `tip image library` 的入口 / 生命周期体验
2. 更严格 `renderer-backed preview`
3. 更复杂随机 / spacing 系统
4. 更宽真实绘制 gate

## 4. Deferred Items

- `selection.fill / lasso.fill` 慢确认：deferred known limitation
- 完整 `swift test` 的长跑 perf 项未收口到最终 passed / failed 结论：deferred validation note
- Dual Tip 的 `smudge` 路径：继续排除，不在本轮范围

## 5. 不要做的事

- 不要再写 performance closure audit
- 不要再复述 [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- 不要扩大到新的 history 结构改造
- 不要碰 `smudge / trim / restore` 主线语义
- 不要重开通用 partial history
- 不要把当前任务扩成新的大范围性能项目
- 不要脱离当前已确认范围去扩新的 Dual Tip 家族能力
- 不要默认将更宽 gate 一次性放开到所有工具 / 所有主次笔尖 / 所有模式

恢复开发时，默认先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
