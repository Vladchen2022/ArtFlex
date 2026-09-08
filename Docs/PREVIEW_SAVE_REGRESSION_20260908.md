# 调色预览与保存计数回归稳定性（2026-09-08）

## 范围与决策

本批承接右侧面板验收留下的两项偶发失败。只修调色预览生命周期与测试计数隔离，不改调色公式、像素规范、笔刷、工程格式、保存算法、主界面布局，也未开始磁盘辅助撤销。

复用 `WorkspaceViewModel+ColorAdjustment` 已有的预览代号、过期回调检查和合并更新机制；复用 `PerformanceAuditStore` 的线程安全记录器，通过现有服务构造入口传入独立实例，无新增依赖。

参考核对：

- [Apple Metal 完成回调](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler(_:))：GPU 完成后触发回调；转入 MainActor 的后续工作仍有排队过程。
- [Apple Swift Testing 并行语义](https://developer.apple.com/documentation/Testing/Parallelization)：默认在同一进程并行运行；单个套件的 `.serialized` 不隔离其他套件。

因此不全局禁用并行、不延长固定休眠、不删除或放宽像素／次数断言，也不引入额外调度框架。

## 根因与验证证据

### 调色

更换已提交选区时创建了新预览纹理，却沿用旧预览的 token 和 in-flight 状态。旧 GPU 作业即使已经结束，只要它的 MainActor 回调还没执行，新纹理的渲染仍会被推迟。旧完成回调还能增加共用重绘 revision，造成测试将新纹理的底色误认成已完成预览。

此外，旧等待辅助函数把“存在纹理”或“重绘 revision 增加”视为最新效果已经完成，没有等待合并后的后续作业。

确定性回归用例在同一个 MainActor 调用内提交旧预览、换选区，再通过原有 Metal 队列读取新纹理，不靠随机睡眠制造故障。修复前稳定出现 5 项断言失败，RGB 为 0.2392／0.2784／0.3216，仍是底色；修复后同一测试通过。

修正方式：更换预览上下文立即更新 token、清除旧作业状态，提交新纹理作业；已有 token 检查忽略旧完成回调。等待辅助函数同时检查 in-flight 与 needs-resubmit 均结束，像素断言保持原样。补充连续参数变更测试，要求最终亮度对应最后一次设置，原图层像素仍未被预览改写。

### 保存计数

失败断言统计的是全局记录器中的 `LayerTextureSerializer.snapshot`，并非保存失败次数。其他并行测试也读取纹理、重置和关闭同一个记录器；所以“单次保存是否批量快照”的测试会被无关读取污染。

`LayerTextureSerializer` 可接收独立记录器，生产默认仍使用 `.shared`。保存测试从 `AppSharedMetalServices` 注入独立记录器，仍要求恰好 1 次批量快照、0 次单层快照，并补验重开后的图层记录及快照数量。另一个用例明确交错两套记录器的批量／单次读取、reset 和停用，验证计数互不干扰。

这项计数失败本身不构成丢失工程的证据；本批未用它推导文件损坏，也未为此改写保存流程。

## 改动文件

- `Platform/macOS/App/WorkspaceViewModel+ColorAdjustment.swift`：统一预览失效处理，补齐选区及新上下文替换时的旧回调隔离。
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`：性能记录器构造注入，默认行为不变。
- `Platform/macOS/App/AppBootstrap.swift`：现有共享 Metal 服务支持传入纹理记录器。
- `Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift`：等待最新作业完成；新增上下文替换和连续参数变更的像素测试。
- `Tests/ArtFlexTests/PersistenceSaveQueueTests.swift`：独立计数，并验证重开内容。
- `Tests/ArtFlexTests/LayerTextureSerializerQueueSafetyTests.swift`：交错记录隔离回归。
- `Platform/macOS/Distribution/Info.plist`：构建号 `20260908.18`。
- 本记录、面板验收记录的后续说明和当前状态索引。

## 自动验证

| 验证 | 结果 |
| --- | --- |
| 修改前全量基线 | 910 项／84 套通过，36.612 秒；单次通过不能否认历史偶发失败 |
| 新增确定性用例，修改产品代码前 | 1 项测试失败，5 项断言失败 |
| 针对性修复验证 | 3 项通过，0.769 秒 |
| 最终全量第 1 轮 | 913 项／84 套通过，37.141 秒 |
| 最终全量第 2 轮 | 913 项／84 套通过，36.836 秒 |
| 最终全量第 3 轮 | 913 项／84 套通过，37.681 秒 |
| Release | 构建通过，101.55 秒，无编译警告 |
| Git 检查 | `git diff --check` 通过 |

日志：`/tmp/artflex-regression-baseline-20260908.log`、`/tmp/artflex-preview-before-fix-20260908.log`、`/tmp/artflex-preview-save-after-fix-20260908.log`、`/tmp/artflex-preview-save-full-{1,2,3}-20260908.log`、`/tmp/artflex-preview-save-release-20260908.log`。临时日志可能被系统清理，上表保留结果。

## 直接界面验收

通过 Computer Use 在安装后的 ArtFlex 窗口操作。测试工程为 `/Users/victorcloux/Downloads/ArtFlex-调色保存回归验收-20260908.artflex`，800×800，灰色图层加白色背景。

- 矩形选区选左侧，亮度拖到约 +64%，只有左侧变亮。
- 保留调色参数改选右侧，再改选下方，预览跟随最新选区，旧区域恢复底色。
- 亮度连续向负值、正值拖动，最终正值效果正确，没有残留前一个区域。
- 切换画笔出现未确认调整提示；“取消”保留调色状态，“放弃”恢复灰底并切换工具。
- 重新选右侧并确认效果，图层缩略图更新；一次撤销恢复灰底，一次重做恢复右侧亮块。
- 保存后界面显示“已保存”；通过文件窗口重开，右侧亮块与两个图层完整保留，调色参数已归零。

现有语义的边界：矩形选区工具下 Escape 是取消选区，未确认的调色随之变为整层预览，并不等于放弃调色。本轮实际通过切换工具的“放弃”完成取消验收，没有把 Escape 误记成成功取消。这个范围切换的提示值得后续单独改善，本批未擅改快捷键。

界面测试不能精确安排 GPU 回调时序；该部分由确定性回归覆盖。三轮全量通过不能证明所有硬件及长时间负载下绝无问题。

## 安装、数据保护与回退

- 当前安装 `.build/ArtFlex.app`，版本 `20260908.18`，与 Release 的 UUID 都是 `88500075-9281-3619-87E2-2842D8AA1F0D`；代码签名验证通过。安装时正常退出，不强杀进程。
- 备份目录 `/Users/victorcloux/Downloads/ArtFlex-调色保存回归备份-20260908-PK9RZC/`，保留保存前、保存后原工程及 `ArtFlex-20260908.17.zip`。
- 开始时原工程有未保存内容，已先备份磁盘版本，再通过原生保存按钮保存用户当前状态。保存前哈希 `4f2e9e92fa344c6973b6e8f985d90b126907aa97876af538956b1617f6f0ea32`；保护性保存后哈希 `9adc181792cfb3e741a9f89c3276212d8e2dceaaa64210402859dfd7ac5b594c`。
- 后续绘画与调色仅操作独立测试文件。原工程保护性保存后的哈希未变；验收结束后已在界面重新打开原工程 `ArtFlex-体块参考验收-20260906`，体块参考内容可见，保存状态正常。
- 开发分支 `codex/preview-save-regression-stability`，基线 `e21cf7d`。本批独立提交可撤销，不应对整个仓库做硬重置。

## 用户手测清单与下一批

1. 在有底色的图层上建立选区，调亮后更换选区，确认效果只在最新区域出现。
2. 快速往返拖亮度，确认最终画面符合最后的滑块位置。
3. 未确认时切换工具，分别检查“取消”保留预览、“放弃”还原底色。
4. 确认效果后撤销／重做；保存并重开，检查像素及图层保留。

本批到此停止。原定下一批建议为磁盘辅助撤销：先明确内存与磁盘预算、回读失败时保留可用历史，再做一个完整可验收模块；需要用户再次确认才开始。
