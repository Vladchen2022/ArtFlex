import Foundation
import Metal
import simd

private struct LinearGradientVertex {
    var position: SIMD2<Float>
}

private struct LinearGradientUniforms {
    var canvasSize: SIMD2<Float>
    var pointA: SIMD2<Float>
    var pointB: SIMD2<Float>
    var color: SIMD4<Float>
    var paintJitterAmount: Float
    var paintContrastAmount: Float
    var distortionAmount: Float
    var usesSelectionMask: Float
    var usesAlphaLock: Float
}

final class LinearGradientRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let fallbackSelectionMaskTexture: MTLTexture
    private let fallbackAlphaLockTexture: MTLTexture
    private var cachedSelectionMaskShape: SelectionShape?
    private var cachedSelectionMaskCanvasSize: CanvasSize?
    private var cachedSelectionMaskTexture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct LinearGradientVertex {
            float2 position;
        };

        struct LinearGradientUniforms {
            float2 canvasSize;
            float2 pointA;
            float2 pointB;
            float4 color;
            float paintJitterAmount;
            float paintContrastAmount;
            float distortionAmount;
            float usesSelectionMask;
            float usesAlphaLock;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
        };

        vertex VertexOut linearGradientVertexShader(
            const device LinearGradientVertex *vertices [[buffer(0)]],
            constant LinearGradientUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            LinearGradientVertex inputVertex = vertices[vertexID];
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

        float3 linearPaintJitteredSrgbColor(
            float3 srgbColor,
            float stripeCoord,
            float paintJitterAmount,
            float paintContrastAmount
        ) {
            float contrastAmt = clamp(paintContrastAmount, 0.0, 1.0);
            if (paintJitterAmount <= 0.001 && contrastAmt <= 0.001) {
                return srgbColor;
            }

            float amount = clamp(paintJitterAmount, 0.0, 1.0);
            float coord = clamp(stripeCoord, 0.0, 1.0);
            float stripeCount = 70.0;
            float stripeIndex = floor(coord * stripeCount);
            float scattered = fract(stripeIndex * 0.618033988749895) * stripeCount;
            float hueRandom = hash11(scattered + 1001.0);
            float satRandom = hash11(scattered + 1031.0);
            float valRandom = hash11(scattered + 1061.0);

            float3 hsv = rgbToHsv(srgbColor);

            // Hue spread: slider 0-100% maps to ±0° to ±180° on the color wheel
            float hueSpread = amount * 0.5;
            float hueOffset = ((hueRandom * 2.0) - 1.0) * hueSpread;

            // Subtle saturation/value variation
            float satOffset = ((satRandom * 2.0) - 1.0) * amount * 0.10;
            float valOffset = ((valRandom * 2.0) - 1.0) * amount * 0.08;

            if (contrastAmt > 0.001) {
                float complementRandom = hash11(scattered + 1091.0);
                float threshold = 1.0 - (contrastAmt * 0.20);
                if (complementRandom > threshold) {
                    hueOffset = 0.5 + hueOffset;
                }
            }

            hsv.x = fract(hsv.x + hueOffset + 1.0);
            hsv.y = clamp(hsv.y + satOffset, 0.0, 1.0);
            hsv.z = clamp(hsv.z + valOffset, 0.0, 1.0);
            return hsvToRgb(hsv);
        }

        fragment float4 linearGradientFragmentShader(
            VertexOut in [[stage_in]],
            constant LinearGradientUniforms &uniforms [[buffer(1)]],
            texture2d<float> selectionMask [[texture(0)]],
            texture2d<float> alphaLockTexture [[texture(1)]]
        ) {
            constexpr sampler maskSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float2 axis = uniforms.pointB - uniforms.pointA;
            float axisLength = max(length(axis), 0.0001);
            float axisLengthSquared = max(dot(axis, axis), 0.0001);
            float t = clamp(dot(in.canvasPosition - uniforms.pointA, axis) / axisLengthSquared, 0.0, 1.0);
            float maskAlpha = 1.0;
            if (uniforms.usesSelectionMask > 0.5) {
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 uv = in.canvasPosition / canvasSize;
                maskAlpha = selectionMask.sample(maskSampler, uv).r;
            }
            if (uniforms.usesAlphaLock > 0.5) {
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 uv = in.canvasPosition / canvasSize;
                if (alphaLockTexture.sample(maskSampler, uv).a <= 0.001) {
                    return float4(0.0);
                }
            }
            float easedAlpha = 1.0 - smoothstep(0.0, 1.0, t);
            float alpha = easedAlpha * uniforms.color.a * maskAlpha;
            float2 axisDirection = axis / axisLength;
            float2 perpendicularDirection = float2(-axisDirection.y, axisDirection.x);
            float2 distortedPos = noiseDistort(in.canvasPosition, uniforms.distortionAmount);
            float2 centered = distortedPos - uniforms.canvasSize * 0.5;
            float across = dot(centered, perpendicularDirection);
            float canvasDiag = length(uniforms.canvasSize);
            float stripeCoord = clamp(across / canvasDiag + 0.5, 0.0, 1.0);
            float3 jitteredColor = linearPaintJitteredSrgbColor(
                uniforms.color.rgb,
                stripeCoord,
                uniforms.paintJitterAmount,
                uniforms.paintContrastAmount
            );
            float3 premultiplied = jitteredColor * alpha;
            return float4(premultiplied, alpha);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile LinearGradientRenderer shader: \(error)")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "linearGradientVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "linearGradientFragmentShader")
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
            self.pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create LinearGradientRenderer pipeline: \(error)")
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
        pointA: CanvasPoint,
        pointB: CanvasPoint,
        pointC: CanvasPoint,
        color: RGBAColor,
        paintJitterAmount: Float = 0,
        paintContrastAmount: Float = 0,
        distortionAmount: Float = 0,
        selectionShape: SelectionShape? = nil,
        alphaLockTexture: MTLTexture? = nil
    ) {
        let vertices: [LinearGradientVertex] = [
            .init(position: SIMD2(0, 0)),
            .init(position: SIMD2(Float(canvasSize.width), 0)),
            .init(position: SIMD2(0, Float(canvasSize.height))),
            .init(position: SIMD2(Float(canvasSize.width), Float(canvasSize.height)))
        ]
        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: canvasSize
        ) ?? fallbackSelectionMaskTexture
        var uniforms = LinearGradientUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            pointA: SIMD2(Float(pointA.x), Float(pointA.y)),
            pointB: SIMD2(Float(pointB.x), Float(pointB.y)),
            color: SIMD4(color.red, color.green, color.blue, color.alpha),
            paintJitterAmount: paintJitterAmount,
            paintContrastAmount: paintContrastAmount,
            distortionAmount: distortionAmount,
            usesSelectionMask: selectionShape == nil ? 0 : 1,
            usesAlphaLock: alphaLockTexture == nil ? 0 : 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<LinearGradientVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LinearGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LinearGradientUniforms>.stride, index: 1)
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    func render(
        into texture: MTLTexture,
        pointA: CanvasPoint,
        pointB: CanvasPoint,
        pointC: CanvasPoint,
        color: RGBAColor,
        paintJitterAmount: Float = 0,
        paintContrastAmount: Float = 0,
        distortionAmount: Float = 0,
        commandQueue: MTLCommandQueue,
        selectionShape: SelectionShape? = nil
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        encode(
            into: descriptor,
            commandBuffer: commandBuffer,
            canvasSize: .init(width: texture.width, height: texture.height),
            pointA: pointA,
            pointB: pointB,
            pointC: pointC,
            color: color,
            paintJitterAmount: paintJitterAmount,
            paintContrastAmount: paintContrastAmount,
            distortionAmount: distortionAmount,
            selectionShape: selectionShape
        )
        commandBuffer.commit()
    }

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
                        if selectionShape.contains(
                            CanvasPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                        ) {
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
