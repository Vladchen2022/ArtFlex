# ArtFlex 性能优化指南

## 🎯 已实施的优化

### 1. ✅ 移除 GPU 同步等待（最关键）
**问题**：6 处 `commandBuffer.waitUntilCompleted()` 导致主线程阻塞
**解决**：
- 改为异步提交，使用 `addCompletedHandler` 处理回调
- 允许 CPU 和 GPU 流水线并行工作
- **预期提升**：笔刷输入延迟降低 50-80%

---

## 🚀 推荐的进一步优化

### 2. Triple Buffering 纹理池（高优先级）

**问题**：每次笔刷渲染都可能与 MTKView 的显示冲突

**解决方案**：
```swift
final class TexturePool {
    private var availableTextures: [MTLTexture] = []
    private let maxPoolSize = 3
    private let device: MTLDevice
    private let descriptor: MTLTextureDescriptor
    
    func acquire() -> MTLTexture? {
        if let texture = availableTextures.popLast() {
            return texture
        }
        return device.makeTexture(descriptor: descriptor)
    }
    
    func release(_ texture: MTLTexture) {
        guard availableTextures.count < maxPoolSize else { return }
        availableTextures.append(texture)
    }
}
```

**预期提升**：消除纹理分配/释放开销，减少内存碎片

---

### 3. Dirty Region 跟踪（中优先级）

**当前问题**：每次重绘整个画布，即使只有小部分改变

**优化方案**：
```swift
struct DirtyRegion {
    var minX: Int = Int.max
    var minY: Int = Int.max
    var maxX: Int = Int.min
    var maxY: Int = Int.min
    
    mutating func expand(center: SIMD2<Float>, radius: Float) {
        minX = min(minX, Int(center.x - radius) - 1)
        minY = min(minY, Int(center.y - radius) - 1)
        maxX = max(maxX, Int(center.x + radius) + 1)
        maxY = max(maxY, Int(center.y + radius) + 1)
    }
    
    func toScissorRect(clamping size: CanvasSize) -> MTLScissorRect {
        let x = max(0, minX)
        let y = max(0, minY)
        return MTLScissorRect(
            x: x,
            y: y,
            width: min(maxX - minX, size.width - x),
            height: min(maxY - minY, size.height - y)
        )
    }
}
```

**在 render() 中应用**：
```swift
encoder.setScissorRect(dirtyRegion.toScissorRect(clamping: canvasSize))
```

**预期提升**：大画布上小笔刷性能提升 3-5 倍

---

### 4. Command Buffer 批处理（中优先级）

**当前问题**：每个 stamp 都提交独立的 draw call

**优化方案**：
```swift
// 在 interpolatedPoints 中批量处理
private let maxStampsPerBatch = 64

func renderBatched(samples: [StampSample], ...) {
    for batch in samples.chunked(into: maxStampsPerBatch) {
        // 一个 command buffer 处理多个 stamps
        let commandBuffer = commandQueue.makeCommandBuffer()
        // ... encode all stamps in batch
        commandBuffer.commit()
    }
}
```

**预期提升**：减少 Metal 驱动开销 20-30%

---

### 5. Catmull-Rom 插值优化（低优先级）

**当前实现**：每次细分计算 16 段，包含大量重复计算

**优化方案 A - 使用查找表**：
```swift
private let catmullRomLUT: [Float] = {
    // 预计算常用 t 值的 basis 函数
    stride(from: 0.0, through: 1.0, by: 0.01).map { t in
        // ... basis calculation
    }
}()
```

**优化方案 B - SIMD 加速**：
```swift
// 使用 SIMD4 同时计算 4 个点
func catmullRomSIMD(
    p0: SIMD2<Float>, p1: SIMD2<Float>,
    p2: SIMD2<Float>, p3: SIMD2<Float>,
    t: Float
) -> SIMD2<Float> {
    let t2 = t * t
    let t3 = t2 * t
    
    let basis = SIMD4<Float>(
        -t3 + 2*t2 - t,
        3*t3 - 5*t2 + 2,
        -3*t3 + 4*t2 + t,
        t3 - t2
    ) * 0.5
    
    return (p0 * basis.x + p1 * basis.y + p2 * basis.z + p3 * basis.w)
}
```

**预期提升**：插值计算速度提升 2-3 倍

---

