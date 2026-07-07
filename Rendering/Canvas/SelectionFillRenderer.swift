import Foundation
import Metal
import simd

private struct SelectionFillVertex {
    var position: SIMD2<Float>
}

private struct SelectionFillUniforms {
    var canvasSize: SIMD2<Float>
    var selectionBoundsMin: SIMD2<Float>
    var selectionBoundsMax: SIMD2<Float>
    var fillCenter: SIMD2<Float>
    var color: SIMD4<Float>
    var paintJitterAmount: Float
    var paintContrastAmount: Float
    var distortionAmount: Float
    var usesAlphaLock: Float
}

final class SelectionFillRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let alphaLockPipelineState: MTLRenderPipelineState
    private let fallbackAlphaLockTexture: MTLTexture
    private var reusableSelectionMaskTexture: MTLTexture?
    private var reusableSelectionMaskTextureSize: SIMD2<Int>?

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct SelectionFillVertex {
            float2 position;
        };

        struct SelectionFillUniforms {
            float2 canvasSize;
            float2 selectionBoundsMin;
            float2 selectionBoundsMax;
            float2 fillCenter;
            float4 color;
            float paintJitterAmount;
            float paintContrastAmount;
            float distortionAmount;
            float usesAlphaLock;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 canvasPosition;
        };

        vertex VertexOut selectionFillVertexShader(
            const device SelectionFillVertex *vertices [[buffer(0)]],
            constant SelectionFillUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            SelectionFillVertex inputVertex = vertices[vertexID];
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

        fragment float4 selectionFillFragmentShader(
            VertexOut in [[stage_in]],
            constant SelectionFillUniforms &uniforms [[buffer(1)]],
            texture2d<float> selectionMask [[texture(0)]],
            texture2d<float> alphaLockTexture [[texture(1)]]
        ) {
            float2 boundsSize = max(uniforms.selectionBoundsMax - uniforms.selectionBoundsMin, float2(1.0, 1.0));
            float2 localCoord = clamp((in.canvasPosition - uniforms.selectionBoundsMin) / boundsSize, 0.0, 1.0);
            constexpr sampler maskSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float maskAlpha = selectionMask.sample(maskSampler, localCoord).r;
            if (maskAlpha <= 0.001) {
                return float4(0.0);
            }
            float lockedDestinationAlpha = 1.0;
            if (uniforms.usesAlphaLock > 0.5) {
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 canvasUV = in.canvasPosition / canvasSize;
                lockedDestinationAlpha = alphaLockTexture.sample(maskSampler, canvasUV).a;
                if (lockedDestinationAlpha <= 0.001) {
                    return float4(0.0);
                }
            }

            float2 distortedPos = noiseDistort(in.canvasPosition, uniforms.distortionAmount);
            float angle = atan2(distortedPos.y - uniforms.fillCenter.y, distortedPos.x - uniforms.fillCenter.x);
            float angleNormalized = (angle / 6.283185307179586) + 0.5;
            float3 jitteredColor = radialPaintJitteredSrgbColor(
                uniforms.color.rgb,
                angleNormalized,
                uniforms.paintJitterAmount,
                uniforms.paintContrastAmount
            );

            float alpha = uniforms.color.a * maskAlpha;
            float3 premultiplied = jitteredColor * alpha;
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
            fatalError("Failed to compile SelectionFillRenderer shader: \(error)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "selectionFillVertexShader")
        descriptor.fragmentFunction = library.makeFunction(name: "selectionFillFragmentShader")
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
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Failed to create SelectionFillRenderer pipeline: \(error)")
        }

        let alphaLockDescriptor = MTLRenderPipelineDescriptor()
        alphaLockDescriptor.vertexFunction = library.makeFunction(name: "selectionFillVertexShader")
        alphaLockDescriptor.fragmentFunction = library.makeFunction(name: "selectionFillFragmentShader")
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
            alphaLockPipelineState = try device.makeRenderPipelineState(descriptor: alphaLockDescriptor)
        } catch {
            fatalError("Failed to create SelectionFillRenderer alpha lock pipeline: \(error)")
        }

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
        selectionMaskOriginX: Int,
        selectionMaskOriginY: Int,
        selectionMaskWidth: Int,
        selectionMaskHeight: Int,
        selectionMaskAlphaBytes: Data,
        fillCenter: CanvasPoint,
        color: RGBAColor,
        paintJitterAmount: Float = 0,
        paintContrastAmount: Float = 0,
        distortionAmount: Float = 0,
        alphaLockTexture: MTLTexture? = nil
    ) {
        let minX = max(selectionMaskOriginX, 0)
        let minY = max(selectionMaskOriginY, 0)
        let maxX = min(selectionMaskOriginX + selectionMaskWidth, canvasSize.width)
        let maxY = min(selectionMaskOriginY + selectionMaskHeight, canvasSize.height)
        guard minX < maxX, minY < maxY else {
            return
        }
        guard selectionMaskAlphaBytes.count == selectionMaskWidth * selectionMaskHeight else {
            return
        }

        let vertices: [SelectionFillVertex] = [
            .init(position: SIMD2(Float(minX), Float(minY))),
            .init(position: SIMD2(Float(maxX), Float(minY))),
            .init(position: SIMD2(Float(minX), Float(maxY))),
            .init(position: SIMD2(Float(maxX), Float(maxY)))
        ]
        guard let selectionMaskTexture = makeSelectionMaskTexture(
            alphaBytes: selectionMaskAlphaBytes,
            width: selectionMaskWidth,
            height: selectionMaskHeight
        ) else {
            return
        }

        var uniforms = SelectionFillUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            selectionBoundsMin: SIMD2(Float(minX), Float(minY)),
            selectionBoundsMax: SIMD2(Float(maxX), Float(maxY)),
            fillCenter: SIMD2(Float(fillCenter.x), Float(fillCenter.y)),
            color: SIMD4(color.red, color.green, color.blue, color.alpha),
            paintJitterAmount: paintJitterAmount,
            paintContrastAmount: paintContrastAmount,
            distortionAmount: distortionAmount,
            usesAlphaLock: alphaLockTexture == nil ? 0 : 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(alphaLockTexture == nil ? pipelineState : alphaLockPipelineState)
        encoder.setScissorRect(MTLScissorRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        ))
        encoder.setVertexBytes(vertices, length: MemoryLayout<SelectionFillVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SelectionFillUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SelectionFillUniforms>.stride, index: 1)
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    private func makeSelectionMaskTexture(
        alphaBytes: Data,
        width: Int,
        height: Int
    ) -> MTLTexture? {
        guard width > 0, height > 0 else {
            return nil
        }
        guard alphaBytes.count == width * height else {
            return nil
        }

        let texture: MTLTexture
        if reusableSelectionMaskTextureSize != SIMD2(width, height) || reusableSelectionMaskTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: width,
                height: height,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let newTexture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            reusableSelectionMaskTexture = newTexture
            reusableSelectionMaskTextureSize = SIMD2(width, height)
        }
        guard let reusableSelectionMaskTexture else {
            return nil
        }
        texture = reusableSelectionMaskTexture

        alphaBytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }

        return texture
    }
}
