# ArtFlex Handoff

最后更新：2026-05-23

## 1. 先记住这四句话

1. 当前仓库已经不是第一阶段 MVP，也不是“旧 dual-tip 回退基线”。
2. 当前最值得关注的产品主线是组合笔刷参数语义、颜色工作流，以及局部交互一致性。
3. 当前不要再默认假设仓库挂着一批历史性 dirty 性能 patch；接手前先看 `git status` 再判断。
4. `~/Library/Application Support/ArtFlex/brush-library.json` 是用户真实画笔库，测试不能写这里。

## 2. 推荐阅读顺序

1. [CURRENT_STATUS.md](CURRENT_STATUS.md)
2. [DECISIONS.md](DECISIONS.md)
3. [Docs/reference/REPO_MAP.md](Docs/reference/REPO_MAP.md)
4. [Docs/reference/COLOR_PIXEL_SPEC.md](Docs/reference/COLOR_PIXEL_SPEC.md)
5. [Docs/reference/COLOR_ADJUSTMENT_STATUS.md](Docs/reference/COLOR_ADJUSTMENT_STATUS.md)
6. [Docs/reference/PRESSURE_CURVE_STATUS.md](Docs/reference/PRESSURE_CURVE_STATUS.md)
7. [Docs/reference/TEXTURE_FILL_STATUS.md](Docs/reference/TEXTURE_FILL_STATUS.md)

如果任务和组合笔刷直接相关，再看：

- [Core/Tools/ToolKind.swift](Core/Tools/ToolKind.swift)
- [Platform/macOS/App/WorkspaceViewModel.swift](Platform/macOS/App/WorkspaceViewModel.swift)
- [Platform/macOS/UI/CompoundBrushBuilderSheet.swift](Platform/macOS/UI/CompoundBrushBuilderSheet.swift)
- [Rendering/Canvas/StageOneBrushRenderer.swift](Rendering/Canvas/StageOneBrushRenderer.swift)

## 3. 当前最重要的结论

### 3.1 组合笔刷已经接回主工程

不要再按“旧 dual-tip flat 字段 + 回退 patch”理解当前状态。

当前真实路径是：

- 数据：`CompoundBrushSettings`
- 接线：`WorkspaceViewModel`
- UI：`CompoundBrushBuilderSheet`
- runtime：`StageOneBrushRenderer` 的 compound 分支

### 3.2 当前默认不要再重查 plumbing

如果没有新的硬证据，当前不应优先怀疑：

- sample builder
- tip sampling
- 主 / 次 tip 资源接线
- actual canvas vs replay 的基础 plumbing
- display / composite / export 主链

当前主要问题仍在主层外观表达，而不是底层接线重新失效。

### 3.3 项目范围已经明显扩大

不要再把项目理解成“只有画布 + 图层 + 画笔”的基础原型。

当前正式主链还包括：

- 参考图与 LAB 黑白参考
- 画笔库与 tip image library
- 快照对比
- ideation 分支工作流
- timelapse 录制 / 导出
- 线性渐变 / 扇形渐变

另外当前应用图标不要按 Xcode asset catalog 方案去找。

当前真实路径是：

- 资源文件：`Platform/macOS/Resources/AppIcon.png`
- 运行时设置：`ArtFlexApp.applyApplicationIconIfAvailable()`
- 最近一次更新是替换内部 artwork，同时保留现有图标的整体大小与圆角轮廓

也就是说，当前主工程还没有单独维护 `.appiconset` / `.icns` 主链；如果后续只是在调图标外观，默认先继续修这张 PNG 资源。

### 3.4 右侧画笔参数区已经有“主笔尖参数 / 整体画笔参数”分层

当前右侧参数区不要再全部按“主笔尖参数”理解。

更接近真实状态的是：

- 结构类：`间距 / 散布 / 旋转 / 抖动`
  - 当前仍偏主笔尖 / 主体结构
- 整体表现类：`杂色 / 杂色对比 / 大小压感 / 透明压感 / 透明修正`
  - 普通笔刷时作用于当前笔刷
  - 组合笔刷时作用于整支组合笔刷，而不是只等于主笔尖内部参数

另外需要记住：

- `大小压感 / 透明压感` 当前已经升级成真实曲线编辑器，不再是旧的“三滑块示意曲线”阶段
- 实际出笔、右侧预览和 HUD 预览已经统一使用真实曲线状态
- 压感弹窗顶部预设条当前已经恢复可见，这条线不要再按“预设区看不见”的旧问题接手

