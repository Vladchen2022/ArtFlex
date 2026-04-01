# ArtFlex 当前状态

- 当前阶段：Dual Tip 已完成到 `invert`，并补齐了主/次笔尖来源语义、preview 收口，以及最近一轮普通画笔卡顿 / 偶发不出笔 / 导入笔尖白边修复；下一阶段已开始推进，其中 `secondary image tip` 已先完成 archive / persistence 边界、imported-image model-driven 收口，以及共享 `tip image library` 当前基线；`renderer-backed preview` 第一刀也已落地；更复杂随机 / `spacing` 的前五刀 `secondary size jitter`、`secondary angle jitter`、`secondary spacing phase`、`secondary spacing phase jitter` 与 `secondary scatter jitter` 也已落地
- 当前画布视口交互新增两项：顶部工具栏已提供 `锁定画布` 切换；开启后主画布不能缩放、旋转或移动。当前缩放也已改为优先围绕最近一次笔尖 / hover 所在的画布位置进行，而不是固定围绕画布中心
- `直线渐变` 与 `扇形渐变` 当前已从工具入口、快捷键循环和工具切换主链中摘掉，现视为“停用待重建”状态；旧实现不再作为当前稳定功能继续维护
- 画笔库当前已收口为：不再通过格子右上角小叉删除笔刷预设；删除入口改为“先选中格子，再右键菜单删除”，以降低误点
- `方案试探` 当前也已收口一条视口规则：四宫格模式下 4 个分支画布会统一回到默认 fit 视口，并临时锁定视口交互；因此不再继承主画布的平移/旋转偏移，也不会在四宫格里被继续拖动
- `快照对比` 当前也已收口一条布局规则：右侧 2x2 对比卡片会按卡片总高度反推预览可用高度，不再让底部两格因为额外留白和高度估算偏差而被裁掉；4 个预览位现在都以完整画布为目标
- `移动变形` 当前也已收口一条预览规则：无选区 whole-layer 自由变形在预览阶段会直接围绕被移动像素的内容中心旋转，不再临时按整张画布中心旋转；预览与回车确认后的最终提交当前已对齐
- 当前范围判断已调整：组合笔尖后续默认只继续推进“明显影响画笔效果”的能力，以及“预览 / 保存恢复 / 资料库稳定性”这类必做收口；轻微影响画笔效果的新随机 / `spacing` 小参数默认暂停
- 当前代码状态：`multiply`、`subtract`、`intersect` 已可用；`secondary scatter`、`secondary scatter jitter`、`secondary angle offset`、`secondary invert`、`secondary size jitter`、`secondary angle jitter`、`secondary spacing phase`、`secondary spacing phase jitter` 已进入真实绘制；当前基线和主绘制路径未被打坏
- 当前编辑/保存状态：主笔尖单一真相源已接通；次笔尖来源已接通；主/次笔尖的 `procedural / customMask / importedImage` 来源语义已能保存到 preset / project；imported-image 的来源标签与原始像素尺寸也已能保存和恢复
- 当前支持：
  1. 主笔尖：圆形、自定义笔尖
  2. 次笔尖：圆形、自定义笔尖
  3. 组合模式：`multiply`、`subtract`、`intersect`
  4. 当前真正会影响绘制的参数：`strength`、`secondary size ratio`、`secondary size jitter`、`secondary angle jitter`、`secondary spacing phase`、`secondary spacing phase jitter`、`secondary scatter`、`secondary scatter jitter`、`secondary angle offset`、`secondary invert`
  5. 当主/次笔尖是自定义笔尖时：`customTipMaskData / softness / roundness / angle`
  6. 主/次笔尖摘要现在都能稳定区分：`procedural / customMask / importedImage`
- 当前已接通的来源/说明能力：
  1. `组合笔尖…` 面板里的主笔尖摘要 + 跳转
  2. 次笔尖摘要
  3. `编辑次笔尖…` 子面板
  4. 主/次笔尖来源语义的 preset / project 保存
  5. 自定义主/次笔尖的三格示意已与真实形状对齐，并已收口为黑底白笔触高对比样式
  6. 预设预览的 Dual Tip 重计算热点已收口，不再拖慢普通画笔输入
  7. 主/次 imported-image 现在会在 UI 中显示当前导入来源与像素尺寸摘要
