# ArtFlex 纹理填充任务 Handoff

## Objective

继续完成并验证当前任务：用“纹理填充”替换原左栏“基底填充”，默认快捷键 `F` 且可在设置中改键；左栏所有已有快捷键的工具名后显示当前快捷键；新填充不再使用扇形/沿边缘排列笔尖，而是在闭合区域内用当前画笔或导入素材生成随机纹理场。

## Current state

- 仓库：`/Users/victorcloux/Desktop/ArtFlex`
- 分支：`codex/generative-gesture-experiment`
- HEAD：`c372e1c Optimize brush tip editor stroke rendering`
- 所有本任务改动均未提交。不要 reset/revert；工作区原本就包含上一轮纹理工具的未提交改动，本轮是在其上定向替换。
- `swift build` 已通过。
- 已通过：
  - `swift test --filter TextureFill`：5 tests passed。
  - `swift test --filter 'WorkspaceViewModelPixelHistoryTests.textureFill'`：15 tests passed。
  - `swift test --filter AppShortcutSettingsTests`：4 tests passed。
  - `swift test --filter StageOneBrushPreviewRasterizerTests.textureFillMaterialFieldPreservesBrushTextureWithoutBecomingSolid`：1 test passed。
- 完整 `swift test` 在输出过程中被用户中断，没有最终结果，也没有残留测试进程。下一线程必须重跑。
- `/tmp/ArtFlex-LayoutTest.app` 当前仍在运行旧二进制，不能作为本轮验证结果；需要替换/重建后重启。

## Decisions already made

- 复用现有套索输入、闭合选区 mask、历史记录、透明像素锁定、当前笔刷执行器和 `SelectionFillRenderer`。
- 删除当前尝试的 fan mesh 路径；不再把区域建模为“从原点向边缘排笔尖”。相关未跟踪文件 `TextureFillFanGeometry.swift` 和测试已删除。
- 当前画笔先生成固定大小材质图，GPU 在选区内完成镜像平铺、低频形变、覆盖率阈值和二次采样；不做整画布 CPU 像素循环。
- 材质方向由套索点 PCA 主轴推断；每次操作 seed 不同，但提交结果仍是普通图层像素，可正常 undo/redo。
- 轻量参数：`纹理尺寸`、`覆盖率`、`变化度`。旧工程缺少这些字段时解码为 `1.0 / 0.58 / 0.45`。
- 素材来源暂为“当前画笔”或共享笔尖图片库，未新增依赖，也未接入独立图案库。

## Implemented changes

- `Core/Tools/ToolKind.swift`
  - 显示名改为“纹理填充”。
  - 默认/分组快捷键改为 `F`。
  - `TextureFillTipSettings` 增加 3 个兼容解码参数。
- `Platform/macOS/UI/ToolSidebarView.swift`
  - 左栏主按钮显示 `工具名(当前快捷键)`，读取同一 `AppShortcutSettingsStore`，用户改键后同步。
- `Platform/macOS/UI/RightInspectorView.swift`
  - 改名并增加纹理尺寸、覆盖率、变化度滑块；素材按钮改为“选择纹理…”/“使用当前画笔”。
- `Platform/macOS/App/WorkspaceViewModel.swift`
  - 填充开始时冻结画笔/颜色/参数；提交时生成闭合区域材质填充。
  - 当前画笔和导入素材走同一个 GPU 材质路径。
  - 添加参数 setter 和每次操作 seed sequence。
- `Rendering/Canvas/StageOneBrushPreviewRasterizer.swift`
  - 新增 `materialFieldAlphaBytes`，用 4 条轻微弯曲笔触组成材质图，并缓存 64 份；删除 fan-stroke 生成逻辑。
- `Rendering/Canvas/SelectionFillRenderer.swift`
  - 新增 GPU 材质采样；小选区自动缩小世界材质尺度，避免只采到素材的空白部分。
- `Docs/reference/TEXTURE_FILL_STATUS.md`
  - 已改为当前实现说明。
- 相关快捷键、兼容解码、材质缓存、像素历史测试已更新。

## Pending work

1. 先运行完整 `swift test`，记录最终 test/suite 数和失败；不要依赖被中断的那次输出。
2. 检查 `git diff --check`、`rg` 是否还残留 `基底填充`、`肌理填充`、`TextureFillFan`、`fanStrokeAlphaBytes`。
3. 构建最新 executable，并更新 `/tmp/ArtFlex-LayoutTest.app/Contents/MacOS/ArtFlex` 后重启 App。
4. 使用 computer-use 实际验证：
   - 左栏显示如 `画笔(B)`、`橡皮(E)`、`纹理填充(F)`，长名称不截断/重叠。
   - 按 `F` 能切换到纹理填充。
   - 设置页出现“纹理填充 F”，改成其他未占用键后快捷键和左栏标签同步；测试后可改回 F。
   - 右栏 3 个滑块布局无溢出。
   - 用默认画笔圈 3 个大小不同区域：内部有纹理和空隙，不沿轮廓描边，松笔延迟可接受。
   - 连续圈同一区域结果有变化；第二次应命中材质缓存。
   - 调覆盖率/纹理尺寸/变化度后效果方向正确。
   - 测一次导入素材、undo/redo、锁定透明像素。
5. 如果视觉结果仍太规则，优先调 `SelectionFillRenderer` 的材质阈值/warp 和 `materialFieldAlphaBytes` 的 4 条路径；不要恢复 fan geometry。
6. 完成后更新计划状态和向用户给出简短手测清单。用户没有要求 commit，不要自行提交。

## Risks / caveats

- `RightInspectorView` 新增 3 个滑块后的实际高度尚未 UI 验证。
- 第一笔需要生成 384x384 材质图（4 次小型笔刷栅格化）；已缓存，但尚未在真实 App 测首笔延迟。
- 当前完整 diff 较大（约 13 个文件，包含此前未提交的旧工具替换），审查时按 `git diff` 工作，不要假设都来自最后一次修改。
- `TextureFillProceduralField.importedRegionAlphaBytes` 仍作为旧辅助和测试存在，但新主路径不调用它；是否后续清理不是当前阻塞项。
- 编译仅见项目既有 Sendable warnings（`StageOneBrushRenderer` / `TimelapseRecorderController`），本轮没有新增编译错误。

## Suggested skills

- `computer-use:computer-use`：完成真实 macOS App UI 和绘画操作验证。
