# ArtFlex Handoff

## 1. 项目一句话说明

ArtFlex 是旧版 `BrushCanvas` 的 Metal-first 重构版 macOS 绘图软件；当前一轮性能主线与小范围 UX/perf follow-up 已经收尾，项目已转入新功能开发。当前最新已完成并定住的小功能是 `绘画数据` 工具；较大的阶段性能力仍是 Dual Tip / 复合笔尖到 `invert`，并继续补齐了主/次笔尖来源语义、三格示意同源性收口，以及最近一轮“普通画笔卡顿 / 偶发不出笔 / 导入笔尖白边”修复。当前下一阶段范围已经确认，将继续推进共享 `tip image library` / `secondary image tip` 资产系统、`renderer-backed preview`、更复杂随机 / `spacing`、以及更宽真实绘制 gate，`smudge` 明确不在本轮范围内。`secondary image tip` 目前已完成三步：archive-backed 资产边界、imported-image 来源说明与 preview fit 的 model-driven 收口，以及共享 `tip image library` 当前基线；`renderer-backed preview` 第一刀也已落地；更复杂随机 / `spacing` 的前五刀 `secondary size jitter`、`secondary angle jitter`、`secondary spacing phase`、`secondary spacing phase jitter` 与 `secondary scatter jitter` 也已落地。

本轮范围判断已收缩：组合笔尖后续默认只继续推进“明显影响画笔效果”的能力，以及“预览 / 保存恢复 / 资料库稳定性”这类必做收口；轻微影响画笔效果的新随机 / `spacing` 小参数默认暂停。

当前画布视口交互也新增了一条独立小主线：顶部工具栏已加入 `锁定画布` 开关；开启后主画布不能缩放、旋转或移动。与此同时，缩放行为已从“固定围绕画布中心”改成“优先围绕最近一次笔尖 / hover 所在的画布位置”，以减少放大缩小时的找位成本。

`直线渐变 / 扇形渐变` 当前都已切到重建主线：入口恢复到 `油漆桶` 子菜单，`Shift + G` 可在 `油漆桶 / 直线渐变 / 扇形渐变` 之间切换。`直线渐变` 当前采用单段 `A→B` 拖拽、拉完自动确认的线性投影模型：A 前保持前景色实色，A→B 渐变到透明，B 后保持透明。`扇形渐变` 当前则按新产品定义重建为“以 A 为圆心、用户画出一个不可见 lasso 区域、并只在这个区域内生成径向渐变”的工具；同样是松手自动确认，不依赖手动应用或 `Enter`。两者当前都已支持 preview / commit 同源，以及当前选区裁剪。

`直线渐变 / 扇形渐变 / 套索填充` 当前都已接通顶部工具栏 `不透明度` 滑块；滑块值会直接乘进填充 alpha。三者当前也都继续吃 `杂色` 滑块；其中 `扇形渐变` 的杂色已收口为“以 A 点为中心的放射状条纹”，`套索填充` 的杂色则已收口为“以最初接触点为中心的放射状条纹”。

`套索填充` 当前已切到 GPU local-mask 填色链，不应再按旧文档里“selection.fill / lasso.fill 一起视为慢确认 deferred limitation”的结论理解。`油漆桶` 当前也已补了局部范围优化，并新增了只在油漆桶工具下生效的 `option + delete / option + forward delete` 当前选区填充快捷键。

默认新建画布当前已改成双图层基线：底部白色 `背景` + 顶部透明 `图层 2`；默认活动层固定为顶部透明层。新建画布时，顶部工具栏 `不透明度` 会重置回 `100%`。图层面板底部按钮顺序当前冻结为“新建 / 复制 / 删除”，删除按钮固定为红色并位于第三个位置；`不透明度封顶` 右侧 3 个按钮的前两个顺序也已对调。

当前图层也已新增 `锁定透明像素` 能力。这条功能按用户确认过的语义实现为当前图层级 `Alpha Lock`，不是 Photoshop 式图层对图层剪贴蒙版。图层行会显示 `α` 状态图标，`A` 用于切换当前活动图层。开启后，后续 `画笔 / 橡皮 / 涂抹 / 直线 / 直线渐变 / 扇形渐变 / 套索填充 / 普通选区填充与擦除 / 油漆桶` 都只能落在该图层原本已有非透明像素范围内。

当前还已新增一条轻量快捷 HUD 拾色器：按住 `Shift + Z` 会在笔尖附近弹出一个小型拾色器，松开即消失。HUD 目前会同步右侧主拾色器的主要滑块语义，并在下方映射画笔库前四格；如果前四格里已有画笔预设，HUD 下方对应小格子也会显示并可直接点击切换。当前实现保持轻量，不允许把这条功能重新拉回 CPU 热路径。

