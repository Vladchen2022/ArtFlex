# AGENTS.md

## 项目背景

本项目是旧版 `BrushCanvas` 的 Metal 重构版。

目标是保留旧项目已经验证过的产品设计和工作流，但重做底层画布、渲染、图层、文档和工具实现。旧项目的 CPU 架构只作为产品参考，不作为实现模板。

## 产品层必须保留的内容

以下内容视为已验证的产品定义，不允许随意改动：

### 主界面结构
- 顶部工具栏
- 左侧竖向工具栏
- 中央视图画布
- 右侧生成器 / 色彩 / 笔刷 / 参数区
- 图层面板
- 笔尖形状设计区域

### 核心用户功能
- 画笔
- 橡皮擦
- 吸管
- 油漆桶
- 涂抹
- 套索选区
- 矩形选区
- 椭圆选区
- 套索填充
- 套索擦除
- 自由变形
- 图层新建 / 删除 / 复制 / 排序 / 合并 / 显示隐藏 / 锁定 / 透明度
- 缩放 / 平移 / 重置视角
- 撤销 / 重做
- 自定义笔尖设计
- 笔刷库
- 工程打开 / 保存 / 导出
- 生成器系统

### 交互层约束
- 保留旧项目整体工作流
- 保留工具分布和面板职责
- 保留桌面绘图软件风格的主操作路径
- 不允许为了技术实现方便而擅自砍掉关键产品能力
- 不允许随意重排成熟 UI 结构，除非明确进入产品设计调整阶段

## 来自旧项目的刚性约束

这些是从旧项目迁移中总结出的硬性规则：

### 颜色与像素规则必须先统一
必须先定义并固定：
- CPU 侧像素格式
- Metal texture format
- render target pixel format
- premultiplied alpha 规则
- sRGB / linear 规则
- 吸管采样来源
- 涂抹采样来源
- 导出使用的数据源

不得边开发边临时补通道交换、颜色补偿、shader 层临时修正。

### 显示、编辑、取样、导出必须共享同一套真相源
不能出现：
- 屏幕显示走一条链
- 吸管取色走另一条链
- 涂抹采样走第三条链
- 导出再走第四条链

必须尽量统一到底层标准化画布数据。

### 不再使用旧项目的 CPU 画布合成思路作为核心方案
旧项目中这类实现不能继续作为新项目主方案：
- CGContext 整图合成显示
- 图层 = strokes + bitmapContext + redraw flag 的混合模型
- 预览与最终绘制混在一个状态对象中
- 用大量整图 CGImage / CGContext 拷贝支撑交互

### 不允许再做巨型 CanvasState
旧项目的 `CanvasState.swift` 集中了过多职责。新项目必须拆分，不允许再出现一个对象同时管理：
- 文档
- 图层
- 工具
- 选区
- 变形
- 剪贴板
- 文件状态
- 生成器
- 画布视图状态
- 笔刷库

## 底层必须用 Metal 思路重建的部分

以下模块不允许简单照搬旧实现，必须按 Metal-first 架构重建：

- Canvas renderer
- Layer storage
- Layer compositing
- Transform preview/render pipeline
- Selection mask pipeline
- Eyedropper sampling
- Smudge sampling and blending
- Undo/redo model
- Project/document format
- Brush execution backend
- Texture cache / tile cache strategy

## 可以继承的内容

只允许继承“产品定义”和“行为参考”，不允许直接复制底层实现：

- UI 结构
- 工具集合
- 参数命名
- 快捷键逻辑
- 图层面板交互
- 生成器类型与入口
- 自定义笔尖工作流
- 文件入口设计
- 旧项目中的用户可见行为

## 开发顺序

### 第一阶段：最小可用核心
先做：
- App 壳层
- 主窗口结构
- Metal 画布
- 单图层
- 基础画笔
- 橡皮擦
- 平移 / 缩放
- PNG 导出
- 最小工程保存格式

### 第二阶段：文档与图层系统
再做：
- 多图层
- 图层排序 / 可见性 / 锁定 / 透明度
- 撤销 / 重做
- 工程保存 / 打开

### 第三阶段：基础编辑能力
再做：
- 选区系统
- 自由变形
- 吸管
- 油漆桶

### 第四阶段：高级创作能力
再做：
- 涂抹
- 自定义笔尖设计
- 笔刷库
- 套索填充 / 擦除
- 生成器

## 不允许做的事

- 不允许把旧项目的 CPU 画布实现直接迁移过来继续用
- 不允许先把功能堆起来，再事后补颜色规范
- 不允许为了赶进度随意改产品层布局
- 不允许无计划地扩大功能范围
- 不允许在还没有颜色一致性和像素规范前就接入吸管、涂抹、导出完整链路
- 不允许把实验性渲染路径直接替换为默认主路径，除非已经通过对照验证

## 遇到不确定时的优先级

决策优先级如下：

