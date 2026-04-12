# ArtFlex 颜色与像素规范

最后更新：2026-04-12

本文件记录当前项目仍然生效的颜色与像素底层规范。  
它不是“第一阶段规划文档”，而是后续线程接手时必须遵守的实现边界。

## 1. 当前规范一句话

ArtFlex 当前文档颜色标准保持为：

- `RGBA8`
- `premultiplied alpha`
- `sRGB`

而 GPU 主 surface / drawable 统一使用：

- `bgra8Unorm_srgb`

业务层按 `RGBA` 语义理解文档颜色，底层 `BGRA` 只是 Metal 资源格式细节。

## 2. 当前代码里的真实依据

### 2.1 文档颜色标准

[Core/Color/ColorStandard.swift](../../Core/Color/ColorStandard.swift) 当前定义：

- `ArtPixelFormat.rgba8`
- `ArtAlphaMode.premultiplied`
- `ArtColorSpace.sRGB`

对应默认值：

- `ArtColorStandard.stageOneDefault`

### 2.2 GPU layer surface / canvas drawable

当前主工程里的图层 texture 和 canvas drawable 都以 `bgra8Unorm_srgb` 为主：

- [Rendering/Canvas/StageOneLayerSurfaceStore.swift](../../Rendering/Canvas/StageOneLayerSurfaceStore.swift)
- [Rendering/Canvas/StageOneCanvasPresenter.swift](../../Rendering/Canvas/StageOneCanvasPresenter.swift)
- [Platform/macOS/Canvas/MetalCanvasHost.swift](../../Platform/macOS/Canvas/MetalCanvasHost.swift)
- [Rendering/Metal/MetalSurfaceDescriptor.swift](../../Rendering/Metal/MetalSurfaceDescriptor.swift)

说明：

- 文档逻辑仍按 `RGBA` 语义理解
- `BGRA` 只是在 Metal 资源和读回时集中处理
- 不允许在上层工具和业务代码里散落通道交换补丁

### 2.3 CPU 读回 / 导出

[Infrastructure/FileFormat/LayerTextureSerializer.swift](../../Infrastructure/FileFormat/LayerTextureSerializer.swift) 和 [Infrastructure/FileFormat/PNGExporter.swift](../../Infrastructure/FileFormat/PNGExporter.swift) 负责：

- 从同一套 layer texture 读回像素
- 在基础设施层集中做 BGRA 数据解释
- 导出时统一转换到 PNG 所需的 RGBA 输出

当前 PNG 导出行为是：

- 从同一套 layer surface 数据读回
- 先按线性 premultiplied 颜色解释
- 再合成到白底
- 最终写出不透明 sRGB PNG

## 3. 单一真相源规则

当前仍然坚持：

- 屏幕显示来自 layer textures
- 画笔 / 橡皮 / 涂抹写入 layer textures
- 吸管采样基于同一套 layer 数据
- 导出从同一套 layer 数据读回
- 历史快照恢复的对象也是同一套 layer textures

不允许演变成：

- 显示走一套链
- 吸管另走一套 CPU 合成链
- 涂抹再走第三套中间缓存
- 导出再走第四套临时补偿链

## 4. Alpha 规则

### 4.1 文档语义

文档层和工具写入统一按 `premultiplied alpha` 理解。

这意味着：

- 颜色进入底层存储前应先 premultiply
- 任何混合结果都必须保持合法 premultiplied 像素

当前代码中的对应实现可见于：

- [Core/Color/ColorStandard.swift](../../Core/Color/ColorStandard.swift)
- [Core/Color/LinearPremultipliedColor.swift](../../Core/Color/LinearPremultipliedColor.swift)
- [Platform/macOS/App/WorkspaceViewModel.swift](../../Platform/macOS/App/WorkspaceViewModel.swift)
- [Rendering/Canvas/StageOneBrushRenderer.swift](../../Rendering/Canvas/StageOneBrushRenderer.swift)

### 4.2 不允许混用

不允许出现：

- 某个工具写 straight alpha
- 某个显示路径按 premultiplied 解读
- 导出前再临时做局部 alpha 修补

## 5. sRGB / linear 规则

### 5.1 存储语义

文档和导出的颜色目标按 `sRGB` 语义理解。

### 5.2 计算边界

需要做线性空间计算的地方，应集中在渲染或颜色基础设施层处理，例如：

- `LinearPremultipliedColor`
- `StageOneBrushRenderer`
- `LABLuminosityPostProcessor`
- `PNGExporter`

不允许在业务层随意混用：

- 一部分把颜色当 sRGB 编码值
- 另一部分把同一值当 linear

### 5.3 UI 颜色边界

SwiftUI / AppKit 的颜色对象不能直接成为文档底层格式。  
平台颜色进入核心逻辑前，应转换到当前文档标准颜色语义。

## 6. 辅助 surface 与真相源的区别

项目里确实存在一些辅助贴图或中间贴图，例如：

- selection mask：`r8Unorm`
- opacity cap / 临时 alpha texture：`r8Unorm`
- 某些 preview / analysis texture：`rgba32Float`

这些都不是文档真相源本身。  
它们可以作为局部算法中间结果存在，但不能演变成新的“主颜色标准”。

同理：

- 参考图贴图不是文档真相源
- LAB 黑白参考是显示 / 参考路径，不是文档像素改写

## 7. 后续实现时的硬约束

后续接新功能时，默认遵守：

1. 先确认它读写的是哪一套 layer data
2. 先确认它是否保持 `RGBA8 + premultiplied + sRGB` 语义
3. 先确认通道映射是否只在基础设施层处理
4. 再去做工具逻辑、预览逻辑和导出逻辑

不允许为了赶功能而回到：

- 临时通道交换
- 临时 shader 补偿
- 一次性颜色修正 patch
- 单独为某个工具开一条旁路颜色链