当前启动与新建画布的笔刷大小默认值也已固定为 `60`。这条默认值只影响当前 `toolSession` 的默认 brush，不改画笔库 preset 自身保存的 size。启动恢复画笔库时，可以恢复当前选中的 preset 高亮，但不允许自动用该 preset 覆盖当前 brush 默认值。

画笔库交互当前也有一条已冻结的小规则：笔刷预设不再通过格子右上角小叉删除；删除统一走“先选中格子，再右键菜单删除”，以减少误点。

`方案试探` 当前也新增了一条已冻结的视口规则：四宫格模式下，4 个分支画布会统一使用默认 fit 视口，并临时锁定视口交互；因此不再继承主画布进入方案试探前的平移/旋转偏移，也不会在四宫格里继续被移动。若临时切到“放大单画布”模式，则该分支会恢复正常视口交互；返回四宫格时再次统一回正并锁定。

`方案试探` 当前还新增了一条 GPU-first 性能基线：进入方案试探时，不再先抓 CPU history snapshot 再把同一份 snapshot 恢复到 4 个分支，而是直接从当前 `WorkspaceState` 起步，并通过 GPU texture copy 克隆图层纹理到 4 个 branch。与此同时，“应用于主画布”时也不再走 CPU per-pixel diff，而是通过新的 `VisibleDeltaRenderer` 在 GPU 上生成可见差异，再落成单张 delta snapshot 追加回主画布。这一刀只改性能主链，不改四宫格 / 同步推进 / 差异推进 / 应用结果的产品语义。

`快照对比` 当前也新增了一条已冻结的布局规则：右侧 2x2 对比卡片必须以完整画布为目标显示，不允许因为卡片内部额外留白和高度估算误差，让底部两格被裁掉。当前实现已按卡片总高度反推可用预览高度，并去掉对比卡片里不必要的纵向留白。

`快照对比` 当前还新增了一条 GPU-first 性能基线：保存快照时的可见图层合成已改走 `StageOneCanvasPresenter` 的 GPU 合成链，而不是旧的 CPU `mergeVisible` 路径；保存后和进入对比界面时，已保存快照的大预览会后台预热，减少首次进入对比和首次拖入对比位时的等待。当前这条工具线先定住，不再主动继续改动。

当前还新增了一个轻量 `绘画数据` 工具。左侧工具栏会提供 `绘画数据` 按钮，点击后弹出一个较大的 popover，而不是常驻侧板。面板当前显示：`总绘画时长 / 当前作品用时 / 今日绘画时长 / streak / 最近里程碑 / 过去 12 周热力图`。计时策略当前冻结为 `活跃创作计时 + 60 秒宽限期`：除 `画笔 / 橡皮 / 涂抹` 的真实笔触外，`油漆桶 / 直线 / 直线渐变 / 扇形渐变 / 套索填充 / 套索擦除 / 普通选区填充与删除 / 图形生成器 / 套索选区 / 矩形选区 / 椭圆选区` 也都会开始或继续计时；停下这些创作操作后 60 秒无新活动才正式结算。切图层、缩放、拖面板等非创作操作不计时；应用进入后台或窗口失去焦点会立即暂停，不再继续吃宽限期。

这条 `绘画数据` 功能当前刻意避开渲染热路径：不读纹理、不做快照、不碰 Metal 绘制主链。全局统计会写入 `Application Support/ArtFlex/drawing-stats.json`；当前作品时长则写进文档 metadata 的 `drawingStatsID + accumulatedPaintingTime`。因此用户即使先在未命名画布上画一段时间、之后才第一次保存，这段未保存时期的时长也会在保存后并入同一作品；下次打开继续画时，会继续沿这份累计时长往上加。`方案试探` 分支当前也会共享同一个 drawing stats service，避免四分支同步推进时把同一段创作时间重复记多次。

`移动变形` 当前也新增了一条已冻结的预览规则：无选区 whole-layer 自由变形在拖动预览阶段，就必须围绕被移动像素的内容中心旋转，不允许预览先按整张画布中心旋转、回车确认后才变对。当前预览链与最终提交链已经对齐到同一个内容中心 pivot。

本轮三个定点 follow-up 的最终状态是：

