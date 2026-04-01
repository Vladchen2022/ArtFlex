# DECISIONS

最后更新：2026-04-01

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

### 0.4 旧的 `selection.fill / lasso.fill` 合并性能限制已失效

已确认：

- 旧文档里把 `selection.fill / lasso.fill` 一起视为 deferred known limitation 的结论已过时
- `lasso.fill` 当前已切到 GPU local-mask 填色链，不再按旧的慢确认限制对待
- 如果未来必须重开填充性能问题，`selection.fill`、`lasso.fill` 与 `fillAtPoint` 必须分开看，不允许继续沿用旧的合并 profiling 结论
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
- `secondary size jitter` 已完成并通过定向测试
- `secondary angle jitter` 已完成并通过定向测试
- `secondary spacing phase` 已完成并通过定向测试
- `secondary spacing phase jitter` 已完成并通过定向测试
- `secondary scatter jitter` 已完成并通过定向测试
- 组合笔尖后续默认只继续推进“明显影响画笔效果”的能力，以及“预览 / 保存恢复 / 资料库稳定性”这类必做收口
- 轻微影响画笔效果的新随机 / `spacing` 小参数默认暂停，不再为“参数完整”继续扩面
- `组合笔尖` 面板后续按“简洁优先”维持：默认只保留控制、必要状态和示意图，不再回加大段说明性文字
- `编辑次笔尖…` 面板后续也按同一原则维持：默认只保留标题、控件、预览和按钮，不再回加说明句或 slider helper text
- 当前代码基线已完成到：
  - `multiply`
  - `subtract`
  - `intersect`
  - `secondary scatter`
  - `secondary scatter jitter`
  - `secondary angle offset`
  - `secondary invert`
  - `secondary size jitter`
  - `secondary angle jitter`
  - `secondary spacing phase`
  - `secondary spacing phase jitter`
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
    - `secondary size jitter`
    - `secondary angle jitter`
    - `secondary spacing phase`
    - `secondary spacing phase jitter`
    - `secondary scatter`
    - `secondary scatter jitter`
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
  - `secondary size jitter`
  - `secondary angle jitter`
  - `secondary spacing phase`
  - `secondary spacing phase jitter`
  - `secondary scatter`
  - `secondary scatter jitter`
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
- `secondary image tip` 第三刀已完成：
  - imported-image 资产的 archive / resolve 条件不再绑定“当前正在使用 customRound”
  - 即使当前临时切到硬边圆 / 柔边圆 / 方形，隐藏的 imported-image 笔尖状态也会继续走统一资产链
  - 这保证了用户切回 `customRound` 后，导入图像笔尖不会因为保存工程 / 导出笔刷库 / 重开而丢失
- `secondary image tip` 第四刀方向已确认并开始落地：
  - 主笔尖与次笔尖共用一套持久化 `tip image library`
  - 由外部导入图片制作、并已保存为画笔的笔刷，无论是否重启软件，都必须恢复出此前导入图片的笔尖效果
  - `tip image library` 中未被任何画笔引用的图片，也必须独立保留并在重启后恢复
  - `tip image library` 在打开工程、导入画笔库、以及恢复持久化资料库时，重复 asset ID 不允许再简单丢弃后来的项；必须做稳妥归并，优先保住可恢复的 `maskData`
  - 恢复持久化画笔库时，如果此前有明确选中的画笔预设，当前笔刷也必须重新对齐到这支预设
  - 画笔库替换/追加导入时，当前笔刷在需要时也必须重新对齐到结果里的已选预设；如果导入资源里的 `tip image library` 不完整，必须从导入后的当前笔刷与预设里自动回填缺失的 imported tip 资料
  - 删除当前已选画笔预设时，如果画笔库自动切到了新的已选预设，当前笔刷也必须一起切过去
  - 自动化测试默认不允许再触碰真实 `Application Support/ArtFlex/brush-library.json`；测试运行中的默认画笔库持久化必须隔离到临时目录
  - `tip image library` 现在已接通 workspace / project / brush library 持久化，当前 UI 采用“点选卡片后按完成应用 / 拖拽排序 / 右上角删除 / Esc 退出资料库”
  - 资料库里的“导入图片…”现在支持一次多选多张；在资料库里导入时只会先批量入库，不会立刻改当前主/次笔尖
  - 删除规则已冻结为：如果某张资料库图片仍被当前主/次笔尖或任一画笔预设引用，则阻止删除
  - 资料库卡片现在会直接显示引用状态：`当前主笔尖 / 当前次笔尖 / N 个预设 / 未引用`；删除图标在被引用时直接禁用并给出更明确的来源提示
  - `undo / redo` 的 history 合并链必须保留当前 `tip image library`，不允许再把资料库回退成空库或局部库后写回磁盘
  - 当前“临时切走别的形状后仍保留隐藏 imported tip”只作为兼容语义存在，后续主入口以显式资料库为准