继续接手这块时，先读：

- [Docs/reference/PRESSURE_CURVE_STATUS.md](Docs/reference/PRESSURE_CURVE_STATUS.md)

### 3.4A 画笔库当前有“最近使用首行 vs 正式快捷槽位”分层

当前不要把画笔库第一排“最近使用”和第二排 `1/2/3/4` 快捷槽位混为一谈。

当前真实语义是：

- 第一排是最近使用首行
- 但它只记录第三排及之后的正式库画笔
- 第二排 `1/2/3/4` 快捷槽位不进入最近使用首行
- `Shift+Z` HUD 里的 4 个快捷笔刷仍然绑定第二排 `1/2/3/4`
- 软件启动默认使用的也是第二排第一个正式画笔（`slot 0`），不是最近使用首行

后续线程如果继续动画笔库，默认不要改坏这层区分。

### 3.4B 画笔库持久化和测试隔离是当前硬约束

当前真实持久化文件是：

- `~/Library/Application Support/ArtFlex/brush-library.json`

当前 archive 保存的不只是 preset 列表，还包括：

- `library`
- `tipImageLibrary`
- `tipImageAssets`

本机这次已经发生过一次测试 fixture 污染真实画笔库的问题。当前修正后的状态是：

- `BrushLibraryPersistenceController` 支持 `rootDirectoryURL`
- `AppBootstrap` 在 XCTest 环境下会把画笔库 / 图案库根目录默认指向临时目录
- `BrushLibraryStateTests` 通过后，真实用户文件仍保持 `13` 个 preset、`53` 个 tip image library item、`53` 个 tip image asset
- 被污染的旧文件保留为 `~/Library/Application Support/ArtFlex/brush-library.json.corrupted-test-fixture-20260523_104544`
- 可用备份文件是 `~/Library/Application Support/ArtFlex/brush-library.json.sb-76b8f964-AfHU39`

后续线程如果继续改画笔库，先确认测试不会写真实用户目录。

### 3.5 颜色面板拾色器和 HUD 快速拾色器不能分开改

当前颜色工作流里，`Shift+Z` HUD 拾色器和右侧颜色面板拾色器必须一起理解。

后续若继续修改这块，必须同步考虑：

- 色立方显示
- 点选实际取色结果
- 当前颜色反推拾色器位置
- `光色 / 明度 / 纯度` 滑块语义

不要只修其中一层。

另外，当前 `Shift+Z` HUD 里还挂着一条已经接通并收口过的“最近笔触调整组”：

- 只作用于 `brush`
- 默认就是最近 `1` 笔，可回溯到最近 `20` 笔
- 当前支持：
  - 透明度
  - 明度
  - 饱和度
- `最近` 滑块当前是反向语义：
  - 最右是 `1`
  - 往左退回更多笔
- 这组最近笔触不是新图层，而是隐藏可调后缀
- 一旦离开画笔语境，会先无感固化到当前图层再继续后续操作
- 当前已经明确接通的自动固化边界包括：
  - 切工具
  - 切活动图层
  - 开始下一笔新的正常绘画
  - 进入统一 `flushBrushEditingBoundary(...)` 的其他像素编辑边界

后续线程默认不要把它误改成：

- 全局所有工具共享的“最近 20 步系统”
- 需要用户显式确认才能落像素的悬挂状态
- 独立于 HUD / 快速拾色器语义之外的另一套面板

### 3.6 色彩调整已经不再是阶段 A-only

当前不要再把 `色彩调整` 理解成“只有蓝色蒙版绘制 demo”。

当前真实状态是：

- `painted mask`、`selection`、`wholeLayer` 三条 source 都已经接通
- 右侧参数面板、参数预览、`确认应用`、`恢复默认`、`按住预览` 都已接通
- 正式写回和对应 undo / redo 已接通
- 切工具 / 切图层 / 打开新文档 / 关闭 / history navigation 前的确认弹窗已接通
- `undo / redo` 现在会在弹窗处理后自动继续原 history navigation
- `selection / wholeLayer` session 会根据当前上下文自动重建
- whole-layer `effectBounds` 已接入 preview / commit 的局部 redraw
- `brightnessAdjust` 主要承担 painted-mask 路径；选区 / 整层直调可以直接从参数面板创建 session
- 这几项最近一轮已经过针对性测试，当前可以阶段性暂停，不需要继续把它当成紧急未闭环工作

