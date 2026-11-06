# ArtFlex 十项稳定性改造执行记录

日期：2026-11-06。基线：`2e2446061a2efa42900798a7f172e82a0ad3eede`。
分支：`codex/stability-overhaul-20261106`；回退标签：`backup/pre-stability-overhaul-20261106`。
原有 `HANDOFF.md` 修改不属于本任务，不编辑、不提交。

## 决策与范围

复用现有 DocumentSessionController、ProjectOpen/SaveCoordinator、DocumentLifecycleCoordinator、ProtectedLibraryFile、HistoryDiskCache、TileGrid、LayerChangeJournal、稀疏图层与失败前暂存机制。保留产品布局与标准化 Metal 像素真相源。

采用 Foundation 文件协调、Swift actor/Task、Metal 完成检查和已有分块传输。资源和编辑事务需要项目自身的所有权模型；原生框架不能替代文档版本、像素历史和工具会话语义。不引入第三方依赖，不重建一套 CPU 画布。

参考：
- Apple 文件协调：https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system
- Apple 主线程响应：https://developer.apple.com/documentation/xcode/improving-app-responsiveness
- Metal 设备预算：https://developer.apple.com/documentation/metal/mtldevice/recommendedmaxworkingsetsize

## 顺序与验收

| 项目 | 计划 | 验收重点 | 状态 |
| --- | --- | --- | --- |
| 1 | 恢复源与会话目录分离；成功后接管；发现旧代和方案副本 | 失败、取消、关闭后原副本字节不变；旧代可发现 | 已实施；恢复专项 10 项通过 |
| 2 | 应用共享素材库与单一持久化队列 | 双文档交错增删/保存/退出不丢更新 | 已实施；素材/方案/会话专项 43 项通过 |
| 3 | 文件身份、写入租约与外部变化检查 | 同目标另存为、并发保存、外部替换安全拒绝 | 已实施；文件流程专项 44 项通过 |
| 4 | 图层准备/复制/初始化失败事务化 | 分配、编码、GPU 失败不发布图层与假成功 | 已实施；图层事务专项 43 项通过 |
| 9 | 文档级调色空间与连续色域处理 | 边界连续、旧 sRGB 行为、预览提交导出一致 | 已实施；色域/高精度专项 19 项通过 |
| 5 | 进程级 CPU/GPU 资源账本与任务预留 | 多文档/方案/后台并行预算和回收 | 已实施；资源/保存专项 53 项及跨文档账本 1 项通过 |
| 6 | 分块冻结、共享快照和局部历史恢复 | 像素一致；小改动不额外整层克隆；失败原子性 | 待实施 |
| 7 | 裁剪、素材捕获等重工作移出主线程 | 取消、过期结果、不阻塞主线程 | 待实施 |
| 8 | 不可变源资产按需落盘与历史引用 | 大素材不挤掉历史；损坏不改变当前像素 | 待实施 |
| 10 | 编辑会话所有权、命令目标和替换边界统一 | 工具/标签/预览/保存/退出交叉状态 | 待实施 |

每组修正独立提交。自动测试包括像素对照、临时目录故障注入、资源计量与流程回归。最终编译 Release、完整回归、校验安装包，再通过真实软件窗口验收。界面测试另存验收工程，不改写原画稿。

## 证据

日志集中在 `.build/stability-evidence/`。最终报告补充确切测试数量、安装版本、界面证据、性能测量和未覆盖边界；不将历史测试当作本次结果。