### 6. 选区遮罩缓存优化（中优先级）

**当前问题**：每次渲染都检查缓存，对于复杂选区（lasso/mask）每次都重新生成

**优化方案**：
```swift
// 在 makeSelectionMaskTexture 中
if selectionShape.kind == .lasso || selectionShape.kind == .mask {
    // 使用更高效的 hash 而不是完整的 Equatable
    let shapeHash = selectionShape.quickHash()
    if cachedSelectionMaskHash == shapeHash {
        return cachedSelectionMaskTexture
    }
}
```

**额外优化**：对于笔刷工具，选区在笔画期间不会变化，可以在 stroke 开始时缓存整个笔画

---

### 7. Metal Shader 优化（中优先级）

**A. 使用 Metal 函数常量**：
```swift
// 在初始化时编译专用 pipeline
let constants = MTLFunctionConstantValues()
var tipShape: UInt32 = 0  // 0=round, 1=soft, 2=square
constants.setConstantValue(&tipShape, type: .uint, index: 0)

let fragmentFunction = library.makeFunction(
    name: "stageOneBrushFragment",
    constantValues: constants
)
```

在 shader 中：
```metal
constant uint TIP_SHAPE [[function_constant(0)]];

fragment float4 stageOneBrushFragment(...) {
    if (TIP_SHAPE == 1) {
        // 编译时优化的软圆分支
    } else if (TIP_SHAPE == 2) {
        // 编译时优化的方形分支
    }
}
```

**B. 减少 fragment shader 分支**：
```metal
// 当前：多个 if-else 分支
// 优化：使用 mix() 和 step() 消除分支

float alpha = mix(
    smoothHardnessAlpha(distance, hardness),
    customTipAlpha(...),
    step(2.5, float(uniforms.tipShape))
);
```

**预期提升**：GPU 执行效率提升 10-20%

---

### 8. 输入事件优化（高优先级）

**当前问题**：可能在主线程处理所有输入事件

**查看优化机会**：
```swift
// 在 MetalCanvasHost/StrokeCaptureMTKView 中
override func mouseDragged(with event: NSEvent) {
    // 🔍 需要检查：是否在主线程同步调用 render？
    // 优化：使用输入队列 + 后台处理
}
```

**优化方案**：
```swift
private let inputQueue = DispatchQueue(
    label: "com.artflex.input",
    qos: .userInteractive
)
private var pendingInputPoints: [StrokePoint] = []
private let inputProcessingLock = NSLock()

override func mouseDragged(with event: NSEvent) {
    let point = capturePoint(from: event)
    
    inputProcessingLock.lock()
    pendingInputPoints.append(point)
    inputProcessingLock.unlock()
    
    // 在下一个 CADisplayLink 周期批量处理
    needsInputFlush = true
}
```

---

### 9. 图层合成优化（中优先级）

**建议**：使用 Metal Performance Shaders (MPS) 加速

```swift
import MetalPerformanceShaders

func compositeLayersOptimized(
    layers: [MTLTexture],
    into destination: MTLTexture,
    commandBuffer: MTLCommandBuffer
) {
    // 使用 MPS 内置的高效 blend kernels
    for (index, layerTexture) in layers.enumerated() {
        let blend = MPSImageNormalizedHistogram(device: device)
        // ... MPS optimized blending
    }
}
```

**预期提升**：多图层合成速度提升 2-4 倍

---

### 10. 颜色抖动（Color Jitter）优化（低优先级）

**当前问题**：在 fragment shader 中进行复杂的 HSV 转换和随机数生成

**优化方案 A - 预计算纹理**：
```swift
// 生成一个 256x256 的颜色抖动 LUT 纹理
func makeColorJitterLUT(baseColor: SIMD3<Float>) -> MTLTexture {
    let size = 256
    var pixels = [UInt8](repeating: 0, count: size * size * 4)
    
    for y in 0..<size {
        for x in 0..<size {
            let jittered = applyJitter(
                baseColor,
                x: Float(x) / Float(size),
                y: Float(y) / Float(size)
            )
            let offset = (y * size + x) * 4
            pixels[offset] = UInt8(jittered.r * 255)
            pixels[offset + 1] = UInt8(jittered.g * 255)
            pixels[offset + 2] = UInt8(jittered.b * 255)
            pixels[offset + 3] = 255
        }
    }
    
    // Upload to texture...
}
```