继续接手这块时，先读：

- [Docs/reference/COLOR_ADJUSTMENT_STATUS.md](Docs/reference/COLOR_ADJUSTMENT_STATUS.md)

### 3.7 纹理填充当前以 `phase 4.3 + imported mapped live/final + final cover` 为 accepted 基线

当前 `textureFill` 已经是一条正式活动线，不要再把它理解成“未开始的试验工具”。

当前更准确的状态是：

- 程序化模式已经跑通到可用基线
- 最终定稿链已经推进到 `phase 4.3`
- imported 模式已经接通共享 `tipImageLibrary`
- imported live 已经切到区域映射，并优先复用 smooth final shape
- imported final field 当前已修到 `cover`，最终区域不会再留白

当前接手时要先记住：

1. 当前 accepted 基线是：
   - `phase 4.3 + imported mapped live/final + final cover`
2. 当前 imported 模式不要再按旧 mismatch 理解：
   - 拖动中：区域映射 live field
   - 松手后：区域纹理映射 final field
3. 当前程序化模式的 live 多边形感与残余轻微延迟，已经比 imported mismatch 更值得关注

当前不要再重复这些失败路线：

- 只靠 `densify` 修 live 边缘
- 首段 cap + 长段 densify
- 把开放路径平滑直接塞进 live 切片链

如果后续继续做 `textureFill`，当前更合理的下一步是：

- 观察程序化模式的 live 多边形感是否值得继续收口
- 在有实际体感问题时再继续压 imported / 整体 live 延迟

专项状态文档先读：

- [Docs/reference/TEXTURE_FILL_STATUS.md](Docs/reference/TEXTURE_FILL_STATUS.md)

## 4. 当前 working tree 状态

当前不要再沿用旧文档里“仓库默认 dirty，且主要是性能 patch”的说法。

接手前建议先执行：

```bash
git status --short
git diff --stat   # 仅在 dirty 时再看
```

截至 2026-05-23，代码侧已知未提交改动是：

- `Core/Selection/TextureFillProceduralField.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Platform/macOS/App/AppBootstrap.swift`
- `Platform/macOS/Services/BrushLibraryPersistenceController.swift`

其中 `AppBootstrap` 和 `BrushLibraryPersistenceController` 是画笔库测试隔离修正。

## 5. 关键入口文件

### 5.1 应用壳与状态中心

- `Platform/macOS/App/ArtFlexApp.swift`
- `Platform/macOS/App/AppBootstrap.swift`
- `Platform/macOS/UI/MainWindowView.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Core/Application/WorkspaceStore.swift`

### 5.2 画布与渲染主链

- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Rendering/Canvas/StageOneCanvasPresenter.swift`
- `Rendering/Canvas/StageOneLayerSurfaceStore.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`
- `Rendering/Canvas/MetalStrokeEngine.swift`
- `Rendering/Canvas/SmudgeEngine.swift`
- `Rendering/Canvas/BucketFillEngine.swift`
- `Rendering/Canvas/EyedropperSampler.swift`

### 5.3 文件 / 导出 / 历史

- `Core/Application/HistoryController.swift`
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
- `Infrastructure/FileFormat/ProjectPackage.swift`
- `Infrastructure/FileFormat/PNGExporter.swift`
- `Core/Application/PersistenceController.swift`

### 5.4 颜色 / 参考图

- `Core/Color/ColorPanelState.swift`
- `Core/Color/QuickColorPickerState.swift`
- `Rendering/Canvas/LABLuminosityPostProcessor.swift`
- `Platform/macOS/UI/ReferenceImagePanelSupport.swift`

## 6. 常用验证

```bash
swift build
swift test --filter WorkspaceViewModelSafetyTests
swift test --filter BrushStrokeSamplingTests
swift test --filter HistoryControllerTests
swift test --filter StageOneBrushPreviewRasterizerTests
swift test --filter BrushLibraryStateTests
```

## 7. 不要被这些旧叙事带偏

- 不要再寻找已经删除的阶段计划 / MVP / Stage1 文档，它们已从仓库移除，历史内容请直接查 git。
- 不要默认把当前项目理解成“只有组合笔刷”或“只有性能优化”；现在它已经是多工作流并行的主工程。
- 不要无计划发起 `WorkspaceViewModel` / `RightInspectorView` 的整文件重构，除非任务本身就是明确拆分某个子系统。
