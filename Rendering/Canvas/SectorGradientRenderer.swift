import Foundation
import Metal
import simd

private struct SectorGradientVertex {
    var position: SIMD2<Float>
}

private struct SectorGradientUniforms {
    var canvasSize: SIMD2<Float>
    var center: SIMD2<Float>
    var maxRadius: Float
    var color: SIMD4<Float>
    var paintJitterAmount: Float
    var paintContrastAmount: Float
    var distortionAmount: Float
    var usesSelectionMask: Float
    var usesAlphaLock: Float
}

private struct SectorGradientGPUStop {
    var positionAndPadding: SIMD4<Float>
    var color: SIMD4<Float>
}

private final class SectorGradientVertexBufferLease: @unchecked Sendable {
    let buffer: MTLBuffer
    let capacity: Int
    var isInUse = false

    init(buffer: MTLBuffer, capacity: Int) {
        self.buffer = buffer
        self.capacity = capacity
    }
}

private final class SectorGradientVertexBufferPool: @unchecked Sendable {
    private static let maxReusableCount = 6
    private static let maxReusableBytes = 8 * 1024 * 1024

    private let device: MTLDevice
    private let lock = NSLock()
    private var leases: [SectorGradientVertexBufferLease] = []

    init(device: MTLDevice) {
        self.device = device
    }

    func lease(vertices: [SectorGradientVertex]) -> SectorGradientVertexBufferLease? {
        let length = MemoryLayout<SectorGradientVertex>.stride * vertices.count
        guard length > 0 else { return nil }

        lock.lock()
        let lease: SectorGradientVertexBufferLease?
        if let reusable = leases
            .filter({ !$0.isInUse && $0.capacity >= length })
            .min(by: { $0.capacity < $1.capacity }) {
            reusable.isInUse = true
            lease = reusable
        } else {
            let capacity = max(length, 16 * 1024)
            if let buffer = device.makeBuffer(length: capacity, options: .storageModeShared) {
                let created = SectorGradientVertexBufferLease(buffer: buffer, capacity: capacity)
                created.isInUse = true
                leases.append(created)
                lease = created
            } else {
                lease = nil
            }
        }
        lock.unlock()

        guard let lease else { return nil }
        vertices.withUnsafeBytes { rawBuffer in
            guard let sourceBaseAddress = rawBuffer.baseAddress else { return }
            lease.buffer.contents().copyMemory(
                from: sourceBaseAddress,
                byteCount: rawBuffer.count
            )
        }
        return lease
    }

    func release(_ lease: SectorGradientVertexBufferLease) {
        lock.lock()
        lease.isInUse = false
        trimLocked()
        lock.unlock()
    }

    private func trimLocked() {
        var retainedBytes = leases.reduce(0) { $0 + $1.capacity }
        while leases.count > Self.maxReusableCount || retainedBytes > Self.maxReusableBytes {
            guard let removalIndex = leases.indices
                .filter({ !leases[$0].isInUse })
                .max(by: { leases[$0].capacity < leases[$1].capacity }) else {
                return
            }
            retainedBytes -= leases[removalIndex].capacity
            leases.remove(at: removalIndex)
        }
    }

#if DEBUG
    func debugStats() -> (count: Int, bytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (
            count: leases.count,
            bytes: leases.reduce(0) { $0 + $1.capacity }
        )
    }
#endif
}

enum SectorGradientMaskQuality {
    case preview
    case commit
}

func sectorGradientTriangleFanVertexPositions(
    center: CanvasPoint,
    pathPoints: [CanvasPoint]
) -> [CanvasPoint] {
    let boundaryPoints = normalizedSectorGradientBoundaryPoints(
        center: center,
        pathPoints: pathPoints
    )
    guard boundaryPoints.count >= 2 else { return [] }

    var vertices: [CanvasPoint] = []
    vertices.reserveCapacity((boundaryPoints.count - 1) * 3)
    for index in 0..<(boundaryPoints.count - 1) {
        vertices.append(center)
        vertices.append(boundaryPoints[index])
        vertices.append(boundaryPoints[index + 1])
    }
    return vertices
}

