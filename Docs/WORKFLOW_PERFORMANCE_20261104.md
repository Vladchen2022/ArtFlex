# ArtFlex 十项优化改造报告

日期：2026-11-04。状态：十项改动已实施，定向回归和代表性界面验收通过，正式应用已安装。

正式位置为 `/Applications/ArtFlex.app`，构建 `20261104.33`。当前打开的是正式应用中的验收工程 `final-workflow.artflex`。用户原有自动恢复副本仍保留，未点击恢复或丢弃。

## 1. 决策摘要

本轮沿用现有 Metal 图层、像素格式、历史事务、工程归档和资源缓存，不改变成熟工作区布局，不新增第三方依赖。

| 范围 | 仓库复用 | 原生／既有方案与决策 |
| --- | --- | --- |
| 退出、文件操作 | `DocumentLifecycleCoordinator`、`ProjectSaveCoordinator`、`FilePanelService` | 使用 AppKit 的延迟退出与确认回复协议；文件面板仍为系统面板，补齐模态运行循环和状态通知。 |
| 预览与取消 | `WorkCancellation`、既有 GPU 渲染器、像素序列化和选区算法 | 用 Swift actor 串行执行预览、任务取消和请求身份校验；小型协调器仅管理本项目的“最新结果有效”规则。 |
| 历史与保存 | 稀疏图层编辑事务、分块像素恢复、压缩缓存、原子归档写入 | 修正已有路径的使用方式，保留大范围操作的批处理；避免重建另一套像素／文件基础设施。 |
| 最近工程与恢复 | 现有工程打开、保存、恢复归档 | 最近工程使用 `NSDocumentController`；恢复摘要只读既有归档，并新增可选缩略图。 |
| 打包和安装 | 原有签名、图标生成与应用打包脚本 | 以 Python 标准库、系统 `ditto`、`codesign`、`dwarfdump` 组合本地校验、备份和替换；没有引入更新服务。 |

已查阅的官方接口：

