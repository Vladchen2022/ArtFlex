# XCODE_NOTES

最后更新：2026-03-20

本文件记录当前项目在 Xcode / SwiftPM 下恢复开发时最值得知道的事实与注意事项。

## 1. 工程组织

当前项目是 **Swift Package 可执行程序**，不是传统 `.xcodeproj` 工程。

入口文件：

- [Package.swift](/Users/victorcloux/Desktop/ArtFlex/Package.swift)

当前配置可确认：

- package 名称：`ArtFlex`
- 平台：`macOS 14`
- 产品：可执行程序 `ArtFlex`
- 测试 target：`ArtFlexTests`

## 2. Package.swift 当前真实状态

当前 [Package.swift](/Users/victorcloux/Desktop/ArtFlex/Package.swift) 的 `exclude` 列表只排除了：

- `.git`
- `AGENTS.md`
- `COLOR_PIXEL_SPEC.md`
- `CURRENT_STATUS.md`
- `MIGRATION_NOTES.md`
- `MVP_PLAN.md`
- `STAGE1_STATUS.md`
- `README.md`
- `Tests`

注意：

- `STATUS.md`
- `CURRENT_TASK.md`
- `DECISIONS.md`
- `XCODE_NOTES.md`
- `HANDOFF.md`
- `selection-trace.log`

**当前并没有被 exclude。**

这也是为什么 `swift build` / `swift test` 现在会提示：

- found file(s) which are unhandled

这不是本轮新引入的问题，而是当前 `Package.swift` 的真实状态。

## 3. 当前应优先参考的文档

如果现在从 Xcode 恢复开发，建议优先看：

1. [STATUS.md](/Users/victorcloux/Desktop/ArtFlex/STATUS.md)
2. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)

说明：

- [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md) 是较早阶段文档，已经落后于当前代码

## 4. 当前最重要的代码入口

### 工作区与状态变更

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
- [WorkspaceStore.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Application/WorkspaceStore.swift)

作用：

- UI 触发的大多数用户操作都会落到这里
- 包括：
  - 工具切换
  - 颜色面板参数
  - 笔刷参数
  - 画笔库保存 / 移动 / 导入导出
  - 录像工具入口
  - 视口缩放 / 平移 / 旋转
  - 选区 / 自由变形

### 中央视图与画布显示链

- [CanvasContainerView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/CanvasContainerView.swift)
- [MainWindowView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/MainWindowView.swift)
- [MetalCanvasHost.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift)
- [CanvasPresentation.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Viewport/CanvasPresentation.swift)

当前注意点：

- 画布缩放流畅性最近刚开始做重构
- `CanvasPresentation` 现在已经把基础 fit 尺寸和 `documentZoomScale` 拆开
- `CanvasContainerView` 已改为对文档内容组施加 `.scaleEffect`
- 这条链是当前最值得继续看的技术主线

### 右侧检查器

- [RightInspectorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RightInspectorView.swift)

注意：

- 这个文件依然很大
- 右侧绝大部分 UI 都集中在这里：
  - 创意图形生成器占位
  - 颜色
  - 画笔库
  - 笔尖形状设计
  - 画笔参数
  - 图层

### 颜色系统

- [ColorPanelState.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Color/ColorPanelState.swift)

当前这里定义了：

- picker / blocks 双模式状态
- 色块组合算法
- 色光层参数

### 笔刷系统

- [ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)
- [BrushPreset.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/BrushPreset.swift)
- [StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)
- [BrushLibraryPersistenceController.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Services/BrushLibraryPersistenceController.swift)

说明：

- `StageOneBrushRenderer.swift` 是当前实际笔刷渲染主链的重要文件
- 杂色方向跟随笔触方向的逻辑也在这里
- 画笔库现在有独立持久化 controller

### 自由变形

- [TransformInteractionState.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Application/TransformInteractionState.swift)
- [TransformPreviewSession.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/TransformPreviewSession.swift)
- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
- [MetalCanvasHost.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift)

当前注意点：

- 自由变形主链已可用
- 但如果继续优化，优先针对明确问题做小修，不要大范围重构

### 录像工具

- [TimelapseRecorderController.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Services/TimelapseRecorderController.swift)
- [RecorderSectionView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RecorderSectionView.swift)
- [ToolSidebarView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/ToolSidebarView.swift)

当前注意点：

- 录像工具入口现在在左侧底部按钮
- 同文档目录策略已经接好

## 5. 当前常用命令

构建：

```bash
swift build
```

全量测试：

```bash
swift test
```

常用定向测试：

```bash
swift test --filter CanvasPresentationTests
swift test --filter DocumentStateTests
swift test --filter ProjectPackageTests
swift test --filter BrushTipShapeTests
swift test --filter TransformInteractionStateTests
```

## 6. 当前最容易误判的点

### 6.1 旧状态文档不是最新事实

不要再把 [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md) 当作当前实现的唯一状态来源。

### 6.2 画布旋转工具当前已定版

用户已经明确要求：

- 画布旋转链不要再主动修改

如果再出现看起来像旋转问题的现象，先怀疑别的链，不要先去动旋转工具本身。

### 6.3 画笔库主链当前也已定版

最近刚做完：

- 槽位尺寸统一
- `1 2 3 4` 快捷键
- 应用级持久化
- 导入 / 导出

当前不要再主动碰这条链。

### 6.4 当前仍会出现 SwiftPM warning

当前 `swift build` / `swift test` 仍会提示两类 warning：

1. 根目录若干文件未被 package 处理  
2. `MetalCanvasCoordinator` 的 `SendableClosureCaptures` warning

这些 warning 当前都存在，但并不阻塞构建和测试通过。

## 7. 当前建议的恢复开发顺序

如果下一轮恢复开发，建议先看：

1. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
2. [STATUS.md](/Users/victorcloux/Desktop/ArtFlex/STATUS.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)

然后优先继续：

- 画布缩放流畅性这条技术主线

而不是重新打散已经定住的工具链。
