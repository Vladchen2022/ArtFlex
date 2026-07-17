# ArtFlex 新线程接手文档

最后更新：2026-07-16

当前仓库：`Vladchen2022/ArtFlex`

当前分支：`codex/generative-gesture-experiment`

已推送基线：`1dd5e30 Add block reference modeling workspace`

## 1. 新线程先做什么

只需先读本文件，然后执行：

```bash
cd /Users/victorcloux/Desktop/ArtFlex
git status -sb
git log -3 --oneline --decorate
```

不要按旧文档或早期 MVP 状态猜测项目。`CURRENT_STATUS.md`、`DECISIONS.md` 和 `README.md` 的主体仍有参考价值，但更新时间停留在 2026-05-23；如有冲突，以本文件、当前代码和测试为准。

用户的固定工作要求：

- 使用中文，直接给结论。
- 实现前遵守根目录 `AGENTS.md` 的 reuse-first 决策流程。
- 交互、渲染、几何或坐标问题连续修补两次仍失败时，停止打补丁，转为 reference-first。
- 所有软件改动完成后必须构建并自动替换现有 ArtFlex；关闭旧进程，只保留一个最新版窗口供用户测试。
- 用户要求“界面测试”时，必须实际操作 ArtFlex 窗口，后台单元测试不能替代界面验收。
- 不要修改或覆盖用户真实画笔库：`~/Library/Application Support/ArtFlex/brush-library.json`。
- 工作区可能包含用户改动；提交前必须检查范围，不能无差别覆盖或回退。

## 2. 项目定位与架构约束

ArtFlex 是旧版 `BrushCanvas` 的 macOS Metal-first 重构版绘画软件。保留旧产品工作流，但不能迁移旧 CPU 画布架构。

必须保持：

- 顶部工具栏、左侧工具栏、中央 Metal 画布、右侧 inspector、图层面板和笔尖设计区。
- 显示、编辑、采样、导出尽量共享标准化画布数据。
- `RGBA8 + premultiplied alpha + sRGB`；GPU surface/drawable 为 `bgra8Unorm_srgb`。
- 3D 体块参考是画布外置 UI/文档场景，不写入像素图层；冻结绘画时作为可调透明、鼠标穿透的参考叠层。
- 业务和文档逻辑不要进一步绑死 SwiftUI/AppKit；Metal 渲染与上层状态保持分离。
- 不做无边界的 `WorkspaceViewModel` 或 `RightInspectorView` 全文件重构，按子系统小步拆分。

## 3. 当前产品状态

当前已经不是 MVP。主工程至少包含：

- 多图层、撤销/重做、图层锁定/透明像素锁定/合并。
- 画笔、橡皮、吸管、油漆桶、涂抹、直线和渐变。
- 套索/矩形/椭圆等选区、羽化、填充、删除和画布外起选。
- 自由变形与网格变形、多点控制。
- 画布平移/缩放/旋转/裁剪、水平观察翻转。
- 色彩调整、曲线、参考图、导航器、快照、方案试探、录像。
- 画笔库、笔尖图片库、自定义/组合笔尖和真实压力曲线。
- 纹理填充已合并到套索填充工作流，支持多种排列和实时预览。
- 外部图片拖入画布成为新图层；图片可拖入参考图槽位。
- 透视工具和当前主线“体块参考”。
- 工程保存/打开、PNG 导出；工程文档可持久化 3D 体块场景。

组合蜡笔/压力纹理画笔经历过多轮调整。没有新的硬证据时，不要再次大改公共笔刷采样或全局间距逻辑；此前公共路径错误曾导致所有画笔断线和界面卡顿。

## 4. 体块参考：当前最重要的完成状态

入口：左侧“透视”下面的“体块参考”。激活时右侧两列 inspector 被一个宽 3D 面板替换，标签为：

- 建模
- 变换
- 参考
- 相机
- 场景

### 4.1 建模与模块

已经实现：

- 方块、圆柱、圆锥、球体；圆形截面采用 8 边低模。
- 类 SketchUp 两阶段建模：在工作面拖出二维基面，再拖拉高度。
- 拉基面和高度时显示实时尺寸。
- 参数面板可精确修改尺寸、位置、旋转；数值框支持水平拖动调整，Shift 精细调整。
- “表面直接建模”：鼠标触及现有实体表面时，直接把该表面作为临时工作面。
- 表面起建使用视觉偏移/预览处理，避免共面闪烁。
- 内置模块：站姿人体、坐姿人体、可摆姿人体、楼梯、门框、房间盒、桌体。
- 固定站/坐人体不可拆分、不可布尔，只能整体移动旋转。
- 可摆姿人体包含骨盆和父子关节，画布可选关节并显示符合自由度的旋转环；膝关节为单向铰链，骨盆/躯干支持水平旋转。

### 4.2 变换与组织

已经实现：