1. history retention policy：先接受
2. brush size indicator 的最小 fast-path 修复：先接受
3. 旧的 `selection.fill / lasso.fill` 合并性能结论已过时：当前 `lasso.fill` 已切到 GPU local-mask 填色链，不再按旧 deferred limitation 对待

当前这一轮性能优化与小范围 UX/perf follow-up 已收尾。下一阶段默认转入新功能开发，不要回头重开旧性能项目；如果未来必须重开填充性能问题，`selection.fill`、`lasso.fill` 与 `fillAtPoint` 必须分开看，不再沿用旧的合并 profiling 结论。

如果未来必须继续重开 `方案试探` 性能问题，先从这两条已经落地的 GPU-first 基线往下看，而不是回头把分支初始化或差异生成重新拉回 CPU：

1. 分支初始化：`WorkspaceState` + GPU texture copy clone
2. 应用主画布：GPU visible delta render

## 1.1 Dual Tip / 复合笔尖当前状态

### 已完成到 `invert` 并通过手测

- Phase 0 已完成：
  - 数据层 / UI 占位 / preset 与 project round-trip 已打通
  - 关闭时不影响旧绘制
- Phase 0.5 已完成：
  - UI 可读性、参数说明和可见性问题已修正
- Phase 1 已完成：
  - 真实绘制的最小闭环已接入：
    - 主笔尖：圆形
    - 次笔尖：圆形
    - 模式：`multiply`
    - 当前真正会影响绘制的参数：`strength`、`secondary size ratio`
- Phase 2 第一刀已完成：
  - `subtract` 已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- Phase 2 第二刀已完成：
  - `intersect` 已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- `scatter` 已完成：
  - 次笔尖相对主笔尖的稳定偏移已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- `angle offset` 已完成：
  - 次笔尖相对自身基准角度的额外旋转已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏
- `invert` 已完成：
  - 次笔尖反相已进入真实绘制
  - 手测通过
  - 基线和旧主绘制路径未被打坏

### 当前真实已支持的范围

- 当前真实已支持的组合模式：
  - `multiply`
  - `subtract`
  - `intersect`
- 当前真实已支持的附加参数 / 变换：
  - `scatter`
  - `angle offset`
  - `invert`
- 它们当前只在窄 gate 下真实生效：
  - 工具：`brush`、`eraser`
  - 主笔尖：`硬边圆`、`柔边圆`、`自定义笔尖`
  - 次笔尖：`硬边圆`、`柔边圆`、`自定义笔尖`
- 当前真正会影响绘制的参数包括：
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
  - 当主笔尖是 `自定义笔尖` 时：
    - `customTipMaskData`
    - `customTipSoftness`
    - `customTipRoundness`
    - `customTipAngleDegrees`
  - 当次笔尖是 `自定义笔尖` 时：
    - `customTipMaskData`
    - `customTipSoftness`
    - `customTipRoundness`
    - `customTipAngleDegrees`

### 当前来源编辑 / 保存层状态

- 主笔尖单一真相源接通已完成：
  - `组合笔尖…` 面板里的主笔尖现在只做“真实摘要 + 编辑入口”
  - `编辑主笔尖…` 会直接把用户带回现有 `笔尖形状设计` 主入口
  - 不存在第二套独立主笔尖状态
  - 当前自定义主笔尖已经进入 `multiply / subtract / intersect + scatter + angle offset + invert` 的真实绘制
- 次笔尖来源接通已完成：
  - `SecondaryTipDescriptor` 现在已扩成 tip-source 安全子集：
    - `tipShape`
    - `customTipMaskData`
    - `customTipSoftness`
    - `customTipRoundness`
    - `customTipAngleDegrees`
  - `组合笔尖…` 面板里现在能看到当前次笔尖摘要
  - `编辑次笔尖…` 会打开独立子面板，复用现有笔尖遮罩编辑画布
  - 次笔尖自定义遮罩和参数已经能保存到 preset / project
  - 当前自定义次笔尖已经进入 `multiply / subtract / intersect + scatter + angle offset + invert` 的真实绘制
  - 当前三格示意也已经按自定义主/次笔尖的真实遮罩关系显示，不再退回柔边圆近似
  - 当前三格示意已调整为高对比显示，默认使用黑底白笔触，更容易辨认主/次/最终组合关系
  - 主/次笔尖当前都已补齐来源语义：
    - `procedural`
    - `customMask`
    - `importedImage`
  - Dual Tip 面板摘要现在能稳定区分“自定义笔尖”和“导入图像笔尖”
- 但要注意：
  - 这不代表所有次笔尖来源都已进入真实绘制
  - `方形` 次笔尖当前仍然只是编辑 / 保存，真实绘制仍会回旧 gate

