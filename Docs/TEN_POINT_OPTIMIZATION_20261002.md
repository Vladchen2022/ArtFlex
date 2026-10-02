# ArtFlex 十项优化报告（构建 20261002.30）

本轮从 `9d5b575` 开始，实施用户批准的十项优化。分支为 `codex/ten-point-optimization`，改造前标签为 `backup/pre-ten-point-20261002`。保留产品布局、笔刷语义、像素/颜色规范和 V2 工程格式；没有增加依赖。原有 `HANDOFF.md` 的未提交修改没有覆盖或纳入提交。

十项均已有实现和回归测试。下文分别列出实际收益与仍保留的边界，不将局部计时、缓存资源计数等同于整机响应或峰值内存。最终 Debug、Release 和窗口验收均已完成。

## 决策与复用

复用现有文档生命周期、渐变版本保护、区域历史、稀疏纹理、变化日志、规范化合成计划、磁盘历史和体块几何算法。GPU 完成、线程调度、内存分配继续使用 Metal、Swift 和 Foundation 原生接口。

笔触提交必须连历史读回一起异步，否则只移除渲染等待仍会阻塞主线程。交互路径使用可等待、无 MainActor 依赖的完成票据；强制保存、撤销等边界消费同一任务。

软选区按原像素乘覆盖率提取，原层保留其余覆盖率，移动后按 source-over 合成。恒等变换保留原纹理，亚像素位移不再被四舍五入成恒等。

保存优先减少重复解包、未变化资源的冻结/读回/压缩，不改变磁盘格式。冷历史按预算准备；长跳转先后台校验整段，再逐步应用，避免已知磁盘损坏引发半途切换。

## 十项实现及边界

| 项 | 已完成的改动 | 验证重点与保留边界 |
|---|---|---|
| 1. 历史与保存状态 | 历史位置与文档内容分别使用稳定 ID；撤销、重做和跳转推进文档版本；保存点随成功写入记录；回到保存内容恢复“已保存” | 覆盖保存后撤销、保存中编辑/撤销、旧保存完成、重做与分叉，以及选区历史夹在保存与变形之间；参考图和快照修改不会被历史误清除 |
| 2. 安全提交 | 生成器、套索/实色纹理填充和变形先生成暂存结果，确认源版本、GPU 和历史成功后才发布 | 编码/分配/GPU/历史失败保留原像素、redo；生成器取消及迟到结果拒绝；变形失败保留可重试草稿 |
| 3. 软选区变形 | 保留未选覆盖、处理重叠与恒等结果；预览先完整合成活动层，再进入正常层序、蒙版、透明度和混合 | 8/16 位覆盖、平移重叠、mesh、identity、预览/提交对照；新增一张复用的全画布预览纹理，不能称变形所有场景更省内存 |
| 4. 异步笔触提交 | 单个待完成任务连接 GPU、后台历史读回和主线程发布；保存/撤销可同步等待同一任务 | 人为延迟 GPU 和历史，检查非阻塞返回、只提交一次、失败不丢输入；CPU 编码预算仍是软预算 |
| 5. 局部笔触资源 | 实时目标与提交暂存按真实笔印边界映射 Metal sparse tiles；包括 V2 和涂抹 | 7 类笔刷/工具 × 8/16 位，共14组实际稀疏分配与完整像素对照；部分 opacity-cap/V2 中间资源仍为全尺寸，高占用/未知稠密源保留 dense 路径 |
| 6. 合成与吸管 | 缓存活动层下方稳定前缀；区域 GPU 吸管使用相同合成 shader，异步读取少量结果 | 内容/蒙版/剪贴/顺序/透明度失效，分配失败回退；8/16 位、曲线、隐藏当前层、零透明度及颜色统计；3D 底衬存在时暂禁前缀缓存 |
| 7. 文件与恢复 | 未变化图层/蒙版复用有界压缩缓存；打开只解包一次；恢复冻结的等待转到后台 | 缓存64 MiB、弱纹理身份和变化版本失效，内存压力释放；保留完整文件重写、最终校验和原子替换，首存与超预算仍完整捕获 |
| 8. 局部选区与填充 | 运行时遮罩保存有效区域；连续魔棒状态按需分页；组合/羽化/预览按局部处理；普通16位填充按需读块；选区历史不再捕获整图像素 | 旧 Codable 格式兼容，布尔/羽化/坐标与原实现对照；建立/清除选区历史复用 workspaceOnly，不冻结图层像素，覆盖边框刷新及失败保留；全局、补缝和扩张填充保留原全图路径，GPU 遮罩仍有全画布逻辑尺寸 |
| 9. 冷历史准备 | 后台读盘/校验/解压，最多预取两项并限制字节；长导航可取消、逐步反馈、拒绝旧文档结果 | 缓存破坏与修复、取消、预览恢复中继续编辑；GPU 逆向快照与恢复仍同步，长跳转为安全预检仍有两阶段磁盘读取 |
| 10. 体块缓存 | 按对象缓存世界几何，按完整相机/剖切/深度/显示参数缓存投影，静止帧复用上传缓冲 | 静止、单对象编辑、环绕分别对照；相机变化仍 CPU 重投影，未做缺乏测量依据的 GPU 几何重写 |

