# ArtFlex 工作交接

> 更新时间：2026-07-23
> 仓库：`/Users/victorcloux/Desktop/ArtFlex`
> 远端：`https://github.com/Vladchen2022/ArtFlex.git`
> 当前分支：`codex/brush-inspector-layer-split`
> 当前代码提交：`6994c74 feat: unify circular color pickers`

本文用于新的 Codex 对话快速接手。它记录当前事实、稳定约束、代码入口和已知风险；更高优先级的工程规则在根目录 `AGENTS.md`，接手时必须同时完整阅读。

## 1. 新线程先做这些

```bash
cd /Users/victorcloux/Desktop/ArtFlex
cat AGENTS.md
cat HANDOFF.md
git status -sb
git log --oneline --decorate -12
pgrep -fl '/ArtFlex.app/Contents/MacOS/ArtFlex' || true
```

然后再根据用户的新任务检查相关代码。不要仅凭本文件直接改实现；本文件是索引，不代替源码。

本文件写入前，代码工作树是干净的，当前分支与远端同名分支一致。若用户尚未提交这份交接文档，新线程里唯一预期的未提交变更应是 `HANDOFF.md`；任何其他变更都要先确认来源，不得覆盖。

## 2. 项目是什么

ArtFlex 是 macOS 绘画创作软件，是旧版 BrushCanvas 的 Metal-first 重构。目标不是复制旧 CPU 画布，而是保留已经验证过的桌面绘画工作流，同时重做渲染、图层、工具、文档、撤销和取样链路。

产品主结构已经确定：

- 顶部工具栏；
- 左侧竖向工具栏；
- 中央 Metal 画布；
- 右侧双列面板：参考图 / 颜色 / 资源库，以及笔尖 / 导航器 / 工具参数 / 图层；
- 体块参考工具进入专用 3D 工作区，但视觉语言尽量沿用常规右侧面板。

架构硬规则见 `AGENTS.md`，尤其不要破坏这些边界：

- 显示、编辑、取样和导出应共享标准化画布数据；
- 颜色格式、预乘 alpha、sRGB / linear 规则不能靠临时补偿维持；
- 不回到整图 CGContext 合成或巨型 CanvasState；
- 核心业务状态尽量不耦合 SwiftUI / AppKit；
- 先复用仓库现有实现和 Apple 官方 API，再考虑自建基础设施；
- 困难的交互、几何、坐标或渲染 bug 连续两次修补无效后，停止打补丁，进入 reference-first 调查。

## 3. 与用户协作的固定规则

这些不是偏好，是后续工作的执行约束：

1. 用户说“先讨论”“先出方案”“先别写代码”时，禁止改代码。
2. 非平凡修改前，先给简短决策摘要：
   - 仓库里能复用什么；
   - Apple / 标准方案是否可用；
   - 最终选择与取舍。
3. 大改必须可回退。开始前确认干净基线、当前分支和提交；不要覆盖用户未提交内容，不要使用 `git reset --hard` 或擅自回滚。
4. 完成任何会改变软件行为或界面的代码更新后，必须：
   - 跑与风险相称的自动测试；
   - Release 构建；
   - 替换 `.build/ArtFlex.app`；
   - 关闭全部旧版、预览版或重复实例；
   - 只打开一个最新应用。
5. 用户明确要求在软件界面上测试。不能只跑后台单元测试就声称交互可用；必须在前台实际操作关键路径，并如实说明覆盖了什么。
6. 重启应用前保护未保存画布。必要时先保存带时间戳恢复文件，重启后重新载入。
7. 不要自动提交或推送。只有用户明确要求时才执行 Git commit / push。
8. 截图反馈优先当成真实验收结果。若代码判断与截图冲突，先核对运行的是哪个应用进程和哪个构建，不要假设用户看错。
9. 用户要求中文、直接、基于证据。无法确认的内容明确写“未确认”，不要用高确定性语气包装推断。

## 4. 当前 Git、构建和运行状态