private func normalizedSectorGradientBoundaryPoints(
    center: CanvasPoint,
    pathPoints: [CanvasPoint]
) -> [CanvasPoint] {
    var boundaryPoints = pathPoints
    while let first = boundaryPoints.first, distanceBetween(first, center) <= 0.5 {
        boundaryPoints.removeFirst()
    }
    while let last = boundaryPoints.last, distanceBetween(last, center) <= 0.5 {
        boundaryPoints.removeLast()
    }

    guard !boundaryPoints.isEmpty else { return [] }
    var deduplicated: [CanvasPoint] = []
    deduplicated.reserveCapacity(boundaryPoints.count)

    for point in boundaryPoints {
        if let last = deduplicated.last, distanceBetween(last, point) <= 0.25 {
            continue
        }
        deduplicated.append(point)
    }

    return deduplicated
}

final class SectorGradientRenderer {
    private let pipelineVariants: ColorRenderPipelineVariants
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let alphaLockPipelineState: MTLRenderPipelineState
    private let fallbackSelectionMaskTexture: MTLTexture
    private let fallbackAlphaLockTexture: MTLTexture
    private var cachedSelectionMaskShape: SelectionShape?
    private var cachedSelectionMaskCanvasSize: CanvasSize?
    private var cachedSelectionMaskTexture: MTLTexture?
    private let vertexBufferPool: SectorGradientVertexBufferPool