## 自动化验证

- 改前：Debug 全量1002项 / 101组通过，41.814秒。
- 最终 Debug：1054项 / 111组通过，44.109秒，退出码0。
- 最终 Release + DEBUG：1054项 / 111组通过，13.821秒，退出码0。
- 无 DEBUG 的交付 Release：`swift build -c release` 通过，109.37秒。
- 初始回归明确复现了“保存后撤销仍显示已保存”和“保存中撤销接受旧版本”两条错误，再由修复通过。
- 后续全量发现并修复了 ROI 字节读取的 Swift 指针类型推断错误，以及选区后台栅格化与变形提交版本校验的竞争。
- 窗口验收另外复现“保存→选区→变形→撤销”像素恢复但仍显示未保存；新增3个真实保存回归，在修复前精确产生5条保存状态失败，像素对照通过。修复分离历史位置和内容身份，覆盖 dirty 分支与保存进行中的选区变化；清选区也统一走同一规则。
- 代码确认此前单纯选区按 full 历史捕获两层像素，现在改用已有 workspaceOnly 路径。内存口径校正：窗口中的704 KB→48.7 MB发生在选区加变形的整段流程，不能全算作单独选区的成本或本次节省量；最终纯选区流程的面板像素历史为0 KB。回归检查纹理身份、像素不变、历史像素 payload 增量为0，以及 undo/redo/预览后的选区边框与场景 revision。选区遮罩本身仍占内存，并非整条历史零内存。
- 新增事务测试保留真实失败后的像素、纹理身份、变化版本、历史状态、redo、dirty 及重试检查；异步改动的旧测试等待完成后继续检查原像素条件。

测试命令使用 `swift test` 和 `swift test -c release -Xswiftc -DDEBUG`。后者保留故障注入钩子供测试使用；交付应用另外使用无 DEBUG 的 Release 构建。

## 测量口径与结果

同一 M4 Max / 128 GiB 机器，Release + DEBUG 测试配置。工作负载含4个绘画层、活动层蒙版、固定种子笔触、撤销/重做、局部填充、工程保存重开；2048/4096画布、8/16位各6次，第一次数值作为冷启动样本，热数据取后5次中位数。

改前原始样本为 `Docs/Measurements/TEN_POINT_BASELINE_20261002.json`；最终 `db8f4b9` 样本为同目录的 `TEN_POINT_FINAL_20261002.json`，统计为 `TEN_POINT_COMPARISON_20261002.json`。中间版本两轮样本保留在 `TEN_POINT_AFTER_20261002.json`、`TEN_POINT_AFTER_REPEAT_20261002.json`，不以较好的样本替换最终结果。保存阶段计时口径已改变：现在 materialize 同时执行变化层编码，应比较 save 总时间，不把该阶段误称为纯读回。

| 画布与精度 | 改前保存中位数 | 改后保存中位数 | 耗时降低 |
|---|---:|---:|---:|
| 2048²，8位 | 253.64 ms | 153.49 ms | 39.5% |
| 2048²，16F | 489.59 ms | 287.31 ms | 41.3% |
| 4096²，8位 | 947.87 ms | 552.02 ms | 41.8% |
| 4096²，16F | 1,858.85 ms | 1,077.39 ms | 42.0% |

中间版本的独立复测四组保存中位数分别为152.26、289.54、546.85、1,080.17 ms，与最终结果接近。它反映连续编辑中复用未变化图层的收益，不代表首存及所有图层同时改变时也有相同提升。

4096²、32px小笔触的实际工作目标分配由8位的64 MiB降至128 KiB、16F的128 MiB降至192 KiB。数据来自实际 sparse heap 分配，dense对照仍为64/128 MiB；14组工具×精度矩阵进行了完整像素对照。这是工作纹理的分配，不能声称整个应用内存降低99%。