- 分支：`codex/brush-inspector-layer-split`
- HEAD：`6994c74`
- 跟踪：`origin/codex/brush-inspector-layer-split`
- 远端已包含 `6994c74`
- `main` 仍停在较早的 `4733514`；当前工作成果在功能分支上，禁止误切 `main` 后继续开发或强行重置。
- 当前本地应用：`/Users/victorcloux/Desktop/ArtFlex/.build/ArtFlex.app`
- 写本文时只有一个 ArtFlex 进程，路径指向上述应用包。
- 应用二进制时间：2026-07-19 21:32。

最近验证记录：

- 最近一次完整测试记录：604 项通过。该数字来自最近功能验收，不是本次纯文档任务重新运行的结果。
- 最近一次针对圆形 HUD 拾色器的定向测试：`QuickColorPickerHUDTests` 6 项通过。
- 最近一次相关更新已完成 Release 构建、签名、替换应用并单实例启动。

现存编译告警，不是本轮引入：

- `Rendering/Canvas/StageOneBrushRenderer.swift`：`@Sendable` 闭包捕获 completion 的并发告警；
- `Platform/macOS/Services/TimelapseRecorderController.swift`：AVAssetWriter / exportError 的 Swift 并发告警。

不要把告警误报成新回归；但若任务涉及这两个模块，应单独处理。

## 5. 当前产品能力与近期状态

### 5.1 画布、工具、文档

当前项目已具备多图层绘画、画笔、橡皮、吸管、油漆桶、涂抹、选区、套索填充、变形、透视辅助、撤销重做、工程保存打开和导出等主流程。底层是 Metal 画布；不要引入旧项目的 CPU 整图重绘思路。

大笔刷撤销残留已在 `1a83667` 修复：撤销脏区会计入尺寸随机导致的最大足迹。修改笔刷足迹、抖动或撤销边界时必须保留这条性质。

网格变形已从“只能拖 16 个点”向 Photoshop 式交互演进：保留四角锚点，同时允许从网格内部拖动像素。入口主要在 `Core/Application/TransformInteractionState.swift` 和画布交互层。

### 5.2 右侧检查器布局

当前右列采用“内容自适应工具参数 + 图层补足剩余高度”：

- 画笔常用参数保持可见，`杂色`滑块必须始终暴露，且其产品语义不得改成普通随机噪声；
- 低频参数折叠，减少工具参数对图层空间的挤压；
- 调色、曲线以及参数较少的工具面板按内容收缩，不保留大块空白；
- 图层面板自动取得剩余高度；
- 相邻面板必须保留一致间距；
- 小窗口下圆角和裁切必须完整，不能被内部滚动容器截平。

相关提交：`8c8171d`、`8584289`、`37b1939`、`08ad55d`。

### 5.3 图层面板

图层工作流已在 `9bf5112` 集中改造，包含绘画软件所需的常见操作入口和更清晰的层级控制。继续修改时先读现有实现和测试，不要另建一套平行的图层状态。

图层面板的产品优先级高：它应尽量显示更多图层，并由工具参数面板让出不需要的高度。

### 5.4 笔尖形状设计与导航器

两个面板的外框和画布尺寸已经对齐，切换时不应跳动。笔尖小画布不再依赖额外尺寸滑块；编辑器显示时，笔头大小使用与主画布一致的大小快捷键路由。

相关提交：`144cc2a`、`64c57e9`、`5ccd416`、`071da19`。
相关测试：`Tests/ArtFlexTests/BrushTipEditingAndNavigatorTests.swift`。

纯图标按钮已有统一 hover 名称提示，入口为 `Platform/macOS/UI/ButtonTooltipModifier.swift`。

### 5.5 画笔库、图案库、纹理库

三类资源库共用一致的面板语言，但数据和行为分开：

