# ArtFlex Handoff

## 1. Current status

### 目前已经完成了什么

当前仓库已经不再是早期 MVP 壳子，而是一个已有主工作流的 Metal 绘图应用基础版。

已完成并能在代码中确认存在的主链包括：

- 主窗口结构：
  - 顶部工具栏
  - 左侧竖向工具栏
  - 中央视图画布
  - 右侧两列检查器
- 文档与图层基础：
  - 多图层文档状态
  - 图层新增 / 删除 / 复制 / 显示隐藏 / 锁定 / 透明度
  - 向下合并 / 合并可见
  - 图层拖拽排序
- 基础编辑链：
  - 画笔
  - 橡皮擦
  - 吸管
  - 油漆桶
  - 涂抹
  - 选区相关能力
  - 基础变形
  - 缩放 / 平移 / 重置视图
- 持久化与导出：
  - PNG 导出
  - 工程保存 / 打开
  - 画笔库、颜色面板等状态写入工程
- 撤销 / 重做：
  - 历史系统已建立
  - 当前撤销步数不设上限（`HistoryController.maxEntries == nil`）

### 目前界面上已经能看到什么

右侧当前结构已经比较完整：

- 左列：
  - 创意图形生成器
  - 颜色
  - 画笔库
- 右列：
  - 笔尖形状设计
  - 画笔参数
  - 图层

其中已比较完整的板块：

- **笔尖形状设计**
  - 独立小画布
  - 橡皮工具
  - 柔边、灰度
  - 插入基础形状
  - 喷墨散点
  - 旋转 / 左右翻 / 上下翻
- **画笔参数**
  - 不透明度封顶
  - 间距
  - 散布
  - 旋转
  - 抖动
  - 杂色
  - 压感
  - 尺寸下限
  - 跟随笔迹方向
  - 压感曲线入口
- **画笔库**
  - 保存除颜色外的笔刷定义
  - 自由拖拽到任意格子
  - 格子位置可保存
  - 缩略图使用“笔迹预览 + 小截面预览”
- **颜色面板**
  - 拾色器模式
  - 色块模式
  - 同步 / 刷新 / 从图片 / 重置 / 模式切换
  - 明度 / 饱和度 / 对比 / 对比色
  - 色光色相条与色强度
- **图层面板**
  - 缩略图
  - 拖拽排序
  - 图标式底部操作栏

### 目前哪些部分可以在 Xcode 里测试

当前最适合在 Xcode 里手测的部分：

- 笔尖形状设计 → 画笔参数 → 画笔库 这条完整链
- 颜色面板：
  - picker / blocks 双模式
  - 色块稳定方案
  - 从图片提色
  - 色光色相条 / 色强度
- 图层面板：
  - 拖拽排序
  - 缩略图
  - 图标操作栏
- 工程保存 / 打开
- PNG 导出
- Undo / Redo 的当前语义

当前最明确还只是骨架的部分：

- **创意图形生成器**
  - 面板和参数切换 UI 已有
  - 真实往大画布生成内容的逻辑尚未接通

## 2. Changed files so far

以下是本线程里高频改动或持续作为实现核心的关键文件，以及它们现在各自负责的内容。

### 1. [Platform/macOS/UI/RightInspectorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RightInspectorView.swift)

当前最重要的 UI 文件之一。负责：

- 创意图形生成器面板
- 颜色面板
- 画笔库
- 笔尖形状设计小画布
- 画笔参数面板
- 图层面板

本线程里右侧大部分布局、面板结构、画笔库网格、颜色面板几何、图层面板布局都在这里迭代。

### 2. [Platform/macOS/App/WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)

当前 UI 行为入口核心。负责：

- 画笔参数 setter
- 颜色面板 setter
- 画笔库保存 / 删除 / 排序
- 图层相关用户动作
- 自定义笔尖数据更新
- 轻量刷新与工作区状态变更

### 3. [Core/Tools/ToolKind.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/ToolKind.swift)

核心参数模型文件。负责：

- `BrushBuildMode`
- `BrushTipShape`
- `BrushSettings`

当前笔刷系统的大多数参数都定义在这里。

