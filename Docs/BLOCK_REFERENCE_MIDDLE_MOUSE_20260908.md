# 体块参考：真实中键输入路由

## 状态

修复实现、事件回归和最终版界面复查已完成。用户明确确认：“鼠标和压感笔都正常了，都可以使用中键。”实体设备确认与自动化测试分别记录，不以合成事件测试替代用户设备验收。

## 实测证据与判断修正

旧版安装构建 20260908.15，PID 2201。普通合成 OtherMouseDown（buttonNumber 2，windowNumber 22019）会命中 `BlockReferenceInteractionView`，并调用相机导航 begin。

用户真实鼠标 Shift＋中键拖动，在不暂停程序的 AppKit 本地记录中出现：

```
t=14 flags=131074 loc=1567,877 win=0
t=27 b=2 flags=131074 loc=1567,877 win=0
t=27 b=2 flags=131074 loc=1938,845 win=0
t=14 flags=131074 loc=1938,845 win=0
t=5 b=0 flags=131074 loc=1434,494 win=22019
```

没有正常窗口关联的按下事件，但中键拖动确实到了应用，坐标为屏幕坐标。原视图依赖 `otherMouseDown` 建立状态，后续事件又无法被 AppKit 路由到该视图，因此不会导航。“中键没有进入软件”的早期结论不成立。

数位笔记录包含 TabletPoint、笔尖 LeftMouseDown/Dragged 及 windowless OtherMouseUp。不能把原始笔侧键 bitmask 直接当作用户配置后的中键。修复后用户已确认数位笔映射的中键恢复工作；这不等于已逐一验收所有驱动、悬空与接触组合。

本地记录已移除，调试器已正常 detach，未强制退出或重启驱动。

## 参考与复用决策

- Apple 事件监听生命周期：<https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html>
- Apple IOLLEvent.h 的 `NX_SUBTYPE_AUX_MOUSE_BUTTONS`，data1 为变化位，data2 为当前按下位，bit 2 为中键：<https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDSystem/IOKit/hidsystem/IOLLEvent.h>
- Blender Cocoa 的 `handleMouseEvent`，没有关联窗口时回退到活动窗口：<https://github.com/blender/blender/blob/main/intern/ghost/intern/GHOST_SystemCocoa.mm>
- Qt 的 Cocoa tablet 处理区分物理笔键与映射后的鼠标按键：<https://github.com/qt/qtbase/blob/dev/src/plugins/platforms/cocoa/qnsview_tablet.mm>

沿用仓库 `OutsideCanvasBrushEventView` 的本地监听、挂载/卸载模式；不复制其 nil 合并写法，因为已消费事件的 nil 必须原样返回，不能通过 `?? event` 再次放行。相机算法、渲染、文档与撤销事务继续复用。不复制外部实现，不新增依赖。

## 改动边界

- 新增仅挂在 3D 交互视图的中键捕获器，统一标准中键、辅助按键和无窗口拖动的入口。
- 无窗口事件先由 screen 转 window，再转 view，保留上下方向和窗口位置。
- 首次拖动缺失 down 时，仅在活动窗口的 3D 命中区域接续；面板、输入框、其他窗口、模态面板不接管。
- 重复 down 不重复建立事务；按键松开、失焦、视图移除结束一次捕获。
- 已拥有中键手势期间，数位笔接触产生的左键事件不编辑模型。未确认中键的普通笔尖输入不被擅自改为导航。

## 回归验证

- 修复前：普通原生窗口事件测试通过；windowless auxiliary 测试 begin/change/end 三项失败。
- 命令行测试宿主不能正常成为活动 GUI 应用，windowless 用明确的测试窗口 key-owner 属性验证，不要求抢占用户应用焦点。
- 初版修复后：体块相关 100 项 / 8 套通过。随后新增“面板按下后拖入画布不接管”保护，共新增 8 项输入测试。
- 最终源代码全量 910 项 / 84 套通过（38.310 秒），日志 `/tmp/artflex-middle-final-tests.log`。
- 最终 Release 构建成功（96.92 秒），日志 `/tmp/artflex-middle-final-release.log`。
- 日志 `/tmp/artflex-middle-regression.log`。

## 安装与屏幕状态

初版修复 20260908.16 安装后，用户用实体鼠标和数位笔确认中键恢复工作。该版与 Release UUID 均为 `DA56F288-F346-329F-8475-D576973174E4`。

最终 20260908.17 增加“面板按下后拖入 3D 区域不接管”的边界保护，已安装到 `.build/ArtFlex.app`，安装二进制与 Release UUID 均为 `63AC1B4B-F5B9-31EE-A5F2-B1720698BDD8`。代码签名验证通过，最终检查只有一个 ArtFlex 进程 PID 12793。未重启或改动输入设备驱动。

最终版直接在软件界面、独立验收副本中复查：

- 两个原有体块完整载入，画布位置保持不变。
- 点击“环绕”，使用界面控制的左键拖动，水平从 63.64892578125° 变为 30.63173828124999°，俯仰从 19.00271606445314° 变为 35.99686279°；一次 Cmd+Z 恢复原始相机参数和画面。这验证共用导航处理与单次撤销事务，不冒充实体中键拖动。
- 面板中键点击后，相机水平、俯仰、距离未变化。
- “锁定参考，返回绘画”可切回画笔；重新进入体块参考仍保留锁定。
- 锁定状态下，画布中键点击触发“正在临时观察；原构图已保留”；Escape 后显示“已返回原构图”，模型编辑仍保持禁用。
- 验收副本通过界面保存，随后重新打开原工程。原工程内容哈希与最初保护性保存后的值一致，测试未覆盖原工程。

## 画稿保护

备份目录 `/Users/victorcloux/Downloads/ArtFlex-中键修复备份-20260908-dYDAkg/`。

- `保存前画稿.artflex` 保留修复前磁盘状态，SHA-256 `6ea802e145adfd6a2e6b8d3d6c53eb7efab0be7e5b257b596da53f2322844f1d`。
- 通过原生保存按钮保留用户当前未保存内容。原工程保存后 SHA-256 `4f2e9e92fa344c6973b6e8f985d90b126907aa97876af538956b1617f6f0ea32`。
- `中键验收副本.artflex` 从上述已保存工程复制，后续界面测试仅使用此副本。

## 验证边界

- 实体鼠标与数位笔中键可用，由用户实测确认。用户未逐一说明所有修饰键及悬空/接触状态，不把这些细分项写成已全部人工验收。
- 缺失 down、无窗口坐标、重复 down、笔尖接触、失焦、视图卸载、面板与其他窗口排除、越界拖入等由事件回归测试覆盖。
- 界面控制工具只能执行中键点击，不能持住中键拖动。环绕拖动与一次撤销的可见测试使用现有“环绕”按钮加左键，实体中键的结论来自用户确认。
- 当前硬件故障已关闭；其他驱动版本和长时间连续操作没有在本轮穷举。

## Git 回退

源代码提交 `1796af9`，上一个基线 `99dea06`。需要回退时可撤销该独立提交；不应重置整个工作区。旧安装包归档在上述备份目录的 `ArtFlex-20260908.15.zip` 中。
