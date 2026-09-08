# 文件操作稳定性：实现与验收记录

状态：构建号 20260908.13 已部署；核心保存、打开、新建和退出路径已通过真实界面验证，剩余资源文件入口及最终恢复原工程尚待完成。不能将本批标为全部验收完成。

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

- 分支：`codex/painting-reliability-and-workflow`。
- 用户授权后已将前几批已验收的代码整理为本地基线提交 `7d80625`，未推送。
- 本批改动暂未提交，仍等待界面验收，不得称为已发布。
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
- [ ] 新建保存位置取消、Cmd+W 保存完成分支的单独界面验证。
- [ ] 图案文件/文件夹选择；画笔库导出与导入取消；录像位置选择；窗口全部关闭后再绘画。
- [ ] 本轮没有实际批量添加笔尖/Krita 素材，也没有在用户库上执行追加/替换导入；这些破坏性资源变更不冒充已通过界面验收。
- [ ] 测试完重新打开用户原工程或保存的当前修改版本，保证只有一个正式应用进程。

当前界面阻塞：打开系统“文件”菜单后，Computer Use 的 Escape、菜单 Cancel 均未能执行，截图再次不可用。重建控制会话也未恢复。进程 CPU 为 0%，1 秒采样主线程全部在 AppKit 正常输入事件循环等待，无忙等或保存线程卡住的证据。已询问用户是否再次锁屏；没有强制退出。当前仅测试工程 01 的参考图导入尚未保存，用户两体块画稿已安全保存在原路径和备份目录。

## 限制

- 文件窗口异步化不等于所有图片解码、目录枚举、画笔库编码都已移出主线程，这些数据处理路径仍有后续优化空间。
- 自动恢复或录像写入进行中，文档切换会保留当前文档并提示稍后重试；普通手动保存保留已有的排队处理，没有新增所有任务的统一队列。
- 色彩/曲线调整的独立确认提示仍有同步 NSAlert，本批没有改其编辑会话语义。
- 没有做真实磁盘写满、断电或 GPU 故障测试。受控写入失败的代码测试不能替代上述情景。
- 新的关闭/退出和嵌套窗口行为必须完成 Computer Use 验收，后台测试通过不能作为发布结论。
