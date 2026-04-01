# CURRENT_TASK

## 1. 当前任务

- 当前任务已切换为：填充 / 渐变工具、快照 / 方案试探与默认 UX 基线收口；Dual Tip 当前冻结，除非有明确新需求或实际 bug，不再主动改动
- 当前另有一条非 Dual Tip 小主线：画布视口交互已开始补功能，当前已纳入“锁定画布（禁缩放/禁旋转/禁移动）”和“按笔尖位置缩放”的实现
- `直线渐变 / 扇形渐变` 当前都已切到重建主线：入口恢复到 `油漆桶` 子菜单，`Shift + G` 可在 `油漆桶 / 直线渐变 / 扇形渐变` 之间切换；其中 `直线渐变` 已按单段 `A→B` 拖拽、自动确认和选区适配重做，`扇形渐变` 则已按“不可见 lasso 区域 + A 为圆心的径向渐变 + 松手自动确认”重建
- `直线渐变 / 扇形渐变 / 套索填充` 当前都已接通顶部工具栏 `不透明度` 滑块；滑块往左时填充更透明，往右时更不透明
- `直线渐变 / 扇形渐变 / 套索填充` 当前都继续吃 `杂色` 滑块；其中 `扇形渐变` 与 `套索填充` 的杂色当前都已收口为“以起点为中心的放射状条纹”，不再是平行条纹或颗粒噪声
- `套索填充` 当前已切到 GPU local-mask 填色链，并复用了放射状杂色语义；`油漆桶` 当前也已做局部范围优化，并新增了只在油漆桶工具下生效的 `option + delete / option + forward delete` 当前选区填充快捷键
- `快照对比` 当前已切到更稳定的 GPU-first 基线：保存快照时的可见图层合成已改走 `StageOneCanvasPresenter` 的 GPU 合成链，大预览会在保存后与进入对比界面时后台预热；当前这条工具线先定住，不再主动继续改
- `方案试探` 当前已切到更轻的 GPU-first 基线：进入方案试探时不再先抓 CPU history snapshot 再把同一份快照恢复到 4 个分支，而是直接从当前 workspace state 起步，并通过 GPU texture copy 克隆分支图层；“应用于主画布”当前也不再做 CPU per-pixel diff，而是改成 GPU visible delta render 后再生成单张 delta snapshot
- 默认新建画布当前已改成双图层基线：底部白色 `背景` + 顶部透明 `图层 2`；默认活动层为顶部透明层，顶部工具栏 `不透明度` 也会在新建时重置为 `100%`
- 图层面板当前默认基线也已更新：底部按钮顺序固定为“新建 / 复制 / 删除”，删除图层垃圾桶按钮固定为红色；`不透明度封顶` 右侧 3 个按钮的前两个顺序也已对调
- 当前范围已重新收缩：后续只继续做“明显影响画笔效果”或“明显影响保存 / 预览一致性 / 资料稳定性”的事项；轻微影响画笔效果的新随机 / `spacing` 小参数默认暂停
- 当前已完成的阶段性刀法：
  - `secondary image tip` 独立资产系统已先落到 archive / persistence 边界
  - imported-image 的来源说明与 preview fit 已改成 model-driven：主/次笔尖现在会保存导入来源信息，preview 不再依赖会话态 flag
  - imported-image 即使当前临时切到其他笔尖形状，也会继续走统一资产归档与恢复链；切回 `customRound` 不会因为保存 / 重开而丢失
  - 共享 `tip image library` 当前基线已落地：主/次笔尖共用一套资料库，已接通 workspace / project / brush library 持久化；未被任何画笔引用的资料库图片也会随重启恢复
  - `tip image library` 当前对重复 asset ID 的合并已补强：打开工程、导入画笔库、恢复持久化资料库时，不再简单丢弃后来的重复项；如果后来的项带着缺失的 `maskData` 或更可靠的资产内容，会补进现有资料库项
  - 持久化画笔库恢复时，若此前有明确选中的画笔预设，当前笔刷也会一并重新对齐到这支预设，不再出现“预设高亮已恢复，但当前笔刷还是旧默认值”的分离状态
  - 画笔库替换/追加导入时，当前笔刷现在也会在需要时重新对齐到结果里的已选预设；如果导入资源里的 `tip image library` 不完整，也会从导入后的当前笔刷与预设里自动回填缺失的 imported tip 资料
  - 删除当前已选画笔预设时，如果画笔库自动切到了新的已选预设，当前笔刷也会一起切过去，不再留下“画笔库选中已变、当前笔刷仍停在已删预设”的分离状态
  - `tip image library` 的引用状态现在已可视化：卡片会区分 `当前主笔尖 / 当前次笔尖 / N 个预设 / 未引用`，被引用时删除图标会直接禁用，并带更明确的来源提示
  - `tip image library` 资料库面板现在支持批量导入图片；在资料库里导入只会批量入库，不会立刻改当前笔尖，仍需点选后按“完成”应用
  - `undo / redo` 的 history 合并链现在会保留 `tip image library`，不会再把资料库误掉成空库或局部库后写回磁盘
  - 默认画笔库不再附带 3 个 Dual Tip Phase 1 示例预设；旧持久化或导入链若还带着这 3 个 legacy demo preset ID，也会在恢复时被过滤掉
  - 无选区 whole-layer `移动变形` 的旋转预览当前已收口：预览阶段与最终提交都围绕被移动像素的内容中心旋转，不再在拖动预览时临时退回整张画布中心
  - `renderer-backed preview` 第一刀已落地：新增共享 `StageOneBrushPreviewRasterizer`，主/次笔尖卡片、三格示意最终笔尖、画笔库斜线笔触预览、以及 `tip image library` 资料库卡片都已切到同一套 stamp rasterizer
  - `renderer-backed preview` 第一刀的启动成本已补收口：画笔库斜线预览不再为每个 stamp 重算 Dual Tip 组合图，小尺寸 preview 分辨率也会按显示尺寸动态下调
  - `组合笔尖` 面板里的主笔尖 / 次笔尖 / 最终笔尖预览现在已拆成独立异步刷新；参数或图片变化时不会再等三张图串行算完才一起更新
  - 三格示意里的最终笔尖，现在即使当前工具或形状不在真实绘制 gate，或 `Dual Tip` 开关暂时未开启，也仍会显示组合图形示意，不再只剩“示意”文字
  - 画笔库斜线笔触预览的 Dual Tip 语义也已与三格示意对齐：只要该预设启用了 `Dual Tip`，就会显示组合笔触示意，不再要求先进入当前真实 gate
  - 画笔库右下角的小 glyph 预览现在也已与组合预览语义对齐：`Dual Tip` 预设会优先显示组合笔尖，而不是只显示主笔尖
  - 更复杂随机 / `spacing` 前五刀已落地：新增 `secondary size jitter / 次笔尖大小抖动`、`secondary angle jitter / 次笔尖角度抖动`、`secondary spacing phase / 次笔尖节距错相`、`secondary spacing phase jitter / 次笔尖节距错相抖动` 与 `secondary scatter jitter / 次笔尖散布抖动`，可让次笔尖大小比例、角度，以及沿笔触方向的相位位移与散布量围绕当前中心值安全变化
  - inspector 中残余的自定义笔尖静态预览也已改成走共享 stamp preview
  - 笔尖形状设计区域里的黑白 mask 预览，现在也已复用共享 preview rasterizer 的 resample / crop / cache 链，不再单独维护一套小图生成逻辑
  - `编辑次笔尖…` 顶部概览卡片也已切到独立异步 preview；换图或调参数时不会再被同步 `stampImage` 阻塞
  - `组合笔尖` 面板当前已继续收成“简洁优先”版：主/次笔尖预览直接并入三格示意前两格，格子下方直接提供编辑按钮；不再保留重复的“笔尖概览”区
  - `组合笔尖` 面板当前不再用“进阶参数”折叠隐藏选项；参数区默认全部展开，popover 也已放大并压紧间距
  - `编辑次笔尖…` 顶部预览当前已改成黑底白图案的高对比样式
