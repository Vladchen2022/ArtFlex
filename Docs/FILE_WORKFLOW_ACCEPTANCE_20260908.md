# 文件操作稳定性：实现与验收记录

状态：2026-09-08 已在构建号 20260908.14 上完成本批文件窗口与文档切换的剩余界面验收，并恢复用户原工程。本批不包含真实资源库替换/批量导入、长时间压力测试和磁盘故障注入，不能据此宣称整个存储系统已充分验收。

## 范围与决策

本批仅处理工程保存、打开、新建、退出的状态衔接及剩余系统文件选择入口。不开始面板布局、磁盘撤销、稀疏图层、增量恢复等后续批次。

- 复用 `FilePanelService` 的异步附属文件窗口、现有冻结纹理快照、后台工程编码和原子写入。没有引入依赖或更改工程文件格式。
- 文件面板只允许一个未完成请求，回调仅执行一次，结束时先移除面板，再执行后续动作；嵌套编辑器中的选择窗口附着到当前最上层 sheet。
- 采用 AppKit 延后退出回调，在用户选择保存时等待写入完成；取消、失败和保存后又有新修改均不允许继续破坏性文档切换。
- 文件选择结果绑定文档代次，防止旧请求影响新工程；工程读取期间若产生新修改，保留当前文档。
- 保存成功后才更新当前工程名称和路径。打开文件不更新 Finder 图标；保存时仅生成最长边 256 像素的图标。
- 实际编辑修订号与自动恢复调度编号分离。补充回归测试先复现了“切换应用重新调度恢复后，未修改的保存被误判为有新修改”的问题，再调整判断来源；不能用调度次数代替内容变化。
- 主应用重新激活时只接管主窗口代理，不覆盖系统文件面板及编辑器 sheet 的代理。

官方资料已实际查阅：