### 当前仍未支持 / 尚未接入真实绘制

- `renderer-backed preview` 的剩余 rollout
- 共享 `tip image library` 的剩余管理 / 生命周期体验
- 更复杂随机 / spacing 系统
- 更宽真实绘制 gate
- `smudge` 路径

其中除 `smudge` 外，其余四项已确认纳入下一阶段开发范围；`smudge` 继续排除在本轮范围外。需要注意：`secondary image tip` 目前虽然已经接通 project package / brush library archive 的 `tipImageAssets`、来源摘要 / preview fit 的模型语义驱动，以及共享 `tip image library` 第一刀，但完整管理体验和 preview/renderer 终态都还没做完。以上这些现在最多只是局部数据 / UI / persistence 层存在，不代表已经进入最终形态真实绘制。

### 当前用户体验状态

- Dual Tip 的启用开关和当前已接入参数现在已经能真实影响落笔
- `subtract`、`intersect`、`scatter`、`angle offset`、`invert` 现在都已经进入真实绘制
- `组合笔尖…` popover 已补齐可解释性：
  - 主笔尖
  - 次笔尖
  - 最终笔尖
  - `multiply` 当前是“调制 / 压缩”逻辑
  - `subtract` 当前是“挖掉 / 削减”逻辑
  - `intersect` 当前是“只保留交集 / 收口”逻辑
  - `scatter` 当前是“次笔尖相对主笔尖的稳定偏移”逻辑
  - `angle offset` 当前是“次笔尖相对自身基准角度的额外旋转”逻辑
  - `invert` 当前是“次笔尖 coverage 反相后再参与组合”逻辑
- `组合笔尖…` 面板里的主笔尖现在与真实绘制主笔尖保持同一真相源
- 次笔尖现在不再只是形状 picker，而是已经能独立编辑和保存来源
- 自定义主笔尖现在也已经能进入当前 `multiply / subtract / intersect + scatter + angle offset + invert` 真实绘制
- 自定义次笔尖现在不只可编辑 / 可保存，也已经能进入当前 `multiply / subtract / intersect + scatter + angle offset + invert` 真实绘制
- 三格示意现在已经能按自定义主/次笔尖的真实形状示意最终组合结果
- 三格示意的视觉对比已收口到高对比样式，当前默认是黑底白笔触
- 主/次笔尖的 `importedImage / customMask / procedural` 来源语义现在已经能保存、恢复并在 UI 摘要中稳定区分
- imported-image 主/次笔尖现在还会在 UI 中显示当前导入来源和原始像素尺寸摘要
- imported-image preview fit 现在由模型语义驱动，不再依赖“当前会话”临时 flag
- 主笔尖与次笔尖现在共用一套 `tip image library` 入口
- `tip image library` 会跟随 workspace / project / brush library 一起保存和恢复；已保存为画笔的 imported-image 笔刷，重启后再次点击仍会恢复原图片笔尖效果
- `tip image library` 中未被任何画笔引用的图片，现在也会独立保留并在重启后恢复，不会因为“当前没在用”而丢失
- `tip image library` 当前在打开工程、导入画笔库、以及恢复持久化资料库时，也会按重复 asset ID 做更稳的归并：不再简单丢弃后来的重复项；如果后来的项带着缺失的 `maskData` 或更可靠的资产内容，会补进现有资料库项
- 恢复持久化画笔库时，如果此前有明确选中的画笔预设，当前笔刷现在也会重新对齐到这支预设，不再出现“预设高亮已恢复，但当前笔刷仍停在旧默认值”的分离状态
- 画笔库替换/追加导入时，当前笔刷现在也会在需要时重新对齐到结果里的已选预设；如果导入资源里的 `tip image library` 不完整，也会从导入后的当前笔刷与预设里自动回填缺失的 imported tip 资料
- 删除当前已选画笔预设时，如果画笔库自动切到了新的已选预设，当前笔刷现在也会一起切过去，不再留下“画笔库选中已变、当前笔刷仍停在已删预设”的分离状态
- 自动化测试当前也已默认使用隔离的临时画笔库持久化，不再意外碰到真实 `Application Support/ArtFlex/brush-library.json`
- `undo / redo` 的 history 合并链现在会保留 `tip image library`，不会再把资料库误掉成空库或局部库后写回磁盘
- `tip image library` 卡片现在会直接显示引用状态：
  - `当前主笔尖`
  - `当前次笔尖`
  - `N 个预设`
  - `未引用`
