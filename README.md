# ArtFlex

ArtFlex 是旧版 `BrushCanvas` 的 Metal-first 重构版 macOS 绘图软件。

项目目标不是复制旧项目的 CPU 画布实现，而是在保留成熟产品结构、工具集合和主工作流的前提下，用更稳定的 Metal 渲染、图层、文档和工具架构重建整套编辑链。

## 当前基线（2026-04-14）

当前仓库已经不是“第一阶段 MVP”状态，也不是“旧 dual-tip / 回退基线”。

主工程目前已经具备：

- 多图层基础系统
- 撤销 / 重做
- 选区与自由变形主链
- PNG 导出与工程保存 / 打开
- 自定义笔尖设计
- 画笔库与 tip image library
- 参考图、多槽位参考图管理与 LAB 黑白参考
- 快照对比工作流
- ideation 分支工作流
- timelapse 录制 / 导出
- 组合笔刷工作台与正式运行链

当前最活跃的工作主要集中在三条线上：

1. 组合笔刷外观与参数语义继续收口，重点是“整体画笔 vs 内部结构”的边界清晰
2. 颜色 / 色标 / 黑白参考 / 画笔库工作流继续打磨
3. HUD 拾色器、颜色面板拾色器和参考图 UI 等交互一致性继续打磨

## 文档入口

后续线程接手时，按这个顺序读：

1. [CURRENT_STATUS.md](CURRENT_STATUS.md)
2. [HANDOFF.md](HANDOFF.md)
3. [DECISIONS.md](DECISIONS.md)
4. [Docs/reference/REPO_MAP.md](Docs/reference/REPO_MAP.md)
5. [Docs/reference/COLOR_PIXEL_SPEC.md](Docs/reference/COLOR_PIXEL_SPEC.md)

## 常用验证

```bash
swift build
swift test --filter WorkspaceViewModelSafetyTests
swift test --filter BrushStrokeSamplingTests
swift test --filter HistoryControllerTests
swift test --filter ColorStandardTests
swift test --filter StageOneBrushPreviewRasterizerTests
```

## 说明

- 旧的阶段计划、MVP 状态、临时编译修复记录和性能建议文档已经移除；如果需要历史上下文，请直接查 `git log` / `git show`。
- 当前不要假设仓库一定带着一批历史性的 pending 性能 patch；接手前先看 [CURRENT_STATUS.md](CURRENT_STATUS.md) 里的 working tree 说明。
