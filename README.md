# ArtFlex

ArtFlex 是旧版 `BrushCanvas` 的 Metal-first 重构版 macOS 绘图软件。

项目目标不是复制旧项目代码，而是在保留旧产品结构、工具体系和工作流的前提下，用更稳定的 Metal 渲染与文档架构重建画布、图层、工具和导出链路。

## 当前阶段

当前项目已经明显超出最小 MVP，主工程里已经具备：

- 多图层基础系统
- 撤销 / 重做
- 选区基础能力
- PNG 导出
- 工程保存 / 打开
- 组合笔刷工作台与真实预览链

当前最活跃的工作不是管线接线，而是：

- 在主工程内继续收组合笔刷的最终外观
- 保持现有 brush core、采样链、tip sampling 和显示链稳定
- 只针对主层视觉表达做 look reconstruction

## 当前组合笔刷状态

当前组合笔刷已经不是“旧回退基线”。

现状是：

- 活动 UI 是 [CompoundBrushBuilderSheet.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- 活动运行时是 [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift) 里的 compound 分支
- 主笔尖和次笔尖都已经通过 `BrushSettings` / `CompoundBrushSettings` 落到正式运行链
- 当前目标 brush 的主路径是：
  - 主笔尖决定笔触范围
  - 次笔尖在笔迹坐标空间形成更大的重复纹理场
  - 最终结果由主笔触包络裁剪
  - 压力控制主次主导权
  - 透明度曲线独立控制整条笔触深浅

当前这条路径已经接回软件，可直接手测；剩余问题主要是主层外观仍需继续收口。

## 新线程建议先看

如果你是新线程或刚恢复开发，先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)

## 迁移原则

- 产品层设计优先继承旧项目
- 底层实现优先重建，不复制旧项目 CPU 逻辑
- 所有颜色、纹理、混合、导出、取色路径必须共享统一规范
- 不为了短期“能跑”而引入长期架构债务

## 成功标准

本项目阶段性成功的标志是：

- 核心画布显示稳定
- 颜色一致性稳定
- 大画布下交互性能优于旧项目
- 图层、画笔、选区、变形具备可持续扩展能力
- 组合笔刷既能稳定运行，也能在主工程里持续迭代外观而不破坏管线
