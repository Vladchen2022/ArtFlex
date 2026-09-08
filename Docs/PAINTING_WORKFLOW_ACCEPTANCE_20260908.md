# 绘画稳定性与工作流优化验收

## 范围与取舍

这是整体优化方案中的第一批落地，不代表所有架构项目已经完成。
保留现有主界面结构、工程格式及已验收的蜡笔效果，不修改笔刷盖印、压感、混色公式。

复用仓库现有的 Metal 图层存储、合成输入计划、选区形态学、填色引擎、资源预算、缩略图队列和历史系统。
使用 Apple 的 NSCache、Metal Performance Shaders 与异步 AppKit 文件面板，不引入第三方依赖。
没有把新的 CPU 整图合成器接入画布；填色闭合缺口仅在临时选区拓扑上计算。

## 本批改动

1. 笔触提交先写入暂存纹理，确认 GPU 完成后才替换正式图层、移除待提交任务；创建必需资源失败时保留任务和原图层。
2. 裁剪和方案试探复制色彩图层与蒙版；图层组不被当作必须有像素纹理的图层。准备失败时不替换正式表面存储。
3. 组合笔尖纹理使用有成本上限的缓存，避免达到固定数量后全部清空；取消的缩略图任务不继续排队渲染。
4. 填色和魔棒任务接入协作取消；填色界面提供取消按钮及 Escape 取消。
5. 填色新增“闭合缺口”和“向外扩展”。默认均为 0，保留原有填色路径；线稿引用不被修改，可在独立图层着色。
6. 图片色板的聚类计算移到后台，保留灰色、黑色和白色；随机初始化固定，避免同一图反复得到无谓变化。
7. 资源库显示当前/总项目数量，明确标记筛选状态，并能一键“显示全部”。
8. 录像沿用正式合成规则，包含最近仍在实时缓冲中的可见笔触；合成失败时不改用忽略蒙版/混合模式的备用合成器。半尺寸/四分之一尺寸先在 GPU 缩小，再读回。
9. 录像目录选择、视频导出从同步 runModal 改为异步文件面板；先收起录像浮窗，避免嵌套模态循环。

## 代码位置

- `Core/Application/WorkCancellation.swift`、`FillSettings.swift`
- `Core/Selection/SmartSelectionSegmenter.swift`
- `Core/Ideation/IdeationSessionState.swift`
- `Rendering/Canvas/LayerSurfaceTransfer.swift`、`StageOneLayerSurfaceStore.swift`
- `Rendering/Canvas/MetalStrokeEngine.swift`、`BrushLiveSession.swift`
- `Rendering/Canvas/StageOneBrushRenderer.swift`、`BrushV2Renderer.swift`
- `Rendering/Canvas/BucketFillEngine.swift`、`MagicWandSelectionEngine.swift`
- `Infrastructure/FileFormat/LayerTextureSerializer.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/Services/ImagePaletteExtractor.swift`、`TimelapseRecorderController.swift`、`FilePanelService.swift`
- `Platform/macOS/UI/BrushLibraryStrokeThumbnail.swift`、`RightInspectorView.swift`、`RecorderSectionView.swift`、`ToolSidebarView.swift`
- `Platform/macOS/Distribution/Info.plist`

## 屏幕验收记录

本轮通过 Computer Use 操作真实 ArtFlex 窗口，未运行后台单元测试。编译只用于生成应用，不计为功能验收。

| 场景 | 操作与观察 | 结果 |
| --- | --- | --- |
| 方案试探蒙版 | 旧版同一工程中的黑笔触白色缺口在四个分支消失；新版四个分支均保留缺口 | 前后对照通过 |
| 带蒙版与空图层组裁剪 | 裁为 1067×578；蒙版缺口和空组保留；撤销、重做、保存、重新打开结果一致 | 通过 |
| 缺口填色 | 800×800 线稿，缺口设置 0 时红色泄漏到外部；撤销后设为 16，红色留在轮廓内 | 前后对照通过 |
| 独立图层填色 | 可见层采样，新建着色层，向外扩展设为 4；隐藏着色层后原黑线和缺口仍在 | 通过 |
| 资源筛选提示 | 19 项库搜索 Krita，显示 1/19 和筛选提示；显示全部恢复 19 项 | 通过 |
| 黑白图片提取色板 | 从界面导出黑白线稿 PNG，再从界面导入色板；得到可见的黑白灰色块，画稿未变 | 通过 |
| 大画布填色取消 | 5600×5600 画布正常填色、撤销，重新填色后立即 Escape；显示“已取消填充，画布未改变”，保持白色 | 通过 |
| 尺寸安全上限 | 8000×8000 被现有 3200 万像素限制阻止；改为 5600×5600 可创建 | 既有保护回归通过 |
| 录像目录选择 | 旧同步面板两次报“未能连接打开和保存面板服务”；异步面板正常选取 Downloads 内测试目录 | 修正后通过 |
| 录像最新笔触 | 初次 PNG 帧保留蒙版但漏掉实时笔触；修正合成输入后，新帧同时包含蒙版、已保存粗笔触、尚未保存的细笔触 | 前后对照通过 |
| 录像分辨率 | Finder 中三张 PNG 都显示 533×289；对应 1067×578 画布减半取整 | 通过 |
| 视频导出 | 界面导出 MP4，系统快速查看可播放并显示新细笔触和蒙版；非后台生成 | 通过 |
| 组合蜡笔与历史 | 主画布绘制、撤销、重做；橡皮擦后撤销；保存后更新应用并重新打开，笔触保留 | 通过 |
| 压力预览 | 笔刷工作室“压感”示笔及 20%/50%/85% 小样显示不同浓度和纹理；未修改预设 | UI 回归通过，不替代数位板测试 |
| 锁定透明像素 | 在红色笔触图层锁定透明像素，黑笔跨越两条红线；仅红线内部着色，间隔白色保持；撤销并解锁 | 通过 |
| 涂抹 | 从红色笔触拖入白色区域出现拖色，撤销恢复 | 基础操作通过，不作为涂抹质感评价 |