- 当前已确认纳入本轮范围：
  - 完整 `secondary image tip` 独立资产系统
  - 更严格 `renderer-backed preview`
  - 更复杂随机 / spacing 系统
  - 更宽真实绘制 gate
- 当前已新增确认的产品规则：
  - 由外部导入图片制作、并已保存为画笔的笔刷，无论是否重启软件，都必须能恢复出此前导入图片的笔尖效果
  - 主笔尖和次笔尖共用一套持久化 `tip image library`
  - `tip image library` 中未被任何画笔引用的图片，也必须独立保留，不能因为未使用而在重启后消失
  - `tip image library` 中已被画笔引用的图片当前禁止删除
  - `组合笔尖` 面板后续按“简洁优先”维持：默认只保留控制、必要状态和示意图，不再回加大段说明性文字；三格示意优先承担主/次笔尖预览，不再回加重复概览区
  - `直线渐变 / 扇形渐变 / 套索填充` 当前都必须受顶部工具栏 `不透明度` 滑块影响，不再各自维护独立的不透明度默认值
  - `扇形渐变` 的杂色当前必须维持为“以 A 点为中心的放射状条纹”；`套索填充` 的杂色当前必须维持为“以最初接触点为中心的放射状条纹”
  - 新建画布当前必须默认生成 2 层：底部白色 `背景` + 顶部透明 `图层 2`；默认活动层必须是顶部透明层
  - 图层面板底部按钮顺序当前冻结为“新建 / 复制 / 删除”；删除按钮保持红色并固定在第三个位置
