# 磁盘辅助撤销（2026-09-08，已验收）

## 决策与范围

复用 `HistoryController` 的完整／局部／拓扑增量／纯元数据历史与 Metal 暂存恢复；复用 `ZlibCodec` 和 `ProjectReferenceImageHash`。原生 Foundation 文件句柄、NSLock、串行 DispatchQueue 足以实现缓存，不引入依赖，不更换笔触、颜色、图层或工程格式。

[Apple UndoManager](https://developer.apple.com/documentation/foundation/undomanager/levelsofundo) 解决操作组与步数，不替代这里的像素快照存储。[Apple NSCache](https://developer.apple.com/documentation/foundation/nscache) 允许自动淘汰，不能保存只有唯一副本的撤销像素。

## 实现

- 历史上限由 24 步改为 128 步，仍受存储预算约束，不承诺所有画布都保留 128 步。
- 每个撤销／重做方向最近 8 条优先留在内存；超出内存预算时可提前转存。原有自适应像素内存预算保留，上限 768 MiB。
- 每个工作区磁盘预留预算 2 GiB，按未压缩像素保守预留；实际磁盘占用显示压缩后的大小。工作区元数据和恢复时的临时 GPU 资源不计在“像素历史”数字内。
- 4 MiB 分块、zlib level 1；压缩变大时存原块。串行后台写入及校验，校验完成才释放内存副本。不把整个工程编码成 JSON，也不复制素材库到每个磁盘记录。
- 读取前核对文件长度及每块 SHA-256，解压使用已知长度。损坏／缺失时不弹出历史记录，不改变当前图层。
- 多步历史预览先校验所需磁盘记录；取消恢复失败时保留预览会话并标记未保存，不谎报已恢复。恢复期间其他错误造成部分跳转时也刷新画面与未保存状态。
- 新笔触清除旧重做分支、工程切换清空历史；后台未完成记录被取消后不能重新出现。超预算只移除最旧连续尾部，不挖掉中间的增量记录。
- 待写队列同样受内存保护；写盘失败保留内存副本，后续超预算退回最旧优先裁剪，并显示警告。
- 缓存独立于自动恢复，放在当前进程／工作区专用目录。正常释放清理；启动时只清理已退出进程的缓存目录，保留活跃进程和符号链接。
- 历史窗口显示内存、实际磁盘大小、磁盘记录数、转存状态和错误提示。只改原有历史窗口，不新增主面板。

### 界面验收发现的落笔／快捷键竞态

在真实画布落笔后立即按重做，曾观察到新笔触不完整。确定性用例不让显示帧执行就结束落笔并调用撤销／重做；产品修正前两项测试共 5 项断言失败。原因是只 drain 提交队列，再 reset 会话，丢掉仍在 `liveEvents` 中的未编码输入。

复用现有 `flushPendingBrushWorkAtEditingBoundaryIfNeeded`，在 drain/reset 前处理未编码输入；历史跳转还检查队列是否真正完成，捕获失败不跳转、不丢任务。没有改笔刷着色算法。修正后同样两项测试通过，相关 40 项定向回归通过。

参考 [Apple CPU/GPU 同步](https://developer.apple.com/documentation/metal/synchronizing-cpu-and-gpu-work)，核对编码、提交、完成后再复用资源的顺序；不是复制该示例的渲染器。

## 文件

- `Infrastructure/FileFormat/HistoryDiskCache.swift`
- `Core/Application/HistoryController.swift`
- `Platform/macOS/Services/HistoryCacheDirectory.swift`
- `Platform/macOS/App/AppBootstrap.swift`
- `Platform/macOS/App/WorkspaceViewModel.swift`
- `Platform/macOS/UI/VisibleHistoryPopover.swift`
- `Tests/ArtFlexTests/HistoryDiskCacheTests.swift`
- `Tests/ArtFlexTests/HistoryControllerTests.swift`
- `Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift`
- 构建号与本验收记录。

## 当前测试证据

- 定向 37 项通过，0.631 秒，覆盖 30 笔完整像素的逐步撤销／重做、跨压缩块、蒙版类型与区域元数据、截断／损坏／写入失败、预算裁剪、分支清理、待写取消、过期进程缓存清理。
- 全量 924 项中，新增磁盘历史及预览恢复失败保护测试通过；已有 `QuickColorPickerHUDTests` 两项失败，单独 8 项复测通过。不能称该次全量通过，后续独立排查。
- 修复快捷键竞态并补充捕获失败保护后，全量 **927 项／85 套通过，37.999 秒**。一次通过不解释前一轮颜色缓存的偶发失败，该项转入独立模块继续调查。
- 最终 Release 构建通过，104.30 秒；`git diff --check` 通过。
- 编写测试时修正过坐标类型、失效表面 ID 与私有状态访问的测试问题，没有把它们当作产品像素故障。
- 日志 `/tmp/artflex-disk-undo-targeted-4.log`、`/tmp/artflex-disk-undo-full-2.log`、`/tmp/artflex-disk-undo-color-cache-check.log`、`/tmp/artflex-disk-undo-mouseup-before.log`、`/tmp/artflex-disk-undo-mouseup-after.log`、`/tmp/artflex-disk-undo-full-3.log`、`/tmp/artflex-disk-undo-release-final.log`。

## 直接界面验收

通过 Computer Use 控制已安装的 ArtFlex，不使用测试接口代替界面绘画。

- 1600×1600 独立工程中画出三列共 30 笔。历史显示 30/30，22 步转存磁盘；当时像素历史内存 1.3 MB、磁盘 17 KB。这个压缩比例仅对应稀疏小笔触测试，不能推广到普通画稿。
- 拖历史滑块到 0，画布恢复白底；取消预览，30 笔完整返回。
- 连续撤销 12 次、重做 12 次，画面对应减少并恢复。
- 早期界面分支测试发现落笔后立即重做会损失新输入，已按上文修复，没有把早期失败算通过。
- 安装最终修复版后：落笔立即重做，整笔保留且提示无可重做；撤销后画新分支并立即重做，新分支保留、旧笔触不复活；落笔立即撤销后再重做，完整笔触恢复。
- Cmd+S 保存到测试工程，界面显示“已保存”。通过原生打开窗口重开，所有保存的笔触与两个图层保留。
- 重开后历史窗口显示内存 0 KB、磁盘 0 KB、0 步；没有把旧会话历史带入新载入的工程。

鼠标的界面事件间隔不能严格控制在一帧内；未编码输入竞态同时由不等待下一帧的确定性回归覆盖。

## 数据保护与回退

- 分支 `codex/disk-assisted-undo`，基线 `caf1950`。
- 原工程 `/Users/victorcloux/Downloads/ArtFlex-体块参考验收-20260906.artflex`。
- 备份目录 `/Users/victorcloux/Downloads/ArtFlex-磁盘撤销备份-20260908-DJGrRi/`，含原工程和构建 18 的应用压缩包。
- 原工程 SHA-256 `9adc181792cfb3e741a9f89c3276212d8e2dceaaa64210402859dfd7ac5b594c`。
- 界面验收使用单独的 `ArtFlex-磁盘撤销验收-20260908.artflex`，1600×1600。原工程哈希复查未变。
- 已安装构建 `20260908.19`，应用与 Release 的 UUID 为 `255BB0E6-9640-365F-9B9A-98E3112658EF`，代码签名验证通过。保存测试工程后正常退出再更新，没有强杀。

## 用户手测清单

1. 在测试工程连续画至少 30 笔，打开顶部历史窗口，确认步数超过原先的 24 步，等待后能看到磁盘记录。
2. 拖到较旧的状态，取消后应回到打开历史前；再次选择旧状态并应用，画布应保留该状态。
3. 连续撤销／重做，观察每一步只对应预期操作。撤销后画新笔触，旧的重做分支应被清除。
4. 刚松开鼠标就按 Cmd+Z，然后 Cmd+Shift+Z，新笔触应完整回来；直接 Cmd+Shift+Z 不应吃掉新笔触。
5. 保存并重开，图层和像素保留，历史清空。缓存故障使用自动故障注入验证，不建议手动破坏用户工作目录。

## 边界

撤销缓存不是持久历史，关闭工程／应用后不保证保留；不能替代正式保存及自动恢复。冷记录回读仍经过现有同步撤销入口，极大快照的磁盘读取／GPU 恢复可能出现等待，本批没有宣称它完全无延迟。真正稀疏图层、增量自动恢复和共享分支底稿仍是后续模块。

用户已授权后续按优先级连续推进，不再逐批等待确认；模块仍单独提交和验收。