1. 产品行为正确
2. 颜色与像素一致性正确
3. 架构边界清晰
4. 可维护性
5. 性能优化
6. 实现速度

## 旧项目参考文件

以下旧文件可作为产品和行为参考：

- `ContentView.swift`
- `CanvasView.swift`
- `CanvasState.swift`
- `LayerPanelView.swift`
- `BrushSectionView.swift`
- `StrokeRenderer.swift`
- `ProjectFileManager.swift`
- `GlobalBrushManager.swift`

注意：
这些文件仅供“理解旧产品”，不能默认作为新项目实现模板。

虽然当前项目只实现 macOS 版本，但请在架构上为未来可能的 Windows 版本保留空间。

要求：
1. 业务逻辑、文档模型、工具状态尽量不要直接耦合到 SwiftUI/AppKit
2. Metal 渲染实现尽量与上层逻辑分离
3. 平台相关能力（窗口、菜单、文件面板、权限）集中在平台层
4. 不为了跨平台而过度设计，但要避免把整个项目写死成只能在 mac 上重用为零的结构

## Reuse-First Implementation Policy

### Core Principle
For any non-trivial feature, bug fix, refactor, subsystem, performance optimization, or architectural change, do **not** jump straight into custom implementation.

Always follow this order:

1. Check whether this repository already contains reusable code, patterns, helpers, wrappers, or prior implementations.
2. Check whether Apple official frameworks, Swift standard library, or official platform-recommended approaches already solve the problem.
3. Check whether there is a mature, well-maintained, commonly used existing solution that is clearly more suitable than writing custom infrastructure.
4. Only write a custom implementation if existing options are clearly unsuitable.

### Default Bias
Default to:
- reusing existing code in this repository
- using Apple official APIs and recommended patterns
- using standard library and platform-native solutions
- choosing the simplest maintainable solution

Do **not** reinvent common infrastructure unless there is a strong reason.

### Before Coding
Before implementing any non-trivial task, first produce a short decision summary.

That summary must include:

1. **Repository reuse check**
   - What existing files, types, helpers, or patterns in this repo may already help
   - Whether they can be reused directly, adapted slightly, or should be avoided

2. **Existing solution check**
   - Whether Apple official frameworks or standard APIs already solve this
   - Whether there is an established common approach for this kind of problem

3. **Decision**
   - Which approach is recommended
   - Why it is better than custom reinvention
   - What tradeoffs were considered

Do not start large-scale edits before this decision summary is written.

### Custom Implementation Is Allowed Only If
A custom solution may be written only if at least one of the following is true:

- Existing repo code cannot support the requirement without worse complexity
- Official/native approaches do not fit the product or architecture
- Existing solutions add unreasonable dependency, maintenance, or integration cost
- A custom solution is clearly smaller, safer, or easier to maintain in this project

If choosing a custom solution, explicitly explain:
- why reuse was rejected
- why official/native approaches were rejected
- why custom code is justified here

### Scope Control
Do not explore broadly and do not keep “trying random approaches”.

Instead:
- decide first
- implement second
- keep implementation minimal
- stay within the requested scope
- avoid opportunistic refactors unless they are necessary for the task

### Output Requirements For Each Task
For any meaningful implementation task, respond in this order:

1. **Decision summary**
2. **Implementation plan**
3. **Code changes**
4. **Changed files list**
5. **Validation steps**
6. **Risks / follow-up notes**

### Architecture Preference
For this project:
- prefer stable, platform-native, maintainable solutions
- prefer clear layering over clever hacks
- avoid tightly coupling business logic to UI details
- avoid tightly coupling upper-level logic to one-off rendering details
- avoid carrying over weak patterns from the old CPU-based project unless explicitly justified

### Performance Work
For performance-sensitive work:
- first check whether the bottleneck can be solved by better architecture or existing APIs
- do not write custom low-level optimization code prematurely
- prefer measurement-driven decisions over speculative rewrites

### Dependency Policy
Do not add a new dependency casually.

Before introducing any dependency, explain:
- what problem it solves
- whether the standard library or Apple frameworks already solve it
- integration cost
- maintenance cost
- long-term risk

### Hard Rule
The goal is not “write code as soon as possible”.
The goal is “choose the most appropriate existing solution first, then implement the smallest correct change”.

## Reference-first bug fixing policy

For difficult interaction bugs, geometry bugs, selection bugs, coordinate-space bugs, or rendering-path bugs:

- Do not keep patching the current implementation repeatedly.
- If the same bug survives more than 2 failed attempts, stop patching.
- Switch to reference-first mode.
- Before coding, inspect mature existing approaches:
  - Apple official APIs and documentation
  - mature open-source implementations
  - clearly established patterns used by serious drawing tools

Before any code change, produce a short reference report that includes:
- exact sources consulted
- how the current implementation differs
- why the current implementation fails
- what should be rewritten instead of patched

If external references are not accessible, state that explicitly.
Do not claim to have referenced external implementations unless specific sources are named.