- 当前新增已落地的资产层能力：
  1. imported-image 主/次笔尖现在会在 project package / brush library archive 中抽成独立 `tipImageAssets`
  2. archive 内的主/次 imported-image 笔尖现在会保存资产引用，再在打开/导入时解析回当前运行态 `maskData`
  3. imported-image 的来源说明和 preview fit 现在由 `TipSourceSemantic + ImportedTipSourceInfo` 决定，不再依赖会话态 flag
  4. 主笔尖和次笔尖现在共用一套持久化 `tip image library`，资料库会跟随 workspace / project / brush library 一起保存和恢复
  5. `tip image library` 现在会独立保留未被任何画笔引用的图片；重启后打开资料库也能恢复这些未使用项
  6. `tip image library` 在打开工程、导入画笔库、以及恢复持久化资料库时，当前也会按重复 asset ID 做更稳的合并：不再简单丢弃后来的重复项；如果后来的项带有缺失的 `maskData` 或更可靠的资产内容，会补进现有资料库项
  7. 重启恢复持久化画笔库时，如果此前有明确选中的画笔预设，当前笔刷现在也会重新对齐到这支预设，不再出现“预设已恢复高亮，但当前笔刷仍停在旧默认值”的分离状态
  8. 画笔库替换/追加导入时，当前笔刷现在也会在需要时重新对齐到结果里的已选预设；如果导入资源里的 `tip image library` 不完整，也会从导入后的当前笔刷与预设里自动回填缺失的 imported tip 资料
  9. 删除当前已选画笔预设时，如果画笔库自动切到了新的已选预设，当前笔刷现在也会一起切过去，不再留下“画笔库选中已变、当前笔刷仍停在已删预设”的分离状态
  10. 自动化测试当前也已默认使用隔离的临时画笔库持久化，不再意外碰到真实 `Application Support/ArtFlex/brush-library.json`
  11. 默认画笔库当前不再附带 3 个 Dual Tip Phase 1 示例预设；旧持久化或导入资源若还带着这 3 个 legacy demo preset ID，也会在恢复链里被过滤掉，不再重新出现在画笔库
  12. `tip image library` 当前 UI 已切到：点选卡片后按“完成”应用、拖拽排序、右上角删除图标、`Esc` 退出资料库；资料库面板里的“导入图片…”现在支持一次多选多张
  13. 在资料库面板里批量导入图片时，只会先批量入库，不会立刻改当前主/次笔尖；仍需手动点选一张后按“完成”应用
  14. `tip image library` 卡片现在会直接显示引用状态：`当前主笔尖`、`当前次笔尖`、`N 个预设` 或 `未引用`
  15. 当前删除规则已冻结为：如果某张图片仍被当前主/次笔尖或任一画笔预设引用，则禁止删除；资料库里的删除图标会直接禁用，并显示更明确的来源提示
  16. `undo / redo` 的 history 合并链现在会保留 `tip image library`，不会再把资料库误掉成空库或局部库后写回磁盘
  16. 即使当前临时切到硬边圆 / 柔边圆 / 方形，隐藏的 imported-image 笔尖状态也会继续走统一资产归档与恢复链；这目前作为兼容行为保留，但后续主入口将以显式资料库为准
  16. 新增了共享 `StageOneBrushPreviewRasterizer`：当前会复用 `StageOneBrushRenderer` 的 `tipAlpha / dualTip combine / stable scatter` 公式来生成小尺寸 preview image
  17. 主笔尖卡片、次笔尖卡片、三格示意最终笔尖、画笔库斜线笔触预览，以及 `tip image library` 资料库卡片，当前都已切到这条共享 preview rasterizer
  18. 右侧 inspector 里残余的自定义笔尖静态预览，也已改成走同源 stamp preview，不再直接画旧的 mask 直出图
  19. 画笔库斜线预览当前不会再为每个 stamp 重算一次 Dual Tip 组合图；小尺寸 preview 的 raster 分辨率也已按显示尺寸动态下调，避免拖慢启动和首屏布局
  20. `组合笔尖` 面板里的主笔尖 / 次笔尖 / 最终笔尖预览，当前也已拆成独立异步刷新；参数或图片变化时不会再等三张图串行算完才一起更新
  21. 三格示意里的最终笔尖，当前即使工具或形状不在真实绘制 gate，或 `Dual Tip` 开关暂时未开启，也仍会继续显示组合图形示意，不再只剩“示意”文字
  22. 画笔库斜线笔触预览的 Dual Tip 语义，当前也已与三格示意对齐：只要预设启用了 `Dual Tip`，就会显示组合笔触示意，不再要求先进入当前真实 gate
  23. 画笔库右下角的小 glyph 预览，当前也已与组合预览语义对齐：`Dual Tip` 预设会优先显示组合笔尖，而不是只显示主笔尖
  24. `secondary size jitter / 次笔尖大小抖动` 当前已落地：会让 `secondary size ratio` 围绕当前中心值按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  25. `secondary angle jitter / 次笔尖角度抖动` 当前也已落地：会让次笔尖角度围绕当前基准角度按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  26. `secondary spacing phase / 次笔尖节距错相` 当前也已落地：会让次笔尖相对主笔尖沿当前笔触方向前后错开半个节距以内；真实落笔仍维持当前窄 gate
  27. `secondary spacing phase jitter / 次笔尖节距错相抖动` 当前也已落地：会让节距错相围绕当前中心值按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  28. `secondary scatter jitter / 次笔尖散布抖动` 当前也已落地：会让次笔尖散布量围绕当前 `secondary scatter` 中心值按每个 stamp 的稳定随机值波动；真实落笔仍维持当前窄 gate
  29. 笔尖形状设计区域里的黑白 mask 预览，当前也已复用共享 preview rasterizer 的 resample / crop / cache 链，不再单独维护一套小图生成逻辑
  30. 参数化 `customRound` 在没有 `maskData` 时的小预览，也已优先走共享 preview rasterizer，不再默认退回手工渐变椭圆
  31. `组合笔尖` 面板与 `编辑次笔尖…` 在高清 preview 尚未回填前，当前也会先显示同源的小型 rasterized 占位笔尖，不再只剩 spinner
  32. `编辑次笔尖…` 的“次笔尖形状”菜单项现在也会显示同源小预览，不再只剩文字标签
  33. `编辑次笔尖…` 顶部概览卡片，当前也已切到独立异步 preview；换图或调参数时不会再被同步 `stampImage` 阻塞
  34. 画笔库小 glyph、笔尖静态小预览、资料库卡片、`编辑次笔尖…` 形状菜单，以及 `组合笔尖` / `编辑次笔尖…` 的异步 preview 与占位图，当前都已切到 best-effort shared rasterizer：如果高清图或 composite 图暂时拿不到，会先退同源低分辨率 raster preview，而不是再退回手工 `Circle / RadialGradient` 示意
  35. 当前 renderer / preview 运行态仍继续直接吃解析后的 `maskData`，这一刀没有改动真实绘制主链，也还不是完整的离屏 Metal preview 终态
  36. 画笔库笔触 preview 当前已改成模拟由轻到重的压感变化，因此有无压力变化、以及压力变化强不强，会比原来的单一力度预览更容易辨认
  37. `组合笔尖` 面板当前已再次瘦身：顶部 gate 徽标、支持 chip、主/次笔尖说明句、三格示意说明字都已去掉；重复的“笔尖概览”也已移除，主/次笔尖预览直接并入三格示意前两格，并在格子下方直接放置编辑按钮
  38. `组合笔尖` 面板当前不再用“进阶参数”折叠隐藏选项；参数区默认全部展开，popover 也已相应放大，并通过更紧凑的 card / section 间距维持可读性
  39. `编辑次笔尖…` 面板当前也已按同一原则瘦身：顶部说明句、形状说明、画布说明，以及各 slider 的 helper text 都已去掉；顶部次笔尖预览也已改成黑底白图案的高对比样式
- 当前未完全落地但已确认继续推进：
  1. `renderer-backed preview` 的剩余 rollout（高感知一致性项）
  2. 共享 `tip image library` 的剩余生命周期 / 管理体验收尾
  3. 更宽真实绘制 gate（仅在效果提升明显时继续）
- 当前明确不在本轮范围：
  1. `smudge` 路径
- 当前策略：下一阶段范围已经确认，但仍按小步分刀和强旁路原则推进，不一次性把 Dual Tip 扩成全家桶

如果要恢复上下文，先看：

1. [HANDOFF.md](/Users/victorcloux/Desktop/ArtFlex/HANDOFF.md)
2. [CURRENT_TASK.md](/Users/victorcloux/Desktop/ArtFlex/CURRENT_TASK.md)
3. [DECISIONS.md](/Users/victorcloux/Desktop/ArtFlex/DECISIONS.md)