测试文件都在 Downloads，文件名包含“ArtFlex-优化验收”，没有使用用户原画稿做破坏性测试。

实际输出：

- 最新正确帧 `/Users/victorcloux/Downloads/ArtFlex-录像验收-20260908/ArtFlex-优化验收-蒙版基线-20260908-5de97a0f/frame_000002.png`。
- 前两帧保留作为漏笔触问题的对照，不冒充正确结果。
- 视频 `/Users/victorcloux/Downloads/ArtFlex-优化验收-蒙版基线-20260908-timelapse.mp4`。
- 5600×5600 取消测试空白文档已从退出提示中明确放弃，未删除任何用户工程。
- 最后已在界面重新打开用户原工程，显示“已保存”，录像停止。

## 用户手测清单

1. 在线稿中留一个小缺口，在独立着色层用“可见层”采样；先闭合缺口 0，再试 4–16，确认外部不漏色。数值是画布像素，不是屏幕像素。
2. 打开“边缘扩展” 1–4，确认颜色填进线条下方；隐藏着色层，原线稿不应改变。
3. 大范围填色后立即 Escape，确认画布没有部分填入；随后再填一次应仍可正常完成。
4. 给图层添加蒙版并遮掉部分笔触，进入方案试探，所有分支应保留遮挡；取消返回后原图不变。
5. 带蒙版和图层组裁剪，分别检查撤销、重做、保存重开，尺寸和蒙版位置应一致。
6. 录制时连续画几笔，不先保存，等一个捕获间隔后停止；打开帧文件，最后一笔不能消失。
7. 用半尺寸录制，检查帧尺寸，再导出视频并播放；蒙版/颜色/最新笔触应与画布一致。
8. 库搜索后确认显示“当前/总数”和筛选提示；点“显示全部”应恢复资源，不应把隐藏误判成删除。
9. 导入黑白灰图片提取色板，不应丢掉所有中性色；连续换两张图时最终应保留后一次结果。
10. 用自己的数位板检查已认可蜡笔的轻压纹理、重压实色、连续笔触、撤销和锁透明；这是本次鼠标验收没有覆盖的部分。

## 保留与回退

- 分支 `codex/painting-reliability-and-workflow`；基线提交 `8683cac`。
- 原应用、原资源库和原工程的备份目录 `/Users/victorcloux/Downloads/ArtFlex-优化前备份-sJ8bwT`。
- 用户原工程 `/Users/victorcloux/Downloads/ArtFlex-体块参考验收-20260906.artflex` 未被验收图案覆盖。
- 收尾时原工程与备份的 SHA-256 均为 `5cf5220bd7735f0cdab06e9d00f88424f639d756213a135161af6528c39bd002`。
- 不自动提交或推送 Git；改动仍可逐文件审阅。
- 构建号 `20260908.4`。安装入口 `.build/ArtFlex.app`；备份应用为压缩包，不注册成第二个可启动应用。
- 收尾时只有一个 ArtFlex 应用进程；已安装二进制与本轮 Release 产物的 Mach-O UUID 均为 `790F384E-A2F8-38EC-A5D4-87D8ECA0E69D`。

## 验证边界与剩余方案

- 鼠标界面测试不能证明真实数位板的压力范围、驱动行为和长期稳定性；没有宣称已验证它们。
- 没有注入 GPU 故障、磁盘写满或断电；异常保留路径有代码保护，但不能称为故障注入验收通过。
- 暂存笔触提交增加了一张图层大小的工作纹理与 GPU 拷贝；安全性改善不能直接等同于速度提升。大画布耗时需要单独测量。
- 缺口闭合是临时形态学方法；过大的数值会封住有意留白的窄通道，必须允许减小或关闭。该可选路径仍有整图内存成本。
- 取消检查覆盖分割循环和阶段边界，尚未覆盖每个形态学内循环；不承诺任意规模下瞬时停止。
- 图片解码/缩略采样仍经过主线程 AppKit；本批仅迁移聚类计算，超大图片解码仍是后续优化项。
- 真正稀疏瓦片存储、磁盘撤销、写时复制方案分支、增量恢复、非破坏裁剪、高位深色彩仍未实施。
- 绘画导向的封闭围涂、笔刷诊断/工程内资源集、体块布尔后台化/GPU 投影/简化阴影仍需独立批次。
- 开工程时 Finder 自定义图标更新在当前系统产生 IconServices 诊断报告；不是本轮已确认的应用崩溃，也未作为已修复项。后续应限制图标尺寸并减少打开时写入。

## 参考

- [Apple CPU/GPU 同步](https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work)
- [Apple MPSImageBilinearScale](https://developer.apple.com/documentation/metalperformanceshaders/mpsimagebilinearscale)
- [Apple 异步附属文件面板](https://developer.apple.com/documentation/appkit/nssavepanel/beginsheetmodal(for:completionhandler:))
- [Krita 填色工具](https://docs.krita.org/en/reference_manual/tools/fill.html)
- [Krita 性能设置](https://docs.krita.org/en/reference_manual/preferences/performance_settings.html)