- `renderer-backed preview` 第一刀已完成：
  - 新增共享 `StageOneBrushPreviewRasterizer`
  - 当前会复用 `StageOneBrushRenderer` 的 `tipAlpha / dualTip combine / stable scatter` 公式生成小尺寸 preview image
  - 主笔尖卡片、次笔尖卡片、三格示意最终笔尖、画笔库斜线笔触预览，以及 `tip image library` 资料库卡片，当前都已切到这条共享 preview rasterizer
  - inspector 中残余的自定义笔尖静态预览，也已切到共享 stamp preview
  - 为避免拖慢启动与首屏布局，画笔库斜线预览不再为每个 stamp 重算一次 Dual Tip 组合图；小尺寸 preview 的 raster 分辨率也会按显示尺寸动态下调
  - `组合笔尖` 面板里的主笔尖 / 次笔尖 / 最终笔尖预览，当前也已拆成独立异步刷新；参数或图片变化时不会再等三张图串行算完才一起更新
  - 三格示意里的最终笔尖，当前即使工具或形状不在真实绘制 gate，或 `Dual Tip` 开关暂时未开启，也仍会继续显示组合图形示意，不再只剩“示意”文字
  - 画笔库斜线笔触预览的 Dual Tip 语义，当前也已与三格示意对齐：只要预设启用了 `Dual Tip`，就会显示组合笔触示意，不再要求先进入当前真实 gate
  - 画笔库右下角的小 glyph 预览，当前也已与组合预览语义对齐：`Dual Tip` 预设会优先显示组合笔尖，而不是只显示主笔尖
  - `secondary size jitter / 次笔尖大小抖动` 当前也已落地：会让 `secondary size ratio` 围绕当前中心值按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  - `secondary angle jitter / 次笔尖角度抖动` 当前也已落地：会让次笔尖角度围绕当前基准角度按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  - `secondary spacing phase / 次笔尖节距错相` 当前也已落地：会让次笔尖沿当前笔触方向相对主笔尖前后错开半个节距以内；真实落笔仍维持当前窄 gate
  - `secondary spacing phase jitter / 次笔尖节距错相抖动` 当前也已落地：会让节距错相围绕当前中心值按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  - `secondary scatter jitter / 次笔尖散布抖动` 当前也已落地：会让次笔尖散布量围绕当前 `secondary scatter` 中心值按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  - 参数化 `customRound` 在没有 `maskData` 时的小预览，当前也已优先走共享 preview rasterizer，不再默认退回手工渐变椭圆
  - `组合笔尖` 面板与 `编辑次笔尖…` 在高清 preview 尚未回填前，当前也会先显示同源的小型 rasterized 占位笔尖，不再只剩 spinner

### 0.8 画布视口交互当前冻结为“可锁定 + 优先围绕笔尖缩放”

已确认：

- 顶部工具栏当前提供 `锁定画布` 开关
- 开启后主画布不能缩放、旋转或移动
- 当前缩放默认优先围绕最近一次笔尖 / hover 所在的画布位置进行
- 如果当前没有可用笔尖 / hover 位置，则继续安全回退到旧的中心缩放行为

### 0.9 画笔库笔刷预设删除入口当前冻结为“右键删除”

已确认：

- 画笔库格子右上角不再放删除小叉
- 删除笔刷预设的主入口改为：先选中格子，再通过右键菜单删除
- 这样做是为了减少误点，不再回退到格子内的小面积删除热区

### 0.10 方案试探四宫格当前冻结为“默认 fit 视口 + 锁定视口”

已确认：

- 进入 `方案试探` 后，四宫格模式下的 4 个分支画布必须统一回到默认 fit 视口
- 四宫格模式下的分支画布不允许继续缩放、旋转或移动
- 因此四宫格不再继承主画布进入方案试探前的平移/旋转偏移
- 若切到“临时放大画布”单分支模式，可以恢复该分支的正常视口交互
- 从单分支模式返回四宫格时，必须再次统一回正并锁定

### 0.11 快照对比 2x2 预览当前冻结为“完整画布优先”

已确认：

- `快照对比` 右侧 2x2 预览位必须优先保证完整画布可见
- 不允许因卡片内部额外留白和高度估算偏差，让底部两格预览被裁掉
- 当前布局实现已按卡片总高度反推可用预览高度，并移除对比卡片里的多余纵向留白

### 0.12 无选区自由变形当前冻结为“预览与提交共用内容中心 pivot”

已确认：

### 0.13 `直线渐变 / 扇形渐变` 当前冻结为“都按重建主线维护，不回头救旧实现”

已确认：

- `直线渐变` 当前已恢复到 `油漆桶` 子菜单中，并采用重建后的单段 `A→B` 拖拽模型
- `直线渐变` 当前默认规则为：
  - 使用前景色
  - `A` 点之前保持实色
  - `A→B` 线性渐变到透明
  - `B` 点之后保持透明
  - 拖拽结束后自动确认，不依赖手动应用或 `Enter`
  - preview / commit 两条链都必须支持当前选区裁剪