- 画布 gizmo：X/Y/Z 轴移动、旋转环、缩放。
- 世界/局部/工作面坐标切换；局部 gizmo 会随物体旋转。
- Blender 风格快捷键：`G` 移动、`R` 旋转、`S` 缩放；接轴键约束；重复轴键切换局部轴，例如 `G X X`、`R Z Z`。
- gizmo 拖动后数值输入框自动获取输入，可直接键入数字并回车。
- 统一缩放、活动对象/选择中心/工作面/自定枢轴。
- 几何镜像、线性阵列、环形阵列；阵列轴和枢轴可选。
- `Ctrl+G` 编组、`Ctrl+Shift+G` 解组；组选中和变换会作用于整个组。
- 隐藏、显示全部、锁定、隔离、复制、删除。
- 撤销/重做体块文档操作。

最近修复：

- 线性/环形阵列现在显示明确完成提示和副本数量。
- 体块工具激活时，Cmd+Z/Cmd+Shift+Z 会把面板提示同步为“已撤销/已重做上一项操作”，不再残留旧提示。

### 4.3 工作面、捕捉和结构参考

已经实现：

- 从实体面拾取斜工作面，网格会随工作面方向变化。
- 恢复默认地面、保存/调用/偏移工作面。
- 网格、顶点、中点、面中心捕捉。
- 拉伸高度可吸附到其他体块端点高度。
- 测量距离和 X/Y/Z 分量。
- 持久辅助轴。
- 剖切、反向剖切。
- 实体显示和线框显示；Metal 深度测试处理实体遮挡，弱化/隐藏远端被遮挡结构。
- 近裁剪会裁切穿越 near plane 的面，不使用背面剔除，避免特定角度缺面。
- 布尔结果会过滤共面内部细分线，只保留有结构意义的特征边。

### 4.4 布尔

已经实现：

- 合并、活动对象减去另一对象、相交。
- 基础体和连续布尔结果都可再次参与布尔。
- 圆柱减方块等非方体组合已经测试。
- 空结果有保护，不会破坏源对象。
- 固定人体模块禁止布尔。

布尔几何使用 `Euclid 0.8.18`，依赖固定在 `Package.swift`/`Package.resolved`。不要轻易替换为自制 CSG。

### 4.5 相机、三点透视与场景

已经实现：

- 中键环绕、Shift+中键平移、滚轮缩放；方向按 Blender 习惯调整。
- 透视/正交、水平/俯仰/距离/视场角、重置和标准视图。
- 5 个相机视角槽，可保存、调用、锁定、删除。
- 场景快照。
- 3D 相机 → 三点透视：辅助线来自真实体块特殊边缘/消失方向，并会随相机变化。
- 三点透视 → 3D 相机：可反解并恢复相机。
- 透视辅助可明确清除，不应遗留无意义的全屏线。
- “冻结并绘画”：离开 3D 编辑，保留可调透明度参考叠层；画笔可以在其上正常绘制且叠层不截获鼠标。

### 4.6 文档持久化

`ArtDocument` 包含可选 `blockReferenceScene`。保存同一个 ArtFlex 工程时，体块、相机、工作面、辅助线、剖切、快照等与画布一起保存；旧工程缺少该字段时仍可解码。

## 5. 体块参考关键文件

状态和几何：

- `Core/Application/BlockReferenceState.swift`
- `Core/Application/BlockReferenceAdvancedState.swift`
- `Core/Application/BlockReferenceGeometry.swift`
- `Core/Application/BlockReferenceAdvancedGeometry.swift`
- `Core/Application/BlockReferenceBooleanGeometry.swift`
- `Core/Document/ArtDocument.swift`

应用接线：

- `Platform/macOS/App/WorkspaceViewModel+BlockReference.swift`
- `Platform/macOS/App/WorkspaceViewModel+BlockReferenceAdvanced.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/App/WindowKeyboardBridge.swift`

UI 与渲染：

- `Platform/macOS/UI/BlockReferenceParameterPanel.swift`
- `Platform/macOS/UI/BlockReferenceOverlay.swift`
- `Platform/macOS/UI/BlockReferenceMetalSolidView.swift`
- `Platform/macOS/Canvas/BlockReferenceCameraRenderState.swift`
- `Platform/macOS/Canvas/MetalCanvasHost.swift`
- `Platform/macOS/UI/RightInspectorView.swift`
- `Platform/macOS/UI/CanvasContainerView.swift`

测试：

- `Tests/ArtFlexTests/BlockReferenceStateTests.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelSafetyTests.swift`
- `Tests/ArtFlexTests/ProjectPackageTests.swift`

## 6. 最近一次完整验收

2026-07-16 在真实 ArtFlex 窗口完成了 10 个实际项目，而不是只跑后台测试：

