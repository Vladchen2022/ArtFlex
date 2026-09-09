# 体块绘画参考前后层位 · 2026-09-09

## 决策与实现计划

用户需要让绘画笔迹覆盖半透明模型，且能切回模型叠在画稿上方。

- 仓库复用：`BlockReferenceDisplaySettings` 已承担参考显示状态、工程 Codable 与场景快照；`updateBlockReferenceDocument` 已处理元数据撤销和保存标记。复用两者。
- 显示链核对：`CanvasContainerView` 原先在主画布上方放独立透明 3D 视图。默认 `背景` 是真实白色像素层；单纯调整 SwiftUI 顺序会被该层遮住。
- 平台方案：[Apple Metal loadAction](https://developer.apple.com/documentation/metal/mtlrenderpassattachmentdescriptor/loadaction) 提供清空／保留附件内容的原生通道语义。复用现有 `BlockReferenceMetalSolidRenderer` 的几何、深度、线条及 buffer 槽，输出透明 GPU 纹理，再交给现有 `StageOneCanvasPresenter` 合成。没有添加依赖或 CPU 画布合成路径。
- 最小实现顺序：持久层位字段 → 共享离屏编码与显示缓存 → 画布合成入口 → 两处切换控件 → 像素、兼容与工作流测试 → 安装界面验收。

## 代码变更

- 新增 `inFront`／`behindPainting`，旧工程缺少字段时按 `inFront` 解码。
- 在绘画参考面板与画笔临时工具条提供“置前／置后”。切换保留锁定、相机与对象，沿用撤销／重做、工程及场景快照。
- 置后仅在锁定后使用绘画工具时生效。返回体块工具时暂时置前以便建模和临时观察，记忆的绘画层位保持。
- 置后参考插在最底部默认 `背景` 层之上、其它绘画层之下。普通导入图片和不透明绘画层会遮住它；背景隐藏时仍可在透明画布上看到参考。
- 参考纹理属于显示资源，不加入真实图层／剪贴板／历史像素／吸管／导出。复用现有图层透明度、蒙版、混合模式链。
- 同一场景、画布尺寸及显示尺寸复用缓存；只在参考显示变化或尺寸变化时重绘。缓存尺寸跟随 drawable，退出置后模式释放资源。

## 修改文件

- `Core/Application/BlockReferenceState.swift`：层位字段、旧工程兼容与生效条件。
- `Core/Application/BlockReferencePaintingPlan.swift`：背景与绘画层之间的插入规则。
- `Platform/macOS/App/WorkspaceViewModel+BlockReferenceWorkflow.swift`：元数据变更入口。
- `Platform/macOS/Canvas/BlockReferenceCanvasUnderlay.swift`：显示专用离屏纹理缓存。
- `Platform/macOS/Canvas/MetalCanvasHost.swift`：显示刷新及层位合成。
- `Platform/macOS/UI/BlockReferenceMetalSolidView.swift`：屏幕与离屏共用编码入口。
- `Platform/macOS/UI/BlockReferenceWorkflowControls.swift`：面板和临时工具条控件。
- `Platform/macOS/UI/CanvasContainerView.swift`：传递置后场景并关闭对应置前显示。
- `Platform/macOS/Distribution/Info.plist`：构建 `20260909.26`。
- `Tests/ArtFlexTests/BlockReferencePaintingPlacementTests.swift`：新增行为与 GPU 像素测试。

## 验证

- 原有定向 88 项／3 组通过。
- 全量 971 项／95 组通过，40.240 秒。日志 `/tmp/artflex-reference-placement-regression.log`。新增测试包括旧工程解码、锁定状态下切换与撤销、场景快照恢复、插入位置、真实模型离屏绘制、缓存复用与失效、不透明／半透明笔触合成及画稿像素未被改写。
- Release 构建通过，104.81 秒，日志 `/tmp/artflex-reference-placement-release.log`。已正常退出旧应用，在原入口 `.build/ArtFlex.app` 安装构建 `20260909.26`，签名验证通过。安装 arm64 UUID `7D407A89-1314-357E-8476-CA132A1DE458`。
- 真实界面使用 `/Users/victorcloux/Downloads/ArtFlex-参考层位验收-20260909.artflex` 独立副本。该旧工程只有一个白色背景层，因此手动新增绘画层后验收。
- 面板与画笔临时工具条都可切换；灰模 80% 下跨人体和方块绘制黑色实心笔触，置后时笔触完全遮住模型，置前时模型盖回笔触，模型位置一致。切换的撤销／重做通过。
- 置后模式用橡皮擦开笔触，缺口露出参考；水平翻转、100% 缩放与恢复适合窗口后仍对齐。隐藏参考后笔迹不变，显示后恢复。
- 保存重开后仍选中置后，笔迹和擦除缺口保留。通过界面导出 1600×1600 PNG 并读取检查，只有黑色笔触和白底，没有模型。
- 返回体块工具仍显示构图锁定，记忆的绘画层位保持置后。最后重新打开原 `ArtFlex-体块参考验收-20260906.artflex`，界面已保存、旧工程默认置前，原文件 SHA-256 与更新前备份相同。

## 回退、边界与手测

- 改动前 Git 为 `2ff5706`，本地标签 `backup/block-reference-placement-20260909`。
- 更新前从应用保存了当前内存画稿，并备份至 `/Users/victorcloux/Downloads/ArtFlex-参考层位备份-20260909-qsywb1n_/`，包括原工程与构建 25 的 app zip。保存后原工程 SHA-256 为 `d0efa1ffc6666ca7a95d97098f7ec66861fce004240254f83bc313859ebe3052`。
- 软件当前通过最底部图层的默认名称 `背景` 识别纸张；没有新增图层角色。直接在该背景层绘画时，参考仍在它上面。改名后会作为普通绘画层处理，可遮住置后的参考。
- 自动建层是另行征询的可选行为，尚未收到用户选择；本次先保留手动建层，不在层位切换时修改图层结构。
- 半透明笔触自然透出其下的参考。需要判断画稿本色时可使用已有“隐藏参考”。
- 手测：在背景上方绘画层画跨模型的笔触 → 来回切换置前／置后 → 擦除与撤销重做 → 缩放／平移／旋转／翻转 → 隐藏／显示参考 → 保存重开确认层位 → 导出检查没有模型 → 返回建模检查原构图和对象锁定。
- 本次界面未逐项覆盖画布旋转、所有混合模式和高位深组合；现有回归通过不替代这些专项手测。真实鼠标／数位笔中键入口未改动。
