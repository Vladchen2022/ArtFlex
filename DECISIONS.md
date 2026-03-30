# DECISIONS

最后更新：2026-03-30

本文件记录：**当前代码和产品层已经确认的关键决策。**  
如果后续改动与这些点冲突，应先重新讨论，而不是直接改代码。

## 0. 当前阶段与红线

### 0.1 performance closure audit 已完成

已确认：

- performance closure audit 已完成
- 基线文档位于 [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- performance 主线先收口，不再默认继续扩大

### 0.2 本轮性能主线与小范围 UX/perf follow-up 到此结束

已确认：

- 本轮性能主线与小范围 UX/perf follow-up 到此结束
- 后续优先级切换到新功能开发
- 没有新的 P0 / P1 回归，不准重开这一轮性能项目

### 0.3 history policy 以后按真实产品场景定，不按 8192 基准定

已确认：

- 当前产品真实上限不是 `8192 px` 级别工作流
- 后续 history retention policy 以“最大画布不超过 `3000 px`、典型用户 `16G` 内存”的真实场景为准
- 当前默认策略已经调整到：
  - `maxEntries = 24`
  - `maxResidentBytes = 768 MiB`

### 0.4 `selection.fill / lasso.fill` 当前接受为 deferred known limitation

已确认：

- `selection.fill / lasso.fill` 仍慢，但因当前不是高频刚需工具，暂时接受为 deferred known limitation
- 当前不再继续围绕它做优化
- 如果未来必须重开，只允许先检查 [mutateSelectionPixels(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5389)
- 不允许借这个问题重开新的大范围性能项目

### 0.5 dirty history 仍然是试点，不是通用 partial history

已确认：

- dirty history pilot 当前只覆盖定点路径
- 不重开通用 partial history
- 不改 dirty restore fail-closed 语义
- 不引入 `full reset + partial snapshots` fallback
- 不动 `trim / restore` 主模型

### 0.6 Dual Tip 下一阶段继续扩展，`smudge` 仍排除

已确认：

- Dual Tip Phase 0 已完成
- Dual Tip Phase 0.5 已完成
- Dual Tip Phase 1（`multiply`）已完成并通过手测
- Dual Tip Phase 2 第一刀（`subtract`）已完成并通过手测
- Dual Tip Phase 2 第二刀（`intersect`）已完成并通过手测
- `scatter` 已完成并通过手测
- `angle offset` 已完成并通过手测
- `invert` 已完成并通过手测
- 当前代码基线已完成到：
  - `multiply`
  - `subtract`
  - `intersect`
  - `secondary scatter`
  - `secondary angle offset`
  - `secondary invert`
- 下一阶段已确认纳入：
  - 完整 `secondary image tip` 独立资产系统
  - 更严格 renderer-backed preview
  - 更复杂随机 / spacing 系统
  - 更宽真实绘制 gate
- `smudge` 路径继续排除，不在本轮 Dual Tip 范围
- 当前已支持的真实绘制边界：
  - 主笔尖：圆形、自定义笔尖
  - 次笔尖：圆形、自定义笔尖
  - 模式：`multiply`
  - 模式：`subtract`
  - 模式：`intersect`
  - 变换 / 调制参数：`secondary scatter`
  - 变换 / 调制参数：`secondary angle offset`
  - 变换 / 调制参数：`secondary invert`
  - 当前真正会影响绘制的参数：
    - `strength`
    - `secondary size ratio`
    - `secondary scatter`
    - `secondary angle offset`
    - `secondary invert`
    - 当主笔尖为自定义笔尖时：`customTipMaskData / customTipSoftness / customTipRoundness / customTipAngleDegrees`
    - 当次笔尖为自定义笔尖时：`customTipMaskData / customTipSoftness / customTipRoundness / customTipAngleDegrees`
- 当前仍未落地：
  - `secondary image tip` 的完整入口 / 生命周期资产系统
  - 更严格 renderer-backed preview
  - 更复杂随机 / spacing 系统
  - 更宽真实绘制 gate
  - `smudge` 路径
- 关闭 Dual Tip 时，必须继续完全回到旧绘制路径
- 开启但不满足当前已接入条件时，也必须继续回旧路径
- 后续继续扩时，仍必须坚持窄 gate 基线、强旁路和分阶段验证
- 不允许在未验证前一次性扩很多模式 / 工具 / 主次笔尖类型，重新污染旧绘制路径

### 0.7 Dual Tip 的主/次笔尖来源已接通；自定义主/次笔尖已进入当前真实绘制

已确认：

- `组合笔尖…` 面板里的主笔尖不再维护第二套状态
- 主笔尖当前只做：
  - 真实摘要
  - `编辑主笔尖…` 跳回现有主入口
- 必须继续保证：
  - Dual Tip 面板里的主笔尖
  - 右侧 `笔尖形状设计` 里的主笔尖
  - 真实绘制主笔尖
  三者始终是同一个东西
- 次笔尖来源接通已完成：
  - `tipShape`
  - `customTipMaskData`
  - `customTipSoftness`
  - `customTipRoundness`
  - `customTipAngleDegrees`
- `编辑次笔尖…` 当前可以修改和保存这些来源参数
- 自定义主笔尖现在已经进入当前真实绘制
- 自定义次笔尖现在已经进入当前真实绘制，但 gate 仍是窄范围：
  - `multiply`
  - `subtract`
  - `intersect`
  - `scatter`
  - `angle offset`
  - `invert`
- 当前真实 renderer gate 继续要求：
  - 主笔尖：圆形、自定义笔尖
  - 工具：`brush / eraser`
  - 次笔尖若为 `方形`，仍然只编辑 / 保存，不进入真实绘制
- 当前真正会影响绘制的参数现在包括：
  - `strength`
  - `secondary size ratio`
  - `secondary scatter`
  - `secondary angle offset`
  - `secondary invert`
- 三格示意当前也已与自定义主/次笔尖的真实形状对齐
- 三格示意当前已收口到高对比样式，默认使用黑底白笔触
- 主/次笔尖当前都已补齐来源语义：
  - `procedural`
  - `customMask`
  - `importedImage`
- 当前 `importedImage` 语义已进入摘要 / preset / project / preview 说明链，但仍基于 `customTipMaskData`，不是独立资产系统
- `secondary image tip` 独立资产系统第一刀已完成：
  - project package / brush library archive 现在会把 imported-image 主/次笔尖抽成独立 `tipImageAssets`
  - archive 内 brush 现在会保存资产引用，再在打开 / 导入时解析回运行态 `maskData`
  - 当前 renderer 与 preview 运行态仍继续复用解析后的 `maskData`，这一刀不重写真实绘制主链
- `secondary image tip` 第二刀已完成：
  - imported-image 的 preview fit 现在由 `TipSourceSemantic` 驱动，不再依赖会话态 flag
  - imported-image 的来源标签与原始像素尺寸现在由 `ImportedTipSourceInfo` 保存并在 UI 摘要中显示
  - 手绘 / 清空主次笔尖遮罩时，会同步清掉 imported-image 资产引用和来源信息，保持来源语义单一
- 最近一轮回归已修复：
  - 编辑组合笔尖后普通画笔卡顿
  - 偶发画不出笔触
  - 导入图像笔尖后的白边
- 下一阶段扩展方向已经确认：
  - 完整 `image tip` 资产系统
  - 更严格 preview 同源
  - 更复杂随机 / spacing 系统
  - 更宽真实绘制 gate
- `smudge` 路径继续不纳入本轮范围
- 但这些事项必须拆成独立小刀推进，不应一次性并到同一改动

## 1. 总体架构

### 1.1 Metal-first，不回退旧 CPU 画布

已确认：

- 旧版 `BrushCanvas` 只作为产品与行为参考
- 新项目不回退到 `CGContext / CGImage / CPU 整图合成` 主路径
- 画布、图层、笔刷执行、显示与文档链继续围绕 Metal 主链构建

### 1.2 统一底层真相源

已确认：

- 显示、编辑、取样、导出尽量共用同一套底层数据真相源
- 不接受长期并存的“显示一套 / 采样一套 / 导出一套”路径分裂

### 1.3 旧项目只继承产品定义，不继承主实现

可继承：

- UI 结构
- 工具职责
- 工作流
- 参数命名
- 用户可见行为

不继续采用：

- 旧 CPU 画布主路径
- 整图 CGContext 合成
- 巨型单状态对象

## 2. 历史系统

### 2.1 Undo/Redo 主要回退文档，不回退当前工具面板状态

当前 [HistoryController.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift) 仍保留这个决策：

- 恢复：
  - 文档
  - 图层
  - 选区
  - 图层像素快照
- 保留当前：
  - `toolSession`
  - `colorPanel`
  - `brushLibrary`
  - `generator`
  - `viewport`

### 2.2 当前撤销保留策略使用有限预算，不再是不设上限

当前代码中：

- [HistoryController.defaultMaxEntries](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L59) = `24`
- [HistoryController.defaultMaxResidentBytes](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L60) = `768 MiB`

仍然保留的决策：

- 不改 `trim` 语义
- 预算裁剪时至少保留最新 entry

## 3. 选区与自由变形

### 3.1 选区主链已经成型，但不要再大范围扰动

当前产品层已经确认：

- 套索 / 多边形 / 矩形 / 椭圆选区主链已可用
- 增选 / 减选功能本体正确
- 蚂蚁线显示链目前已达到“可接受且不应再随意大改”的状态

### 3.2 自由变形保留“确认式”工作流

已确认：

- 自由变形使用：
  - `Enter` 应用
  - `Esc` 取消
- 它不是简单拖完立即落地的移动工具

### 3.3 自由变形已经是正式工具链

已确认：

- `V` 对应自由变形
- 有选区和无选区两条路径都已接通
- 当前可继续优化细节，但不应再尝试“摘掉工具入口”或推翻主链

## 4. 画布视图能力

### 4.1 画布旋转工具已定版

这是近期最明确的一条冻结决策：

- 画布旋转工具 `R`
- 旋转 HUD
- 回正按钮
- 旋转状态下的采样链

**当前已被用户明确要求：不要再主动修改。**

后续除非用户明确要求，不应再碰这条链。

### 4.2 画布缩放正在往“视图 transform”方向重构

已确认方向：

- 不继续走“缩放 = 改文档 frame 尺寸”这条重 layout 路线
- 改成更接近成熟绘图软件的：
  - 稳定 viewport
  - 内容组 transform 缩放

当前这是正在推进但未宣布定版的技术主线。

## 5. 笔刷系统

### 5.1 画笔主工作流已确认

当前产品链条已确认并已落到代码模型中：

1. 在 `笔尖形状设计` 中制作截面
2. 在 `画笔参数` 中调行为
3. 点击 `存为笔刷`
4. 在 `画笔库` 中保存、应用、排序

### 5.2 画笔库不保存颜色

这是明确产品决策，当前代码也按此方向组织：

- 画笔库保存的是笔刷定义
- 切换预设不应改变当前颜色

### 5.3 旧的默认内置笔刷已移除

已确认：

- 旧的 3 个默认笔刷已移除
- 旧默认笔刷移除后，默认画笔库一度可以为空
- 当前默认画笔库是否为空，以最新的内置示例预设决策为准

### 5.4 画笔库当前是“应用级持久化库”

当前已确认：

- 笔刷库会持久保存到应用级目录
- 重新启动 / 重新编译后仍存在
- 目前更偏向“全局笔刷库”，不是工程私有笔刷库

### 5.5 前 4 个槽位是快速调用位

已确认：

- 前 4 个槽位显示 `1 / 2 / 3 / 4`
- 按 `1 2 3 4` 会在任何工具下切回画笔，并激活对应笔刷

### 5.6 画笔库主链已定版

用户已明确要求：

- 当前画笔库功能先定住，不再主动修改

### 5.7 默认画笔库现在保留 3 个 Dual Tip Phase 1 示例预设

已确认：

- 默认画笔库不再是完全空白状态
- 当前默认会带 3 个 built-in Dual Tip Phase 1 示例预设，方便直接体验当前能力边界
- 这 3 个示例预设是 `multiply` 能力演示，不应被误读成 `intersect / scatter / image tip` 的展示预设

## 6. 笔尖形状设计

### 6.1 手动画预览和导入图片预览已拆开

已确认：

- 手动画笔尖时，不应自动裁内容再放大
- 外部图片导入时，可以继续使用内容 fit 预览

### 6.2 图片导入支持三种入口

已确认：

- 文件导入
- `cmd+V`
- 拖拽导入

### 6.3 导入图片转笔尖时必须保持等比

已确认：

- 导入图片可以缩小适配
- 但不能拉伸或压扁

## 7. 颜色面板

### 7.1 颜色面板是独立双模式系统

已确认：

- `picker`
- `blocks`

### 7.2 色块模式中的色块组合不会被吸管自动破坏

已确认产品决策：

- 吸管取色只改变当前颜色
- 不应自动重建或污染色块组合
- 只有点击“同步”才把当前颜色同步进色块组合

### 7.3 色块模式支持从图片生成色块组合

已确认：

- 文件导入
- `cmd+V`
- 拖拽导入

## 8. 杂色功能

### 8.1 杂色色带方向独立于笔尖旋转

这是近期明确确认的产品决策：

- 杂色方向始终跟随笔触行进方向
- 不管笔刷本身是否旋转

这条链已经按这个规则落地，不应再回退到复用 `tipAngleDegrees` 的旧逻辑。

## 9. 录像工具

### 9.1 录像工具入口位于左侧底部按钮

已确认：

- 不再占用右侧“创意图形生成器”面板位
- 左侧底部按钮 + popover 是当前正式入口

### 9.2 录制采用“只在内容变化时录帧”的策略

已确认：

- 不做实时录屏
- 只在内容变更且满足最小间隔时录帧
- 写图走后台队列

### 9.3 同一文档固定目录

已确认：

- 同一文档多天录制的帧应继续写到同一个目录
- 已保存文档目录使用：
  - 文档名 + 路径指纹

### 9.4 录像工具当前主链已可用

当前已确认：

- 第一版功能已经成立
- 后续可继续升级，但不应再破坏当前不卡的录制主链

## 10. 新建画布

### 10.1 新建画布使用独立弹窗

已确认：

- 顶部有新建文件入口
- `cmd+n` 可打开
- 采用独立弹窗而不是重排主窗口

### 10.2 当前有未保存内容时，新建前必须确认

已确认：

- `保存 / 放弃 / 取消`

## 11. 当前冻结 / 不应主动再碰的部分

当前已明确冻结的链路：

- 画布旋转工具
- 画笔库主链

当前建议谨慎修改的链路：

- 录像工具主链
- 自由变形主链
- 选区显示链

## 12. 当前文档使用约定

已确认：

- 当前继续开发时，应优先参考：
  - [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
  - [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
  - [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
- 当前线程默认不再从性能优化开始，而是先进入新功能定义与实现
