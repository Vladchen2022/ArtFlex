# 右侧参数／图层空间适配（2026-09-08）

## 范围与决策

本批只调整现有右侧检查器的纵向空间分配。保留两列、导航器／笔尖、参数标签、图层和资源库的职责，不改笔刷引擎、图层像素、工程格式或 3D 操作。

复现的问题：普通画笔模式的参数区不可压缩，固定高度导航器进一步占用空间，图层列表与底部按钮会被挤压／裁切；选中曲线调整层时，属性编辑器也会争抢列表高度。

复用现有 InspectorPanel、参数控件、图层列表及 SwiftUI DragGesture。分隔偏好使用 AppStorage，内容高度使用 onGeometryChange。已核对本机 Apple SDK 接口：单值 action 重载支持 macOS 13，符合本工程 macOS 14 最低版本。几何转换只读取局部不可变尺寸配置，不跨线程读取 WorkspaceViewModel。

参考：

- [Apple AppStorage](https://developer.apple.com/documentation/swiftui/appstorage)
- [Apple onGeometryChange](https://developer.apple.com/documentation/swiftui/view/ongeometrychange(for:of:action:))
- [Apple NSSplitView autosaveName](https://developer.apple.com/documentation/appkit/nssplitview/autosavename-swift.property)

NSSplitView 可保存分隔位置，但本需求还要按内容自动收拢，并对缩小窗口只作临时限制。为此增加 AppKit 托管层的改动比小型 SwiftUI 布局组件更大，故不引入；没有新增依赖。

## 代码改动

- `Platform/macOS/UI/InspectorPanelSplit.swift`：独立高度分配策略、18 点拖动区、双击／辅助功能复位、按标签保存分隔偏好。缩小窗口不覆盖已保存偏好；长参数情况下给图层面板保留 264 点。
- `Platform/macOS/UI/RightInspectorView.swift`：取消紧凑／完整参数两条不同布局路径；标签固定、参数内部滚动；短内容让出空间；导航器／笔尖预览在 160–264 点面板内适配；图层属性独立滚动，保留列表和底部操作区。
- `Tests/ArtFlexTests/InspectorSplitLayoutTests.swift`：7 项高度计算、极限、无效几何与偏好恢复测试。
- `Tests/ArtFlexTests/TextureFillPhase0Tests.swift`：删除已不存在的紧凑／完整布局分支测试，不删除纹理填充行为测试。
- `Platform/macOS/Distribution/Info.plist`：构建号 20260908.15。

## 界面验证记录

使用 Computer Use 在实际 ArtFlex 窗口操作，没有用后台 API 代替界面验收。

- 普通画笔面板、多个图层、底部操作按钮可见；测试工程中通过按钮新增 8 个图层和 1 个曲线调整层。
- 拖动分隔条，将参数区从 286 点缩至 134 点，列表显示更多图层；反向拖动到上限时仍保留图层区域。
- 参数滚到底后，三个标签仍能直接切换；下方组合笔刷入口可滚动到达。
- 曲线调整层属性可独立滚动到 RGB 等底部控件，图层列表／操作栏不随它滚走。
- 工具参数偏好 286 点跨正常退出／重启恢复；曲线偏好改为 320 点后，两个标签来回切换分别保留 286／320 点。
- 矩形选区的空参数区最终收拢至 63 点；切回画笔恢复 286 点。
- 已查看普通窗口、最大化和系统全屏状态。窄窗口沿用已有“检查器”弹出入口；工具截图不能完整覆盖伸出主窗口的弹出层，不据此声称该弹出层已完成全面验收。
- 当前显示器之外的缩放比例、实体外接屏、所有最小尺寸组合尚未穷尽验收。高度策略测试不等于上述真机验证。

界面测试发现并修正了两处初版问题：标签被一起滚走，以及空参数内容未能正确触发收拢。最终使用固定标签与原生几何回调。不能把最初后台计算测试通过当作初版界面已通过。

## 回归结果与限制

新增 7 项布局测试通过。全量回归运行 902 项／83 套时暴露了不稳定用例，不能写成全量通过：

- 前两轮：`colorAdjustmentSelectionSessionRebuildsWhenCommittedSelectionChanges` 的第二选区 RGB 预览断言失败；单独运行通过。
- 第三轮：上述调色测试通过，但 `projectSaveUsesSingleBatchTextureSnapshotForAllLayers` 的全局性能记录断言失败。
- 最终将这两个用例一并缩小范围复测：2 项均通过（0.863 秒）。这不能抵消全量失败，也不能证明根因已修复。

本批没有修改上述调色／保存实现，也没有删除或放宽这些断言。保存用例使用全局 PerformanceAuditStore，存在测试相互影响的合理怀疑；调色测试涉及异步预览等待。尚不能把这些失败确定归因为测试问题，也不能据此认定发生工程丢失。建议下一批先定位回归的不确定性，再开始磁盘辅助撤销。

完整日志在 `/tmp/artflex-inspector-tests-20260908.log`、`/tmp/artflex-inspector-tests-final-20260908.log`、`/tmp/artflex-inspector-tests-final3-20260908.log`；临时日志可能被系统清理，本记录保留关键结果。

后续收尾：构建 `20260908.18` 已补齐调色预览上下文失效处理，并隔离保存测试的共享计数；保留原断言，新增确定性回归，最终三轮全量各 913 项通过。详见 [调色与保存回归稳定性](PREVIEW_SAVE_REGRESSION_20260908.md)。以上历史失败记录保留，不以之后通过覆盖原始事实。

## 数据保护与手测清单

原工程备份与旧应用压缩备份位于 `/Users/victorcloux/Downloads/ArtFlex-面板适配备份-20260908-MAssdk/`。界面绘画／图层测试使用该目录下的 `面板适配测试.artflex`，不覆盖原画稿；旧应用只保存为 zip，不部署成第二个可启动版本。

最终已重新打开 `/Users/victorcloux/Downloads/ArtFlex-体块参考验收-20260906.artflex`，界面显示“已保存”和 2 个体块。原文件 SHA-256 仍为 `6ea802e145adfd6a2e6b8d3d6c53eb7efab0be7e5b257b596da53f2322844f1d`，与本轮开始前一致。

交付应用为 `.build/ArtFlex.app`、构建号 `20260908.15`。最终 Release 编译成功且无警告；安装二进制与 Release 二进制 UUID 均为 `F19703BA-CC71-3FB6-8E29-B9673CACEC0A`。最终版本再次从测试工程加载了 10 个普通图层和 1 个曲线调整层，完整曲线属性与列表均显示正常。

建议用户手测：

1. 将窗口缩到自己常用的最小尺寸；滚动工具参数，检查图层列表和新建／删除按钮始终可用。
2. 上下拖动参数与图层之间的短横条；双击后恢复自动分配。
3. 参数滚到底，直接点击“调色／曲线／工具参数”，无需先滚回顶部。
4. 为不同标签调整分隔位置，正常退出后重开，检查分别恢复。
5. 选中曲线调整层，滚动其属性区，检查图层列表与底部按钮不消失。
6. 矩形选区切到“工具参数”后，空区应收拢；切回画笔后，应恢复之前的可用高度。

本批完成后停止。下一批优先建议：调色预览异步等待与保存性能记录的回归可靠性排查；需用户再次确认开始。