### 4. [Core/Tools/BrushPreset.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Tools/BrushPreset.swift)

负责画笔库与预设模型：

- `BrushPreset`
- `BrushLibraryState`
- `slotIndex`
- 保存当前笔刷
- 自由格子定位
- 预设移动与交换

### 5. [Core/Color/ColorPanelState.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Color/ColorPanelState.swift)

负责颜色面板核心状态与算法：

- picker / blocks 双模式
- picker 颜色逻辑
- 色块方案逻辑
- 对比 / 对比色
- 色光层（`lightingHue` / `lightingStrength`）

### 6. [Core/Application/HistoryController.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift)

负责当前历史系统：

- checkpoint 捕获
- undo / redo
- 历史导航时保留当前工具、颜色面板、画笔库、生成器、视口状态

### 7. [Rendering/Canvas/StageOneBrushRenderer.swift](/Users/victorcloux/Desktop/ArtFlex/Rendering/Canvas/StageOneBrushRenderer.swift)

当前主笔刷渲染后端的重要实现文件。负责：

- 基础画笔主链
- build-up / opacity-cap 路径
- 杂色（条带式 color jitter）
- 与当前 brush settings 相关的 stamp 行为

### 8. [Core/Document/ArtDocument.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Document/ArtDocument.swift)

负责文档层结构与图层集合。

### 9. [Infrastructure/FileFormat/ProjectPackage.swift](/Users/victorcloux/Desktop/ArtFlex/Infrastructure/FileFormat/ProjectPackage.swift)

负责工程格式持久化。当前用于保存：

- 文档
- 图层
- 画笔库
- 颜色面板
- 其他工作区状态

### 10. [Platform/macOS/Canvas/MetalCanvasHost.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift)

负责画布宿主、输入路径、连续绘制状态，是高频交互性能的重要入口。

### 11. [Tests/ArtFlexTests/DocumentStateTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/DocumentStateTests.swift)

当前文档和工作区默认状态的重要测试文件。

### 12. [Tests/ArtFlexTests/ProjectPackageTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/ProjectPackageTests.swift)

当前工程保存 / 打开与状态持久化的重要测试文件。

## 3. Architecture decisions

### 已经确定的关键架构决策

1. **Metal-first**
   - 旧 CPU 项目只作为产品和行为参考
   - 新项目继续以 Metal 画布、真实 texture 图层为主链

2. **显示 / 编辑 / 采样 / 导出尽量共享同一套底层真相源**
   - 不接受长期“显示一套、采样一套、导出一套”的路径分裂

3. **历史系统主要回退文档，不回退当前工具参数**
   - Undo/Redo 当前恢复文档、图层和选区
   - 保留当前工具状态、颜色面板、画笔库、生成器、视口

4. **画笔库不保存颜色**
   - 画笔库保存的是笔刷定义
   - 切换预设不应改变当前颜色

5. **颜色面板是独立双模式色彩系统**
   - picker
   - blocks
   - 外加色光层

6. **创意图形生成器不是具象图像生成器**
   - 目标是抽象、随机、可联想的图形素材
   - 当前采用 A/B 结构：
     - A：生成器按钮区
     - B：随按钮切换的参数面板区

### 明确不再采用的旧思路

1. 不再回退到旧 CPU 画布主路径
2. 不再使用“巨型 CanvasState 一把抓”的状态组织方式
3. 不把旧项目的 CGContext / CGImage 整图合成继续作为新项目核心显示或编辑方案
4. 不让画笔库和颜色绑定在一起

### 当前实现依赖的核心约束

1. 旧版只继承产品定义，不直接继承实现
2. 右侧检查器结构当前已基本定型：
   - 左列：创意图形生成器 / 颜色 / 画笔库
   - 右列：笔尖形状设计 / 画笔参数 / 图层
3. 当前生成器面板虽然已经可见，但仍然只算 UI 骨架
4. 当前 `HistoryController.maxEntries == nil`
   - 即撤销步数当前不封顶

## 4. Current task boundary

### 当前做到哪一步

当前代码状态下：

- 笔刷系统主链已经基本完整
- 颜色面板主链已经建立
- 图层面板主工作流已经建立
- 右侧布局主结构已经基本确立
- 创意图形生成器已经从旧“核心生成器”替换成 A/B 面板骨架

