# 体块参考：观察导航修复

## 决策与原因

复用现有 `BlockReferenceInteractionView`、相机模型、实时相机渲染状态和文档撤销事务；不替换渲染引擎、不修改工程格式、不增加依赖。

参考了 Blender 官方默认键位定义，以及其观察旋转、缩放实现：

- https://github.com/blender/blender/blob/main/scripts/presets/keyconfig/keymap_data/blender_default.py
- https://github.com/blender/blender/blob/main/source/blender/editors/space_view3d/view3d_navigate_view_zoom.cc
- https://github.com/blender/blender/blob/main/source/blender/editors/space_view3d/view3d_navigate_view_rotate.cc

仅参照操作定义与坐标处理思路，没有复制 GPL 实现。Apple `NSResponder.otherMouseDown(with:)` 文档入口已检查，但网页正文抓取失败；实际沿用仓库现有 AppKit 鼠标、滚动与捏合事件接口。

已确认的故障：

1. 构图锁定会移除整个输入覆盖层，滚轮穿透到二维画布。旧版界面测试中，滚动后画布被移出视野，模型观察没有按预期缩放。
2. 锁定条件在相机、键盘、按钮三处重复拦截，临时观察中部分操作仍不可用。
3. 触控板精细滚动固定映射到平移，而且每个事件单独提交。
4. 相机接近顶视图时突然切换参考轴；连续拖动未在渲染前规范角度和距离。
5. Option 模拟中键时，已选左键导航模式覆盖了修饰键意图。

## 本次行为

| 操作 | 默认输入 |
|---|---|
| 环绕 | 中键拖动；触控板双指移动 |
| 平移 | Shift＋中键；Shift＋双指 |
| 缩放 | 滚轮；Ctrl＋中键；Ctrl＋双指；捏合 |
| 前后移动观察位置 | Ctrl＋Shift＋中键；Shift＋小键盘 ＋ / − |
| 前 / 右 / 顶 | 小键盘 1 / 3 / 7 |
| 后 / 左 / 底 | Ctrl＋小键盘 1 / 3 / 7 |
| 分步环绕 | 小键盘 2 / 4 / 6 / 8，每步 15° |
| 分步平移 | Ctrl＋小键盘 2 / 4 / 6 / 8 |
| 滚转画面 | Shift＋小键盘 4 / 6 |
| 正交 / 透视 | 小键盘 5 |
| 反面 | 小键盘 9 |
| 对准所选 / 全部 | 小键盘 . / Home；Shift＋C 显示全部 |
| 缩放 | 小键盘 ＋ / −；紧凑键盘 Ctrl＋= / − |

无中键设备可以用 Option＋左键模拟中键，叠加 Shift / Ctrl；也保留“环绕 / 平移 / 远近”按钮后的左键拖动。这是 ArtFlex 提供的便利入口，Blender 默认需在偏好设置中启用三键鼠标模拟。

锁定场景的第一次导航自动进入临时观察。原工程相机、模型和锁定状态不变；Esc、返回原构图或临时观察中的小键盘 0 返回保存构图。这里的小键盘 0 是 ArtFlex 的绘画构图语义，不是 Blender 独立 Camera 对象切换。

本次对齐日常观察导航，不引入 Blender 的漫游/飞行、局部视图、相机对象系统、鼠标侧键和 NDOF 控制器支持；轨迹球、灵敏度偏好与 Blender 的全部可配置行为不宣称完全一致。

## 回退与数据保护

- 上一批未完文件工作流单独保留为检查点 `f931c5b`，未将它冒充已完成验收。
- 本批分支 `codex/block-reference-blender-navigation`。
- 原画稿 `/Users/victorcloux/Downloads/ArtFlex-体块参考验收-20260906.artflex` 保持不变。
- 本批界面只使用 `/Users/victorcloux/Downloads/ArtFlex-3D导航验收-20260908-82t561/navigation-test.artflex`。
- 不修改/清理用户笔刷库、自动恢复文件或模型资源。

## 验证记录

修复前 4 个回归测试出现 17 个失败断言，记录 `/tmp/artflex-navigation-before.log`。

最终全量回归 896 项、82 套通过，38.757 秒（部署验收后再次运行）。新增 9 项覆盖锁定观察隔离、键盘导航、顶视连续性、实时参数边界、触控板累计事务、Option 修饰键优先级、旋转镜像画布中的平移、空选择定位，以及一次撤销/重做。日志 `/tmp/artflex-navigation-verified-tests.log`。