- [NSSavePanel.beginSheetModal](https://developer.apple.com/documentation/appkit/nssavepanel/beginsheetmodal(for:completionhandler:))：完成回调可能发生在面板仍可见时，先 `orderOut` 再进行后续展示。
- [NSApplication.reply(toApplicationShouldTerminate:)](https://developer.apple.com/documentation/appkit/nsapplication/reply(toapplicationshouldterminate:))：返回 terminateLater 后必须回复最终退出决定。
- [ImageIO 缩略图 API](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex(_:_:_:))：使用 ImageIO 限制解码后的缩略图尺寸。

## 回退与数据保护

- 实现时分支：`codex/painting-reliability-and-workflow`；验收收尾分支：`codex/file-workflow-acceptance-finish`。
- 用户授权后已将前几批已验收的代码整理为本地基线提交 `7d80625`，未推送。
- 本批实现已在后续导航修复前提交为独立检查点 `f931c5b`。验收收尾基线为 `2173812`，只更新本记录，没有修改应用代码或重新替换应用。
- 备份目录：`/Users/victorcloux/Downloads/ArtFlex-文件稳定性改进前备份-e3Gp1U`。
- 目录包含原工程（保存当前修改前）、ArtFlex 资源与恢复目录、旧应用 20260908.12 的 ZIP 副本。
- 磁盘原工程与备份 SHA-256 均为 `5cf5220bd7735f0cdab06e9d00f88424f639d756213a135161af6528c39bd002`。
- 9 月 8 日用户恢复界面权限后，已通过 Cmd+S 保存当前两体块画稿，界面显示“已保存”。随后追加备份 `当前两体块画稿-已保存-20260908.artflex`，它与原文件的 SHA-256 均为 `6ea802e145adfd6a2e6b8d3d6c53eb7efab0be7e5b257b596da53f2322844f1d`。正常退出旧程序后才替换应用。
- 安装包与 Release 可执行文件 UUID 均为 `09D5DDAC-180D-3A25-9033-E5D638D91F56`。进程采样确认实际运行 20260908.13；没有启动第二份 ArtFlex。

## 修改文件

- `Platform/macOS/Services/FilePanelService.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/App/ArtFlexApp.swift`
- `Platform/macOS/UI/CompoundBrushBuilderSheet.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Platform/macOS/Distribution/Info.plist`
- `Tests/ArtFlexTests/FileWorkflowSafetyTests.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift`

## 开发验证

最终代码的全量 `swift test`：887 项、81 套通过，37.559 秒。包含本批 16 项文件工作流测试。修订号回归在修复前出现 2 个断言失败，修复后通过；失败日志保留用于说明复现过程。

最终 `swift build -c release` 成功，105.51 秒；`git diff --check` 通过。日志：

- `/tmp/artflex-file-workflow-tests.log`
- `/tmp/artflex-file-workflow-full-tests.log`
- `/tmp/artflex-file-workflow-release.log`
- `/tmp/artflex-save-revision-regression-before.log`

## 真实界面验收进度

使用独立目录 `/Users/victorcloux/Downloads/ArtFlex-文件界面验收-20260908-Vu74FZ`，不在用户画稿或资源库上做破坏测试。界面截图已在任务中逐项展示。

- [x] 首次保存取消后笔画与未保存标记保留；重试保存 `01-首次保存-单笔画.artflex` 并重开，斜线完整。
- [x] 打开其他文件前选“保存”，在位置窗口取消，当前未命名画稿未被替换。
- [x] 新建前选“保存”，写出 `02-新建前保存.artflex` 后才出现空白画布；重开斜线完整。另在 02 添加第二笔后打开 01，先保存才完成切换。
- [x] Cmd+Q 取消后画稿保留；重试选择保存，写出 `03-退出前保存.artflex` 后程序退出；重启并打开 03，横线完整。Cmd+W 的取消分支也正常。
- [x] 素材库第三层文件窗口中 Cmd+N、Cmd+Q 不穿透、不清空画稿，窗口仍可取消。首次保存窗口重复 Cmd+S 会执行系统默认保存，后续快捷键没有造成文档丢失。
- [x] 打开独立的 `invalid-project.artflex` 报文件损坏，01 画稿仍完整保留。
- [x] PNG 实际导出为 `ui-export.png`，界面报告 2048 × 2048；从参考图入口先取消，再重试实际导入，正确显示同一斜线。
- [x] 笔尖预处理实际读取 `ui-export.png` 并显示原图和遮罩，随后取消，不写入全局笔尖库。
- [x] 笔刷编辑器的 Krita 文件窗口打开与取消正常，编辑草稿保持不变。素材库第三层导入窗口取消、重试、再取消均返回正确层级；退出编辑器时取消测试草稿。
- [x] 新建前选择保存，再取消保存位置，返回新建设置；取消新建设置后，原测试笔画及未保存标记保留。
- [x] Cmd+W 选择保存，实际写出 `01-close-save.artflex` 后关闭。当前单窗口应用随最后窗口关闭退出；重新启动，重开测试工程，原斜线完整。继续绘制第二笔并 Cmd+S 保存成功。
- [x] 图案文件选择取消后可重试，实际加载 `pattern-file.png`，原图及导入后预览均显示正确，尺寸 2048 × 2048。
- [x] 图案文件夹选择取消后保留已选图片；重试选择 `pattern-folder`，其 `folder-image.png` 正确加入预览。取消整个导入草稿后，图案库仍为原来的 5 项。
- [x] 画笔库导出取消后可重试，实际导出 `01-close-save.brushes.json`，界面报告成功，文件约 9.1 MB。分别进入“导入并替换”和“导入并追加”后取消，画笔库仍为 19 项，工程仍显示已保存。
- [x] 录像目录选择取消后，保留 `/Users/victorcloux/Downloads/ArtFlex-录像验收-20260908`，状态仍为未录制；重试并确认同一目录，界面报告设置成功，没有启动录制。
- [x] 测试完重新打开用户原工程 `ArtFlex-体块参考验收-20260906.artflex`，两体块完整，显示已保存；只有一个正式应用进程。

此前 Computer Use 的菜单/截图阻塞已经解除，不再是当前阻塞。收尾过程中出现过自动化元素失效、键盘输入早于路径窗口出现的问题；通过刷新可访问性状态、分步输入及文件图标的“打开”动作完成验证。这些自动化失败没有当作应用保存/导入成功，也没有修改应用来绕过它们。

## 2026-09-08 收尾证据

- 本轮使用独立目录 `/Users/victorcloux/Downloads/ArtFlex-文件入口收尾-20260908-qxEWHO`。其中保留原画稿备份、两笔测试工程、导出的画笔库和两张测试素材；没有在用户画稿上绘制验收笔画。
- 测试前及恢复后，原工程和本轮备份的 SHA-256 均为 `6ea802e145adfd6a2e6b8d3d6c53eb7efab0be7e5b257b596da53f2322844f1d`。
- 界面截图已在任务中展示：新建取消后的笔画、关闭保存后重开的笔画、继续绘制第二笔、单文件和文件夹预览、最终恢复的两体块工程。
- 界面测试完成后补跑 `swift test --filter FileWorkflowSafetyTests`，16 项 / 1 套全部通过，2.934 秒。没有把前一轮全量测试数字冒充本轮重新运行。
- 没有发现本批待验收路径需要再次修改实现的问题；保留已安装的 `20260908.14`，不做无必要的重建或安装。
- 本轮结束后停止；下一批建议是右侧面板空间适配，须用户明确要求开始后再实施。

## 限制

- 文件窗口异步化不等于所有图片解码、目录枚举、画笔库编码都已移出主线程，这些数据处理路径仍有后续优化空间。
- 自动恢复或录像写入进行中，文档切换会保留当前文档并提示稍后重试；普通手动保存保留已有的排队处理，没有新增所有任务的统一队列。
- 色彩/曲线调整的独立确认提示仍有同步 NSAlert，本批没有改其编辑会话语义。
- 本轮实际图案读取止于预览后取消，没有批量添加笔尖/Krita 素材，也没有向用户画笔库提交追加/替换；资源写入语义仍需在隔离资源库中独立验收。
- 没有做真实磁盘写满、断电或 GPU 故障测试。受控写入失败的代码测试不能替代上述情景。
- 当前通过的是上面列出的关闭/退出、嵌套窗口和选择/取消路径；不扩大成所有资源格式、任意规模与长期使用均已验证的结论。
