# 应用退出后图标丢失修复

日期：2026-10-06。分支：`codex/persistent-app-icon`。打包修复提交：`a6021c7`。

## 原因与决策

`ArtFlexApp.swift` 只在启动时通过 `NSApp.applicationIconImage` 设置 PNG。分发用 `Info.plist` 没有 `CFBundleIconFile`，应用主资源目录也没有 `.icns`。因此运行时能显示自定义图标，退出后系统无法从应用包解析图标。

复用 `Platform/macOS/Resources/AppIcon.png`，通过系统自带 `sips` 与 `iconutil` 生成标准 1x/2x 图标，在主资源目录声明和安装。未新增依赖，未改变绘画代码、图案设计或文档格式。运行时 PNG 设置继续保留，支持现有开发启动方式。

参考 Apple [CFBundleIconFile 说明](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html#//apple_ref/doc/uid/TP40009249-SW10) 和 [应用包结构](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html)。系统从应用主资源目录读取声明的图标；SwiftPM 子资源包中的 PNG 和运行时图标设置不能代替这一声明。

## 修改

- `Platform/macOS/Distribution/Info.plist`：声明 `AppIcon.icns`，分发构建号更新为 `20261006.32`。
- `Platform/macOS/Distribution/package-app.sh`：从已有编译产物打包，生成图标、复制资源、校验配置并签名；输出已存在时拒绝覆盖。
- `README.md`：记录统一打包命令，避免后续手动打包再次遗漏图标。

## 安装与验证

- 确认 Dock 固定入口是 `.build/ArtFlex.app`，更新前已退出。
- 对固定入口原包只补充图标及配置并重新签名，保留 `20261002.30` 的功能版本。
- 上一轮 `.build/ArtFlex-交互改进.app` 同步补齐图标，分发号为 `20261006.32`。
- 新打包脚本实际生成 `.build/ArtFlex-icon-fixed.app`，配置校验与 `codesign --verify --deep --strict` 均通过。
- 通过 CUA 在 Finder 实际观察：程序未运行时，三个修复后的应用包均显示红色 A 图标，未修复的历史包仍显示系统默认图标。
- 通过 CUA 启动固定入口对应应用，再用 Cmd+Q 完全退出；进程列表确认已退出，Finder 中图标仍正常。未打开、恢复、编辑或保存画稿。
- 对固定入口执行定向 Launch Services 重新登记后，用户反馈 Dock 仍显示默认图标；重启 Dock 后用户再次确认未恢复。因此没有以 Finder 结果宣告 Dock 修复完成，也没有继续重复刷新。
- 核对原入口的 URL 与实际解析书签，均指向 `.build/ArtFlex.app`，书签未失效。单靠上述结果无法确定 Dock 内部缓存未更新的具体原因。
- 用户指出尚未正式安装。检查确认系统及用户的 Applications 目录均不存在 ArtFlex，于是用统一打包脚本正式安装 `/Applications/ArtFlex.app`（`20261006.32`，包含上一轮十项交互改进）。
- 参考 Apple [Dock 项目管理](https://support.apple.com/en-gb/guide/mac-help/mh35859/26/mac/26) 和 [dockutil 的 Dock.swift](https://github.com/kcrawford/dockutil/blob/main/Sources/DockUtil/Dock.swift) 中的入口替换方式，先备份固定入口列表，再通过原生 CFPreferences 将 ArtFlex 项重建到正式路径。保留它在固定应用列表中的第 8 个位置，核对其他应用的数量、顺序和目标路径均未变化。此一次性安装修复没有增加项目依赖。
- 通过 CUA 启动正式安装版，进程路径确认为 `/Applications/ArtFlex.app/Contents/MacOS/ArtFlex`，随后 Cmd+Q 退出并确认进程消失。Finder“显示简介”实际显示位置为“应用程序”，退出后红色 A 图标正常，应用签名校验通过。
- Dock 本身无法由当前 CUA 工具读取（两次超时），重建入口后的显示待用户前台确认。

本次只有包配置和打包脚本变化，复用上一轮已编译的 Release 产物，无需重新编译绘画核心或运行后台功能测试。更新前后应用可执行文件的 UUID 均保持一致；重新签名会改变二进制签名及文件摘要。

## 回退与边界

更新前两个应用包完整备份在 `.build/icon-fix-backups-20261006/`；该目录的 `dock-persistent-apps.plist` 保存重建前的固定入口列表。退出应用后可按同名恢复应用。若需回退 Dock，应只恢复其中 ArtFlex 这一项，避免覆盖后续其他入口调整。Git 中不包含这些构建产物；代码与打包流程可单独 revert 本次修复提交。

已有 `HANDOFF.md` 修改保留原状，未加入本次提交。本机签名仍为开发用 ad-hoc 签名，未进行公证分发。
