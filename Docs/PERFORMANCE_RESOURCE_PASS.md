# 第二批优化：按需分配笔触显存 · 2026-09-05

## 决策与范围

复查了实际笔触引擎、画布重绘门控、画笔库缩略图队列/缓存和现有性能审计。
画布已采用按需刷新，笔触已有分块初始化，缩略图已有后台队列与缓存，未重复实现这些机制。
本批只处理已经测得的 V2 笔触多余整画布缓冲，不改变笔刷外观、参数语义、UI 或文件格式。

复用 `BrushV2Session`、现有 256×256 初始化块及 `StageOneBrushRenderer` 测试路径。
使用 Metal 原生 `MTLResource.allocatedSize` 与完成后的命令缓冲 GPU 时间，不新增依赖。
不新建纹理池或 Metal heap：本批问题是不需要的资源仍被分配，直接不分配比增加资源池简单。
不采用降低精度、降低分辨率或 memoryless 存储，三个有效颜料场仍必须跨绘画事件保留原始 RG16F 数据。

参考：

- [Apple Metal 内存建议](https://developer.apple.com/documentation/metal/reducing-the-memory-footprint-of-metal-apps)，其中“不加载未使用资源”的原则可复用；该文的 iOS/tvOS 进程限制不作为 macOS 事实引用。
- [Apple Persistent Objects](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/PersistentObjects.html)，保留会话内资源复用与 GPU 管线复用。

## 代码改动

- `Rendering/Canvas/BrushV2Renderer.swift`
  - A 保持必需，B 和范围缓冲仅在相应笔刷模式需要时分配。
  - 会话内只分配一次，不在关闭开关时释放后重建。
  - 原画捕获和每个颜料场的已初始化块分别跟踪，支持绘画后才启用 B/范围。
  - 无 B 的笔刷不读取 B；未使用的纹理参数绑定已有 A，不新建占位整图。
  - 初始化编码器创建失败时停止该次编码，不读取未初始化块。
  - 保持所有颜色、压感、盖印、Wash、Overlay 公式和中间精度。
- `Tests/ArtFlexTests/BrushV2ResourceTests.swift`
  - 实際渲染的按需分配/全量预分配逐像素对照。
  - 活跃缓冲数、重复申请身份不变、后启用字段的跨块初始化回归。
  - 可选 4K 测量，避免在普通并发测试中占用大量资源。
- `Platform/macOS/Distribution/Info.plist`：构建号 `20260905.5`。

## 实测结果

设备 Apple M4 Max，4096×4096，读取实际 Metal `allocatedSize`。
下表只统计 **V2 单个笔触会话的 A/B/范围颜料缓冲**，不是整个软件内存。

| 笔刷配置 | 修改前 | 修改后 | 减少 |
| --- | ---: | ---: | ---: |
| 普通 V2，无范围裁切 | 192 MiB | 64 MiB | 128 MiB / 66.7% |
| 组合 V2，无范围裁切（含已验收蜡笔） | 192 MiB | 128 MiB | 64 MiB / 33.3% |
| 普通 V2，有范围裁切 | 192 MiB | 128 MiB | 64 MiB / 33.3% |
| 组合 V2，有范围裁切 | 192 MiB | 192 MiB | 不变 |

固定 41 个输入点的短曲线，每种配置 5 次，独立记录 CPU 编码及已完成 GPU 时间。
该小样本耗时存在波动，不据此宣称帧率、长笔画速度或输入延迟有提升。
原画/撤销/合成/材质等其他资源未计入上表，也未在本批重构。

优化前后 9 组 128×128 RGBA 像素 SHA-256 全部一致，包含单笔尖/组合、范围开关、
压力混合/叠加蒙版和本机实际 Krita 参考素材。
实际蜡笔基线 `a4d0fca65db7bfe56d360b4a3f85ee63e928cda68a2cbbae91498facaaf1fb8a`。
源码历史中的优化前版本也有独立测量，不仅是在修改后的实现上进行自我对照。

测量日志：

- `/tmp/artflex-v2-resource-before.log`
- `/tmp/artflex-v2-resource-after.log`
- `/tmp/artflex-resource-regression.log`：377 项测试、37 个套件通过（定向回归，非全库测试）。

设置 `ARTFLEX_MEASURE_V2_RESOURCES=1` 并运行 `swift test --filter BrushV2ResourceTests`
可复测资源大小。实际本地素材测试另需 `ARTFLEX_KRITA_REFERENCE`；没有把用户素材提交到仓库。

## 安全与回退

分支 `codex/performance-resource-pass`，基线 `80f5f4e`。
升级前备份 `/Users/victorcloux/Downloads/ArtFlex-显存优化前备份-QhKQKw`，
含构建 `20260905.4` 压缩包、完整 Application Support 及原画稿。
不删除旧工程或预设，不迁移文件格式。

原画稿校验值 `c4ed94a881e3221ab85ad695dfa7a595a6743bcd46ad148cb4d5dc4df5940975`。
画笔库校验值 `ffc3d68a1659636a4d47c50ed1985e35c1f47b19ffd2450aeaf9396c27d80635`。

## 验证边界

本批有意不调整已经验收的笔刷效果。分配失败的完整笔触事务和更大范围 GPU 错误处理，
以及长笔画、重涂抹、多图层合成的专项性能测量，仍需分别处理，不能视为本批已经解决。
鼠标界面测试不等价于实物数位板压感/驱动验证。