- [NSApplicationDelegate.applicationShouldTerminate](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldterminate(_:))
- [NSApplication.reply(toApplicationShouldTerminate:)](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:))
- [Task.cancel()](https://developer.apple.com/documentation/swift/task/cancel())
- [NSDocumentController.noteNewRecentDocumentURL](https://developer.apple.com/documentation/appkit/nsdocumentcontroller/notenewrecentdocumenturl(_:))

取消是协作式的，不能让已经提交的 GPU 命令或正在执行的系统图像函数瞬间停止。因此实现同时包含阶段检查、串行执行和过期结果丢弃，不能仅依赖 `Task.cancel()`。

## 2. 实施顺序与十项结果

先建立 Git 回退点，再处理文件安全和异步任务边界，然后修改历史、保存、缓存与入口，最后执行回归、可见界面验收、安装回退和正式版重开。

| # | 改进前 | 改进后 | 验证与限制 |
| --- | --- | --- | --- |
| 1 | 退出确认、异步保存与系统终止流程衔接不完整；取消面板后命令可用性可能不刷新。 | 退出返回 `terminateLater`，完成选择／保存后只回复一次；模态循环可以接收完成通知，面板和生命周期状态会触发界面刷新。 | 界面实测取消退出、立即保存，以及“退出→保存→文件面板→真正退出”。未执行系统关机／注销。 |
| 2 | 最近一次纹理填充的参数调整依赖工作区中的同步渲染，快速修改缺少独立作业边界。 | 冻结原始画面，独立渲染器在串行 worker 上执行；80 ms 合并请求，仅发布最新有效结果；处理期间不允许应用未完成结果，失败时保留错误状态。 | 用户绘制有效区域后，实测改尺寸、取消、重新调整为环形、应用、撤销、重做。两种像素格式验证结果确定且不污染原始画面。 |
| 3 | 取消部分预览只能阻止最后写回；导出预览重复读回和编码大图。 | 选区算法在行／列和阶段边界检查取消；导出预览缓存不可变源，GPU 先缩至最长边 1200，输出预览最长边 600，再编码。 | 选区预览取消、PNG/JPEG 设置切换通过，实际 PNG 导出为 2048×2048。预览为缩小的 8 位图，正式导出保持原有精度链路。 |
| 4 | 菜单、搜索和工具栏各自描述命令，禁用原因及快捷键提示可能偏离实际行为。 | 主要文件／编辑／选区／显示命令共用描述、执行与可用性；变形快捷键取自实际配置，搜索结果会说明禁用原因。 | 搜索“移动”显示 V，执行后进入变形；变形期间保存等文件命令明确提示先确认或取消，取消后恢复。没有将所有零散 UI 操作都强制改成命令系统。 |
| 5 | 局部撤销恢复可能退回整张纹理克隆，抵消稀疏图层的局部编辑收益。 | 小区域恢复复用稀疏编辑事务，先完成所有准备和校验再发布；大范围／蒙版继续走密集批量克隆。 | 4K、RGBA8 和 RGBA16Float 的多轮撤销／重做验证像素一致与稀疏存储保留。未给出新旧耗时对照，不声称历史报告中的性能退步已被量化消除。 |
| 6 | 正式保存压缩前可能同时持有全部原始资源读回数据；预览先读回整图。 | 复用压缩缓存的保存路径逐个读回、压缩资源；预览先在 GPU 缩至最长边 512，再读回。 | 持久化与异步保存回归通过，界面保存后正式版重开图像一致。仍需保留冻结 GPU 资源和压缩后的负载，不是整个归档的恒定内存流式写入。 |
| 7 | 蒙版缩略图随全局内容变化重复计算。 | 独立 actor 按图层、修改版本和纹理身份缓存，最多 96 项，同层旧版本淘汰；任务结果发布前复核身份。 | 界面验证白蒙版、反转为黑蒙版、画面隐藏及撤销恢复。缓存边界为代码保证，未量化实际帧率收益。 |
| 8 | 工程入口缺少最近文件；恢复按钮不能事先说明将恢复什么。 | 打开菜单提供最近工程和继续上次工程；仅在成功保存／打开后记录。恢复卡显示名称、日期、尺寸和可用预览，旧归档无预览时明确提示。 | 最近工程实际打开成功；隔离验收环境的恢复卡显示 `quit-save`、日期、2048×2048 及预览。用户真实恢复副本未被恢复或丢弃。 |
| 9 | 大工作区对象同时承担选区栅格化、预览渲染、缓存和平台文件入口。 | 拆出 `SelectionMaskRasterizer`、`TextureAdjustmentRenderer`、预览协调器、缩略图／导出预览缓存及工程访问控制器。 | 工作区文件由 20348 行降至 19536 行；相关回归覆盖行为。文件仍很大，这次不是彻底完成工作区架构拆分。 |
| 10 | 构建产物缺少与源码的可核对身份，安装和回退依赖手动复制。 | 构建清单记录提交、源码指纹、版本、UUID 和资源哈希；打包拒绝过期产物；安装前签名校验与备份，失败恢复；关于窗口展示代码身份及实际路径。 | 实际执行安装新版→回退旧版→重新安装新版，分别核对版本和 UUID；过期源码指纹被拒绝。正式关于窗口确认运行路径。 |

## 3. 主要代码与文件

| 模块 | 变更文件 |
| --- | --- |
| 退出与文件生命周期 | `Platform/macOS/App/ArtFlexApp.swift`、`Platform/macOS/Services/MainRunLoopDelivery.swift`、`Platform/macOS/Services/FilePanelService.swift`、`Core/Application/ProjectSaveCoordinator.swift`、`Core/Lifecycle/DocumentLifecycleCoordinator.swift` |
| 纹理／选区预览 | `Core/Application/LatestPreviewCoordinator.swift`、`Rendering/Canvas/TextureAdjustmentRenderer.swift`、`Rendering/Canvas/TextureFillGestureState.swift`、`Rendering/Canvas/SelectionMaskRasterizer.swift`、`Core/Selection/SelectionMaskRegion.swift`、`Core/Selection/SelectionRefinement.swift` |
| 历史、保存和恢复 | `Core/Application/HistoryController.swift`、`Core/Application/PersistenceController.swift`、`Core/Application/RecoveryProjectSummary.swift`、`Infrastructure/FileFormat/IncrementalRecoveryArchive.swift`、`Infrastructure/FileFormat/ProjectArchiveV2.swift` |
| 缓存与工程入口 | `Platform/macOS/App/MaskThumbnailStore.swift`、`Platform/macOS/App/RasterPreviewStore.swift`、`Platform/macOS/App/ProjectAccessController.swift`、`Platform/macOS/UI/ProjectAccessViews.swift` |
| 工作区接线与命令 | `Platform/macOS/App/WorkspaceViewModel.swift`、`Platform/macOS/App/InteractionWorkflowState.swift`、`Platform/macOS/UI/WorkspaceCommands.swift`、`Platform/macOS/UI/CanvasWorkflowBar.swift`、`Platform/macOS/UI/MainToolbarView.swift` |
| 发行与身份 | `Platform/macOS/App/AppBuildIdentity.swift`、`Platform/macOS/Distribution/release.py`、`Platform/macOS/Distribution/package-app.sh`、`Platform/macOS/Distribution/Info.plist` |
| 测试与说明 | `Tests/ArtFlexTests/FileWorkflowSafetyTests.swift`、`HistoryControllerTests.swift`、`LatestPreviewCoordinatorTests.swift`、`TextureAdjustmentRendererTests.swift`；`README.md`、`CURRENT_STATUS.md`、本报告 |

## 4. 验证证据

### 构建和定向回归

Release 构建通过；最终应用代码为 `5db4a8e7d5f8bcd26487e6953512c5d8001e0c7c`。

```sh
swift test --filter 'LatestPreviewCoordinatorTests|HistoryControllerTests|FileWorkflowSafetyTests|ProjectSaveCoordinatorTests|PersistenceOptimizationTests|SelectionRefinementAndPreciseAffineTests|BoundedSelectionOptimizationTests|RasterExporterTests|IncrementalRecoveryTests'
# 101 tests / 9 suites，8.430 秒，通过。

swift test --filter TextureAdjustmentRendererTests
# 1 test / 1 suite，两个像素格式参数案例，0.356 秒，通过。
```

这两次是最终代码的定向运行，共 102 项测试；没有把先前版本或重复执行的数量累加，也没有把它称为全量回归。前一轮同范围 101 项也通过，随后仍在界面中发现了取消对话框后的状态刷新问题，这说明自动测试不能代替真实界面验收。

现有构建警告仍在：`BlockReferenceMetalSolidView.swift:541` 不可达分支；测试编译有 `BrushV2ResourceTests.swift:157` 冗余 `#require`。本轮没有将无关警告清理混入改造。

### 可见界面验收

通过界面控制实际操作，未用后台状态注入代替用户操作。临时验收应用使用独立标识和数据目录，避免改写用户的笔刷库与真实恢复数据。

1. 新建画面并画线，调用退出，取消。初版暴露“文件按钮仍禁用”；补充面板和生命周期通知后重新构建，复测取消退出后可立即打开保存面板。
2. 带未保存内容退出，选保存，实际出现系统保存面板；保存 `quit-save.artflex` 后进程结束，文件存在。随后通过最近工程入口重开。
3. 选区扩展预览修改后取消，选区仍在，文件命令恢复；蒙版反转后画面隐藏，撤销后恢复。
4. 用户在验收窗口画出有效纹理区域；改尺寸后取消，重新调整为环形并应用；撤销显示原流向纹理，重做显示环形纹理，随后保存。
5. 搜索“移动”执行自由变形。再次打开搜索，保存等文件命令显示“请先确认或取消自由变形”；取消变形后保存按钮重新可用。
6. 打开导出，切换 JPEG 和 PNG，实际导出 PNG。界面报告 2048×2048，文件元数据核对为该尺寸，检查导出图像与环形画面一致。
7. 安装新版、回退、重新安装完成后，从 `/Applications/ArtFlex.app` 启动；关于窗口显示构建、提交、源码指纹和正确路径。
8. 正式版通过系统打开面板重开 `final-workflow.artflex`，画面和“已保存”状态正确，原有“恢复”入口仍保留。

验收文件保存在 `/Users/victorcloux/Desktop/ArtFlex-优化验收-20261104/`：

- `quit-save.artflex`、`final-workflow.artflex`、`final-workflow.png`
- `focused-regression.log`、`texture-renderer-tests.log`、`release-build.log`
- `BuildManifest.json`

### 构建和安装身份

| 项目 | 值 |
| --- | --- |
| Git 分支 | `codex/workflow-performance-20261104` |
| 改造前回退标签 | `backup/pre-workflow-performance-20261104`，指向 `d12a605` |
| 主实现提交 | `b8370b0` |
| 界面修正及密集历史批处理提交 | `5db4a8e` |
| 正式构建 | `20261104.33` / Release |
| 源码指纹 | `a417d25e71e14a1e105d621371ab02e6fbbb588eccf01b08d4bfbe96d24c5d9b` |
| 新版可执行文件 UUID | `46A8045A-AA33-3D82-8BF6-07A3F123E665` |
| 旧版版本和 UUID | `20261006.32` / `8F4EE241-B6F2-3289-B9CF-6FE566F81B54` |

文档和补充测试在应用构建之后提交，因此 Git HEAD 可晚于构建清单中的应用代码提交。正式代码指纹仍匹配。预先存在的 `HANDOFF.md` 工作区修改未改写、未纳入本轮提交。

## 5. 回退方法

保存画稿并退出 ArtFlex 后，执行以下命令可回到本轮改造前正式安装的 `20261006.32`：

```sh
cd /Users/victorcloux/Desktop/ArtFlex
python3 Platform/macOS/Distribution/release.py rollback .build/install-backups/20261104-145423-463189-ArtFlex.json
```

此记录对应首次安装前的完整应用备份，已用于真实回退并核对旧版 UUID。回退还会备份被替换的当前版本，不修改画稿、库或恢复数据。保留 `.build/install-backups/` 中对应 `.app` 与 `.json`，清理 `.build` 会删除这些本地备份。

源码可通过标签 `backup/pre-workflow-performance-20261104` 查阅或另建分支恢复。不要在有未提交用户修改的工作区执行破坏性重置。

## 6. 风险与后续边界

- **未量化性能收益。** 已验证数据一致性、稀疏恢复路径和取消行为；没有本轮前后对照的时间、峰值内存或长时间稳定性数据，不给出速度或内存下降百分比。
- **取消不等于硬中断。** 已提交的 GPU 工作与部分系统图像运算需完成当前阶段；过期结果不会发布，但取消延迟受该阶段耗时影响。
- **保存仍有大资源成本。** 冻结 GPU 资源及压缩负载仍占内存，旧的无缓存保存路径保留完整快照要求。
- **工作区继续需要拆分。** 19536 行仍然过大；本轮完成已批准的职责抽离，不代表全面解耦到可跨平台直接复用。
- **系统终止边界未现场测试。** 已验证原生 Cmd+Q 和模态保存；未注销或关机，也未模拟断电、磁盘故障或强制杀进程。
- **安装为本地签名。** 已校验正式包、图标资源和实际路径；没有公证、自动更新服务，也未单独确认退出后的 Dock 图标缓存。

对本轮列出的功能路径与交付身份，证据充分；对普遍性能提升和所有边界无回归，证据不足。后续性能工作应以固定画稿、固定硬件的对照测量为起点。