    init(device: MTLDevice) {
        let pipelineVariants = ColorRenderPipelineVariants(device: device)
        self.pipelineVariants = pipelineVariants
        self.device = device
        self.vertexBufferPool = SectorGradientVertexBufferPool(device: device)
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        \(MetalColorFunctions.source)

        struct SectorGradientVertex {
            float2 position;
        };

        struct SectorGradientUniforms {
            float2 canvasSize;
            float2 center;
            float maxRadius;
            float4 color;
            float paintJitterAmount;
            float paintContrastAmount;
            float distortionAmount;
            float usesSelectionMask;
            float usesAlphaLock;
        };

        struct GradientGPUStop {
            float4 positionAndPadding;
            float4 color;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
        };

        vertex VertexOut sectorGradientVertexShader(
            const device SectorGradientVertex *vertices [[buffer(0)]],
            constant SectorGradientUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            SectorGradientVertex inputVertex = vertices[vertexID];
            float2 normalized = float2(
                (inputVertex.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (inputVertex.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            VertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.canvasPosition = inputVertex.position;
            return out;
        }

        float3 rgbToHsv(float3 c) {
            float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
            float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }

        float3 hsvToRgb(float3 c) {
            float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }

        float hash11(float value) {
            return fract(sin(value * 127.1) * 43758.5453123);
        }

        float2 hash22(float2 p) {
            float3 a = fract(p.xyx * float3(0.1031, 0.1030, 0.0973));
            a += dot(a, a.yzx + 33.33);
            return fract((a.xx + a.yz) * a.zy);
        }

        float valueNoise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            float a = hash22(i).x;
            float b = hash22(i + float2(1.0, 0.0)).x;
            float c = hash22(i + float2(0.0, 1.0)).x;
            float d = hash22(i + float2(1.0, 1.0)).x;
            return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
        }

        float2 noiseDistort(float2 pos, float amount) {
            if (amount <= 0.001) return pos;
            float frequency = 0.015;
            float strength = amount * 80.0;
            float2 p = pos * frequency;
            float dx = (valueNoise(p + float2(0.0, 137.0)) - 0.5) * 2.0 * strength;
            float dy = (valueNoise(p + float2(237.0, 0.0)) - 0.5) * 2.0 * strength;
            return pos + float2(dx, dy);
        }

        float3 radialPaintJitteredSrgbColor(
            float3 srgbColor,
            float angleNormalized,
            float paintJitterAmount,
            float paintContrastAmount
        ) {
            float contrastAmt = clamp(paintContrastAmount, 0.0, 1.0);
            if (paintJitterAmount <= 0.001 && contrastAmt <= 0.001) {
                return srgbColor;
            }

            float amount = clamp(paintJitterAmount / 0.75, 0.0, 1.0);
            float stripeCoord = clamp(angleNormalized, 0.0, 1.0);
            float stripeCount = 70.0;
            float stripeIndex = floor(stripeCoord * stripeCount);
            float scattered = fract(stripeIndex * 0.618033988749895) * stripeCount;
            float hueRandom = hash11(scattered + 1001.0);
            float satRandom = hash11(scattered + 1031.0);
            float valRandom = hash11(scattered + 1061.0);
            float contrastRandom = hash11(scattered + 1091.0);

            float3 hsv = rgbToHsv(srgbColor);
            float wheelHue = hueRandom;
            if (contrastAmt > 0.001) {
                float threshold = 1.0 - (contrastAmt * 0.25);
                if (contrastRandom > threshold) {
                    wheelHue = fract(hsv.x + 0.5 + (((hueRandom * 2.0) - 1.0) * 0.06) + 1.0);
                }
            }

            float satSigned = ((satRandom * 2.0) - 1.0);
            float valSigned = ((valRandom * 2.0) - 1.0);
            float wheelS = clamp(mix(hsv.y, 0.82, amount) + (satSigned * 0.12 * amount), 0.0, 1.0);
            float wheelV = clamp(hsv.z + (valSigned * 0.18 * amount), 0.0, 1.0);
            float baseCoverage = mix(1.0, 0.20, amount);
            float3 wheelSrgb = hsvToRgb(float3(wheelHue, wheelS, wheelV));
            return mix(wheelSrgb, srgbColor, baseCoverage);
        }

        float4 gradientColorAt(
            float position,
            const device GradientGPUStop *stops,
            uint stopCount
        ) {
            if (stopCount == 0) return float4(0.0);
            float t = clamp(position, 0.0, 1.0);
            GradientGPUStop lower = stops[0];
            for (uint index = 1; index < stopCount; ++index) {
                GradientGPUStop upper = stops[index];
                float upperPosition = upper.positionAndPadding.x;
                if (t < upperPosition) {
                    float lowerPosition = lower.positionAndPadding.x;
                    float span = upperPosition - lowerPosition;
                    float amount = span > 0.000001
                        ? smoothstep(0.0, 1.0, clamp((t - lowerPosition) / span, 0.0, 1.0))
                        : 1.0;
                    return mix(lower.color, upper.color, amount);
                }
                lower = upper;
            }
            return lower.color;
        }

        fragment float4 sectorGradientFragmentShader(
            VertexOut in [[stage_in]],
            constant SectorGradientUniforms &uniforms [[buffer(1)]],
            const device GradientGPUStop *gradientStops [[buffer(2)]],
            constant uint &gradientStopCount [[buffer(3)]],
            texture2d<float> selectionMask [[texture(0)]],
            texture2d<float> alphaLockTexture [[texture(1)]]
        ) {
            constexpr sampler selectionSampler(coord::normalized, address::clamp_to_edge, filter::nearest);

            float maskAlpha = 1.0;
            if (uniforms.usesSelectionMask > 0.5) {
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 uv = in.canvasPosition / canvasSize;
                maskAlpha = selectionMask.sample(selectionSampler, uv).r;
                if (maskAlpha <= 0.001) {
                    return float4(0.0);
                }
            }
            float lockedDestinationAlpha = 1.0;
            if (uniforms.usesAlphaLock > 0.5) {
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 uv = in.canvasPosition / canvasSize;
                lockedDestinationAlpha = alphaLockTexture.sample(selectionSampler, uv).a;
                if (lockedDestinationAlpha <= 0.001) {
                    return float4(0.0);
                }
            }

            float radius = length(in.canvasPosition - uniforms.center);
            float t = clamp(radius / max(uniforms.maxRadius, 0.0001), 0.0, 1.0);
            float4 gradientColor = gradientColorAt(t, gradientStops, gradientStopCount);
            float alpha = gradientColor.a * maskAlpha;
            float2 distortedPos = noiseDistort(in.canvasPosition, uniforms.distortionAmount);
            float angle = atan2(distortedPos.y - uniforms.center.y, distortedPos.x - uniforms.center.x);
            float angleNormalized = (angle / 6.283185307179586) + 0.5;
            float3 jitteredColor = radialPaintJitteredSrgbColor(
                gradientColor.rgb,
                angleNormalized,
                uniforms.paintJitterAmount,
                uniforms.paintContrastAmount
            );
            float3 premultiplied = artflexSrgbToLinear(jitteredColor) * alpha;
            if (uniforms.usesAlphaLock > 0.5) {
                return float4(premultiplied * lockedDestinationAlpha, alpha);
            }
            return float4(premultiplied, alpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile SectorGradientRenderer shader: \\(error)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "sectorGradientVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "sectorGradientFragmentShader")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let attachment = descriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try pipelineVariants.makeState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create SectorGradientRenderer pipeline: \\(error)")
        }

        let alphaLockDescriptor = MTLRenderPipelineDescriptor()
        alphaLockDescriptor.vertexFunction = library.makeFunction(name: "sectorGradientVertexShader")
        alphaLockDescriptor.fragmentFunction = library.makeFunction(name: "sectorGradientFragmentShader")
        alphaLockDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let alphaLockAttachment = alphaLockDescriptor.colorAttachments[0]!
        alphaLockAttachment.isBlendingEnabled = true
        alphaLockAttachment.rgbBlendOperation = .add
        alphaLockAttachment.alphaBlendOperation = .add
        alphaLockAttachment.sourceRGBBlendFactor = .one
        alphaLockAttachment.sourceAlphaBlendFactor = .one
        alphaLockAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        alphaLockAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        alphaLockAttachment.writeMask = [.red, .green, .blue]

        do {
            alphaLockPipelineState = try pipelineVariants.makeState(descriptor: alphaLockDescriptor)
        } catch {
            fatalError("Failed to create SectorGradientRenderer alpha lock pipeline: \\(error)")
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = .shaderRead
        fallbackDescriptor.storageMode = .shared
        guard let fallbackTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            fatalError("Failed to create fallback selection mask texture.")
        }
        let fullMask: [UInt8] = [255]
        fallbackTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: fullMask,
            bytesPerRow: 1
        )
        self.fallbackSelectionMaskTexture = fallbackTexture

        let fallbackAlphaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackAlphaDescriptor.usage = .shaderRead
        fallbackAlphaDescriptor.storageMode = .shared
        guard let fallbackAlphaTexture = device.makeTexture(descriptor: fallbackAlphaDescriptor) else {
            fatalError("Failed to create fallback alpha lock texture.")
        }
        let fullAlphaPixel: [UInt8] = [255, 255, 255, 255]
        fallbackAlphaTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: fullAlphaPixel,
            bytesPerRow: 4
        )
        self.fallbackAlphaLockTexture = fallbackAlphaTexture
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        center: CanvasPoint,
        pathPoints: [CanvasPoint],
        maxRadius: Double,
        color: RGBAColor,
        settings: GradientSettings? = nil,
        paintJitterAmount: Float = 0,
        paintContrastAmount: Float = 0,
        distortionAmount: Float = 0,
        maskQuality: SectorGradientMaskQuality = .commit,
        selectionShape: SelectionShape? = nil,
        alphaLockTexture: MTLTexture? = nil
    ) {
        _ = maskQuality
        guard pathPoints.count >= 3, maxRadius > 0.5 else { return }

        let vertexPositions = sectorGradientTriangleFanVertexPositions(
            center: center,
            pathPoints: pathPoints
        )
        guard vertexPositions.count >= 3 else { return }

        let vertices = vertexPositions.map {
            SectorGradientVertex(position: SIMD2(Float($0.x), Float($0.y)))
        }
        guard let vertexBufferLease = vertexBufferPool.lease(vertices: vertices) else {
            return
        }
        var shouldReleaseVertexBufferImmediately = true
        defer {
            if shouldReleaseVertexBufferImmediately {
                vertexBufferPool.release(vertexBufferLease)
            }
        }

        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: canvasSize
        ) ?? fallbackSelectionMaskTexture