合成与体块使用同一最终测试二进制开关缓存，各3次串行运行；每次去除首帧后共21个样本。20层512²合成的CPU编码中位数0.1123→0.0136 ms，GPU 0.2530→0.0245 ms。100体块静止CPU准备0.5769→0.0236 ms，单对象修改1.4069→0.2613 ms。改前初次笔触/体块fixture曾被测试框架并行运行，保留其资源计数，但不以那些时间作严格性能对照。

不能声称所有操作都加速。4096²/16F重做由4.04 ms变为最终4.94 ms，中间两轮4.77、4.37 ms；该路径存在测量上的退化，最终增加0.893 ms（22.1%），不能称为速度收益。现有记录只有 redo 总时间，尚不能归因；对照确认整纹理clone和局部restore在基线已存在，历史payload和保存后GPU分配逐样本相同。下一步应分段测量逆向捕获、clone等待、restore及视图刷新；目前没有证据支持猜测性重写。其他三组重做最终较快。冷历史主要改进主线程等待、取消和错误处理，像素恢复仍受同步GPU操作约束。

100体块连续环绕最终为关闭缓存0.5879 ms、启用缓存0.6220 ms，增加0.0342 ms（约5.8%）。相机变化时所有对象投影都失效，仍需完整CPU重投影，并有缓存记账开销。首次对照增加0.0589 ms；已将重复删除/插入改为直接替换，最终差距较小，但这些样本不足以把差异全归因于该微调。保留当前策略的判断依据是静止和单对象编辑的明确收益；没有宣称连续环绕得到加速，也没有在收尾阶段冒险替换整套几何管线。

已确认的局部资源计数：4096²画布中64²连续选区的工作状态及输出为200,704 bytes，最终遮罩4,096 bytes；RGBA16F下32²局部填充的参考读回为2,097,160 bytes，历史与结果各8,192 bytes。对照整张RGBA16F参考图为134,217,728 bytes。这些是 fixture 资源计数，不是整个进程峰值。

笔触 liveMs 包括准备、编码和 GPU fence，commitMs 是 forced 边界；都不等于数位笔到屏幕的真实延迟。新增 presentedTime 诊断区分 GPU 完成和实际上屏，尚未进行硬件延迟测量。

## Git、应用与数据

- 主实现提交：`4a8751c`。
- 事务回归与内容版本提交：`5497082`。
- 体块缓存条目替换简化：`c175573`。
- 选区内容身份、状态历史及窗口回归：`db8f4b9`。
- 回退标签：`backup/pre-ten-point-20261002` → `9d5b575`。
- 离线备份：`~/Downloads/ArtFlex-十项优化备份-20261002-9d5b575`，包含旧应用 .29、Git bundle、原有 handoff 副本及验证日志。
- 原画稿 SHA-256 保持 `09ef64c530544642e70d5f5022b306437b4e1520f86a8a479c616dd12622aa44`。
- 原有 `HANDOFF.md` SHA-256 保持 `b3186f8c6d66c28f8d7a4b74c9f82630b74113149f37e797eeacd5d65cb859d4`。

交付应用已更新为 `.build/ArtFlex.app`，构建 `20261002.30`，对应生产代码 `db8f4b9`。无 DEBUG 的 Release 构建和 `codesign --verify --deep --strict` 验证通过，使用本机开发用 ad-hoc 签名。二进制 UUID 为 `4FE9625C-FC27-3BC0-B435-9FB5C9C8D54F`，SHA-256 为 `9349348535ffd2a3ab7374bd2929a6bd29ffafea547575e0c04f7f230569880b`。

实际窗口用独立工程副本完成：打开、画笔、保存、撤销/重做到保存点、矩形选区、变形预览/提交、撤销变形直接恢复已保存、清选区及其撤销/重做、历史预览和取消。选区边框可见地正确恢复，纯选区历史面板显示像素历史0 KB。最后已重新打开原画稿，显示已保存，原文件校验值未变。测试操作记录在备份目录的 `Validation/window-smoke-final.json`，首次发现问题的记录也保留。代码回退、应用回退和画稿恢复分别使用 Git 标签、旧应用压缩包和原画稿，不能互相替代。

## 结论的范围

正确性结论对上述自动化和窗口用例的置信度高；固定负载下的性能变化有原始样本支持。没有测量真实数位笔到屏幕延迟，也没有用这台128 GiB设备的结果推定低内存机器、所有画稿和长期绘画行为。体块环绕与4096/16F热重做的退化已保留为具体后续问题；本轮不宣称整个软件每条路径都更快。