- `扇形渐变` 当前也已恢复到 `油漆桶` 子菜单中，并采用重建后的“不可见 lasso 区域 + A 为圆心的径向渐变”模型
- `扇形渐变` 当前默认规则为：
  - 用户从 `A` 点出发画出一个会回到 `A` 的不可见 lasso 区域
  - 只在这个区域内生效
  - 渐变方向为从 `A` 向外的径向衰减
  - 拖拽结束后自动确认，不依赖手动应用或 `Enter`
  - preview / commit 两条链都必须支持当前选区裁剪
- `直线渐变 / 扇形渐变` 当前都必须受顶部工具栏 `不透明度` 滑块影响
- `直线渐变 / 扇形渐变` 当前都继续吃 `杂色` 滑块
- `直线渐变` 当前透明度分布已切到更柔和的 eased alpha 曲线，不再使用过陡的纯线性衰减
- `扇形渐变` 当前 renderer 已切到 GPU triangle-fan 填充主链
- `扇形渐变` 的杂色当前冻结为“以 A 点为中心的纯角度放射状条纹”，不允许回退成颗粒噪声、平行条纹或半径分层条纹
- 后续若继续调整这两个工具，默认继续走“重建主线”，不要回头补旧的二段式扇区角度实现

- 无选区 whole-layer `移动变形` 在预览阶段与最终提交阶段，都必须围绕被移动像素的内容中心旋转
- 不允许预览阶段临时退回整张画布中心旋转，再在按 `Enter` 确认后才变成正确结果
- 进入无选区自由变形时，whole-layer 内容 bounds 必须在第一帧预览前准备好；只要能同步拿到内容 bounds，就不允许再回退到 full canvas pivot
- 变形框与像素预览在旋转、缩放、移动过程中必须继续共读同一套 interaction bounds / pivot 真相源

### 0.14 套索填充当前冻结为“GPU local-mask 填色 + 起点放射杂色”

已确认：

- `lasso.fill` 当前已切到 GPU local-mask 填色链，不再按旧 CPU 热点路径维护
- `lasso.fill` 当前必须受顶部工具栏 `不透明度` 滑块影响
- `lasso.fill` 当前也继续吃 `杂色` 滑块
- `lasso.fill` 的杂色当前冻结为“以最初接触点为中心的放射状条纹”，不允许回退成平行线

### 0.15 默认新建画布与图层面板当前冻结为新基线

已确认：

- 新建画布当前必须默认生成 2 层：
  - 底部白色 `背景`
  - 顶部透明 `图层 2`
- 默认活动层必须是顶部透明层
- 新建画布时，顶部工具栏 `不透明度` 必须重置回 `100%`
- 图层面板底部按钮顺序当前冻结为：
  - `新建`
  - `复制`
  - `删除`
- 删除图层垃圾桶按钮必须保持红色，并固定在第三个位置
- `不透明度封顶` 右侧 3 个按钮的前两个顺序当前已对调，并按现状冻结

### 0.16 快照对比当前冻结为“GPU composite + preview prewarm”

已确认：

- `快照保存 / 快照对比` 当前保存快照时的可见图层合成，必须优先走 `StageOneCanvasPresenter` 的 GPU 合成链
- 不允许再把这条主链默认退回旧的 CPU `mergeVisible` 路径
- 保存快照后，已保存快照的大预览可以后台预热
- 进入 `快照对比` 时，也可以后台预热所有已保存快照的大预览
- 当前这条工具线先定住，不再主动继续扩大优化范围；后续若重开，只能在不改产品语义前提下继续收口

### 0.17 方案试探当前冻结为“GPU branch clone + GPU visible delta”

已确认：

- 进入 `方案试探` 时，不再先抓 CPU history snapshot 再把同一份 snapshot 恢复到 4 个分支
- 当前正确基线是：
  - 直接从当前 `WorkspaceState` 起步
  - 通过 GPU texture copy 克隆图层纹理到 4 个 branch
- `方案试探` 分支当前应共享一组 device-level Metal 服务，不再为 4 个 branch 重复初始化相同 renderer / serializer / sampler
- “应用于主画布”时，不再走 CPU per-pixel diff
- 当前正确基线是通过 `VisibleDeltaRenderer` 在 GPU 上生成可见差异，再落成单张 delta snapshot 追加回主画布
- 以上改动只允许优化性能主链，不允许改变四宫格 / 同步推进 / 差异推进 / 应用结果的产品语义

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
- 旧默认笔刷移除后，默认画笔库可以为空

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

### 5.7 默认画笔库不再保留 3 个 Dual Tip Phase 1 示例预设

已确认：

- 默认画笔库可以为空
- 那 3 个旧的 Dual Tip Phase 1 示例预设当前不再作为默认内置内容出现
- 旧持久化或导入资源如果还带着这 3 个 legacy demo preset ID，恢复链会主动过滤掉它们，避免再次回到用户画笔库里

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
