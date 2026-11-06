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