- 画笔库：预设、搜索 / 筛选、快捷槽、保存 / 更新等；
- 图案库：图案资源和放置工作流；
- 纹理库：持久保存套索纹理填充配置，不显示画笔库第一排的 4 个历史格；
- 激活套索填充工具时自动切到纹理库，离开后恢复画笔库；
- 纹理填充的 `杂色`参数随纹理预设一同持久化。

资源库最近一轮改造在 `6894f60`，持久化控制器分别位于 `Platform/macOS/Services/`。不要把三类资产混成一个不可区分的数组。

### 5.6 组合笔刷

组合笔刷由 A 外形笔尖和 B 纹理笔尖构成，已有独立编辑器、真实笔迹预览、来源切换、分组参数和诊断。最近两轮主要提交：

- `5e81ab3 Improve compound brush editor preview workflow`
- `d308cf6 Improve compound brush editing workflow`

关键文件：

- `Platform/macOS/UI/CompoundBrushBuilderSheet.swift`
- `Platform/macOS/UI/CompoundBrushEditorComponents.swift`
- `Platform/macOS/UI/CompoundBrushSaveSheet.swift`
- `Core/Tools/CompoundBrushDiagnostics.swift`
- `Tests/ArtFlexTests/CompoundBrushEditingTests.swift`

继续改造前，必须用真实创建流程验证：选择 A / B、调节参数、查看轻中重压预览、保存到画笔库、在主画布绘制。

### 5.7 颜色拾取器

当前侧栏颜色面板和 `Shift+Z` HUD 已统一为圆形拾色器：

- 外圈为窄色相环；
- 中央为更大的饱和度 / 明度方形区域；
- 色相环与方形区域的指示器为小尺寸；
- 复用同一组件，不维护两份色彩映射逻辑；
- HUD 仍保留原有最近颜色和参数滑块；
- HUD 滑块文字位于深色半透明容器上，以保证白色画布上的可读性；
- SV 位图异步、可取消生成，避免拖动卡顿。

最新提交：`6994c74 feat: unify circular color pickers`。

关键文件：

- `Platform/macOS/UI/ColorHueRingPickerView.swift`
- `Platform/macOS/UI/ColorPickerDisplaySupport.swift`
- `Platform/macOS/UI/QuickColorPickerHUD.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Platform/macOS/UI/CanvasContainerView.swift`
- `Tests/ArtFlexTests/QuickColorPickerHUDTests.swift`

已知验证限制：`Shift+Z` 是瞬时 HUD，自动化按键释放后面板会立即消失。之前已在前台验证触发与可读性，但如果继续改 HUD，仍应人工按住快捷键检查拖动、滑块文字和释放关闭，不要只依赖截图自动化。

### 5.8 透视工具与体块参考

两者职责不同：

- 透视工具：匹配现有图片的消失点 / 视平线，并继续拉辅助透视线；不包含建模。
- 体块参考：3D 建模、相机、工作面、参考图、视角槽、体块库和场景对象。

透视匹配和体块参考匹配代码均已存在，但体块参考的“从二维标线反解相机和工作面”曾被用户明确指出误差过大。当前只能视为近似工具，不能宣称高精度透视标定已经解决。涉及这一部分时，应重新检查几何模型和坐标映射，不要继续小修补。

体块参考右侧面板已重构为常规面板语言：

- 左列上方参考图，下方工具与参数；
- 右列上方视角槽，中部体块库，下方场景对象；
- 3D 状态隐藏无用导航器；
- 场景对象操作区贴近面板下缘；
- 面板随窗口填满高度，保留边框、间距和圆角。

自定义体块库现有能力：

- 新建类目；
- 选中部分体块、设置模块基准点并保存到内置或自定义类别；
- 场景对象和模块支持右键编辑；
- 可替换原模块、另存为新模块或放弃修改；
- 可删除已保存模块；
- 每个模块基准点属于自身局部坐标，移动一个模块不得带动另一个模块的基准点。

内置模块已包含：

