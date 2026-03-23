import Foundation
import Metal
import simd

private struct BrushVertex {
    var position: SIMD2<Float>
}

private struct BrushUniforms {
    var center: SIMD2<Float>
    var radius: Float
    var opacity: Float
    var color: SIMD4<Float>
    var colorJitterAmount: Float
    var jitterDirectionDegrees: Float
    var canvasSize: SIMD2<Float>
    var mode: UInt32
    var tipShape: UInt32
    var tipHardness: Float
    var tipSoftness: Float
    var tipRoundness: Float
    var tipAngleDegrees: Float
    var selectionMode: UInt32
    var selectionMin: SIMD2<Float>
    var selectionMax: SIMD2<Float>
}

private struct CompositeUniforms {
    var brushColor: SIMD4<Float>
    var mode: UInt32 = 0
    var paddingValues: SIMD3<UInt32> = .zero
    var padding: SIMD4<Float> = .zero
}

private struct StampSample {
    var point: StrokePoint
    var angleDegrees: Float
    var jitterDirectionDegrees: Float
    var sizeMultiplier: Float
}

struct BrushStrokeSamplingState {
    var distanceSinceLastSample: Double = 0
    var lastSamplePoint: StrokePoint?
    var nextSampleIndex: Int = 0
    /// Look-ahead 输入缓冲：收到的原始输入点全部追加到这里。
    /// 渲染时始终保留最后 1 个点作为 look-ahead（p3），
    /// 确保每段 Catmull-Rom 的 p0..p3 全部是真实点，永远不需要幽灵外推。
    /// 笔触结束（endStroke）时由外部调用 flush，把剩余点全部渲染完。
    var pendingInputPoints: [StrokePoint] = []
    /// 笔触是否已经结束（用于 flush 模式）
    var isFlushing: Bool = false
}

struct OpacityCapSessionResources {
    let originalTexture: MTLTexture
    let alphaTexture: MTLTexture
}

private let customTipMaskResolution = 256

final class StageOneBrushRenderer {
    private let device: MTLDevice
    private let brushPipelineState: MTLRenderPipelineState
    private let eraserPipelineState: MTLRenderPipelineState
    private let smudgePipelineState: MTLRenderPipelineState
    private let opacityCapMaskPipelineState: MTLRenderPipelineState
    private let opacityCapCompositePipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let compositeSamplerState: MTLSamplerState
    private let tipSamplerState: MTLSamplerState
    private let defaultTipTexture: MTLTexture
    private var cachedSelectionMaskShape: SelectionShape?
    private var cachedSelectionMaskCanvasSize: CanvasSize?
    private var cachedSelectionMaskTexture: MTLTexture?
    private var cachedCustomTipData: Data?
    private var cachedCustomTipTexture: MTLTexture?

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct BrushVertex {
            float2 position;
        };

        struct BrushUniforms {
            float2 center;
            float radius;
            float opacity;
            float4 color;
            float colorJitterAmount;
            float jitterDirectionDegrees;
            float2 canvasSize;
            uint mode;
            uint tipShape;
            float tipHardness;
            float tipSoftness;
            float tipRoundness;
            float tipAngleDegrees;
            uint selectionMode;
            float2 selectionMin;
            float2 selectionMax;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 localPoint;
            float2 pixelPoint;
        };

        struct CompositeVertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct CompositeUniforms {
            float4 brushColor;
            uint mode;
            uint3 paddingValues;
            float4 padding;
        };

        float smoothHardnessAlpha(float distance, float hardness) {
            if (distance >= 1.0) {
                return 0.0;
            }

            if (hardness >= 0.999) {
                return 1.0;
            }

            if (distance <= hardness) {
                return 1.0;
            }

            float t = clamp((distance - hardness) / max(1.0 - hardness, 0.0001), 0.0, 1.0);
            return 1.0 - smoothstep(0.0, 1.0, t);
        }

        float tipAlpha(
            float2 localPoint,
            constant BrushUniforms &uniforms,
            texture2d<float, access::sample> customTipMask
        ) {
            float radiansValue = uniforms.tipAngleDegrees * 0.017453292519943295;
            float cosine = cos(radiansValue);
            float sine = sin(radiansValue);
            float2 rotatedPoint = float2(
                (localPoint.x * cosine) + (localPoint.y * sine),
                (-localPoint.x * sine) + (localPoint.y * cosine)
            );

            if (uniforms.tipShape == 2) {
                float squareDistance = max(abs(rotatedPoint.x), abs(rotatedPoint.y));
                return squareDistance <= 1.0 ? 1.0 : 0.0;
            }

            if (uniforms.tipShape == 1) {
                float roundDistance = length(localPoint);
                if (roundDistance >= 1.0) {
                    return 0.0;
                }

                float feather = clamp(1.0 - roundDistance, 0.0, 1.0);
                return feather * feather;
            }

            if (uniforms.tipShape == 3) {
                float roundness = clamp(uniforms.tipRoundness, 0.25, 1.0);
                float2 shaped = float2(rotatedPoint.x / roundness, rotatedPoint.y);
                if (max(abs(shaped.x), abs(shaped.y)) >= 1.0) {
                    return 0.0;
                }

                float2 uv = float2(
                    clamp((shaped.x + 1.0) * 0.5, 0.0, 1.0),
                    clamp((shaped.y + 1.0) * 0.5, 0.0, 1.0)
                );
                constexpr sampler tipSampler(
                    coord::normalized,
                    address::clamp_to_edge,
                    filter::linear
                );
                float sampledAlpha = customTipMask.sample(tipSampler, uv).r;
                float softness = clamp(uniforms.tipSoftness, 0.0, 1.0);
                float exponent = mix(3.2, 0.75, softness);
                return pow(clamp(sampledAlpha, 0.0, 1.0), exponent);
            }

            float roundDistance = length(localPoint);
            return smoothHardnessAlpha(roundDistance, uniforms.tipHardness);
        }