        var uniforms = SectorGradientUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            center: SIMD2(Float(center.x), Float(center.y)),
            maxRadius: Float(maxRadius),
            color: SIMD4(color.red, color.green, color.blue, color.alpha),
            paintJitterAmount: paintJitterAmount,
            paintContrastAmount: paintContrastAmount,
            distortionAmount: distortionAmount,
            usesSelectionMask: selectionShape == nil ? 0 : 1,
            usesAlphaLock: alphaLockTexture == nil ? 0 : 1
        )
        let resolvedSettings = settings ?? .currentColorToTransparent(color)
        let gradientStops = resolvedSettings.stops.map { stop in
            SectorGradientGPUStop(
                positionAndPadding: SIMD4(stop.position, 0, 0, 0),
                color: SIMD4(stop.color.red, stop.color.green, stop.color.blue, stop.color.alpha)
            )
        }
        var gradientStopCount = UInt32(gradientStops.count)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineVariants.state(alphaLockTexture == nil ? pipelineState : alphaLockPipelineState, for: renderPassDescriptor.colorAttachments[0].texture?.pixelFormat ?? .bgra8Unorm_srgb))
        encoder.setVertexBuffer(vertexBufferLease.buffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SectorGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SectorGradientUniforms>.stride, index: 1)
        gradientStops.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            encoder.setFragmentBytes(
                baseAddress,
                length: MemoryLayout<SectorGradientGPUStop>.stride * buffer.count,
                index: 2
            )
        }
        encoder.setFragmentBytes(&gradientStopCount, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
        let vertexBufferPool = vertexBufferPool
        commandBuffer.addCompletedHandler { _ in
            vertexBufferPool.release(vertexBufferLease)
        }
        shouldReleaseVertexBufferImmediately = false
    }