- 基础体：方块、圆柱、圆锥、球体、四边方台、四边方锥、半圆体、圆环体、中空圆筒等；
- 人物与建筑模块；
- 交通工具：小轿车、SUV、小型卡车、中大型卡车、自行车、摩托车，轮径已经按常见真实尺寸重新校正。

关键文件：

- `Core/Application/BlockReferenceState.swift`
- `Core/Application/BlockReferenceAdvancedState.swift`
- `Core/Application/BlockReferenceGeometry.swift`
- `Core/Application/BlockReferenceAdvancedGeometry.swift`
- `Core/Application/BlockReferenceModuleLibrary.swift`
- `Core/Application/BlockReferencePerspectiveMatch.swift`
- `Platform/macOS/App/WorkspaceViewModel+BlockReference*.swift`
- `Platform/macOS/UI/BlockReferenceParameterPanel.swift`
- `Platform/macOS/UI/BlockReferenceOverlay.swift`
- `Platform/macOS/UI/BlockReferenceMetalSolidView.swift`
- `Platform/macOS/Services/BlockReferenceModuleLibraryPersistenceController.swift`
- `Tests/ArtFlexTests/BlockReferenceStateTests.swift`
- `Tests/ArtFlexTests/BlockReferenceModuleLibraryTests.swift`

3D 区域回归敏感点：

- 摇移 / 环绕必须流畅；
- “实体”100% 不透明时不能仍显示为线框或透视；
- 模块部件连接应合理；
- 基准点必须随自己的模块变换；
- 多模块不能共享基准点状态；
- 右键菜单要在画布对象和场景列表两处实际工作。

## 6. 关键代码地图

### 应用状态与画布

- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/UI/CanvasContainerView.swift`
- `Rendering/Canvas/`
- `Core/Application/`

### 右侧检查器

- `Platform/macOS/UI/RightInspectorView.swift`
- `Platform/macOS/UI/ButtonTooltipModifier.swift`

### 图层与撤销

- `Core/Layer/LayerRecord.swift`
- `Core/Application/LayerMergeController.swift`
- `Rendering/Canvas/VisibleDeltaRenderer.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- `Tests/ArtFlexTests/LayerMergeControllerTests.swift`

### 画笔与笔尖

- `Core/Tools/BrushPreset.swift`
- `Core/Tools/BrushTipEditing.swift`
- `Infrastructure/FileFormat/BrushTipImageAssetSystem.swift`
- `Tests/ArtFlexTests/BrushTipShapeTests.swift`

### 图案与纹理填充

- `Core/Patterns/PatternLibraryDomain.swift`
- `Core/Selection/TextureFillLibrary.swift`
- `Core/Selection/TextureFillProceduralField.swift`
- `Platform/macOS/Services/PatternLibraryPersistenceController.swift`
- `Platform/macOS/Services/TextureFillLibraryPersistenceController.swift`

### 透视辅助

- `Core/Application/PerspectiveGuideState.swift`
- `Core/Application/PerspectiveGuideMatchState.swift`
- `Platform/macOS/App/WorkspaceViewModel+PerspectiveGuideMatch.swift`
- `Platform/macOS/UI/PerspectiveGuideMatchOverlay.swift`

## 7. 最近提交顺序

从新到旧的关键节点：

```text
6994c74 feat: unify circular color pickers
08ad55d fix: collapse adjustment inspector panels
37b1939 fix: preserve inspector corners when resized
8584289 fix: balance compact inspector panels
8c8171d feat: balance brush controls and layer space
1a83667 fix: include size jitter in brush undo bounds
6894f60 feat: evolve resource libraries and pattern placement
071da19 Route brush tip sizing while editor is visible
9bf5112 Overhaul painting layer workflow
f993d87 Improve brush parameter controls
d308cf6 Improve compound brush editing workflow
5e81ab3 Improve compound brush editor preview workflow
0bcfc76 Anchor scene object controls to panel bottom
c78540f Optimize block reference performance
009f005 Correct transportation module wheel dimensions
1313a38 Add low-poly transportation reference modules
1dc9197 Add low-poly primitive reference modules
0ef34c9 Fix module-local base point ownership
```

