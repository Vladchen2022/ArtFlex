# 临时工具与画布图层查找

范围仅为用户批准的功能 1、2。基线 `940d6ca`，分支 `codex/painting-convenience-20261106`，回退标签 `backup/pre-painting-convenience-20261106`。原有 HANDOFF.md 不编辑、不提交。

## 决策

- 复用 ToolSessionState 的画笔/橡皮/涂抹参数槽、现有 selectTool/笔触提交边界、快捷键设置和 WorkspaceEditingSessions。
- 复用 CanvasCompositeInputPlan 的可见性、组透明度、蒙版及剪贴关系，以及 LayerTextureSerializer 的局部异步读回。命中判断读少量像素，不拷贝整幅画布；候选预览复用现有 GPU 缩略图能力。
- 原生 AppKit keyDown/keyUp、窗口失焦通知和 NSPopover 足以承担平台交互。只编写项目所需的临时工具状态与图层命中规则，不增加第三方依赖。
- 参考 Apple [NSEvent](https://developer.apple.com/documentation/appkit/nsevent)、[NSPopover](https://developer.apple.com/documentation/appkit/nspopover)；交互参考 [Photoshop 按住工具快捷键](https://helpx.adobe.com/nz/photoshop/desktop/get-started/set-up-toolbars-panels/spring-loaded-shortcuts.html)。

## 实施与验收计划

1. E/T/R 对应工具快捷键支持短按切换、长按松开恢复；尊重自定义键位，忽略自动重复。正在落笔时不截断笔触，松键后完成笔触再恢复；失焦与文档切换回收临时状态。
2. Cmd+Option+点击画布弹出命中图层，按顶层到下层列名称、组路径、锁定状态和缩略图；悬停放大预览，确认只改变活动图层。隐藏、零透明度、蒙版完全遮挡、无效剪贴像素不命中；被上层遮住但在此处有内容的下层也列为候选。调整层不作为像素内容层。
3. 处理弹出面板取消、过期请求、文档/方案切换、文本框焦点和按键抬起时仍绘画等边界。保持原有 UI 布局。
4. 纯状态、Metal 像素、真实命令和回归测试通过后构建安装；在真实窗口验证短按/长按、画布点击候选、选择/取消和撤销隔离。最终补充证据与操作说明。

## 实现结果

仅实现两项批准功能，不包含其余三项建议。最终应用构建号为 `20261106.48`。

| 功能 | 原行为 | 新行为 |
| --- | --- | --- |
| 临时工具 | E/T/R 切换后需要再次选择原工具 | 短按保留原行为；按住超过 0.25 秒，松开恢复原工具及原笔刷参数。松键时仍落笔则等抬笔后恢复。尊重自定义工具快捷键。 |
| 画布图层查找 | 主要依靠图层面板逐项寻找 | Cmd+Option+点击或右键「查找此处图层」，按堆叠顺序列出该像素的内容层；显示名称、组路径、锁定状态、缩略图，并可悬停查看单层内容。选中只改变绘画目标。 |

### 实现边界

- 临时工具状态放在 `MomentaryToolState` / `WorkspaceMomentaryTools`；窗口失焦、文档切换、主动选其他工具会收回状态。现有模态编辑及色彩调整专属快捷键继续优先处理。
- 图层命中在 `CanvasLayerPicker` 中复用规范化合成输入。命中只读取候选纹理各一个像素，计入蒙版、剪贴和组透明度；预览在 GPU 上缩到最长边 256 像素后读回。
- 预览为单层内容预览，使用正常混合；不代表该层与其他图层混合后的最终颜色。隐藏层、有效覆盖率低于 1/255 的像素和调整层不列为内容候选；被上层遮挡的下层仍可查找。
- 不自动解锁图层；查询后文档或像素状态变化会使请求失效，避免选中旧文档的图层。
- 平台事件和弹出面板使用 AppKit / SwiftUI，没有新增依赖、工程格式字段或持久化偏好。

### 改动文件

- 状态：`Core/Tools/MomentaryToolState.swift`、`Core/Layer/CanvasLayerPickCandidate.swift`。
- 交互接入：`Platform/macOS/App/WorkspaceMomentaryTools.swift`、`WorkspaceEditingSessions.swift`、`WorkspaceViewModel.swift`。
- 渲染及界面：`Rendering/Canvas/CanvasLayerPicker.swift`、`Platform/macOS/Canvas/MetalCanvasHost.swift`、`Platform/macOS/UI/CanvasLayerPickerPopover.swift`、`CanvasContainerView.swift`、`SettingsSheetView.swift`、`ToolSidebarView.swift`。
- 验证与版本：`Tests/ArtFlexTests/PaintingConvenienceTests.swift`、`CanvasLayerPickerTests.swift`、`Platform/macOS/Distribution/Info.plist`。

### 自动测试

- 新增 13 项测试（参数化覆盖 E/T/R 以及 rgba8 / rgba16Float），全部通过。
- 修正悬停后的全量 `swift test`：**1,144 项、127 个套件通过，25.786 秒**。日志 `.build/convenience-evidence/full-tests-final.log`。首版 1,143 项通过记录保留在 `full-tests.log`。
- 覆盖短按、长按、自动重复、按键交叠、落笔中松键、真实橡皮像素及撤销、失焦、文档停用、蒙版目标恢复、模态按键优先级、原生画布事件分发、弹窗吞掉 mouseUp 后继续绘画。
- 覆盖堆叠顺序、单像素位置、透明度、父组隐藏及锁定、蒙版和剪贴、异步读回时点、256 像素预览及其颜色/透明度、选择和取消不修改像素/撤销历史/脏标记、内容或文档变化后的失效请求。
- 测试先发现并修正了提交边界接口返回值的误用；同时补上弹窗消费鼠标释放事件后下一笔恢复的回归测试。未把失败运行计作通过。

### 安装与前台验收

首版安装于 `/Applications/ArtFlex.app`，版本 `20261106.47`；签名、资源、构建 UUID 与清单校验通过，`sourceDirty=false`。运行源码提交 `d7eed9921d9c9ce27f12c567dde034b4b8fb071d`，源码指纹 `0719640e01985235487e93be7862baf97851de4a19bb054547b4cf87b54fab26`。

在独立的 800×800 验收画布上，通过可见界面操作确认：

1. 画红色横线，按住 E 点击擦除，松键返回画笔，大小保持 60；画布出现明确擦除缺口。
2. Cmd+Z 恢复横线，Cmd+Shift+Z 恢复擦除缺口。
3. 短按 E 保持橡皮；返回画笔后分别长按 T、R，均显示「已返回画笔」。
4. 新建上层并画竖线，交叉位置 Cmd+Option+点击列出「图层 3 → 图层 2 → 背景」，缩略图与大预览能区分横线和竖线。
5. 选中图层 2 后工具保持画笔，可继续画斜线；再次打开候选并按 Esc，活动图层保持图层 2。
6. 在空白处右键查找，仅列出背景。
7. 锁定图层 3 后，候选显示锁图标及「已锁定」，未自动解锁。

首版 20261106.47 的悬停预览未通过用户手测：移动到图层 2 后仍显示图层 3 的竖线。没有将首版记作验收完成。

修正采用 AppKit `NSTrackingArea`，参考仓库 `ReferenceImagePanelSupport.swift` 和 Apple [Using Tracking-Area Objects](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/TrackingAreaObjects/TrackingAreaObjects.html)。候选行设置 `activeInActiveApp` / `mouseEnteredAndExited` / `mouseMoved` / `inVisibleRect`，并启用面板窗口的鼠标移动接收；跟踪视图不参与点击命中，保留原按钮的选择路径。没有轮询鼠标，也没有添加全局监听器。新增原生非主窗口跟踪与点击穿透回归测试。最终前台复测结果另列。

### 回退

- 源码基线标签：`backup/pre-painting-convenience-20261106`（`940d6ca`）。功能提交：`d7eed99`，悬停修正：`da5652c`；执行 `git revert da5652c d7eed99` 可按从新到旧的顺序撤销功能代码。
- 安装前版本 20261106.46 备份：`.build/install-backups/20261106-224114-727116-ArtFlex.app`。
- 退出 ArtFlex 后，可运行 `python3 Platform/macOS/Distribution/release.py rollback .build/install-backups/20261106-224114-727116-ArtFlex.json` 恢复应用；此操作不会修改画稿。
- 原有未提交的 `HANDOFF.md` 未编辑、未纳入提交，SHA256 仍为 `b3186f8c6d66c28f8d7a4b74c9f82630b74113149f37e797eeacd5d65cb859d4`。

### 修正版构建核对

- 最终安装版本：`20261106.48`，路径 `/Applications/ArtFlex.app`。
- 源码提交：`da5652c4bf4a24f1a28e6cfb5cf17a31b2af577a`，`sourceDirty=false`。
- 源码指纹：`c073ef363504f447fb90a9d917a51c5a574115682a804160afd6c59239461bdb`。
- 构建 UUID：`420ADC5F-6127-3B3C-859D-DD06857A2957`。签名、资源及安装清单核对通过；证据 `.build/convenience-evidence/verify-app-final.json`。
- 验收画稿：`/Users/victorcloux/Desktop/ArtFlex-Convenience-20261106.artflex`，已通过软件界面保存并重新打开。
- 第二次安装另保留了 .47 备份 `.build/install-backups/20261106-225229-821009-ArtFlex.app`；需要整体撤销本次功能时应使用上面的 .46 备份。

### 最终前台复测

用户重新将真实鼠标移到候选「图层 2」后，回复「出现了」。随后通过界面截图独立核对：图层 2 候选行高亮，大白框同时显示带擦除缺口的横线和斜线；上层竖线不出现在该单层预览中，主画布保留完整的横线、斜线和竖线。**悬停预览复测通过**。

最终保留该弹窗，方便继续手测。验收工程之前已经保存；最后用户操作后界面存在未保存标记，未擅自覆盖用户刚进行的操作。安装版本 .48、自动测试及真实界面验收均完成。现有编译警告来自 ZIPFoundation 的 watchOS 最低版本声明和体块渲染中的恒真条件，本次未扩大范围修改。