1. 墙体与表面附着圆柱：两阶段建模、尺寸、表面直接建模。
2. 简化室内场景：房间盒/门框/桌体、精确参数、世界/局部 gizmo。
3. 建筑布尔组合：合并/减去/相交、空结果保护、撤销、显示模式。
4. 斜屋面：复合旋转、斜工作面、网格、保存/偏移/恢复工作面、辅助轴。
5. 重复柱列和环形构图：统一缩放、枢轴、镜像、线性/环形阵列、编组。
6. 人体姿势：站姿/坐姿/可摆姿、骨盆/躯干/膝关节、整体移动。
7. 室内相机和三点透视：视角槽、真实边缘透视线、双向转换、清除。
8. 测量/捕捉/剖切：尺寸、捕捉、测量、正反剖切、遮挡。
9. 场景组织：隐藏、锁定、全选过滤、编组移动、撤销/重做。
10. 工程持久化与冻结绘画：保存、重启打开、3D 场景/相机/快照恢复、冻结后绘画。

全部最终通过。首轮发现的阵列提示和撤销提示问题已经修复并再次在 UI 中通过。

自动测试基线：

- `swift test`：533 tests / 43 suites，通过。
- Release 构建通过。
- 代码签名验证通过。

## 7. 构建、替换和界面测试

常用自动测试：

```bash
swift test
swift test --filter BlockReferenceStateTests
swift test --filter WorkspaceViewModelSafetyTests
```

构建并自动替换当前软件：

```bash
swift build -c release
cp .build/release/ArtFlex .build/ArtFlex.app/Contents/MacOS/ArtFlex
codesign --force --deep --sign - .build/ArtFlex.app
pkill -x ArtFlex 2>/dev/null || true
open -n .build/ArtFlex.app
pgrep -x ArtFlex | wc -l   # 必须为 1
```

这是强制发布步骤，不是可选验证：每次完成软件更新后，必须主动替换应用包、退出所有旧版与隔离预览进程，并只启动一个 `.build/ArtFlex.app`。如果当前文档未保存，先保存到用户指定位置；无法取得位置时保存带时间戳的恢复副本，再重启并重新载入该副本。不得把“请用户自行重启”作为交付结果。

当前用于测试的 bundle：

- `/Users/victorcloux/Desktop/ArtFlex/.build/ArtFlex.app`
- bundle identifier：`com.vladchen.artflex.debug`

界面验收使用 `computer-use` 技能控制 ArtFlex。重启/清场可用终端命令，但功能结果必须在软件界面观察和操作。

## 8. 当前 Git 状态与提交策略

体块参考完整功能已提交并推送：

- commit：`1dd5e30`
- branch：`codex/generative-gesture-experiment`
- remote：`https://github.com/Vladchen2022/ArtFlex.git`

本文件更新后，正常情况下工作区只会多出 `HANDOFF.md` 的未提交修改。新线程开始时仍必须实际运行 `git status -sb`，不要只相信这句话。

提交前：

- `git diff --check`
- 明确检查暂存范围。
- 不提交 `.build`、临时测试工程、截图或用户数据。
- 用户要求推送时推送当前分支；不要擅自重写历史。

## 9. 已知风险与不要误判的现象

- 当前没有已知阻断性的体块参考回归；这是基于 10 个 UI 项目和 533 项测试的高置信度结论，不代表复杂 CSG 永远不会出现数值边界问题。
- Release 构建仍有既存 Swift 并发警告：`TimelapseRecorderController` 的 `AVAssetWriter` 捕获，以及 `StageOneBrushRenderer` completion 的 Sendable 警告；与体块参考无关，不能谎报成零警告。
- `WorkspaceViewModel.swift` 仍然很大，但体块参考主要逻辑已拆到两个扩展文件。不要为了“代码漂亮”无任务地重构。
- Metal 实体渲染的深度、near clipping、背面处理曾出现穿模和缺面；如果再次出现，先做可复现相机/几何案例并读 `BlockReferenceMetalSolidView.swift` 和对应测试，不要靠调整颜色或随意开关 culling 掩盖。
- 局部坐标测试必须在旋转数值真正回车提交后进行；之前曾因输入未提交被误判为局部轴失效。
- 体块参考目标是绘画结构和透视辅助，不是 Blender 替代品。优先操作效率、低模结构、捕捉和相机，不做材质、纹理、光影或精细网格编辑。

## 10. 下一步

当前没有遗留的明确开发任务。等待用户在新线程指定下一项功能或缺陷。

接到体块参考后续需求时：

1. 先在现有 Release 软件中复现。
2. 优先复用当前状态、几何、gizmo、历史和 Metal solid renderer。
3. 先补可重复自动测试，再构建替换应用。
4. 最后用实际 ArtFlex 窗口做针对性场景验收。

适用技能：

- 软件界面操作与验收：`computer-use`
- 需要保存下一轮上下文：`handoff`
- 用户要求提交并推送：`github:yeet`