        float srgbChannelToLinear(float value) {
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4);
        }

        float3 srgbToLinear(float3 color) {
            return float3(
                srgbChannelToLinear(color.r),
                srgbChannelToLinear(color.g),
                srgbChannelToLinear(color.b)
            );
        }

        float3 rgbToHsv(float3 c) {
            float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
            float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return float3(
                abs(q.z + (q.w - q.y) / (6.0 * d + e)),
                d / (q.x + e),
                q.x
            );
        }

        float3 hsvToRgb(float3 c) {
            float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, clamp(p - K.xxx, 0.0, 1.0), c.y);
        }

        float hash11(float value) {
            return fract(sin(value * 127.1) * 43758.5453123);
        }

        float3 jitteredSrgbColor(
            float3 srgbColor,
            float2 localPoint,
            constant BrushUniforms &uniforms
        ) {
            if (uniforms.colorJitterAmount <= 0.001) {
                return srgbColor;
            }

            float amount = clamp(uniforms.colorJitterAmount, 0.0, 1.0);
            float radiansValue = uniforms.jitterDirectionDegrees * 0.017453292519943295;
            float cosine = cos(radiansValue);
            float sine = sin(radiansValue);
            float2 rotatedPoint = float2(
                (localPoint.x * cosine) + (localPoint.y * sine),
                (-localPoint.x * sine) + (localPoint.y * cosine)
            );

            float rightBoost = pow(amount, 1.75);
            float stripeCoordPrimary = clamp((rotatedPoint.x + 1.0) * 0.5, 0.0, 1.0);

            // Build irregular stripe widths by combining macro and micro warps.
            float macroBandCount = floor(6.0 + (amount * 6.0));
            macroBandCount = max(macroBandCount, 2.0);
            float macroBandIndex = floor(stripeCoordPrimary * macroBandCount);
            float macroWarp = ((hash11(macroBandIndex + 151.0) * 2.0) - 1.0) * ((0.025 * amount) + (0.085 * rightBoost));

            float fineWarpSeed = floor(stripeCoordPrimary * 96.0);
            float fineWarp = ((hash11(fineWarpSeed + 5.0) * 2.0) - 1.0) * ((0.015 * amount) + (0.04 * rightBoost));

            float warpedCoord = clamp(stripeCoordPrimary + macroWarp + fineWarp, 0.0, 0.999);
            float stripeCount = floor(30.0 + (amount * 10.0));
            stripeCount = max(stripeCount, 2.0);
            float stripeIndex = floor(warpedCoord * stripeCount);
            float hueRandom = hash11(stripeIndex + 1.0);
            float saturationRandom = hash11(stripeIndex + 31.0);
            float valueRandom = hash11(stripeIndex + 61.0);
            float accentRandom = hash11(stripeIndex + 91.0);
            float stripeShapeRandom = hash11(stripeIndex + 121.0);

            float layeringBandCount = floor(10.0 + (amount * 10.0));
            layeringBandCount = max(layeringBandCount, 2.0);
            float layeringBandIndex = floor(warpedCoord * layeringBandCount);
            float bandSaturationRandom = hash11(layeringBandIndex + 211.0);
            float bandValueRandom = hash11(layeringBandIndex + 241.0);

            float3 hsv = rgbToHsv(srgbColor);
            float hueOffsetRange = 0.25 * amount;
            float saturationOffsetRange = (0.85 * amount) + (0.55 * rightBoost);
            float valueOffsetRange = (0.40 * amount) + (0.28 * rightBoost);

            float hueOffset = ((hueRandom * 2.0) - 1.0) * hueOffsetRange;
            float accentGate = step(0.82 - (0.18 * amount), accentRandom);
            hueOffset += ((accentRandom * 2.0) - 1.0) * (0.03 * rightBoost) * accentGate;

            float saturationBase = mix(saturationRandom, bandSaturationRandom, 0.55);
            float valueBase = mix(valueRandom, bandValueRandom, 0.45);

            float saturationOffset = ((saturationBase * 2.0) - 1.0) * saturationOffsetRange;
            float valueOffset = ((valueBase * 2.0) - 1.0) * valueOffsetRange;

            float vividBoost = accentGate * ((0.18 * amount) + (0.3 * rightBoost));
            float darkLightSwing = ((stripeShapeRandom * 2.0) - 1.0) * ((0.05 * amount) + (0.12 * rightBoost));

            hsv.x = fract(hsv.x + hueOffset + 1.0);
            hsv.y = clamp(hsv.y + saturationOffset + (0.15 * rightBoost) + vividBoost, 0.0, 1.0);
            hsv.z = clamp(hsv.z + valueOffset + darkLightSwing, 0.0, 1.0);
            return hsvToRgb(hsv);
        }

        vertex CompositeVertexOut stageOneCompositeVertex(
            const device BrushVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            CompositeVertexOut out;
            float2 position = vertices[vertexID].position;
            out.position = float4(position, 0.0, 1.0);
            out.texCoord = float2((position.x + 1.0) * 0.5, (1.0 - position.y) * 0.5);
            return out;
        }

        vertex VertexOut stageOneBrushVertex(
            const device BrushVertex *vertices [[buffer(0)]],
            constant BrushUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            float2 local = vertices[vertexID].position;
            float2 pixel = uniforms.center + local * uniforms.radius;
            float2 ndc = float2(
                (pixel.x / uniforms.canvasSize.x) * 2.0 - 1.0,
                1.0 - (pixel.y / uniforms.canvasSize.y) * 2.0
            );
            out.position = float4(ndc, 0.0, 1.0);
            out.localPoint = local;
            out.pixelPoint = pixel;
            return out;
        }

        fragment float4 stageOneBrushFragment(
            VertexOut in [[stage_in]],
            constant BrushUniforms &uniforms [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]]
        ) {
            float alphaMask = tipAlpha(in.localPoint, uniforms, customTipMask);
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            if (uniforms.selectionMode != 0) {
                float2 minPoint = uniforms.selectionMin;
                float2 maxPoint = uniforms.selectionMax;
                bool insideBounds =
                    in.pixelPoint.x >= minPoint.x &&
                    in.pixelPoint.x <= maxPoint.x &&
                    in.pixelPoint.y >= minPoint.y &&
                    in.pixelPoint.y <= maxPoint.y;

                if (!insideBounds) {
                    discard_fragment();
                }

                if (uniforms.selectionMode == 2) {
                    float2 center = (minPoint + maxPoint) * 0.5;
                    float2 radius = max((maxPoint - minPoint) * 0.5, float2(0.0001));
                    float2 normalized = (in.pixelPoint - center) / radius;
                    if (dot(normalized, normalized) > 1.0) {
                        discard_fragment();
                    }
                } else if (uniforms.selectionMode == 3) {
                    uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                    uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                    if (selectionMask.read(uint2(x, y)).r < 0.5) {
                        discard_fragment();
                    }
                }
            }

            float alpha = uniforms.opacity * alphaMask;

            if (uniforms.mode == 1) {
                return float4(0.0, 0.0, 0.0, alpha);
            }

            float4 inputColor = uniforms.color;
            float brushAlpha = inputColor.a * alpha;
            float3 jitteredSrgb = jitteredSrgbColor(inputColor.rgb, in.localPoint, uniforms);
            float3 linearRGB = srgbToLinear(jitteredSrgb);
            return float4(linearRGB * brushAlpha, brushAlpha);
        }

        fragment float4 stageOneSmudgeFragment(
            VertexOut in [[stage_in]],
            constant BrushUniforms &uniforms [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::sample> sourceTexture [[texture(1)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]]
        ) {
            float alphaMask = tipAlpha(in.localPoint, uniforms, customTipMask);
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            if (uniforms.selectionMode != 0) {
                float2 minPoint = uniforms.selectionMin;
                float2 maxPoint = uniforms.selectionMax;
                bool insideBounds =
                    in.pixelPoint.x >= minPoint.x &&
                    in.pixelPoint.x <= maxPoint.x &&
                    in.pixelPoint.y >= minPoint.y &&
                    in.pixelPoint.y <= maxPoint.y;

                if (!insideBounds) {
                    discard_fragment();
                }

                if (uniforms.selectionMode == 2) {
                    float2 center = (minPoint + maxPoint) * 0.5;
                    float2 radius = max((maxPoint - minPoint) * 0.5, float2(0.0001));
                    float2 normalized = (in.pixelPoint - center) / radius;
                    if (dot(normalized, normalized) > 1.0) {
                        discard_fragment();
                    }
                } else if (uniforms.selectionMode == 3) {
                    uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                    uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                    if (selectionMask.read(uint2(x, y)).r < 0.5) {
                        discard_fragment();
                    }
                }
            }

            float alpha = uniforms.opacity * alphaMask;
            if (alpha <= 0.0) {
                discard_fragment();
            }

            float2 sampleUV = float2(
                clamp(uniforms.center.x / uniforms.canvasSize.x, 0.0, 1.0),
                clamp(uniforms.center.y / uniforms.canvasSize.y, 0.0, 1.0)
            );
            constexpr sampler sourceSampler(
                coord::normalized,
                address::clamp_to_edge,
                filter::linear
            );
            float4 sampled = sourceTexture.sample(sourceSampler, sampleUV);
            float3 visibleRGB = sampled.rgb + ((1.0 - sampled.a) * float3(1.0));
            return float4(visibleRGB * alpha, alpha);
        }

        fragment float4 stageOneOpacityCapMaskFragment(
            VertexOut in [[stage_in]],
            constant BrushUniforms &uniforms [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]]
        ) {
            float alphaMask = tipAlpha(in.localPoint, uniforms, customTipMask);
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            if (uniforms.selectionMode != 0) {
                float2 minPoint = uniforms.selectionMin;
                float2 maxPoint = uniforms.selectionMax;
                bool insideBounds =
                    in.pixelPoint.x >= minPoint.x &&
                    in.pixelPoint.x <= maxPoint.x &&
                    in.pixelPoint.y >= minPoint.y &&
                    in.pixelPoint.y <= maxPoint.y;

                if (!insideBounds) {
                    discard_fragment();
                }

                if (uniforms.selectionMode == 2) {
                    float2 center = (minPoint + maxPoint) * 0.5;
                    float2 radius = max((maxPoint - minPoint) * 0.5, float2(0.0001));
                    float2 normalized = (in.pixelPoint - center) / radius;
                    if (dot(normalized, normalized) > 1.0) {
                        discard_fragment();
                    }
                } else if (uniforms.selectionMode == 3) {
                    uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                    uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                    if (selectionMask.read(uint2(x, y)).r < 0.5) {
                        discard_fragment();
                    }
                }
            }

            float flowAlpha = uniforms.opacity * alphaMask;
            return float4(flowAlpha, flowAlpha, flowAlpha, flowAlpha);
        }

        fragment float4 stageOneOpacityCapCompositeFragment(
            CompositeVertexOut in [[stage_in]],
            texture2d<float, access::sample> originalTexture [[texture(0)]],
            texture2d<float, access::sample> alphaTexture [[texture(1)]],
            sampler textureSampler [[sampler(0)]],
            constant CompositeUniforms &uniforms [[buffer(0)]]
        ) {
            float4 original = originalTexture.sample(textureSampler, in.texCoord);
            float accumulatedAlpha = alphaTexture.sample(textureSampler, in.texCoord).r;
            float cappedAlpha = clamp(accumulatedAlpha * uniforms.brushColor.a, 0.0, 1.0);

            if (uniforms.mode == 1) {
                return float4(
                    original.rgb * (1.0 - cappedAlpha),
                    original.a * (1.0 - cappedAlpha)
                );
            }

            float3 linearRGB = srgbToLinear(uniforms.brushColor.rgb);

            return float4(
                (linearRGB * cappedAlpha) + (original.rgb * (1.0 - cappedAlpha)),
                cappedAlpha + (original.a * (1.0 - cappedAlpha))
            );
        }
        """

        let library = try! device.makeLibrary(source: source, options: nil)
        let vertexFunction = library.makeFunction(name: "stageOneBrushVertex")!
        let fragmentFunction = library.makeFunction(name: "stageOneBrushFragment")!

        let brushDescriptor = MTLRenderPipelineDescriptor()
        brushDescriptor.vertexFunction = vertexFunction
        brushDescriptor.fragmentFunction = fragmentFunction
        brushDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let attachment = brushDescriptor.colorAttachments[0]!
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.brushPipelineState = try! device.makeRenderPipelineState(descriptor: brushDescriptor)

        let eraserDescriptor = MTLRenderPipelineDescriptor()
        eraserDescriptor.vertexFunction = vertexFunction
        eraserDescriptor.fragmentFunction = fragmentFunction
        eraserDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let eraserAttachment = eraserDescriptor.colorAttachments[0]!
        eraserAttachment.isBlendingEnabled = true
        eraserAttachment.rgbBlendOperation = .add
        eraserAttachment.alphaBlendOperation = .add
        eraserAttachment.sourceRGBBlendFactor = .zero
        eraserAttachment.sourceAlphaBlendFactor = .zero
        eraserAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        eraserAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.eraserPipelineState = try! device.makeRenderPipelineState(descriptor: eraserDescriptor)

        let smudgeDescriptor = MTLRenderPipelineDescriptor()
        smudgeDescriptor.vertexFunction = vertexFunction
        smudgeDescriptor.fragmentFunction = library.makeFunction(name: "stageOneSmudgeFragment")
        smudgeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let smudgeAttachment = smudgeDescriptor.colorAttachments[0]!
        smudgeAttachment.isBlendingEnabled = true
        smudgeAttachment.rgbBlendOperation = .add
        smudgeAttachment.alphaBlendOperation = .add
        smudgeAttachment.sourceRGBBlendFactor = .one
        smudgeAttachment.sourceAlphaBlendFactor = .one
        smudgeAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        smudgeAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        self.smudgePipelineState = try! device.makeRenderPipelineState(descriptor: smudgeDescriptor)

        let opacityCapMaskDescriptor = MTLRenderPipelineDescriptor()
        opacityCapMaskDescriptor.vertexFunction = vertexFunction
        opacityCapMaskDescriptor.fragmentFunction = library.makeFunction(name: "stageOneOpacityCapMaskFragment")
        opacityCapMaskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm

        let opacityCapMaskAttachment = opacityCapMaskDescriptor.colorAttachments[0]!
        opacityCapMaskAttachment.isBlendingEnabled = true
        opacityCapMaskAttachment.rgbBlendOperation = .max
        opacityCapMaskAttachment.alphaBlendOperation = .max
        opacityCapMaskAttachment.sourceRGBBlendFactor = .one
        opacityCapMaskAttachment.sourceAlphaBlendFactor = .one
        opacityCapMaskAttachment.destinationRGBBlendFactor = .one
        opacityCapMaskAttachment.destinationAlphaBlendFactor = .one
        self.opacityCapMaskPipelineState = try! device.makeRenderPipelineState(descriptor: opacityCapMaskDescriptor)

        let opacityCapCompositeDescriptor = MTLRenderPipelineDescriptor()
        opacityCapCompositeDescriptor.vertexFunction = library.makeFunction(name: "stageOneCompositeVertex")
        opacityCapCompositeDescriptor.fragmentFunction = library.makeFunction(name: "stageOneOpacityCapCompositeFragment")
        opacityCapCompositeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        opacityCapCompositeDescriptor.colorAttachments[0].isBlendingEnabled = false
        self.opacityCapCompositePipelineState = try! device.makeRenderPipelineState(descriptor: opacityCapCompositeDescriptor)

        let vertices = [
            BrushVertex(position: SIMD2(-1, -1)),
            BrushVertex(position: SIMD2(1, -1)),
            BrushVertex(position: SIMD2(-1, 1)),
            BrushVertex(position: SIMD2(1, 1))
        ]

        self.vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<BrushVertex>.stride * vertices.count
        )!

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        self.compositeSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)!
        self.tipSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)!

        let defaultTipDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        defaultTipDescriptor.usage = .shaderRead
        defaultTipDescriptor.storageMode = .shared
        let defaultTipTexture = device.makeTexture(descriptor: defaultTipDescriptor)!
        var fullAlpha: UInt8 = 255
        defaultTipTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &fullAlpha,
            bytesPerRow: 1
        )
        self.defaultTipTexture = defaultTipTexture

    }

    func render(
        stroke: StrokeDescriptor,
        into texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        samplingState: inout BrushStrokeSamplingState?,
        completion: (() -> Void)? = nil
    ) {
        let samples = interpolatedPoints(for: stroke, samplingState: &samplingState)
        guard
            !samples.isEmpty,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            completion?()
            return
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .load
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            completion?()
            return
        }

        let pipelineState: MTLRenderPipelineState
        switch stroke.tool {
        case .eraser:
            pipelineState = eraserPipelineState
        case .smudge:
            pipelineState = smudgePipelineState
        default:
            pipelineState = brushPipelineState
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let selectionShape = stroke.selectionShape?.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        if let selectionShape, selectionShape.isEmpty {
            encoder.endEncoding()
            commandBuffer.commit()
            // ⚡️ 优化：移除同步等待
            if let completion {
                commandBuffer.addCompletedHandler { _ in
                    completion()
                }
            }
            return
        }

        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: CanvasSize(width: texture.width, height: texture.height)
        )
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(
            customTipTexture(for: stroke.brush.customTipMaskData) ?? defaultTipTexture,
            index: 2
        )
        encoder.setFragmentSamplerState(tipSamplerState, index: 1)

        if stroke.tool == .smudge {
            let smudgeSourceTexture = makeSmudgeSourceTexture(
                from: texture,
                commandQueue: commandQueue
            )
            encoder.setFragmentTexture(smudgeSourceTexture, index: 1)
        }

        for sample in samples {
            var uniforms = makeUniforms(
                for: sample,
                stroke: stroke,
                texture: texture,
                selectionShape: selectionShape
            )

            encoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        
        // ⚡️ 优化：异步提交，可选的完成回调
        if let completion {
            commandBuffer.addCompletedHandler { _ in
                completion()
            }
        }
        commandBuffer.commit()
    }

    func makeOpacityCapSession(
        for texture: MTLTexture,
        commandQueue: MTLCommandQueue
    ) -> OpacityCapSessionResources? {
        let originalDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        originalDescriptor.usage = [.shaderRead]
        originalDescriptor.storageMode = .private

        let alphaDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        alphaDescriptor.usage = [.renderTarget, .shaderRead]
        alphaDescriptor.storageMode = .private

        guard
            let originalTexture = device.makeTexture(descriptor: originalDescriptor),
            let alphaTexture = device.makeTexture(descriptor: alphaDescriptor)
        else {
            return nil
        }

        clearTexture(alphaTexture, commandQueue: commandQueue)
        copyTexture(from: texture, to: originalTexture, commandQueue: commandQueue)
        return OpacityCapSessionResources(
            originalTexture: originalTexture,
            alphaTexture: alphaTexture
        )
    }

    func renderOpacityCap(
        stroke: StrokeDescriptor,
        session: OpacityCapSessionResources,
        into texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        samplingState: inout BrushStrokeSamplingState?,
        completion: (() -> Void)? = nil
    ) {
        let samples = interpolatedPoints(for: stroke, samplingState: &samplingState)
        guard
            !samples.isEmpty,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            completion?()
            return
        }

        let selectionShape = stroke.selectionShape?.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: CanvasSize(width: texture.width, height: texture.height)
        )
        let dirtyRect = opacityCapDirtyRect(
            for: samples,
            stroke: stroke,
            texture: texture
        )

        let accumulationPassDescriptor = MTLRenderPassDescriptor()
        accumulationPassDescriptor.colorAttachments[0].texture = session.alphaTexture
        accumulationPassDescriptor.colorAttachments[0].loadAction = .load
        accumulationPassDescriptor.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: accumulationPassDescriptor) {
            encoder.setRenderPipelineState(opacityCapMaskPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(selectionMaskTexture, index: 0)
            encoder.setFragmentTexture(
                customTipTexture(for: stroke.brush.customTipMaskData) ?? defaultTipTexture,
                index: 2
            )
            encoder.setFragmentSamplerState(tipSamplerState, index: 1)
            encoder.setScissorRect(dirtyRect)

            for sample in samples {
                var uniforms = makeUniforms(
                    for: sample,
                    stroke: stroke,
                    texture: texture,
                    selectionShape: selectionShape,
                    modeOverride: 0,
                    includeBrushOpacity: true
                )
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
                encoder.setFragmentBytes(&uniforms, length: MemoryLayout<BrushUniforms>.stride, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            }

            encoder.endEncoding()
        }

        let compositePassDescriptor = MTLRenderPassDescriptor()
        compositePassDescriptor.colorAttachments[0].texture = texture
        compositePassDescriptor.colorAttachments[0].loadAction = .load
        compositePassDescriptor.colorAttachments[0].storeAction = .store

        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositePassDescriptor) {
            encoder.setRenderPipelineState(opacityCapCompositePipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(session.originalTexture, index: 0)
            encoder.setFragmentTexture(session.alphaTexture, index: 1)
            encoder.setFragmentSamplerState(compositeSamplerState, index: 0)
            encoder.setScissorRect(dirtyRect)

            var uniforms = CompositeUniforms(
                brushColor: SIMD4(
                    stroke.color.red,
                    stroke.color.green,
                    stroke.color.blue,
                    stroke.color.alpha
                ),
                mode: stroke.tool == .eraser ? 1 : 0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        // ⚡️ 优化：异步提交
        if let completion {
            commandBuffer.addCompletedHandler { _ in
                completion()
            }
        }
        commandBuffer.commit()
    }

    private func opacityCapDirtyRect(
        for samples: [StampSample],
        stroke: StrokeDescriptor,
        texture: MTLTexture
    ) -> MTLScissorRect {
        guard !samples.isEmpty else {
            return MTLScissorRect(x: 0, y: 0, width: texture.width, height: texture.height)
        }

        var minX = Double.greatestFiniteMagnitude
        var minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        var maxY = -Double.greatestFiniteMagnitude

        for sample in samples {
            let radius = opacityCapRadius(for: sample.point, stroke: stroke)
            minX = min(minX, sample.point.x - radius)
            minY = min(minY, sample.point.y - radius)
            maxX = max(maxX, sample.point.x + radius)
            maxY = max(maxY, sample.point.y + radius)
        }

        if !minX.isFinite || !minY.isFinite || !maxX.isFinite || !maxY.isFinite {
            return MTLScissorRect(x: 0, y: 0, width: texture.width, height: texture.height)
        }

        let originX = max(Int(floor(minX)) - 1, 0)
        let originY = max(Int(floor(minY)) - 1, 0)
        let endX = min(Int(ceil(maxX)) + 1, texture.width)
        let endY = min(Int(ceil(maxY)) + 1, texture.height)

        return MTLScissorRect(
            x: originX,
            y: originY,
            width: max(endX - originX, 1),
            height: max(endY - originY, 1)
        )
    }

    private func makeUniforms(
        for sample: StampSample,
        stroke: StrokeDescriptor,
        texture: MTLTexture,
        selectionShape: SelectionShape?,
        modeOverride: UInt32? = nil,
        includeBrushOpacity: Bool = true
    ) -> BrushUniforms {
        let point = sample.point
        let effectivePressure = min(max(point.pressure, 0), 1)
        let sizePressure = max(effectivePressure, 0.01)
        let opacityPressure = max(effectivePressure, 0.005)
        let sizeResponse = min(max(stroke.brush.pressureSizeAmount, 0), 1)
        let opacityResponse = min(max(stroke.brush.pressureOpacityAmount, 0), 1)
        let curvedSizePressure = sizeCurvePressure(for: sizePressure, stroke: stroke)
        let lowerBound = min(max(stroke.brush.sizeLowerBound, 0), 1)
        let lowerBoundedPressure = lowerBound + ((1 - lowerBound) * curvedSizePressure)
        let sizeFactor = ((1 - sizeResponse) + (sizeResponse * lowerBoundedPressure)) * sample.sizeMultiplier
        let remappedOpacityPressure = pressureResponsePressure(for: opacityPressure, stroke: stroke)
        let curvedPressure = opacityCurvePressure(for: remappedOpacityPressure, stroke: stroke)
        let opacityFactor = (1 - opacityResponse) + (opacityResponse * curvedPressure)
        let selectionMode: UInt32
        let selectionMin: SIMD2<Float>
        let selectionMax: SIMD2<Float>

        if let selectionShape {
            switch selectionShape.kind {
            case .rectangle:
                selectionMode = 1
            case .ellipse:
                selectionMode = 2
            case .lasso, .mask:
                selectionMode = 3
            case .composite:
                selectionMode = 0
            }
            selectionMin = SIMD2(
                Float(selectionShape.bounds.minX),
                Float(selectionShape.bounds.minY)
            )
            selectionMax = SIMD2(
                Float(selectionShape.bounds.maxX),
                Float(selectionShape.bounds.maxY)
            )
        } else {
            selectionMode = 0
            selectionMin = SIMD2(0, 0)
            selectionMax = SIMD2(0, 0)
        }

        let resolvedOpacity = min(
            max((includeBrushOpacity ? stroke.brush.opacity : 1) * opacityFactor, 0),
            1
        )

        return BrushUniforms(
            center: SIMD2(Float(point.x), Float(point.y)),
            radius: max((stroke.brush.size * sizeFactor) / 2, 0.5),
            opacity: resolvedOpacity,
            color: SIMD4(
                stroke.color.red,
                stroke.color.green,
                stroke.color.blue,
                stroke.color.alpha
            ),
            colorJitterAmount: stroke.brush.colorJitterAmount,
            jitterDirectionDegrees: sample.jitterDirectionDegrees + 90,
            canvasSize: SIMD2(Float(texture.width), Float(texture.height)),
            mode: modeOverride ?? (stroke.tool == .eraser ? 1 : 0),
            tipShape: stroke.brush.tipShape == .softRound
                ? 1
                : (stroke.brush.tipShape == .square
                    ? 2
                    : (stroke.brush.tipShape == .customRound ? 3 : 0)),
            tipHardness: stroke.brush.tipShape.hardness,
            tipSoftness: stroke.brush.customTipSoftness,
            tipRoundness: stroke.brush.customTipRoundness,
            tipAngleDegrees: sample.angleDegrees +
                (stroke.brush.tipShape == .customRound ? stroke.brush.customTipAngleDegrees : 0),
            selectionMode: selectionMode,
            selectionMin: selectionMin,
            selectionMax: selectionMax
        )
    }

    // MARK: - Catmull-Rom 曲线插值核心
    //
    // Catmull-Rom 需要 4 个控制点 (p0, p1, p2, p3)，在 p1→p2 段上生成平滑曲线。
    // alpha=0.5 => Centripetal Catmull-Rom，天然避免自交和尖角，是笔迹场景的最佳选择。
    //
    // 采用 look-ahead 缓冲：收到的点先存入 pendingInputPoints，
    // 始终保留最后 1 个点作为 p3 look-ahead，保证每段的 p0..p3 全部是真实点。
    // 笔触结束时（endStroke）触发 flush，把缓冲里最后一段也渲染完。

    /// Centripetal Catmull-Rom 插值（alpha=0.5）
    /// 在 p1→p2 段上按参数 t∈[0,1] 求点，返回插值后的位置和压力。
    private func catmullRomPoint(
        p0: StrokePoint, p1: StrokePoint, p2: StrokePoint, p3: StrokePoint,
        t: Double
    ) -> StrokePoint {
        // Centripetal 参数化：每段的参数间距 = 欧氏距离^0.5
        func knot(_ a: StrokePoint, _ b: StrokePoint) -> Double {
            let dx = b.x - a.x, dy = b.y - a.y
            let d = pow((dx * dx + dy * dy), 0.25) // pow(dist, 0.5*alpha), alpha=0.5
            return max(d, 1e-4)
        }
        let t0 = 0.0
        let t1 = t0 + knot(p0, p1)
        let t2 = t1 + knot(p1, p2)
        let t3 = t2 + knot(p2, p3)
        let tc  = t1 + t * (t2 - t1) // 当前参数（在 t1..t2 段内线性映射）

        func blend(_ a: StrokePoint, _ b: StrokePoint, _ ta: Double, _ tb: Double, _ tv: Double) -> (x: Double, y: Double, p: Float) {
            guard abs(tb - ta) > 1e-8 else { return (a.x, a.y, a.pressure) }
            let f = (tv - ta) / (tb - ta)
            return (
                a.x + (b.x - a.x) * f,
                a.y + (b.y - a.y) * f,
                a.pressure + (b.pressure - a.pressure) * Float(f)
            )
        }

        let a1 = blend(p0, p1, t0, t1, tc)
        let a2 = blend(p1, p2, t1, t2, tc)
        let a3 = blend(p2, p3, t2, t3, tc)

        func blend2(_ a: (x: Double, y: Double, p: Float), _ b: (x: Double, y: Double, p: Float), _ ta: Double, _ tb: Double, _ tv: Double) -> (x: Double, y: Double, p: Float) {
            guard abs(tb - ta) > 1e-8 else { return a }
            let f = (tv - ta) / (tb - ta)
            return (
                a.x + (b.x - a.x) * f,
                a.y + (b.y - a.y) * f,
                a.p + (b.p - a.p) * Float(f)
            )
        }

        let b1 = blend2(a1, a2, t0, t2, tc)
        let b2 = blend2(a2, a3, t1, t3, tc)
        let c  = blend2(b1, b2, t1, t2, tc)

        return StrokePoint(x: c.x, y: c.y, pressure: c.p)
    }

    /// 把一段 Catmull-Rom 曲线（p1→p2）按 spacing 步长采样为 stamps，
    /// 并把采到的点/角度/剩余距离写回 inout 参数。
    private func sampleCatmullSegment(
        p0: StrokePoint, p1: StrokePoint, p2: StrokePoint, p3: StrokePoint,
        spacing: Double,
        distanceSinceLastSample: inout Double,
        lastSamplePoint: inout StrokePoint,
        sampleIndex: inout Int,
        baseAngle: Float,
        stroke: StrokeDescriptor,
        result: inout [StampSample]
    ) {
        // 用细分的方式估算曲线弧长，并在弧长上均匀放置 stamp
        // 步骤：把曲线分成 subdivisions 段，每段视为直线，
        // 然后在线性步长上走 spacing 距离放一个 stamp。
        let subdivisions = 16  // 每两个控制点间的细分数，越大越精确，16 已经足够
        var prevPoint = p1
        for step in 1...subdivisions {
            let t = Double(step) / Double(subdivisions)
            let curPoint = catmullRomPoint(p0: p0, p1: p1, p2: p2, p3: p3, t: t)
            let dx = curPoint.x - prevPoint.x
            let dy = curPoint.y - prevPoint.y
            let segLen = sqrt(dx * dx + dy * dy)
            guard segLen > 1e-6 else { prevPoint = curPoint; continue }

            let dirDeg = Float(atan2(dy, dx) * 180.0 / .pi)
            let segAngleDeg = baseAngle + (stroke.brush.followsStrokeDirection ? dirDeg : 0)

            var traveled = 0.0
            while distanceSinceLastSample + (segLen - traveled) >= spacing {
                let remaining = spacing - distanceSinceLastSample
                traveled += remaining
                let f = traveled / segLen
                let stamped = StrokePoint(
                    x: prevPoint.x + dx * f,
                    y: prevPoint.y + dy * f,
                    pressure: prevPoint.pressure + (curPoint.pressure - prevPoint.pressure) * Float(f)
                )
                result.append(
                    makeStampSample(
                        point: stamped,
                        index: sampleIndex,
                        segmentAngleDegrees: segAngleDeg,
                        jitterDirectionDegrees: dirDeg,
                        stroke: stroke
                    )
                )
                sampleIndex += 1
                lastSamplePoint = stamped
                distanceSinceLastSample = 0
            }
            distanceSinceLastSample += max(segLen - traveled, 0)
            prevPoint = curPoint
        }
    }

    private func interpolatedPoints(
        for stroke: StrokeDescriptor,
        samplingState: inout BrushStrokeSamplingState?
    ) -> [StampSample] {
        // flush 時は points が空で来る（endStroke からの呼び出し）ので通過させる
        let isFlushing = samplingState?.isFlushing ?? false
        guard !stroke.points.isEmpty || isFlushing else { return [] }

        let baseAngle = stroke.brush.stampRotationDegrees
        let spacing = max(
            Double(stroke.brush.size) * Double(stroke.brush.spacingPercent) / 100.0,
            0.5
        )

        // 初始化或重置 state
        var state = samplingState ?? BrushStrokeSamplingState()
        if !stroke.skipLeadingStamp {
            // 全新笔触：完全重置
            state = BrushStrokeSamplingState()
        }

        // 把本次收到的所有点追加进 look-ahead 缓冲。
        // mouseDragged が lastSample を先頭に付けて送ってくるので、
        // pendingInputPoints の末尾点と stroke.points[0] が同一点になる場合がある。
        // その重複を除去してから追加する。
        let incomingPoints = stroke.points
        let dedupedIncoming: [StrokePoint]
        if let tail = state.pendingInputPoints.last,
           let head = incomingPoints.first,
           abs(tail.x - head.x) < 0.001, abs(tail.y - head.y) < 0.001 {
            dedupedIncoming = Array(incomingPoints.dropFirst())
        } else {
            dedupedIncoming = incomingPoints
        }
        state.pendingInputPoints.append(contentsOf: dedupedIncoming)

        var result: [StampSample] = []

        // 决定本次能渲染到哪里：
        // 正常模式：留最后 1 个点作为 look-ahead（p3），只渲到倒数第 2 个
        // flush 模式（endStroke）：全部渲染完
        let renderableCount: Int
        if state.isFlushing {
            renderableCount = state.pendingInputPoints.count
        } else if state.pendingInputPoints.count == 2 {
            // 起笔阶段只有两个点时也要立即渲染首段，
            // 否则普通绘制链在未显式 flush 的情况下会吞掉整段笔迹。
            renderableCount = 2
        } else {
            renderableCount = max(state.pendingInputPoints.count - 1, 0)
        }

        guard renderableCount >= 2 else {
            // 点还不够，等下一帧
            // 单点单击（全程只有 1 个点）特殊处理
            if state.isFlushing, let only = state.pendingInputPoints.first {
                result.append(StampSample(
                    point: only,
                    angleDegrees: baseAngle,
                    jitterDirectionDegrees: 0,
                    sizeMultiplier: 1
                ))
                state.pendingInputPoints = []
            }
            samplingState = state
            return stabilizedPressureSamples(result, stroke: stroke)
        }

        // 放起始 stamp（仅全新笔触且还没放过）
        let pts = state.pendingInputPoints
        if !stroke.skipLeadingStamp {
            let firstDir = strokeDirectionDegrees(from: pts[0], to: pts[1])
            result.append(makeStampSample(
                point: pts[0],
                index: state.nextSampleIndex,
                segmentAngleDegrees: baseAngle + (stroke.brush.followsStrokeDirection ? firstDir : 0),
                jitterDirectionDegrees: firstDir,
                stroke: stroke
            ))
            state.nextSampleIndex += 1
            state.distanceSinceLastSample = 0
            state.lastSamplePoint = pts[0]
        }

        // 遍历每一段 p1→p2，用真实的 p0 和 p3 做 Catmull-Rom
        // 渲染范围：index 1 ..< renderableCount（即 pts[0..renderableCount-1] 中的每一段）
        for idx in 1..<renderableCount {
            let p1 = pts[idx - 1]
            let p2 = pts[idx]

            // p0：前驱，idx>=2 时有真实点；idx==1 时用 p2 反向外推
            // 注意：因为 look-ahead 保证了 p3 始终是真实点，
            // 所以只有第一段（idx==1）可能缺 p0——用 p2 方向反推误差很小
            let p0: StrokePoint = idx >= 2 ? pts[idx - 2] : StrokePoint(
                x: p1.x - (p2.x - p1.x),
                y: p1.y - (p2.y - p1.y),
                pressure: p1.pressure
            )

            // p3：后继，look-ahead 保证 idx < renderableCount 时 pts[idx+1] 存在
            // flush 模式下最后一段用外推
            let p3: StrokePoint = idx + 1 < pts.count ? pts[idx + 1] : StrokePoint(
                x: p2.x + (p2.x - p1.x),
                y: p2.y + (p2.y - p1.y),
                pressure: p2.pressure
            )

            var localLastSamplePoint: StrokePoint = state.lastSamplePoint ?? p1
            sampleCatmullSegment(
                p0: p0, p1: p1, p2: p2, p3: p3,
                spacing: spacing,
                distanceSinceLastSample: &state.distanceSinceLastSample,
                lastSamplePoint: &localLastSamplePoint,
                sampleIndex: &state.nextSampleIndex,
                baseAngle: baseAngle,
                stroke: stroke,
                result: &result
            )
            state.lastSamplePoint = localLastSamplePoint
        }

        // 清理已渲染的点，只保留 look-ahead 尾部（1 个点，或 flush 后清空）
        if state.isFlushing {
            state.pendingInputPoints = []
            state.isFlushing = false
        } else {
        // 保留最后 2 个点：
        // suffix[-1] = look-ahead p3（下一帧第一段的后继）
        // suffix[-2] = 下一帧第一段的 p0（真实前驱，不需要幽灵外推）
        state.pendingInputPoints = Array(state.pendingInputPoints.suffix(2))
        }

        samplingState = state
        return stabilizedPressureSamples(result, stroke: stroke)
    }

    private func stabilizedPressureSamples(
        _ samples: [StampSample],
        stroke: StrokeDescriptor
    ) -> [StampSample] {
        guard
            samples.count >= 3,
            stroke.tool == .brush || stroke.tool == .eraser
        else {
            return samples
        }

        let opacityWeight = min(max(stroke.brush.pressureOpacityAmount, 0), 1)
        let sizeWeight = min(max(stroke.brush.pressureSizeAmount, 0), 1)
        let smoothingStrength = max(opacityWeight * 0.7, sizeWeight * 0.45)
        guard smoothingStrength > 0.0001 else {
            return samples
        }

        let sideWeight = min(max(0.10 + (0.16 * smoothingStrength), 0), 0.24)
        var stabilized = samples

        for index in samples.indices {
            let start = max(index - 1, samples.startIndex)
            let end = min(index + 1, samples.index(before: samples.endIndex))
            var weightedPressure = 0.0 as Float
            var totalWeight = 0.0 as Float

            for neighbor in start...end {
                let weight: Float = neighbor == index ? (1 - (2 * sideWeight)) : sideWeight
                weightedPressure += samples[neighbor].point.pressure * weight
                totalWeight += weight
            }

            guard totalWeight > 0.0001 else { continue }
            stabilized[index].point.pressure = min(max(weightedPressure / totalWeight, 0.01), 1)
        }

        return stabilized
    }

    private func makeStampSample(
        point: StrokePoint,
        index: Int,
        segmentAngleDegrees: Float,
        jitterDirectionDegrees: Float,
        stroke: StrokeDescriptor
    ) -> StampSample {
        let scatterAmount = max(stroke.brush.scatterAmount, 0)
        let jitterAmount = min(max(stroke.brush.jitterAmount, 0), 1)
        let scatterRadius = Double(stroke.brush.size) * Double(scatterAmount) * 0.5
        let radial = scatterAmount > 0.0001
            ? pow(stableScatterRandom(x: point.x, y: point.y, index: index, salt: 0x9E37_79B9), 0.55)
            : 0
        let spreadAngle = scatterAmount > 0.0001
            ? stableScatterRandom(x: point.x, y: point.y, index: index, salt: 0x85EB_CA6B) * (.pi * 2.0)
            : 0
        let offsetX = cos(spreadAngle) * scatterRadius * radial
        let offsetY = sin(spreadAngle) * scatterRadius * radial
        let sizeRandom = Float(stableScatterRandom(x: point.x, y: point.y, index: index, salt: 0xC2B2_AE35))
        let rotationRandom = Float(stableScatterRandom(x: point.x, y: point.y, index: index, salt: 0x27D4_EB2F))
        let sizeMultiplier = max(1 - (jitterAmount * 1.5 * sizeRandom), 0.05)
        let angleJitter = (rotationRandom * 2 - 1) * 180 * jitterAmount
        let offsetPoint = StrokePoint(
            x: point.x + offsetX,
            y: point.y + offsetY,
            pressure: point.pressure
        )
        return StampSample(
            point: offsetPoint,
            angleDegrees: segmentAngleDegrees + angleJitter,
            jitterDirectionDegrees: jitterDirectionDegrees,
            sizeMultiplier: sizeMultiplier
        )
    }

    private func strokeDirectionDegrees(from start: StrokePoint, to end: StrokePoint) -> Float {
        Float(atan2(end.y - start.y, end.x - start.x) * 180.0 / .pi)
    }

    private func stableScatterRandom(x: Double, y: Double, index: Int, salt: UInt64) -> Double {
        var value = UInt64(bitPattern: Int64(index &* 1_103_515_245 &+ 12_345)) ^ salt
        value ^= UInt64(abs(Int64(x * 10_000)).magnitude &* 0x9E37_79B1)
        value ^= UInt64(abs(Int64(y * 10_000)).magnitude &* 0x85EB_CA77)
        value ^= value >> 16
        value &*= 0x45d9f3b
        value ^= value >> 16
        return Double(value & 0xffff) / Double(0xffff)
    }

    private func opacityCurvePressure(for pressure: Float, stroke: StrokeDescriptor) -> Float {
        if (stroke.tool == .brush || stroke.tool == .eraser), stroke.brush.buildMode == .opacityCap {
            let low = min(max(stroke.brush.opacityCurveLow, 0), 0.85)
            let mid = min(max(stroke.brush.opacityCurveMid, low), 0.95)
            let high = min(max(stroke.brush.opacityCurveHigh, mid), 1)
            return samplePiecewiseCurve(
                pressure: pressure,
                points: [
                    (0.0, 0.0),
                    (0.2, low),
                    (0.5, mid),
                    (0.8, high),
                    (1.0, 1.0)
                ]
            )
        }

        return pow(pressure, 3.6)
    }

    private func pressureResponsePressure(for pressure: Float, stroke: StrokeDescriptor) -> Float {
        let clamped = min(max(pressure, 0), 1)
        let sensitivity = min(max(stroke.brush.pressureSensitivity, 0), 2)
        guard sensitivity > 0.0001 else {
            return 1
        }
        return pow(clamped, sensitivity)
    }

    private func sizeCurvePressure(for pressure: Float, stroke: StrokeDescriptor) -> Float {
        let low = min(max(stroke.brush.sizeCurveLow, 0), 0.85)
        let mid = min(max(stroke.brush.sizeCurveMid, low), 0.95)
        let high = min(max(stroke.brush.sizeCurveHigh, mid), 1)
        return samplePiecewiseCurve(
            pressure: pressure,
            points: [
                (0.0, 0.0),
                (0.2, low),
                (0.5, mid),
                (0.8, high),
                (1.0, 1.0)
            ]
        )
    }

    private func opacityCapRadius(for point: StrokePoint, stroke: StrokeDescriptor) -> Double {
        let effectivePressure = min(max(point.pressure, 0), 1)
        let sizePressure = max(effectivePressure, 0.01)
        let sizeResponse = min(max(stroke.brush.pressureSizeAmount, 0), 1)
        let curvedSizePressure = sizeCurvePressure(for: sizePressure, stroke: stroke)
        let lowerBound = min(max(stroke.brush.sizeLowerBound, 0), 1)
        let lowerBoundedPressure = lowerBound + ((1 - lowerBound) * curvedSizePressure)
        let sizeFactor = (1 - sizeResponse) + (sizeResponse * lowerBoundedPressure)
        return max(Double((stroke.brush.size * sizeFactor) / 2), 0.5)
    }

    private func samplePiecewiseCurve(
        pressure: Float,
        points: [(x: Float, y: Float)]
    ) -> Float {
        let clamped = min(max(pressure, 0), 1)

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            if clamped <= current.x {
                let segmentLength = max(current.x - previous.x, 0.0001)
                let t = min(max((clamped - previous.x) / segmentLength, 0), 1)
                let smoothT = t * t * (3 - (2 * t))
                return previous.y + ((current.y - previous.y) * smoothT)
            }
        }

        return points.last?.y ?? clamped
    }

    private func makeSelectionMaskTexture(
        for selectionShape: SelectionShape?,
        canvasSize: CanvasSize
    ) -> MTLTexture? {
        guard let selectionShape, selectionShape.kind == .lasso || selectionShape.kind == .mask else {
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

        let pixels: [UInt8]
        if let maskData = selectionShape.maskData,
           maskData.canvasWidth == canvasSize.width,
           maskData.canvasHeight == canvasSize.height {
            pixels = [UInt8](maskData.alphaBytes)
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
            pixels = generated
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, canvasSize.width, canvasSize.height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: canvasSize.width
        )

        cachedSelectionMaskShape = selectionShape
        cachedSelectionMaskCanvasSize = canvasSize
        cachedSelectionMaskTexture = texture
        return texture
    }

    private func makeSmudgeSourceTexture(
        from texture: MTLTexture,
        commandQueue: MTLCommandQueue
    ) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: texture.width,
            height: texture.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .shaderWrite]

        guard
            let copyTexture = device.makeTexture(descriptor: descriptor),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return nil
        }

        blitEncoder.copy(
            from: texture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: copyTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        
        // ⚡️ 优化：使用 blitCommandEncoder 时这里需要同步，但可以改用共享模式
        // 更好的方案是使用 .private 存储模式 + 异步调用链
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()  // 只等待调度，不等待完成
        return copyTexture
    }

    private func customTipTexture(for data: Data?) -> MTLTexture? {
        guard let data = resampledCustomTipData(data) else {
            cachedCustomTipData = nil
            cachedCustomTipTexture = nil
            return nil
        }

        if cachedCustomTipData == data, let cachedCustomTipTexture {
            return cachedCustomTipTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: customTipMaskResolution,
            height: customTipMaskResolution,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, customTipMaskResolution, customTipMaskResolution),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: customTipMaskResolution
            )
        }

        cachedCustomTipData = data
        cachedCustomTipTexture = texture
        return texture
    }

    private func resampledCustomTipData(_ data: Data?) -> Data? {
        guard let data else { return nil }
        let side = Int(Double(data.count).squareRoot())
        guard side > 0, side * side == data.count else { return nil }

        if side == customTipMaskResolution {
            return data
        }

        let source = [UInt8](data)
        var destination = [UInt8](repeating: 0, count: customTipMaskResolution * customTipMaskResolution)

        for y in 0..<customTipMaskResolution {
            let sourceY = min(Int((Double(y) / Double(customTipMaskResolution)) * Double(side)), side - 1)
            for x in 0..<customTipMaskResolution {
                let sourceX = min(Int((Double(x) / Double(customTipMaskResolution)) * Double(side)), side - 1)
                destination[(y * customTipMaskResolution) + x] = source[(sourceY * side) + sourceX]
            }
        }

        return Data(destination)
    }

    private func clearTexture(
        _ texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        waitForCompletion: Bool = false
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            return
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.endEncoding()
        commandBuffer.commit()
        
        // ⚡️ 优化：可选择是否同步等待
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
        }
    }

    private func copyTexture(
        from sourceTexture: MTLTexture,
        to destinationTexture: MTLTexture,
        commandQueue: MTLCommandQueue,
        waitForCompletion: Bool = false
    ) {
        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else {
            return
        }

        blitEncoder.copy(
            from: sourceTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: sourceTexture.width, height: sourceTexture.height, depth: 1),
            to: destinationTexture,
            destinationSlice: 0,
            destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        blitEncoder.endEncoding()
        commandBuffer.commit()
        
        // ⚡️ 优化：可选择是否同步等待
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
        }
    }
}