#if DEBUG
    func debugReusableVertexBufferPoolStats() -> (count: Int, bytes: Int) {
        vertexBufferPool.debugStats()
    }
#endif

    private func makeSelectionMaskTexture(
        for selectionShape: SelectionShape?,
        canvasSize: CanvasSize
    ) -> MTLTexture? {
        guard let selectionShape else {
            cachedSelectionMaskShape = nil
            cachedSelectionMaskCanvasSize = nil
            cachedSelectionMaskTexture = nil
            return nil
        }

        if
            cachedSelectionMaskShape == selectionShape,
            cachedSelectionMaskCanvasSize == canvasSize,
            let cachedSelectionMaskTexture
        {
            return cachedSelectionMaskTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: canvasSize.width,
            height: canvasSize.height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        if let maskData = selectionShape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            let didUploadMask = maskData.withAlphaBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return false }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, canvasSize.width, canvasSize.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: canvasSize.width
                )
                return true
            }
            guard didUploadMask else { return nil }
        } else {
            var generated = [UInt8](repeating: 0, count: canvasSize.width * canvasSize.height)
            let minX = max(Int(selectionShape.bounds.minX.rounded(.down)), 0)
            let minY = max(Int(selectionShape.bounds.minY.rounded(.down)), 0)
            let maxX = min(Int(selectionShape.bounds.maxX.rounded(.up)), canvasSize.width)
            let maxY = min(Int(selectionShape.bounds.maxY.rounded(.up)), canvasSize.height)

            if minX < maxX && minY < maxY {
                for y in minY..<maxY {
                    for x in minX..<maxX {
                        if selectionShape.contains(CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                            generated[(y * canvasSize.width) + x] = 255
                        }
                    }
                }
            }
            generated.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                texture.replace(
                    region: MTLRegionMake2D(0, 0, canvasSize.width, canvasSize.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: canvasSize.width
                )
            }
        }

        cachedSelectionMaskShape = selectionShape
        cachedSelectionMaskCanvasSize = canvasSize
        cachedSelectionMaskTexture = texture
        return texture
    }
}