如需回退某轮功能，优先用这些提交做比较或创建新分支，不要破坏当前分支历史。

## 8. 构建、替换和验证

常规自动验证：

```bash
swift test
```

定向示例：

```bash
swift test --filter QuickColorPickerHUDTests
swift test --filter BrushTipEditingAndNavigatorTests
swift test --filter BlockReferenceModuleLibraryTests
```

发布替换步骤：

```bash
swift build -c release
cp .build/release/ArtFlex .build/ArtFlex.app/Contents/MacOS/ArtFlex
codesign --force --deep --sign - .build/ArtFlex.app
pkill -x ArtFlex 2>/dev/null || true
open -n .build/ArtFlex.app
```

启动后必须确认：

```bash
pgrep -fl '/ArtFlex.app/Contents/MacOS/ArtFlex'
```

只能有一个目标应用实例。若存在其他 ArtFlex、隔离预览或旧构建，先识别路径，再关闭。

前台 UI 验证应覆盖本次改动的真实用户路径，而不是只看应用能启动。例如：

- 面板调整：缩放窗口、切换多种工具 / 标签、检查间距、圆角、滚动和图层高度；
- 笔刷更新：实际画线、调压感 / 杂色、撤销重做；
- 资源库更新：新增、搜索、加载、保存、删除、重启后持久化；
- 3D 更新：添加多个模块、移动 / 旋转、检查各自基准点、线框 / 实体、摇移 / 环绕；
- HUD 更新：在白色和深色画布上按住 `Shift+Z`，实际拖动色环、SV 区和滑块。

## 9. 数据保护与测试资产

之前为前台 UI 测试保存过恢复文件：

`/Users/victorcloux/Downloads/ArtFlex-Recovery-20260719-2115.artflex.json`

这是用户目录中的恢复资产，不是仓库测试夹具，不要移动、覆盖或提交。测试持久化资源库时也不要随意清空用户现有画笔、图案、纹理或自定义体块数据。

## 10. 当前风险与未解决事项

1. 体块参考的二维透视反解仍是近似方案，用户曾明确否定其精度。置信度：高。
2. 3D 面板和模块系统迭代多、状态复杂，变换、基准点、实体显示和右键菜单容易互相回归。置信度：高。
3. 当前功能分支明显领先 `main`。误切分支或以 `main` 为基线会丢失大量已验收工作。置信度：高。
4. Swift 并发告警仍存在；当前未证实会造成用户可见错误，但未来 Swift 工具链升级可能把它们升级为失败。置信度：中。
5. 最近完整测试通过数是历史记录，不代表任何新改动自动安全。每个任务仍需重新选择测试范围。置信度：高。
6. 瞬时 HUD 的自动 UI 验证能力有限；人工前台检查仍不可省略。置信度：高。

## 11. 新任务的处理方式

接到新需求后按这个顺序：

1. 判断用户是在要求讨论、诊断还是直接实现；
2. 用 `rg` 找到现有实现、状态源和测试；
3. 阅读相关代码后给复用 / 官方方案 / 决策摘要；
4. 明确最小修改范围和回归点；
5. 建立可回退基线；
6. 实现最小正确变更；
7. 自动测试；
8. Release 构建并替换唯一应用；
9. 在前台软件界面操作验证；
10. 汇报实际结果、未覆盖部分和风险；
11. 仅在用户明确要求时提交并推送。

不要从旧对话的最后一个功能自动续做。新线程中以用户最新要求为目标，本文件只提供正确背景。

## 12. 建议使用的技能

- `computer-use:computer-use`：需要在 ArtFlex 前台实际操作和验收时使用；
- `handoff`：下一次交接或上下文压缩时更新本文；
- `github:yeet`：只有用户明确要求提交、推送或开 PR 时使用；
- `browser:control-in-app-browser` 或网页检索：只在需要官方规范、成熟实现或最新外部事实时使用。
