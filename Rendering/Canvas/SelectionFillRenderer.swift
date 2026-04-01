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
    var colorJitterAmount: Float
}

final class SelectionFillRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
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
            float colorJitterAmount;
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

        float hash12(float2 point) {
            return fract(sin(dot(point, float2(127.1, 311.7))) * 43758.5453123);
        }

        float3 radialStripedJitteredFillSrgbColor(
            float3 srgbColor,
            float angleNormalized,
            float amount
        ) {
            if (amount <= 0.001) {
                return srgbColor;
            }

            float amountClamped = clamp(amount, 0.0, 1.0);
            float rightBoost = pow(amountClamped, 1.75);
            float stripeCoordPrimary = clamp(angleNormalized, 0.0, 1.0);

            float macroBandCount = floor(10.0 + (amountClamped * 16.0));
            macroBandCount = max(macroBandCount, 2.0);
            float macroBandIndex = floor(stripeCoordPrimary * macroBandCount);
            float macroWarp = ((hash12(float2(macroBandIndex + 151.0, 3.0)) * 2.0) - 1.0) * ((0.02 * amountClamped) + (0.08 * rightBoost));

            float fineWarpSeed = floor(stripeCoordPrimary * 220.0);
            float fineWarp = ((hash12(float2(fineWarpSeed + 5.0, 9.0)) * 2.0) - 1.0) * ((0.01 * amountClamped) + (0.03 * rightBoost));

            float warpedCoord = clamp(stripeCoordPrimary + macroWarp + fineWarp, 0.0, 0.999);
            float stripeCount = floor(46.0 + (amountClamped * 52.0));
            stripeCount = max(stripeCount, 8.0);
            float stripeIndex = floor(warpedCoord * stripeCount);
            float hueRandom = hash12(float2(stripeIndex + 1.0, 7.0));
            float saturationRandom = hash12(float2(stripeIndex + 31.0, 11.0));
            float valueRandom = hash12(float2(stripeIndex + 61.0, 23.0));
            float accentRandom = hash12(float2(stripeIndex + 91.0, 37.0));
            float stripeShapeRandom = hash12(float2(stripeIndex + 121.0, 43.0));

            float layeringBandCount = floor(16.0 + (amountClamped * 18.0));
            layeringBandCount = max(layeringBandCount, 2.0);
            float layeringBandIndex = floor(warpedCoord * layeringBandCount);
            float bandSaturationRandom = hash12(float2(layeringBandIndex + 211.0, 17.0));
            float bandValueRandom = hash12(float2(layeringBandIndex + 241.0, 29.0));

            float3 hsv = rgbToHsv(srgbColor);
            float hueOffsetRange = 0.30 * amountClamped;
            float saturationOffsetRange = (0.95 * amountClamped) + (0.70 * rightBoost);
            float valueOffsetRange = (0.52 * amountClamped) + (0.38 * rightBoost);

            float hueOffset = ((hueRandom * 2.0) - 1.0) * hueOffsetRange;
            float accentGate = step(0.82 - (0.18 * amountClamped), accentRandom);
            hueOffset += ((accentRandom * 2.0) - 1.0) * (0.03 * rightBoost) * accentGate;

            float saturationBase = mix(saturationRandom, bandSaturationRandom, 0.55);
            float valueBase = mix(valueRandom, bandValueRandom, 0.45);
            float saturationOffset = ((saturationBase * 2.0) - 1.0) * saturationOffsetRange;
            float valueOffset = ((valueBase * 2.0) - 1.0) * valueOffsetRange;

            float vividBoost = accentGate * ((0.24 * amountClamped) + (0.38 * rightBoost));
            float darkLightSwing = ((stripeShapeRandom * 2.0) - 1.0) * ((0.08 * amountClamped) + (0.18 * rightBoost));

            hsv.x = fract(hsv.x + hueOffset + 1.0);
            hsv.y = clamp(hsv.y + saturationOffset + (0.20 * rightBoost) + vividBoost, 0.0, 1.0);
            hsv.z = clamp(hsv.z + valueOffset + darkLightSwing, 0.0, 1.0);
            return hsvToRgb(hsv);
        }

        fragment float4 selectionFillFragmentShader(
            VertexOut in [[stage_in]],
            constant SelectionFillUniforms &uniforms [[buffer(1)]],
            texture2d<float> selectionMask [[texture(0)]]
        ) {
            float2 boundsSize = max(uniforms.selectionBoundsMax - uniforms.selectionBoundsMin, float2(1.0, 1.0));
            float2 localCoord = clamp((in.canvasPosition - uniforms.selectionBoundsMin) / boundsSize, 0.0, 1.0);
            constexpr sampler maskSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
            float maskAlpha = selectionMask.sample(maskSampler, localCoord).r;
            if (maskAlpha <= 0.001) {
                return float4(0.0);
            }

            float angle = atan2(in.canvasPosition.y - uniforms.fillCenter.y, in.canvasPosition.x - uniforms.fillCenter.x);
            float angleNormalized = (angle / 6.283185307179586) + 0.5;
            float3 jitteredColor = radialStripedJitteredFillSrgbColor(
                uniforms.color.rgb,
                angleNormalized,
                uniforms.colorJitterAmount
            );

            float alpha = uniforms.color.a * maskAlpha;
            float3 premultiplied = jitteredColor * alpha;
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

    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        selectionMaskOriginX: Int,
        selectionMaskOriginY: Int,
        selectionMaskWidth: Int,
        selectionMaskHeight: Int,
        selectionMaskAlphaBytes: [UInt8],
        fillCenter: CanvasPoint,
        color: RGBAColor,
        colorJitterAmount: Float = 0
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
            colorJitterAmount: colorJitterAmount
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
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
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    private func makeSelectionMaskTexture(
        alphaBytes: [UInt8],
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

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: alphaBytes,
            bytesPerRow: width
        )

        return texture
    }
}