- 如果某张资料库图片仍被当前主/次笔尖或某个画笔预设引用，删除图标会直接禁用，并显示更明确的来源提示
- 当前新增了共享 `StageOneBrushPreviewRasterizer`，会复用 `StageOneBrushRenderer` 的 `tipAlpha / dualTip combine / stable scatter` 公式来生成小尺寸 preview image
- 主笔尖卡片、次笔尖卡片、三格示意最终笔尖、画笔库斜线笔触预览，以及 `tip image library` 资料库卡片，当前都已切到这条共享 preview 链
- inspector 里残余的自定义笔尖静态预览，也已切到共享 stamp preview，不再直接画旧的 mask 直出图
- 画笔库斜线预览不再为每个 stamp 重算一次 Dual Tip 组合图；小尺寸 preview 的 raster 分辨率也会按显示尺寸动态下调，避免拖慢启动和首屏布局
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
- `编辑次笔尖…` 的“次笔尖形状”菜单项现在也会显示同源小预览，不再只剩文字标签
- 笔尖形状设计区域里的黑白 mask 预览，当前也已复用共享 preview rasterizer 的 resample / crop / cache 链，不再单独维护一套小图生成逻辑
- `编辑次笔尖…` 顶部概览卡片，当前也已切到独立异步 preview；换图或调参数时不会再被同步 `stampImage` 阻塞
- 画笔库小 glyph、笔尖静态小预览、资料库卡片、`编辑次笔尖…` 形状菜单，以及 `组合笔尖` / `编辑次笔尖…` 的异步 preview 与占位图，当前都已切到 best-effort shared rasterizer：如果高清图或 composite 图一时拿不到，会先退同源低分辨率 raster preview，而不是再退回手工 `Circle / RadialGradient` 示意
- 画笔库笔触 preview 当前已改成模拟由轻到重的压感变化，因此有无压力变化、以及压力变化强不强，会比原来的单一力度预览更容易辨认
- `组合笔尖` 面板当前已再次瘦身：顶部 gate 徽标、支持 chip、主/次笔尖说明句、三格示意说明字都已去掉，默认只保留控制、必要状态和图形示意
- `编辑次笔尖…` 面板当前也已按同一原则瘦身：顶部说明句、形状说明、画布说明，以及各 slider 的 helper text 都已去掉，只保留标题、控件、预览和按钮
- 资料库当前 UI 已切到：
  - 资料库里的“导入图片…”支持一次多选多张
  - 在资料库里导入时只会先批量入库，不会立刻改当前笔尖
  - 点选卡片后按“完成”应用
  - 拖拽排序
  - 右上角删除图标
  - `Esc` 退出资料库
- imported-image 主/次笔尖即使暂时切到其他笔尖形状，保存 / 重开后也仍会保留隐藏的图像笔尖资产状态；这现在作为兼容行为保留，但后续主入口将以显式资料库为准
- 最近一轮回归已修复：
  - 编辑组合笔尖后普通画笔卡顿
  - 偶发画不出笔触
  - 导入图像笔尖后的白边
- 当前 Dual Tip 已从概念验证进入“可用阶段”
- 当前已可用来做基础“收口 / 压缩型”“挖空 / 削减型”“交集 / 收口型”笔刷，也能开始体验异形次笔尖的挖空、调制、交集、稳定偏移、角度偏移与反相效果
- 默认画笔库现在不再附带 3 个 Dual Tip Phase 1 示例预设；旧持久化或导入链若还带着这 3 个 legacy demo preset ID，也会在恢复时过滤掉

### 下一步建议

- 下一阶段范围已经确认，不再停留在“只观察、不继续扩”的状态
- 推荐按以下顺序推进：
  1. 继续推进 `renderer-backed preview` 的剩余 rollout
  2. 收尾共享 `tip image library` 的管理 / 生命周期体验
  3. 更宽真实绘制 gate
- `smudge` 不在当前确认范围
- 其中：
  - 更复杂随机 / 变换能力与更宽 gate 的风险仍然更高，应拆成独立小刀推进

### 风险边界

- 不要重新污染旧绘制路径
- 关闭 Dual Tip 时，必须继续和旧版行为一致
- 开启但不满足当前已接入条件时，必须继续回旧路径
- 不要把“来源接通”和“真实绘制扩范围”绑在一起
- 当前自定义主/次笔尖虽然都已经进入 `multiply / subtract / intersect + scatter + angle offset + invert` 的真实绘制，但当前代码基线的 gate 仍是窄范围；后续即使继续扩大，也必须逐项验证：
  - 当前真实已接入模式是 `multiply / subtract / intersect`
  - 当前真实已接入的附加参数包含 `scatter / angle offset / invert`
  - 主笔尖当前只限圆形与自定义笔尖
  - 工具继续只限 `brush / eraser`
