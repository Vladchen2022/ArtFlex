# 像素编辑提交安全改进 · 2026-10-02

## 决策与范围

本批修复纹理填充和共用选区像素操作的失败提交问题。旧路径忽略部分历史检查点或渲染失败，可能继续修改图层、清除重做记录，或者显示成功。

复用仓库的 `StageOneLayerSurfaceStore.copyTextures`、`swapTexture`、资源预算检查和 `HistoryController`。渲染结果先保存在临时 Metal 纹理中，确认编码、GPU 执行和历史捕获均成功后，再发布到图层。没有增加依赖或另建事务框架。

Metal 命令采用现有同步执行方式，并检查最终状态。本批没有把主线程等待改成异步；异步化需要另外处理文档切换、编辑版本和资源生命周期。

参考 Apple 官方接口：[waitUntilCompleted](https://developer.apple.com/documentation/metal/mtlcommandbuffer/waituntilcompleted%28%29)、[addCompletedHandler](https://developer.apple.com/documentation/metal/mtlcommandbuffer/addcompletedhandler%28_%3A%29)。等待结束本身不能替代成功状态检查。

## 实现

1. 像素编辑开始前，确认已有笔触和直线提交已结束；尚未提交成功时保留输入并中止新操作。
2. 纹理填充先生成完整临时结果，再捕获历史、替换图层纹理；拒绝实际覆盖率全为零的区域。
3. 选区填充、擦除等共用像素操作只读原图层，在临时纹理执行。原图层同时供透明像素锁定采样使用。
4. 两个渲染器返回编码是否成功；调用方检查编码结果和 GPU 完成状态。失败不发布本次像素修改，不追加历史或清除原有重做。
5. 成功发布后更新变更区域、缩略图和文档状态。沿用原有颜色规范、着色器、文件格式和 UI。

“失败不改变画布”针对本次像素操作；操作开始前正常提交的已有笔触仍保留。

## 修改文件

| 文件 | 用途 |
| --- | --- |
| `Platform/macOS/App/WorkspaceViewModel.swift` | 准备、验证、捕获历史、发布的顺序及失败处理 |
| `Rendering/Canvas/SelectionFillRenderer.swift` | 显式返回编码结果 |
| `Rendering/Canvas/SelectionPixelOperationRenderer.swift` | 显式返回编码结果 |
| `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift` | 失败注入、共享纹理、历史、变更日志及精确撤销重做测试 |
| `Platform/macOS/Distribution/Info.plist` | 构建号更新为 `20261002.27` |
| `Docs/EDIT_COMMIT_SAFETY_20261002.md` | 本批决策、验证和回退记录 |

任务开始前已经存在的 `HANDOFF.md` 修改保持原样，不纳入本批提交。

## 验证结果

| 验证 | 结果 |
| --- | --- |
| 修复前新增用例复现 | 失败，确认历史捕获失败后仍修改像素、纹理填充错误成功等问题 |
| 像素历史及高精度定向测试 | 95 项、2 个套件通过，3.093 秒 |
| 默认完整测试集 | 975 项、95 个套件通过，39.145 秒，退出码 0 |
| Release 构建 | 通过，108.41 秒，退出码 0 |
| `git diff --check` | 通过 |
| App 签名检查 | `codesign --verify --deep --strict` 通过 |

新增测试覆盖 8 位与 16 位路径，以及准备失败、编码失败、完成结果拒绝、历史捕获失败。检查像素、图层纹理身份、共享分支、变更日志、脏状态和重做记录；成功操作只增加一次历史，撤销与重做精确恢复像素。GPU 失败分支通过 DEBUG 注入模拟，未人为制造驱动故障。

本机日志：`/tmp/artflex-edit-safety-before.log`、`/tmp/artflex-edit-safety-focused3.log`、`/tmp/artflex-edit-safety-regression.log`、`/tmp/artflex-edit-safety-release.log`。临时日志可能被系统清理。

已在 Release 应用中进行界面验收：

- 新建 2048 × 2048 的 16 位浮点画布，矩形选区填充为黑色，擦除恢复白色，撤销和重做正常。
- 撤销擦除后，用直线手势制造零面积纹理填充，提示未完成；原有擦除操作仍可重做。
- 恢复黑色矩形并保存为 `~/Downloads/ArtFlex-编辑安全验收-20261002.artflex`，重新打开后矩形保留，状态为已保存。
- 验收结束后重新打开原画稿，原画笔 7、大小 132 已恢复，状态为已保存。

本批未进行实体数位笔手测、长时间压力测试或强制内存耗尽测试；界面验收没有覆盖正常闭合曲线纹理填充，该路径由自动化 Metal 测试覆盖。

## Git 与应用回退

- 改进前提交：`ef9c0157397cb4d555d3145eabccb49c315175cd`。
- 改进前标签：`backup/pre-edit-commit-safety-20261002`。
- 工作分支：`codex/edit-commit-safety`。
- 本批提交标题：`Make texture and selection edits commit only after success`。
- 需要撤回时，对本批提交执行 `git revert <提交哈希>`，保留后续历史；不要用硬重置清除工作区。
- 代码回退不自动替换正在运行的应用。应先保存画稿并正常退出，再重新构建或恢复备份应用。

备份目录：`/Users/victorcloux/Downloads/ArtFlex-改进前备份-20261002-588f0a49`。

目录中包含完整历史的 `ArtFlex-before.bundle`（已验证）、原有 `HANDOFF-existing.patch`、旧应用 `ArtFlex-20260909.26.zip` 和原画稿副本。

原先未命名画稿已通过应用正常保存为 `/Users/victorcloux/Downloads/ArtFlex-改进前画稿-20261002.artflex`，验收前后 SHA-256 相同：`09ef64c530544642e70d5f5022b306437b4e1520f86a8a479c616dd12622aa44`。

当前应用：`.build/ArtFlex.app`，构建号 `20261002.27`，arm64 UUID `F826C178-4624-3C43-AF94-37BEB75E4211`。

## 代价与后续

普通未锁定透明像素的选区操作新增一张整层临时纹理，并纳入资源预算检查。4096 × 4096 的 RGBA16F 纹理原始数据约为 128 MiB，实际分配可能更高。新增 `applyPixelOperation.stagingCopy` 和 `stagingBytes` 审计指标，用于后续评估；本批不声称性能提升。

仍需分别审查套索颜色填充、油漆桶及其他编辑入口，不能由本批测试推断所有工具都具有相同的失败保护。

下一批可整理正式保存流程的协调职责，保留现有退出保存和编辑版本保护；主线程等待优化应以大工程测量为依据，分开提交。暂不进行全面分块重写或按文件行数机械拆分。

用户手测建议：在常用 8 位和 16 位工程中执行闭合纹理填充、选区填充与擦除、撤销重做，并观察大画布的操作延迟。如发现像素丢失、撤销跳步、失败后重做消失，或明显新增卡顿，应停止后续批次并先复现。
