# 第一批稳定性修正 · 2026-09-05

## 范围与实现决策

本批处理自动恢复时序、资源库读写保护，以及色彩/曲线调整提交和复杂图层合成的失败路径。
不更改笔刷出墨算法、笔刷预设、已验收的真实笔触缩略图、主界面布局或工程格式。
后续性能测量及优化不在本批完成范围内。

复用现有恢复工程 staging/轮换机制、图层撤销快照、独立 Metal 结果纹理和合成纹理池。
资源库保护共用一个小型 `ProtectedLibraryFile`，使用 Foundation 原子写入和 NSLock，
保留上一个经过解码验证的 JSON；不新增依赖或自建文件系统。

## 修改内容及文件

### 自动恢复

- `Platform/macOS/App/WorkspaceViewModel.swift`
  - 将“有新编辑”与“旧捕获已经失效”分开计数。
  - 写盘期间继续绘画，允许安装已经完整写出的恢复点，再追赶较新的编辑。
  - 手动保存、放弃恢复、新建/打开替换文档，会使旧的在途捕获失效。
  - 最大延迟到期后的重试期限，不再被每个新笔画反复推迟。
  - 写盘/准备失败显示错误并重试，不删除原有恢复副本。
- `Tests/ArtFlexTests/SavedSnapshotSessionTests.swift`
  - 精确插入“捕获已写完、安装前又编辑/放弃/换文档”的测试。

### 资源库

- `Infrastructure/FileFormat/ProtectedLibraryFile.swift`
- `Platform/macOS/Services/BrushLibraryPersistenceController.swift`
- `Platform/macOS/Services/PatternLibraryPersistenceController.swift`
- `Platform/macOS/Services/TextureFillLibraryPersistenceController.swift`
- `Platform/macOS/Services/BlockReferenceModuleLibraryPersistenceController.swift`
  - 文件不存在仍是正常首次运行；读取/解码失败不再等价于空库。
  - 读取失败后阻止自动覆盖，并在启动状态栏报告。
  - 写入前再次验证磁盘旧文件，旧内容先原子保存到 `.json.previous`。
  - 备份失败时不替换正式库；相同内容重复保存不消耗上一代备份。
  - 图案孤立文件清理同时保留上一代库引用的素材，避免只留下不可用的 JSON。
  - 修复文件后，成功重新加载会解除保护。没有自动用备份覆盖用户原文件。
- `Tests/ArtFlexTests/LibraryFileProtectionTests.swift`
  - 损坏文件、文件被移走、备份目标不可写、旧格式、重复保存、修复后重载、图案素材保留。

### 调整提交与图层合成

- `Platform/macOS/App/WorkspaceViewModel+ColorAdjustment.swift`
- `Platform/macOS/App/WorkspaceViewModel+CurveAdjustment.swift`
  - 先渲染独立结果，确认 GPU 完成并成功捕获撤销后，才替换原图层纹理。
  - 任一步失败时保留原像素和调整会话。
- `Rendering/Canvas/ColorAdjustmentRenderer.swift`
- `Rendering/Canvas/CurveAdjustmentRenderer.swift`
  - 编码器准备失败返回结果，正式提交可以中止，避免把部分结果当作完成。
- `Rendering/Canvas/StageOneCanvasPresenter.swift`
  - 复杂混合/蒙版合成纹理分配失败时，不再降级为普通混合。
  - 不再在中间编码失败后跳过该图层继续生成不完整图像。
  - 在途纹理通过完成回调释放。
- `Core/Application/LayerMergeController.swift`
- `Rendering/Canvas/TransformGPUCompositor.swift`
- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Platform/macOS/UI/CanvasContainerView.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
  - 调用方检查合成是否准备成功；失败的离屏命令提交后释放资源，但不呈现/安装错误输出。
  - 主画布保留上一帧并报告错误，合并/导出相关操作中止。
- `Core/Application/HistoryController.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Tests/ArtFlexTests/LayerMergeControllerTests.swift`
  - DEBUG 专用故障注入：撤销捕获失败和合成资源分配失败。
  - 核对失败时像素逐字节不变、会话可重试、正常提交后的撤销完全还原。
- `Platform/macOS/Distribution/Info.plist`：构建 `20260905.4`。

## 验证

回归选择 `Library|SavedSnapshot|ProjectPersistence|PersistenceSave|LayerMerge|WorkspaceViewModelPixelHistory|HistoryController|Brush|Curve|ColorStandard`
共 **366 项测试、37 个套件通过**，不是整个测试套件。
日志 `/tmp/artflex-stability-regression-final.log`。

`swift build -c release` 完成，安装包通过 `codesign --verify --deep --strict`。
日志 `/tmp/artflex-stability-release.log`。
安装的二进制 UUID `DCABEC19-8B6C-37DC-85EC-B6910BE102B3`。

Computer Use 在真实发布构建的独立 1024×1024 工程检查：

- 新建、实际画笔输入、撤销到空白、重做。
- 框选红色笔触，色彩调整亮度 +66%，确认预览和提交，撤销回原色。
- 曲线中点提亮，确认预览和提交，撤销回原色。
- 保存并从文件面板重新打开，确认黑色与红色笔触完整。
- 测试工程 `/Users/victorcloux/Downloads/ArtFlex-稳定性界面测试-20260905.artflex`。
- 重开后增加第三条笔触，不执行手动保存；等待恢复副本写出，从顶部“恢复自动保存”打开，
  确认三条笔触完整。另存为 `/Users/victorcloux/Downloads/ArtFlex-稳定性自动恢复验证-20260905.artflex`。
- 最后重新打开用户原画稿，屏幕上的三条原始红色笔触和“已保存”状态均正常。

## 数据安全与回退

分支 `codex/stability-safety-pass`，修改前基线 `b350a53`。
整个批次共用错误返回调用链，作为可构建的原子变更提交，避免回退后调用方与返回语义不一致。

替换程序前已正常退出已保存的旧版，备份目录：
`/Users/victorcloux/Downloads/ArtFlex-稳定性优化前备份-rtylF0`

目录包含旧版 `ArtFlex-build-20260905.3.zip`、完整 ArtFlex Application Support 副本与原画稿。
原画稿 `ArtFlex-叠加蒙版-屏幕对照-20260905.artflex` 未用于测试落笔。
升级前原画稿 SHA-256：`c4ed94a881e3221ab85ad695dfa7a595a6743bcd46ad148cb4d5dc4df5940975`。
升级前画笔库 SHA-256：`ffc3d68a1659636a4d47c50ed1985e35c1f47b19ffd2450aeaf9396c27d80635`。
全部界面测试结束后，再次核对原画稿和画笔库，两个校验值均未改变。

## 限制

- 本批减少已确认的丢失/覆盖路径，不能保证断电、磁盘损坏或所有 GPU 错误下零损失。
- 自动恢复仍在现有安全边界捕获；持续未结束的绘画/变形/调整不能强行中途截断。
- 资源库保护是进程内的读写保护，尚不是跨进程的文件协调器；上一代备份也不是永久版本档案。
- 合成保护重点覆盖资源分配和编码准备失败；未全面重构每一种编辑操作的 GPU 提交事务。
- 没有声称帧率、输入延迟或内存峰值改善。下一批应先测量，再决定缓存/局部更新等性能修改。
