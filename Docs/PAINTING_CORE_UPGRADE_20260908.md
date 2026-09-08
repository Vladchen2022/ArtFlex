# 绘画核心升级实施记录

## 备份

- Git 基线 `488d644`，标签 `backup/painting-core-20260908`。
- 工作分支 `codex/painting-core-upgrade`。
- 完整 Git bundle（已 verify）和原画稿副本保存在 `/Users/victorcloux/Downloads/ArtFlex-核心升级备份-20260908-u2SGfh/`。
- 原工程不用于破坏性测试，屏幕验收使用独立工程。

## 决策与执行顺序

目标为增量自动恢复、稀疏图层、方案共享底稿、非破坏裁剪、高位深绘画链路。用户已授权连续实施，无需逐批确认。资源所有权、编码和持久化相互依赖，作为一致候选提交；屏幕验收产生的修正再单独提交。

复用仓库中的 `TileGrid` / `PixelRegion`、`LayerTextureSerializer`、原子 `LayerSurfaceTransfer`、已有压缩和校验、工程版本备份以及持久化入口保护。不复制旧 CPU 画布，不改变成熟笔刷算法，不增加第三方依赖。

平台方案采用 Metal 原生稀疏纹理、Foundation 不可变数据和文件原子替换、ImageIO 高位深输出。成熟框架不能替本工程决定图层变化、撤销和裁剪语义；自定义代码仅承担这些业务边界及资源所有权。

参考：

- https://developer.apple.com/documentation/metal/managing-sparse-texture-memory
- https://developer.apple.com/documentation/metal/creating-sparse-heaps-and-sparse-textures
- https://developer.apple.com/documentation/metal/assigning-memory-to-sparse-textures
- https://developer.apple.com/documentation/metal/reading-and-writing-to-sparse-textures
- https://developer.apple.com/documentation/metal/streaming-large-images-with-metal-sparse-textures
- 本机 SDK 的 `MTLDevice.h`、`MTLResourceStateCommandEncoder.h`。

实施顺序为资源所有权／变化区域基础 → 增量恢复／稀疏层／方案共享接入 → 非破坏裁剪 → 高位深链路。稀疏纹理单独验证后才启用，未映射写入不能静默丢失。设备不支持时沿用原存储。高位深先明确线性颜色及 alpha，再改渲染、取样、历史、保存、调整和输出。

## 验收要求

逐字节／像素对照，包含失败不改变原状态、图层和蒙版同行、撤销重做、保存重开及旧工程兼容；内存和写入量以测量为准。最终在安装版本中进行真实界面操作，并列出手测清单。尚未完成的功能不能写成完成。

## 当前进度

候选实现已接入，正在收尾验证。源代码构建号 `20260908.23`，运行软件仍为 `20260908.22`。尚未完成安装和屏幕验收，不能称已交付。

### 代码变更

1. **增量自动恢复**：每个图层／蒙版有独立变化游标；首次完整捕获，以后只冻结变化的 512 像素分块。未变块校验后通过硬链接复用（失败改复制）。每一代均可独立打开，沿用多代轮换与暂存原子安装。普通正式保存仍使用兼容单文件工程；恢复目录结构变化不等于正式工程格式被替换。
2. **稀疏图层**：支持的 Metal 设备上，至少 1024×1024 的空图层使用原生 sparse heap。写入前明确映射和初始化；笔触提交后按实际非零内容压缩占用，仅扫描原有内容和本次笔触区域。失败保留原有像素，设备不支持则使用原存储。
3. **方案共享底稿**：未改图层和蒙版共享资源。写入时分离所有权；旧共享资源不可回收为笔刷临时纹理，防止后续笔触修改其他方案。文档元数据和变化游标仍为独立值。
4. **非破坏裁剪**：框外内容分块压缩，作为工程资源保存；工具新增“展开保留区域”。可见区域继续绘画、擦除后展开不恢复已擦掉的可见像素。复制／删除图层、合并、新增／删除／反相蒙版同时处理框外内容，隐藏合并沿用 Metal 合成器。普通选区操作只影响当前画布可见选区，框外内容不是隐含选区。
5. **高位深**：新建时可选 16 位浮点；图层采用线性 sRGB 原色、预乘 alpha、RGBA16Float。渲染、组合笔刷、取样、涂抹、历史、裁剪、工程及恢复保留编码。PNG／TIFF 支持真正 16 位输出，JPEG 明确为 8 位；缩放复用 vImage 浮点重采样。图层蒙版仍为 8 位，显示／视频／缩略图为输出派生图，不反写工程像素。

高精度验证额外查出选区填充／套索填充／直线及扇形渐变的旧 sRGB 数值直写错误。现统一为先解码线性，再预乘与混合，避免中间色偏亮；已保存像素不做追溯转换，已认可的笔刷算法不变。

主要新增文件为 `LayerChangeJournal`、`CanvasPixelEncoding`、`IncrementalRecoveryArchive`、`SparseLayerTexture`／`SparseTileScanner`、`CanvasCropRetention`／`NonDestructiveCanvasCrop`／`RetainedCropLayerOperations`、`ColorRenderPipelineVariants`／`MetalColorFunctions`、`HighPrecisionRasterExporter`。接入点为 `StageOneLayerSurfaceStore`、`MetalStrokeEngine`、`PersistenceController`、`HistoryController`、`ProjectArchiveV2`、各现有工具渲染器、`WorkspaceViewModel`、新建和导出面板。未增加第三方依赖。