## 参考

- [Apple Metal completion handler](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler(_:))。
- [Apple sparse texture memory assignment](https://developer.apple.com/documentation/metal/assigning-memory-to-sparse-textures)。
- [Apple sparse texture reading/writing](https://developer.apple.com/documentation/metal/reading-and-writing-to-sparse-textures)。
- [Krita transform strategy](https://github.com/KDE/krita/blob/master/plugins/tools/tool_transform2/strokes/inplace_transform_stroke_strategy.cpp)，参考选中内容提取、清除和未变化时回退原像素的处理。
- [Krita paint device](https://github.com/KDE/krita/blob/master/libs/image/kis_paint_device.cc)，参考 clearSelection 的剩余 alpha 规则。

## 变更文件

- `Core/Application/HistoryController.swift`
- `Core/Application/PersistenceController.swift`
- `Core/Application/ProjectSaveCoordinator.swift`
- `Core/Application/RecoveryAutosaveCoordinator.swift`
- `Core/Application/TransformInteractionState.swift`
- `Core/Generator/GeneratorRegionRasterizer.swift`
- `Core/Selection/SelectionMaskCombiner.swift`
- `Core/Selection/SelectionRefinement.swift`
- `Core/Selection/SelectionState.swift`
- `Core/Selection/SmartSelectionSegmenter.swift`
- `Docs/Measurements/TEN_POINT_AFTER_20261002.json`
- `Docs/Measurements/TEN_POINT_AFTER_REPEAT_20261002.json`
- `Docs/Measurements/TEN_POINT_BASELINE_20261002.json`
- `Docs/Measurements/TEN_POINT_COMPARISON_20261002.json`
- `Docs/Measurements/TEN_POINT_FINAL_20261002.json`
- `Docs/TEN_POINT_OPTIMIZATION_20261002.md`
- `Infrastructure/FileFormat/DeferredTextureCloneBatch.swift`
- `Infrastructure/FileFormat/HistoryDiskCache.swift`
- `Infrastructure/FileFormat/IncrementalRecoveryArchive.swift`
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
- `Infrastructure/FileFormat/ProjectArchiveV2.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Platform/macOS/Distribution/Info.plist`
- `Platform/macOS/UI/BlockReferenceMetalSolidView.swift`
- `Platform/macOS/UI/CanvasContainerView.swift`
- `Platform/macOS/UI/VisibleHistoryPopover.swift`
- `Rendering/Canvas/BrushLiveSession.swift`
- `Rendering/Canvas/BrushV2Renderer.swift`
- `Rendering/Canvas/BucketFillEngine.swift`
- `Rendering/Canvas/EyedropperSampler.swift`
- `Rendering/Canvas/MagicWandSelectionEngine.swift`
- `Rendering/Canvas/MetalStrokeEngine.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`
- `Rendering/Canvas/StageOneCanvasPresenter.swift`
- `Rendering/Canvas/StageOneLayerSurfaceStore.swift`
- `Rendering/Canvas/TransformGPUCompositor.swift`
- `Rendering/Canvas/TransformPreviewSession.swift`
- `Rendering/Metal/SparseLayerTexture.swift`
- `Tests/ArtFlexTests/BlockReferenceRenderCacheTests.swift`
- `Tests/ArtFlexTests/BoundedSelectionOptimizationTests.swift`
- `Tests/ArtFlexTests/BrushPipelineOptimizationTests.swift`
- `Tests/ArtFlexTests/EyedropperGPUCompositionSemanticsTests.swift`
- `Tests/ArtFlexTests/EyedropperSamplerTests.swift`
- `Tests/ArtFlexTests/FileWorkflowSafetyTests.swift`
- `Tests/ArtFlexTests/HistoryPreparationTests.swift`
- `Tests/ArtFlexTests/MetalStrokeEngineQueueTests.swift`
- `Tests/ArtFlexTests/PersistenceOptimizationTests.swift`
- `Tests/ArtFlexTests/RenderImprovementBaselineTests.swift`
- `Tests/ArtFlexTests/SoftSelectionTransformCoverageTests.swift`
- `Tests/ArtFlexTests/StableCompositePrefixTests.swift`
- `Tests/ArtFlexTests/TransformInteractionStateTests.swift`
- `Tests/ArtFlexTests/WorkspaceTransactionRegressionTests.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift`