- `smudge` 明确不在本轮 Dual Tip 范围
- 当前不是性能优化阶段
- `快照对比` 与 `方案试探` 这两条性能线当前都已收一刀；除非再发现新的实际卡顿 / 回归，否则不要继续主动扩大优化范围
- 新线程默认先看 [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md) 和 [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)

## 2. 当前阶段约束

- 不要把当前线程重新拉回性能优化
- 不要把本轮四项范围一次性打成单次大扩展
- 不要默认把“来源已接通”误读成“所有参数和来源都已进入真实绘制”
- 真实绘制 gate 的扩大必须逐项验证，不要一次性放开到所有工具 / 主次笔尖类型 / 模式
- 当前需要继续扩 Dual Tip，但必须按分阶段顺序推进
- `smudge` 继续排除在本轮范围外
- 不要再按旧文档把 `lasso.fill` 视为 deferred known limitation；当前 `lasso.fill` 已切到 GPU local-mask 填色链
- 除非新功能开发中引入新的 P0 / P1 回归，否则不要重开这一轮性能项目

## 3. 当前推荐顺序

1. 必做：收尾 `renderer-backed preview` 的高感知一致性项
2. 必做：收尾共享 `tip image library` / `secondary image tip` 的稳定性与生命周期体验
3. 可做：更宽真实绘制 gate

## 4. Deferred Items

- 旧的 `selection.fill / lasso.fill` 慢确认合并条目已过时，不再作为当前 `lasso.fill` 基线
- 完整 `swift test` 的长跑 perf 项未收口到最终 passed / failed 结论：deferred validation note
- Dual Tip 的 `smudge` 路径：继续排除，不在本轮范围

## 5. 不要做的事

- 不要再写 performance closure audit
- 不要再复述 [performance-closure-audit.md](/Users/victorcloux/Desktop/ArtFlex/Docs/performance-closure-audit.md)
- 不要扩大到新的 history 结构改造
- 不要碰 `smudge / trim / restore` 主线语义
- 不要重开通用 partial history
- 不要把当前任务扩成新的大范围性能项目
- 不要脱离当前已确认范围去扩新的 Dual Tip 家族能力
- 不要默认将更宽 gate 一次性放开到所有工具 / 所有主次笔尖 / 所有模式

恢复开发时，默认先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_STATUS.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_STATUS.md)