补充参考：

- [Metal 像素格式及 sRGB 自动转换](https://developer.apple.com/documentation/metal/mtlpixelformat)
- [CGImage 每通道精度](https://developer.apple.com/documentation/coregraphics/cgimage/bitspercomponent)
- [Accelerate 图像缩放](https://developer.apple.com/documentation/accelerate/image-scaling)
- [ImageIO PNG 属性](https://developer.apple.com/documentation/imageio/png-image-properties)

### 已完成的后台验证

- 全量回归 953 项／92 组通过（`/tmp/artflex-core-regression3.log`）。补齐裁剪图层生命周期、16 位剪贴板、填充颜色和组合笔刷后，两轮全量均为 959 项／93 组通过，分别 41.130 秒和 39.603 秒（`/tmp/artflex-core-regression4.log`、`/tmp/artflex-core-regression5.log`）。
- 补充失败捕获后的编码器清理测试及 GPU 合并完成状态检查后，最终全量 960 项／93 组通过，40.552 秒（`/tmp/artflex-core-regression6.log`）。最终 Release 构建通过，106.97 秒（`/tmp/artflex-core-upgrade-release-final.log`）；候选可执行文件 `.build/out/Products/Release/ArtFlex`，arm64 UUID `DCFED922-7201-3D99-91D3-DE61DA0C3EB7`。源与现装包的 Info.plist 校验、`git diff --check` 通过。这些不替代安装与屏幕验收。
- 稀疏／普通存储笔触和橡皮逐字节一致，撤销重做一致；首次映射、扩大映射及非整块边缘像素测试通过。
- 1200×1000、两个图层的增量恢复：首轮 12 块；修改 2×2 区域后只捕获 1 块（1 MiB），不再捕获两层共约 9.16 MiB。冻结后继续修改不改变已捕获内容；删去旧代仍能独立恢复新代；损坏块拒绝读取。
- 旧恢复文件升级、失败暂存不覆盖上代通过。测试仅在临时目录进行，未破坏用户恢复文件。
- 框外像素和蒙版经正式保存、增量恢复后可展开。8／16 位下裁剪后合并与未裁剪合并结果一致，撤销重做、复制和蒙版操作通过。
- RGBA16Float 存储及 GPU 读回保留 8 位阶梯之间的值；ImageIO 实际生成 16 位 PNG／TIFF，并校验重新读取的精度、颜色与 alpha；16 位剪贴板、选区填充、组合模式通过。
- 4K 单层、8 条局部笔触的一次测量：普通已提交图层 67,108,864 字节，稀疏 1,261,568 字节。局部扫描版笔触提交总耗时约 75.1／81.6 ms（普通／稀疏），较此前全扫描的约 76.2／88.2 ms 缩小额外成本。这是特定机器与场景的单次测量，不能推断整机内存下降相同比例或所有绘画提速。

### 原画稿保护

基线文件 SHA-256 为 `9adc181792cfb3e741a9f89c3276212d8e2dceaaa64210402859dfd7ac5b594c`；发送保存快捷键后，19:09 磁盘文件变为 `118f14327e472bec377f523b2276efdf8d5c19e36b07b7c602ce47aaad01900e`。已分别保存在备份目录的 `原工程.artflex` 与 `原工程-当前磁盘状态.artflex`，没有用基线覆盖当前画稿。

AppleArchive 解包比较确认 `layers` 和 `preview.png` 逐字节一致。变化只在工程元数据：体块参考绘画覆盖透明度 `1 → 0.21179688`、计时和更新时间，另有 Set 编码顺序变化。不能单凭文件总哈希变化判断画面丢失，也不能据此声称当前屏幕内容已全部确认。

### 界面验收状态与已知边界

- 本轮 Computer Use 能读到文件菜单，但截图持续不可用；菜单动作多次返回失效，重连未解决。已请求保持解锁并关闭菜单，尚待可操作桌面。不强杀进程，不将后台测试冒充屏幕测试。
- 尚未替换正在运行的软件。只有先保护当前未保存内容、确认可操作界面后，才安装候选包并完成 [手测清单](PAINTING_CORE_MANUAL_TESTS_20260908.md) 中的界面验证。
- 稀疏实现减少已提交图层存储；当前笔触工作纹理、部分工具／历史恢复仍会使用全尺寸纹理。预算保持保守，不能宣传整个绘画链都已经成为按块分配。
- 正式保存仍捕获完整资源；增量优化针对自动恢复。恢复打开会重新组装图层，未变的元数据和内嵌素材仍可能重写。保留裁剪数据也仍作为独立侧车整体压缩。继承的旧块仍做解压校验，以发现损坏，当前没有为减少 CPU 开销而跳过完整性检查；主要收益是减少 GPU 快照复制及磁盘新增写入，不是消除一切后台读取。
- 16 位浮点不是 HDR／广色域，未提供已有工程原地切换精度。可新建高精度工程后导入；8 位来源不会凭空产生细节。涉及高位深或裁剪保留的新工程要求 reader 3，旧版会拒绝，防止误读覆盖。
- 高位深通常增加像素工作内存，不承诺它能提高帧率。数位板真实压力仍需使用用户硬件手测。