发布构建 20260908.14 成功，148.07 秒。日志 `/tmp/artflex-navigation-final-release.log`。安装包与 Release 文件 UUID 一致：`02E6289E-EA4C-3C76-B74D-94FC89C05015`；只运行一个 ArtFlex 进程。

## 实际界面验收

以下均通过 Computer Use 在应用窗口里操作，截图已随工具结果展示：

- [x] 锁定场景直接按小键盘 1、Ctrl＋1、7，分别显示前、后、顶视图；自动进入临时观察。
- [x] 通过环绕、平移、远近按钮后实际拖动画面，观察确实改变；二维画布四边保持固定。
- [x] Esc 返回原构图；再次发送滚动事件后只改变 3D 视角，不再把二维画布移出窗口。
- [x] Home、小键盘 ＋、Ctrl＋4、6 依次显示全部、放大、平移和环绕。
- [x] Shift＋4 后相机滚转显示 15°；小键盘 5 切换正交开关；小键盘 0 回到原相机数值。
- [x] 锁定期间以上观察操作保持绿色“已保存”状态；普通左键拖动与右键点击不能编辑模型。
- [x] 在测试副本中解锁，实际环绕后一次 Cmd＋Z 还原整次拖动，Cmd＋Shift＋Z 正确重做。
- [x] 选择人体后小键盘句点将人体放大并居中。
- [x] G 变换输入时，小键盘 1、2 正确输入“12”，没有切换视图；Esc 完整取消该变换。
- [x] 打开文件面板后发送小键盘 1、Home，取消后原模型视角未改变，工程仍显示已保存。
- [x] 已重新打开用户原工程 `ArtFlex-体块参考验收-20260906.artflex`，两体块完整，显示已保存。原文件 SHA-256 仍为 `6ea802e145adfd6a2e6b8d3d6c53eb7efab0be7e5b257b596da53f2322844f1d`。

界面控制接口不支持保持实体中键或模拟真实双指捏合。中键修饰键、触控板连续事务已做事件级测试；不能把它们称为用户物理设备已验收。普通滚轮与精细滚动设备上报类型不同，鼠标/触控板/数位笔驱动的实际手感仍需下方手测核对。

## 修改文件

- `Core/Application/BlockReferenceGeometry.swift`：稳定顶视相机基向量。
- `Core/Application/BlockReferenceState.swift`：观察前后移动模式。
- `Platform/macOS/App/WorkspaceViewModel+BlockReferenceNavigation.swift`：共用观察入口和 Blender 小键盘分流。
- `Platform/macOS/App/WorkspaceViewModel+BlockReference.swift`：连续相机导航、边界规范、平移、定位。
- `Platform/macOS/App/WorkspaceViewModel+BlockReferenceWorkflow.swift`：临时观察与按钮入口。
- `Platform/macOS/App/WorkspaceViewModel.swift`：阻止导航键抢占文件面板。
- `Platform/macOS/UI/BlockReferenceOverlay.swift`：中键、修饰键、触控板输入与事务合并。
- `Platform/macOS/UI/CanvasContainerView.swift`：锁定时保留导航层，同时屏蔽模型编辑菜单与悬停手柄。
- `Platform/macOS/UI/BlockReferenceParameterPanel.swift`、`BlockReferenceWorkflowControls.swift`：可用性与快捷键提示。
- `Platform/macOS/Distribution/Info.plist`：构建号。
- `Tests/ArtFlexTests/BlockReferenceNavigationTests.swift`、`BlockReferenceStateTests.swift`：回归测试与真实中键事件构造。

## 用户手测清单

1. 体块参考中，不选导航按钮，直接按住中键拖动，模型视角应环绕，模型位置与二维画布不变。
2. Shift＋中键向四个方向拖动，画面应跟手；Ctrl＋中键与滚轮应改变远近。
3. 触控板双指应环绕，Shift＋双指平移，Ctrl＋双指或捏合缩放。
4. 连续导航后试小键盘视图、环绕、平移、缩放及 Home；不要用键盘顶排数字替代小键盘。
5. 锁定参考并返回绘画，再回到体块参考，直接重复导航；无需先解锁。Esc 应完整返回原构图。
6. 未锁定时连续拖动后只撤销一次，应回到这一整次拖动之前，模型本身不能被移动。
7. 在相机数值框输入数字，以及打开文件选择窗口时，导航快捷键不能穿透抢走输入。