- 不要在未验证前一次性扩很多模式
- 不要把当前 Dual Tip 直接扩成“全家桶”实现

## 2. 当前进展

### 已完成的主线工作

- 多图层文档、图层排序/可见性/锁定/透明度、工程保存/打开主链已建立
- 选区、自由变形、吸管、油漆桶、画笔、橡皮擦、涂抹等主工具链已接通
- history 主干已经从“全量快照 + 高风险 partial fallback”收口到更安全的 dirty history pilot
- serializer / queue / staging 已完成一轮收口，不再到处随手自建 command queue
- smudge 已完成两轮专项治理，已经去掉最大的 full-size copy/allocation 坑

### 已验证通过的优化

- dirty history pilot 已落到：
  - `brush.commit`
  - `eraser.commit`
  - `applyPixelOperation`
  - `fillAtPoint`
- `undo / redo` 的对称 dirty current capture 已对上面这些 dirty entry 生效
- dirty restore 继续 fail-closed
- dirty restore 失败时 `workspace` 与 `undo/redo` 栈保持不变
- 不允许 `full reset + partial snapshots` fallback
- serializer 共享 `MetalDeviceContext.commandQueue` 和 staging pool 的收口已完成
- smudge 不再发生 per-packet full-size source texture allocation / copy
- performance closure audit 已完成，并已固化在 [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- `selection.fill / lasso.fill` 已完成一轮最小优化：
  - `applyPixelOperation` 不再为像素改写先生成整张画布级 mask 副本
  - `mutateSelectionPixels` 已改成局部 mask + 专用 `fill/clear` 内循环
  - `pixelMutation` 已明显下降
- `selection.fill / lasso.fill` 已完成第二轮最小优化：
  - `rasterizedSelectionMaskRegionBytes(...)` 去掉了 Swift 逐像素结果拷贝，改成 row copy
  - 局部 rasterize 不再为每个 polygon 构建一份平移后的点数组
  - `maskPreparation` 已从约 `700 ms` 量级降到约 `16 ms`
- history retention policy 已调整到更贴近当前产品真实场景：
  - `maxEntries = 24`
  - `maxResidentBytes = 768 MiB`
- brush size indicator 延迟已完成最小 fast-path 修复

### 哪些性能主线已经正式收口

以下主线本轮已经明确收口，不要在新线程里默认重开：

- dirty history 主干试点
- `brush.commit`
- `eraser.commit`
- `applyPixelOperation`
- `fillAtPoint`
- `undo / redo` 对称 dirty current capture
- history 事务性失败保护
- smudge 最大的 full-size copy/allocation 问题
- serializer / queue / staging 收口
- performance closure audit

## 3. 已完成并确认有效的内容

### dirty history pilot 当前落地范围

- 入口：
  - [captureBrushCommitCheckpoint(for:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5134)
  - [checkpointHistoryIfPossible(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5048)
  - [fillAtPoint(_:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L1168)
  - [applyPixelOperation(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5266)
- history mode：
  - `full`
  - `inPlaceChangedLayers(topologySignature, changedLayerIDs)`
- 当前 dirty pilot 只覆盖：
  - `brush.commit`
  - `eraser.commit`
  - `applyPixelOperation`
  - `fillAtPoint`
- 不要把它误读成“通用 partial history 已经重新开放”

### smudge 当前状态

- smudge 已不再做 per-packet full-size source texture allocation
- smudge 已不再做 per-packet full-size snapshot blit
- 当前更深层的 smudge 优化是 deferred 项，不是当前任务

### serializer / queue / staging 当前状态

- `LayerTextureSerializer` 已复用共享 `MetalDeviceContext.commandQueue`
- staging pool 已有同步保护、budget、trim/purge
- `copyTextureAsync` 被限制在 live-session 初始化路径使用
- generic `copyTexture / clearTexture` 仍保持同步安全语义

### fail-closed restore / 事务性失败保护

- dirty restore 前必须验证 `topologySignature`
- 不匹配时直接 fail-closed
- 不允许 fallback 到 `full reset + partial snapshots`
- `undo / redo` 不允许先 pop/append 再 restore
- dirty restore 失败时：
  - `workspace` 不变
  - `undoStack` 不变
  - `redoStack` 不变

### performance closure audit

- 已完成
- 已固化文档：
  - [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- 新线程不要再把它当成当前任务重复做一遍

## 4. 手测结果摘要

以下结论基于当前代码树的定向回归测试、最近一轮核心功能手测记录和针对性 profiling。

### 未发现本轮性能优化破坏已有核心功能

- 未发现 dirty history pilot 破坏已有 undo/redo 正确性
- 未发现 dirty restore 破坏未变更图层内容
- 未发现 serializer / queue / staging 收口后引入新的时序错误
- 未发现 smudge 两轮专项优化破坏当前输出一致性
- 核心功能手测未见本轮优化导致的明显功能破坏

### 通过项

- `brush.commit / eraser.commit / applyPixelOperation / fillAtPoint` 的 dirty history pilot 已通过定向测试
- `undo / redo` 对称 dirty current capture 已通过定向测试
- topology fence 前后链条正确
- hidden / locked / opacity 非变更 layer 内容保持正确
- transaction failure 保护测试通过
- brush size local preview 不会被旧 model 值回踩
- 旧的 `selection.fill / lasso.fill` 合并热点记录当前只保留为历史背景；其中 `lasso.fill` 现已切到 GPU local-mask 填色链，不再按这组旧数值理解

### 存疑项

- 连续撤销的体感仍可能有卡顿，需要继续按真实文档手感观察
- full `swift test` 仍未拿到最终收口结论；`PerformanceAuditFactTests` 长跑不能直接拿来宣称完整通过

### 不适用项

- 多文件同时打开 / 多文档窗口链目前不是当前项目的主要能力，不属于本轮验证范围

## 5. 当前明确存在的问题

当前仍保留但不再作为当前线程主任务的问题是：

1. history retention policy 已按典型 `3000 px` 场景提升，但连续撤销体感仍有卡顿，仍需按真实文档继续验证
2. brush size indicator / 笔头缩放响应仍有延迟风险；这是 UI 指示器延迟，不是笔迹延迟
3. 旧的 `selection.fill / lasso.fill` 合并慢确认结论当前已失效；`lasso.fill` 已切到 GPU local-mask 填色链，如未来还要重开填充性能，应单独评估 `selection.fill`

### 这三项的当前事实

- history retention 当前默认值已改到：
  - `maxEntries = 24`
  - `maxResidentBytes = 768 MiB`
  - 目标是典型 `3000 px` dirty 文档场景下至少约 `20` 步撤销
- brush size indicator 延迟目前定位在：
  - `updateNSView(...)` 的 brush-size-only 更新仍会走一段主线程重路径
  - 不是笔迹渲染本身慢
- `selection.fill / lasso.fill` 的旧热点分解结果当前只保留为历史背景：
  - 第一轮优化前：
    - `selection.fill`: `historyCheckpoint=33.918ms`, `maskPreparation=700.719ms`, `snapshot=29.861ms`, `pixelMutation=1238.055ms`, `restore=9.765ms`, `uiConfirm=0.094ms`, `total=2014.932ms`
    - `lasso.fill`: `historyCheckpoint=30.582ms`, `maskPreparation=697.487ms`, `snapshot=31.106ms`, `pixelMutation=1237.757ms`, `restore=12.771ms`, `uiConfirm=0.100ms`, `total=2011.204ms`
  - 第一轮优化后 / 第二轮优化前：
    - `selection.fill`: `historyCheckpoint=34.109ms`, `maskPreparation=705.433ms`, `snapshot=32.951ms`, `pixelMutation=862.349ms`, `restore=6.470ms`, `uiConfirm=0.095ms`, `total=1644.104ms`
    - `lasso.fill`: `historyCheckpoint=30.638ms`, `maskPreparation=703.275ms`, `snapshot=30.895ms`, `pixelMutation=844.989ms`, `restore=6.350ms`, `uiConfirm=0.099ms`, `total=1617.534ms`
  - 第二轮优化后：
    - `selection.fill`: `historyCheckpoint=33.732ms`, `maskPreparation=16.776ms`, `snapshot=30.829ms`, `pixelMutation=890.757ms`, `restore=9.139ms`, `uiConfirm=0.254ms`, `total=985.899ms`
    - `lasso.fill`: `historyCheckpoint=33.158ms`, `maskPreparation=15.894ms`, `snapshot=31.270ms`, `pixelMutation=877.034ms`, `restore=6.263ms`, `uiConfirm=0.097ms`, `total=964.992ms`
  - 验证收口补充：
    - `swift test --skip PerformanceAuditFactTests`：通过（`107` tests / `18` suites）
    - `swift test --filter PerformanceAuditFactTests/selectionFillProfilingBreakdown`：通过
    - full `swift test`：本轮未拿到最终 passed 结论，不能宣称完整通过
  - 当前结论：
    - `maskPreparation` 已不再是主要剩余热点
    - 这些数值当前只对旧的 `selection.fill` 路径仍有一定参考价值
    - `lasso.fill` 当前已切到 GPU local-mask 填色链，不再沿用这组旧 profiling 结论

## 6. 下一阶段默认任务

新的对话线程默认不再从性能优化开始，而是先看交接文档后直接进入新功能定义与实现：

1. 新线程默认先看 [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md) 和 [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
2. 当前默认任务应切换到新功能开发，不再回头重打旧性能项目
3. 新功能开发前只需把当前状态作为基线；除非引入新的 P0 / P1 回归，否则不要重开这一轮性能项目

## 7. 这三项任务的硬约束

- 不重开通用 partial history
- 不改 dirty restore fail-closed 语义
- 不引入 `full reset + partial snapshots` fallback
- 不碰 trim / smudge 主线
- 不重复做 performance closure audit
- 不要扩大范围到新的大重构
- 不要再把 `lasso.fill` 视为旧的 deferred known limitation
- 如果未来必须重开填充性能问题，`selection.fill`、`lasso.fill` 与 `fillAtPoint` 必须分开看

## 8. 关键文件与入口

### history / dirty pilot

- [HistoryController.swift](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift)
  - [captureCheckpoint(...)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97)
  - [undo()](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L121)
  - [redo()](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L141)
  - [restore(entry:)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L258)
  - [restoreWithFullReset(...)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L292)
  - [restoreInPlaceChangedLayers(...)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L313)
  - [currentEntryCaptureMode(for:)](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L336)

### brush size indicator

- [WindowKeyboardBridge.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WindowKeyboardBridge.swift)
  - [KeyboardBridgeView.keyDown(with:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WindowKeyboardBridge.swift#L40)
- [MetalCanvasHost.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift)
  - [updateNSView(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift#L129)
  - [StrokeCaptureMTKView.keyDown(with:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift#L1044)
  - [previewAdjustBrushSize(by:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/Canvas/MetalCanvasHost.swift#L1751)

### selection.fill / lasso.fill（历史背景 + 当前分流）

- [WorkspaceViewModel.swift](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift)
  - [fillAtPoint(_:)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L1168)
  - [fillSelectionContents()](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L3625)
  - [fillLassoContents()](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L3638)
  - [eraseLassoContents()](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L3974)
  - [applyPixelOperation(...)](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5266)
- 当前 inspection 结论：
  - `selection.fill` 的 profiling 场景里，刚 commit 的 lasso 选区通常还是 `immediateShape(.lasso)`，不会立刻命中 `maskData` 快路径
  - `maskPreparation` 的第二轮热点主要不是 history，也不是 committed `maskData` row copy，而是局部 rasterize 后的 Swift 级结果拷贝和点重映射
  - 当前已把这两块压掉，局部 rasterize 成本已明显下降
  - 以上 inspection 结论当前主要只对旧的 `selection.fill` 路径仍有参考价值
  - `lasso.fill` 当前已切到 GPU local-mask 填色链，并已接通顶部 `不透明度` 与起点放射杂色语义，不再按上面这套旧路径理解

### 基线与 profiling

- [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- [PerformanceAuditFactTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift)
- [HistoryControllerTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift)
- [WorkspaceViewModelPixelHistoryTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift)
- [BrushInputDispatchTests.swift](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/BrushInputDispatchTests.swift)

## 9. 验证方式

后续改动完成后，至少要跑：

- `swift build`
- `swift test --filter HistoryControllerTests`
- `swift test --filter WorkspaceViewModelPixelHistoryTests`
- `swift test --filter BrushInputDispatchTests`
- `swift test --filter PerformanceAuditFactTests`
- 必要时全量 `swift test`

后续手测至少要看：

- 连续 `undo / redo` 体感是否仍卡
- `[` `]` 调笔刷大小时，笔头圈尺寸是否即时变化
- `selection.fill` 点击确认后的主观等待时间；`lasso.fill` 需按新的 GPU local-mask 基线单独观察
- dirty history 路径下不同图层交替操作后，未变更图层是否保持正确

## 10. Stop line

- performance 主线已经收口
- 后续只允许做定点 UX/perf follow-up
- 没有新的 P0 / P1 回归，不准重开整轮性能项目