在 shader 中：
```metal
float2 jitterUV = fract(localPoint * 0.5 + 0.5);
float3 jitteredColor = jitterLUT.sample(sampler, jitterUV).rgb;
```

**预期提升**：高抖动量下 fragment shader 性能提升 30-40%

---

## 📊 性能测量建议

### 使用 Xcode Instruments 分析：

1. **Metal System Trace**：
   - 查看 GPU 利用率
   - 识别渲染瓶颈
   - 检测过度的同步点

2. **Time Profiler**：
   - 找出 CPU 热点
   - 优化 Catmull-Rom 插值
   - 减少选区遮罩生成开销

3. **Allocations**：
   - 检测内存泄漏
   - 优化纹理池使用
   - 减少临时对象分配

### 性能基准测试：

```swift
import os.signpost

let performanceLog = OSLog(subsystem: "com.artflex", category: .pointsOfInterest)

func benchmarkStroke() {
    let signpostID = OSSignpostID(log: performanceLog)
    os_signpost(.begin, log: performanceLog, name: "Stroke Render", signpostID: signpostID)
    
    // ... render stroke
    
    os_signpost(.end, log: performanceLog, name: "Stroke Render", signpostID: signpostID)
}
```

---

## 🎯 优先级总结

### 立即实施（已完成）：
- ✅ 移除 `waitUntilCompleted()` 同步等待

### 高优先级（建议下一步）：
1. **Triple Buffering 纹理池** - 减少分配开销
2. **Dirty Region 跟踪** - 大幅减少不必要的重绘
3. **输入事件优化** - 减少主线程压力

### 中优先级（性能提升明显）：
4. Command Buffer 批处理
5. 选区遮罩缓存优化
6. Metal Shader 优化（函数常量、减少分支）

### 低优先级（代码复杂度高，收益相对较小）：
7. Catmull-Rom SIMD 优化
8. 颜色抖动 LUT 预计算

---

## 🔧 配置建议

### MTKView 设置优化：

```swift
view.preferredFramesPerSecond = 120  // ✅ 已设置
view.framebufferOnly = false  // ✅ 允许读取，但考虑改为 true 提升性能
view.colorPixelFormat = .bgra8Unorm_srgb  // ✅ 适合显示的格式

// 建议添加：
view.presentsWithTransaction = false  // 减少延迟
view.layer?.isOpaque = true  // ✅ 已设置
```

### Metal Device 设置：

```swift
// 在 MetalDeviceContext 中
let device = MTLCreateSystemDefaultDevice()!

// 建议：启用 GPU 捕获（开发时）
if CommandLine.arguments.contains("--metal-capture") {
    device.isLowPower = false  // 强制使用高性能 GPU
}
```

---

## 📈 预期性能提升

| 优化项目 | 预期延迟降低 | 预期帧率提升 |
|---------|------------|-------------|
| 移除同步等待 | 50-80% | 2-3x |
| Triple Buffering | 10-20% | 1.2x |
| Dirty Region | 60-80% (大画布) | 3-5x |
| Shader 优化 | 5-15% | 1.1-1.2x |
| **总计** | **70-90%** | **5-10x** |

---

## ⚠️ 注意事项

1. **异步渲染后的状态同步**：
   - 需要确保 ViewModel 状态在 GPU 完成后正确更新
   - 考虑使用 `MTLEvent` 或 `MTLFence` 进行细粒度同步

2. **纹理生命周期管理**：
   - 异步渲染时纹理可能被提前释放
   - 使用 `commandBuffer.addCompletedHandler` 延长生命周期

3. **错误处理**：
   - Metal 错误现在是异步的，需要在 completedHandler 中检查
   - 考虑添加 `MTLCaptureScope` 用于调试

---

## 🧪 测试建议

创建性能测试套件：

```swift
@Test("Brush stroke latency", .timeLimit(.minutes(1)))
func testBrushLatency() async throws {
    let start = ContinuousClock.now
    
    // 模拟 100 个点的笔画
    for i in 0..<100 {
        let point = StrokePoint(x: Double(i), y: 100, pressure: 0.5)
        // ... render
    }
    
    let duration = ContinuousClock.now - start
    #expect(duration < .milliseconds(100))  // 目标：<1ms per point
}
```

---

最后更新：2026-03-23