也就是说，当前已经从“搭工具”走到了：

**大部分主板块都有了，生成器是下一条真正还没接通的核心链。**

### 下一步最应该继续做什么

最建议的下一步：

**从创意图形生成器里挑一个生成器，接通第一条真实往大画布输出内容的逻辑。**

优先建议：

1. 自动线条
2. 偏离手绘

建议顺序：

- 先做区域生成
- 再做偏离式手绘

### 下一步明确不要做什么

当前不建议优先继续做的事：

- 再继续大范围扩笔刷细节
- 再继续扩颜色面板的新控件
- 一口气同时接通多个生成器
- 大规模 UI 改版

原因：

- 这些都会继续扩散范围
- 当前真正最短的板，是生成器还没有真实输出能力

## 5. Xcode verification

### 当前项目如何在 Xcode 中编译和运行

当前项目是 Swift Package，可直接在 Xcode 中打开包根目录：

- [Package.swift](/Users/victorcloux/Desktop/ArtFlex/Package.swift)

常用命令：

```bash
swift build
swift test
```

常用定向测试：

```bash
swift test --filter DocumentStateTests
swift test --filter ProjectPackageTests
swift test --filter PressureInputTests
swift test --filter BrushTipShapeTests
```

### 这一阶段应该怎么验证

当前更适合手测的链路：

1. 笔尖形状设计 → 画笔参数 → 画笔库
2. 颜色面板：
   - picker / blocks
   - 色块稳定方案
   - 从图片
   - 色光条 / 色强度
3. 图层面板：
   - 缩略图
   - 拖拽排序
   - 图标底栏
4. 工程保存 / 打开
5. PNG 导出

### 预期结果是什么

当前预期是：

- 右侧主要面板都能显示并交互
- 笔刷链条可用
- 颜色面板双模式可用
- 图层主工作流可用
- 创意图形生成器面板能切按钮和参数，但**还不会真正往画布生成内容**

## 6. Known issues / risks

### 当前已知问题

1. 创意图形生成器还没有真实画布输出逻辑
2. 右侧检查器仍然大量集中在一个文件里：
   - [RightInspectorView.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/UI/RightInspectorView.swift)
3. 颜色面板和右侧整体布局近期改动较多，局部几何与视觉收口仍可能继续发生

### 当前风险点

1. 右侧 UI 继续堆功能会让 `RightInspectorView.swift` 继续膨胀
2. 颜色系统和笔刷系统都已经比较复杂，继续同时推进多个板块容易互相干扰
3. 如果不控制范围，后续很容易在“抠细节”里消耗过多轮次

### 哪些地方还只是 UI 骨架或占位实现

最明确的骨架部分：

- **创意图形生成器**
  - 生成器按钮区已存在
  - 参数区已存在
  - 真实生成逻辑未接

相对更成熟但仍可继续打磨的部分：

- 颜色面板
- 画笔库缩略图与布局
- 图层面板细节

## 7. Recommended next prompt

下面这段提示词可以直接用于新线程接手：

---

请先阅读以下文件，再继续当前任务：

- `/Users/victorcloux/Desktop/ArtFlex/AGENTS.md`
- `/Users/victorcloux/Desktop/ArtFlex/README.md`
- `/Users/victorcloux/Desktop/ArtFlex/MIGRATION_NOTES.md`
- `/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md`

阅读后，请不要先扩散功能范围。  
基于当前仓库真实状态，继续推进 **“创意图形生成器”**，目标是：

1. 保持当前右侧 A/B 面板结构不变  
2. 先从一个最合适的生成器开始（优先考虑“自动线条”）  
3. 只做第一条真实往大画布输出内容的最小闭环  
4. 先支持一种交互方式（优先区域生成），不要同时实现多个生成器和多种交互  
5. 继续遵守 AGENTS.md 里的 reuse-first、Metal-first 和产品工作流约束

输出时请先给出：

1. Decision summary  
2. Implementation plan  
3. Code changes  
4. Changed files list  
5. Validation steps  
6. Risks / follow-up notes

---
