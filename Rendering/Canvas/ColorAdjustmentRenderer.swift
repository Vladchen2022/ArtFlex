import Foundation
@preconcurrency import Metal
import simd

private struct ColorAdjustmentVertex {
    var position: SIMD2<Float>
}

private struct ColorAdjustmentPreviewUniforms {
    var canvasSize: SIMD2<UInt32>
    var overlayOnly: UInt32
    var maskReadMode: UInt32
    var vitalizationReferenceColor: SIMD4<Float>
    var selectedHueDegrees: Float
    var hueStrength: Float
    var brightness: Float
    var contrast: Float
    var purity: Float
    var vitalizationStrength: Float
    var vitalizationBandScale: Float
    var vitalizationColorTolerance: Float
    var vitalizationDistortion: Float
    var effectMode: UInt32
    var vitalizationSeed: UInt32
    var materialOptions: SIMD4<Float>
    var materialSeed: SIMD4<Float>
}

private extension TextureFillArrangement {
    var colorVitalizationShaderValue: Float {
        switch self {
        case .directional:
            return 0
        case .interwoven:
            return 1
        case .radial:
            return 2
        case .scattered:
            return 3
        }
    }
}

enum ColorAdjustmentRendererInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(Error)
    case fallbackMaskTextureCreation

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile ColorAdjustmentRenderer shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing ColorAdjustmentRenderer shader function: \(name)"
        case .pipelineState(let error):
            return "Failed to create ColorAdjustmentRenderer pipeline: \(error.localizedDescription)"
        case .fallbackMaskTextureCreation:
            return "Failed to create ColorAdjustmentRenderer fallback mask texture."
        }
    }
}

final class ColorAdjustmentRenderer {
    private let device: MTLDevice
    private let previewPipelineState: MTLRenderPipelineState
    private let fallbackMaskTexture: MTLTexture
    private var reusableMaterialTexture: MTLTexture?
    private var reusableMaterialTextureSize = 0
    private var reusableMaterialMaskData: Data?

    init(device: MTLDevice) throws {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct ColorAdjustmentVertex {
            float2 position;
        };

        struct VertexOut {
            float4 position [[position]];
        };

        struct ColorAdjustmentPreviewUniforms {
            uint2 canvasSize;
            uint overlayOnly;
            uint maskReadMode;
            float4 vitalizationReferenceColor;
            float selectedHueDegrees;
            float hueStrength;
            float brightness;
            float contrast;
            float purity;
            float vitalizationStrength;
            float vitalizationBandScale;
            float vitalizationColorTolerance;
            float vitalizationDistortion;
            uint effectMode;
            uint vitalizationSeed;
            float4 materialOptions;
            float4 materialSeed;
        };

        constant float3 kRedAxis = float3(1.0, -0.5, -0.5);
        constant float3 kGreenBlueAxis = float3(0.0, 0.8660254, -0.8660254);
        constant float kChromaBasisLengthSquared = 1.5;

        float brightnessGammaPositive(float amountAbs) {
            float s = clamp(amountAbs, 0.0, 1.0);
            constexpr float maxGamma = 2.45;
            constexpr float responsePower = 1.18;
            return mix(1.0, maxGamma, pow(s, responsePower));
        }

        float brightnessGammaNegative(float amountAbs) {
            float s = clamp(amountAbs, 0.0, 1.0);
            constexpr float maxGamma = 1.85;
            constexpr float responsePower = 1.08;
            return mix(1.0, maxGamma, pow(s, responsePower));
        }

        float applyBrightnessChannel(float x, float amount) {
            x = clamp(x, 0.0, 1.0);
            if (abs(amount) <= 1.0e-5) {
                return x;
            }

            float s = clamp(abs(amount), 0.0, 1.0);
            if (amount > 0.0) {
                return clamp(
                    1.0 - pow(max(1.0 - x, 0.0), brightnessGammaPositive(s)),
                    0.0,
                    1.0
                );
            }

            return clamp(pow(max(x, 0.0), brightnessGammaNegative(s)), 0.0, 1.0);
        }

        float contrastCurve(float x, float gamma) {
            x = clamp(x, 0.0, 1.0);
            if (x < 0.5) {
                return 0.5 * pow(2.0 * x, gamma);
            }
            return 1.0 - 0.5 * pow(2.0 * (1.0 - x), gamma);
        }

        float contrastGammaPositive(float amountAbs) {
            float s = clamp(amountAbs, 0.0, 1.0);
            constexpr float maxGamma = 1.55;
            constexpr float responsePower = 1.10;
            return mix(1.0, maxGamma, pow(s, responsePower));
        }

        float contrastGammaNegative(float amountAbs) {
            float s = clamp(amountAbs, 0.0, 1.0);
            constexpr float minGamma = 0.72;
            constexpr float responsePower = 1.25;
            return mix(1.0, minGamma, pow(s, responsePower));
        }

        float applyContrastChannel(float x, float amount) {
            x = clamp(x, 0.0, 1.0);
            if (abs(amount) <= 1.0e-5) {
                return x;
            }

            float s = clamp(abs(amount), 0.0, 1.0);
            if (amount > 0.0) {
                return clamp(contrastCurve(x, contrastGammaPositive(s)), 0.0, 1.0);
            }

            return clamp(contrastCurve(x, contrastGammaNegative(s)), 0.0, 1.0);
        }

        float3 safeUnpremultiply(float4 premultiplied) {
            if (premultiplied.a <= 1e-5) {
                return float3(0.0);
            }
            return clamp(premultiplied.rgb / premultiplied.a, 0.0, 1.0);
        }

        float3 applyPurity(float3 color, float amount) {
            if (abs(amount) < 1e-5) {
                return clamp(color, 0.0, 1.0);
            }

            float luminance = dot(color, float3(0.299, 0.587, 0.114));
            float3 gray = float3(luminance);
            float3 chroma = color - gray;

            if (amount < 0.0) {
                return clamp(gray + (chroma * (1.0 - clamp(-amount, 0.0, 1.0))), 0.0, 1.0);
            }

            float boost = 1.0 + (clamp(amount, 0.0, 1.0) * 1.75);
            return clamp(gray + (chroma * boost), 0.0, 1.0);
        }

        float2 chromaCoordinates(float3 color) {
            return float2(
                dot(color, kRedAxis),
                dot(color, kGreenBlueAxis)
            );
        }

        float3 applyChromaDelta(float3 color, float2 chromaDelta) {
            return color
                + ((chromaDelta.x / kChromaBasisLengthSquared) * kRedAxis)
                + ((chromaDelta.y / kChromaBasisLengthSquared) * kGreenBlueAxis);
        }

        float3 applyHueStrength(float3 color, float selectedHueDegrees, float strength) {
            if (abs(strength) < 1e-5) {
                return clamp(color, 0.0, 1.0);
            }

            float angle = selectedHueDegrees * 0.01745329252;
            float2 direction = normalize(float2(cos(angle), sin(angle)));
            float2 chroma = chromaCoordinates(color);
            float projection = dot(chroma, direction);
            float2 chromaDelta = float2(0.0);

            if (strength > 0.0) {
                float chromaMagnitude = length(chroma);
                float headroom = clamp(1.0 - (chromaMagnitude / 1.5), 0.0, 1.0);
                float addition = clamp(strength, 0.0, 1.0) * mix(0.18, 0.62, headroom);
                chromaDelta = direction * addition;
            } else if (projection > 0.0) {
                chromaDelta = direction * (-projection * clamp(-strength, 0.0, 1.0));
            }

            return clamp(applyChromaDelta(color, chromaDelta), 0.0, 1.0);
        }

        float srgbToLinearChannel(float value) {
            value = clamp(value, 0.0, 1.0);
            return value <= 0.04045
                ? value / 12.92
                : pow((value + 0.055) / 1.055, 2.4);
        }

        float3 srgbToLinear(float3 color) {
            return float3(
                srgbToLinearChannel(color.r),
                srgbToLinearChannel(color.g),
                srgbToLinearChannel(color.b)
            );
        }

        float3 linearSRGBToOKLab(float3 color) {
            float3 lms = float3(
                dot(color, float3(0.4122214708, 0.5363325363, 0.0514459929)),
                dot(color, float3(0.2119034982, 0.6806995451, 0.1073969566)),
                dot(color, float3(0.0883024619, 0.2817188376, 0.6299787005))
            );
            float3 root = pow(max(lms, float3(0.0)), float3(1.0 / 3.0));
            return float3(
                dot(root, float3(0.2104542553, 0.7936177850, -0.0040720468)),
                dot(root, float3(1.9779984951, -2.4285922050, 0.4505937099)),
                dot(root, float3(0.0259040371, 0.7827717662, -0.8086757660))
            );
        }

        float3 oklabToLinearSRGB(float3 lab) {
            float3 root = float3(
                lab.x + (0.3963377774 * lab.y) + (0.2158037573 * lab.z),
                lab.x - (0.1055613458 * lab.y) - (0.0638541728 * lab.z),
                lab.x - (0.0894841775 * lab.y) - (1.2914855480 * lab.z)
            );
            float3 lms = root * root * root;
            return float3(
                dot(lms, float3(4.0767416621, -3.3077115913, 0.2309699292)),
                dot(lms, float3(-1.2684380046, 2.6097574011, -0.3413193965)),
                dot(lms, float3(-0.0041960863, -0.7034186147, 1.7076147010))
            );
        }

        float hash21(float2 value, float seed) {
            float3 p = fract(float3(value.xyx) * float3(0.1031, 0.1030, 0.0973));
            p += dot(p, p.yzx + 33.33 + seed);
            return fract((p.x + p.y) * p.z);
        }

        float valueNoise(float2 point, float seed) {
            float2 cell = floor(point);
            float2 fraction = fract(point);
            float2 blend = fraction * fraction * (3.0 - (2.0 * fraction));
            float a = hash21(cell, seed);
            float b = hash21(cell + float2(1.0, 0.0), seed);
            float c = hash21(cell + float2(0.0, 1.0), seed);
            float d = hash21(cell + float2(1.0, 1.0), seed);
            return mix(mix(a, b, blend.x), mix(c, d, blend.x), blend.y);
        }

        float2 rotateMaterialCoordinate(float2 point, float angle) {
            float sine = sin(angle);
            float cosine = cos(angle);
            return float2(
                (point.x * cosine) - (point.y * sine),
                (point.x * sine) + (point.y * cosine)
            );
        }

        float sampleVitalizationMaterial(
            float2 pixel,
            constant ColorAdjustmentPreviewUniforms &uniforms,
            texture2d<float> materialTexture,
            thread float &secondarySignal
        ) {
            float seed = float(uniforms.vitalizationSeed % 65521u) * 0.0137;
            float scaleControl = mix(
                0.48,
                2.25,
                pow(clamp(uniforms.vitalizationBandScale, 0.0, 1.0), 0.82)
            );
            float textureScale = clamp(uniforms.materialOptions.y, 0.25, 3.0);
            float coverage = max(uniforms.materialOptions.z, 0.1);
            float tileWorldSize = clamp(
                min(float(uniforms.canvasSize.x), float(uniforms.canvasSize.y)) * 0.22,
                56.0,
                230.0
            ) * textureScale * scaleControl;
            float variation = max(uniforms.materialOptions.w, 0.0);
            float distortion = clamp(uniforms.vitalizationDistortion, 0.0, 1.0);
            float arrangement = uniforms.materialSeed.w;
            float2 center = float2(uniforms.canvasSize) * 0.5;
            float2 centered = pixel - center;
            float angle = uniforms.materialSeed.z;
            float2 oriented = rotateMaterialCoordinate(centered, angle);
            float2 materialCoordinate = oriented / max(tileWorldSize, 1.0);

            if (arrangement >= 1.5 && arrangement < 2.5) {
                float radius = length(centered);
                float radialAngle = atan2(centered.y, centered.x);
                float arcScale = max(radius / max(tileWorldSize, 1.0), 0.35);
                materialCoordinate = float2(
                    (radialAngle / 6.283185307179586) * arcScale,
                    radius / max(tileWorldSize, 1.0)
                );
            } else if (arrangement >= 2.5) {
                float cellWorldSize = max(tileWorldSize * 0.72, 24.0);
                float2 seededCellPosition =
                    (oriented / cellWorldSize) + (uniforms.materialSeed.xy * 19.0);
                float2 cell = floor(seededCellPosition);
                float2 local = (fract(seededCellPosition) - 0.5) * cellWorldSize;
                float cellAngle = (
                    (hash21(cell + uniforms.materialSeed.xy * 97.0, seed + 53.0) * 2.0) - 1.0
                ) * 3.141592653589793;
                materialCoordinate =
                    rotateMaterialCoordinate(local, cellAngle) / max(tileWorldSize, 1.0);
                materialCoordinate += float2(
                    hash21(cell + 17.0, seed + 59.0),
                    hash21(cell + 31.0, seed + 61.0)
                ) * 5.0;
            }

            float warpScale = 0.0035 / sqrt(max(textureScale * scaleControl, 0.1));
            float2 coarsePosition = pixel * warpScale;
            float2 coarseWarp = float2(
                valueNoise(coarsePosition + float2(17.0, seed + 3.0), seed + 71.0),
                valueNoise(coarsePosition + float2(seed + 5.0, 29.0), seed + 73.0)
            ) - 0.5;
            float2 curlWarp = float2(
                valueNoise(
                    (coarsePosition * 2.7) + float2(43.0, seed + 11.0),
                    seed + 79.0
                ),
                valueNoise(
                    (coarsePosition * 2.7) + float2(seed + 13.0, 47.0),
                    seed + 83.0
                )
            ) - 0.5;
            materialCoordinate += coarseWarp * distortion * (0.82 + (variation * 0.34));
            materialCoordinate += curlWarp * distortion * 0.31;
            materialCoordinate += uniforms.materialSeed.xy * 7.0;

            constexpr sampler materialSampler(
                coord::normalized,
                address::mirrored_repeat,
                filter::linear
            );
            float first = materialTexture.sample(materialSampler, materialCoordinate).r;
            if (arrangement >= 0.5 && arrangement < 1.5) {
                float2 crossCoordinate =
                    rotateMaterialCoordinate(oriented, 1.570796326794897)
                    / max(tileWorldSize, 1.0);
                crossCoordinate += coarseWarp.yx * distortion * 0.68;
                crossCoordinate += uniforms.materialSeed.yx * 5.0;
                float cross = materialTexture.sample(materialSampler, crossCoordinate).r;
                first = mix(first, cross, 0.46);
            }

            float2 rotatedCoordinate =
                rotateMaterialCoordinate(materialCoordinate, 0.73)
                * (1.31 + (variation * 0.08));
            rotatedCoordinate += uniforms.materialSeed.yx * 3.0;
            float second = materialTexture.sample(materialSampler, rotatedCoordinate).r;

            float2 localOffset = float2(0.035, 0.027) / max(textureScale, 0.25);
            float localMean = (
                materialTexture.sample(materialSampler, materialCoordinate + localOffset).r
                + materialTexture.sample(materialSampler, materialCoordinate - localOffset).r
                + materialTexture.sample(
                    materialSampler,
                    materialCoordinate + float2(-localOffset.x, localOffset.y)
                ).r
                + materialTexture.sample(
                    materialSampler,
                    materialCoordinate + float2(localOffset.x, -localOffset.y)
                ).r
            ) * 0.25;
            float broadNoise = valueNoise(
                (pixel * 0.0075) + (uniforms.materialSeed.xy * 41.0),
                seed + 89.0
            );
            float fineNoise = valueNoise(
                (pixel * 0.021) + (uniforms.materialSeed.yx * 67.0),
                seed + 97.0
            );
            float textureDetail = clamp((first - localMean) * 2.6, -1.0, 1.0);
            float textureBody = ((first * 0.64) + (second * 0.36) - 0.5) * 2.0;
            secondarySignal = clamp(
                ((second - first) * 1.45)
                    + ((fineNoise - 0.5) * 0.42)
                    + ((coarseWarp.x - coarseWarp.y) * 0.34),
                -1.0,
                1.0
            );
            float coverageResponse = mix(0.72, 1.18, min(coverage, 1.0));
            return clamp(
                (
                    (textureDetail * 0.58)
                    + (textureBody * 0.30)
                    + ((broadNoise - 0.5) * 0.34)
                ) * coverageResponse,
                -1.0,
                1.0
            );
        }

        float3 applyColorVitalization(
            float3 color,
            float2 pixel,
            constant ColorAdjustmentPreviewUniforms &uniforms,
            texture2d<float> materialTexture,
            thread float &similarity
        ) {
            float3 baseLab = linearSRGBToOKLab(color);
            float3 referenceLinear = srgbToLinear(uniforms.vitalizationReferenceColor.rgb);
            float3 referenceLab = linearSRGBToOKLab(referenceLinear);
            float tolerance = mix(
                0.040,
                0.24,
                clamp(uniforms.vitalizationColorTolerance, 0.0, 1.0)
            );
            float distance = length(baseLab - referenceLab);
            similarity = 1.0 - smoothstep(tolerance * 0.58, tolerance, distance);

            float secondarySignal = 0.0;
            float textureSignal = sampleVitalizationMaterial(
                pixel,
                uniforms,
                materialTexture,
                secondarySignal
            );
            float seed = float(uniforms.vitalizationSeed % 65521u) * 0.0137;
            float grain = valueNoise(
                (pixel * 0.043) + float2(seed * 0.21, seed * 0.61),
                seed + 101.0
            ) - 0.5;
            float tone = clamp(
                textureSignal + (secondarySignal * 0.25) + (grain * 0.14),
                -1.0,
                1.0
            );
            float hueVariation = clamp(
                secondarySignal - (textureSignal * 0.24) + (grain * 0.22),
                -1.0,
                1.0
            );
            float chromaVariation = clamp(
                (textureSignal * 0.52) + (secondarySignal * 0.36),
                -1.0,
                1.0
            );

            float2 chroma = baseLab.yz;
            float chromaLength = length(chroma);
            float2 radial = chromaLength > 1.0e-5
                ? chroma / chromaLength
                : normalize(float2(cos(seed), sin(seed)));
            float2 tangent = float2(-radial.y, radial.x);

            float3 variedLab = baseLab;
            variedLab.x = clamp(variedLab.x + (tone * 0.105), 0.0, 1.0);
            variedLab.yz += tangent * (hueVariation * 0.058);
            variedLab.yz += radial * (chromaVariation * 0.035);
            return clamp(oklabToLinearSRGB(variedLab), 0.0, 1.0);
        }

        float3 applyColorAdjustments(
            float3 color,
            constant ColorAdjustmentPreviewUniforms &uniforms
        ) {
            float3 adjusted = clamp(color, 0.0, 1.0);
            adjusted.r = applyBrightnessChannel(adjusted.r, uniforms.brightness);
            adjusted.g = applyBrightnessChannel(adjusted.g, uniforms.brightness);
            adjusted.b = applyBrightnessChannel(adjusted.b, uniforms.brightness);

            adjusted.r = applyContrastChannel(adjusted.r, uniforms.contrast);
            adjusted.g = applyContrastChannel(adjusted.g, uniforms.contrast);
            adjusted.b = applyContrastChannel(adjusted.b, uniforms.contrast);

            adjusted = applyPurity(adjusted, uniforms.purity);
            adjusted = applyHueStrength(
                adjusted,
                uniforms.selectedHueDegrees,
                uniforms.hueStrength
            );
            return clamp(adjusted, 0.0, 1.0);
        }

        vertex VertexOut colorAdjustmentVertex(
            const device ColorAdjustmentVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            return out;
        }

        fragment float4 colorAdjustmentPreviewFragment(
            VertexOut in [[stage_in]],
            texture2d<float, access::read> sourceTexture [[texture(0)]],
            texture2d<float, access::read> maskTexture [[texture(1)]],
            texture2d<float> materialTexture [[texture(2)]],
            constant ColorAdjustmentPreviewUniforms &uniforms [[buffer(0)]]
        ) {
            uint2 gid = uint2(in.position.xy);
            if (gid.x >= uniforms.canvasSize.x || gid.y >= uniforms.canvasSize.y) {
                return float4(0.0);
            }

            float4 base = sourceTexture.read(gid);
            float influence = uniforms.maskReadMode == 0
                ? maskTexture.read(gid).r
                : base.a;
            influence = clamp(influence, 0.0, 1.0);

            if (influence <= 0.0001) {
                return base;
            }

            if (uniforms.overlayOnly != 0) {
                float overlayAlpha = influence * 0.38;
                float3 overlayColor = float3(0.19, 0.47, 1.0);
                float3 overlayPremultiplied = overlayColor * overlayAlpha;

                float3 rgb = overlayPremultiplied + (base.rgb * (1.0 - overlayAlpha));
                float alpha = overlayAlpha + (base.a * (1.0 - overlayAlpha));
                return float4(rgb, alpha);
            }

            if (base.a <= 0.0001) {
                return base;
            }

            float3 baseColor = safeUnpremultiply(base);
            float3 adjustedColor;
            float effectInfluence = influence;
            if (uniforms.effectMode == 1) {
                float similarity = 0.0;
                adjustedColor = applyColorVitalization(
                    baseColor,
                    float2(gid),
                    uniforms,
                    materialTexture,
                    similarity
                );
                effectInfluence *= similarity * clamp(uniforms.vitalizationStrength, 0.0, 1.0);
            } else {
                adjustedColor = applyColorAdjustments(baseColor, uniforms);
            }
            float4 adjustedPremultiplied = float4(adjustedColor * base.a, base.a);
            return mix(base, adjustedPremultiplied, effectInfluence);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw ColorAdjustmentRendererInitializationError.shaderLibrary(error)
        }

        guard
            let vertexFunction = library.makeFunction(name: "colorAdjustmentVertex"),
            let fragmentFunction = library.makeFunction(name: "colorAdjustmentPreviewFragment")
        else {
            throw ColorAdjustmentRendererInitializationError.missingFunction(
                "colorAdjustmentVertex/colorAdjustmentPreviewFragment"
            )
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            previewPipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw ColorAdjustmentRendererInitializationError.pipelineState(error)
        }

        let maskDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        maskDescriptor.usage = .shaderRead
        maskDescriptor.storageMode = .shared
        guard let fallbackMaskTexture = device.makeTexture(descriptor: maskDescriptor) else {
            throw ColorAdjustmentRendererInitializationError.fallbackMaskTextureCreation
        }
        let zeroPixel: [UInt8] = [0, 0, 0, 0]
        fallbackMaskTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: zeroPixel,
            bytesPerRow: 4
        )
        self.fallbackMaskTexture = fallbackMaskTexture
    }

    func renderPreview(
        sourceTexture: MTLTexture,
        previewTexture: MTLTexture,
        maskTexture: MTLTexture?,
        maskReadMode: ColorAdjustmentMaskReadMode,
        parameters: ColorAdjustmentParameters,
        effectMode: ColorAdjustmentEffectMode = .standard,
        vitalizationReferenceColor: RGBAColor? = nil,
        vitalizationSeed: UInt32 = 0,
        vitalizationMaterial: ColorVitalizationMaterial? = nil,
        overlayOnly: Bool,
        effectRegion: MTLRegion?,
        commandQueue: MTLCommandQueue,
        completion: (@Sendable () -> Void)? = nil
    ) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion?()
            return
        }
        encodePreview(
            sourceTexture: sourceTexture,
            previewTexture: previewTexture,
            maskTexture: maskTexture,
            maskReadMode: maskReadMode,
            parameters: parameters,
            effectMode: effectMode,
            vitalizationReferenceColor: vitalizationReferenceColor,
            vitalizationSeed: vitalizationSeed,
            vitalizationMaterial: vitalizationMaterial,
            overlayOnly: overlayOnly,
            effectRegion: effectRegion,
            commandBuffer: commandBuffer
        )
        if let completion {
            commandBuffer.addCompletedHandler { _ in completion() }
        }
        commandBuffer.commit()
    }

    func encodePreview(
        sourceTexture: MTLTexture,
        previewTexture: MTLTexture,
        maskTexture: MTLTexture?,
        maskReadMode: ColorAdjustmentMaskReadMode,
        parameters: ColorAdjustmentParameters,
        effectMode: ColorAdjustmentEffectMode = .standard,
        vitalizationReferenceColor: RGBAColor? = nil,
        vitalizationSeed: UInt32 = 0,
        vitalizationMaterial: ColorVitalizationMaterial? = nil,
        overlayOnly: Bool,
        effectRegion: MTLRegion?,
        commandBuffer: MTLCommandBuffer
    ) {
        let copyRegion = MTLRegionMake2D(0, 0, sourceTexture.width, sourceTexture.height)
        if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
            blitEncoder.copy(
                from: sourceTexture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: copyRegion.origin,
                sourceSize: copyRegion.size,
                to: previewTexture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: copyRegion.origin
            )
            blitEncoder.endEncoding()
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = previewTexture
        descriptor.colorAttachments[0].loadAction = .load
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let vertices = [
            ColorAdjustmentVertex(position: SIMD2(-1, -1)),
            ColorAdjustmentVertex(position: SIMD2(1, -1)),
            ColorAdjustmentVertex(position: SIMD2(-1, 1)),
            ColorAdjustmentVertex(position: SIMD2(1, 1))
        ]
        let referenceColor = vitalizationReferenceColor
            ?? RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        let materialTexture = vitalizationMaterial.flatMap {
            makeMaterialTexture(maskData: $0.maskData)
        }
        let materialSettings = vitalizationMaterial?.settings ?? .proceduralDefault
        let seedLow = Float(vitalizationSeed & 0x0000_FFFF) / Float(0x0000_FFFF)
        let seedHigh = Float((vitalizationSeed >> 16) & 0x0000_FFFF) / Float(0x0000_FFFF)
        let materialAngle = (seedLow * 2 - 1) * Float.pi
        var uniforms = ColorAdjustmentPreviewUniforms(
            canvasSize: SIMD2(
                UInt32(sourceTexture.width),
                UInt32(sourceTexture.height)
            ),
            overlayOnly: overlayOnly || parameters.isNeutral(for: effectMode) ? 1 : 0,
            maskReadMode: maskReadMode == .maskRed ? 0 : 1,
            vitalizationReferenceColor: SIMD4(
                referenceColor.red,
                referenceColor.green,
                referenceColor.blue,
                referenceColor.alpha
            ),
            selectedHueDegrees: parameters.selectedHueDegrees,
            hueStrength: parameters.hueStrength,
            brightness: parameters.brightness,
            contrast: parameters.contrast,
            purity: parameters.purity,
            vitalizationStrength: parameters.vitalizationStrength,
            vitalizationBandScale: parameters.vitalizationBandScale,
            vitalizationColorTolerance: parameters.vitalizationColorTolerance,
            vitalizationDistortion: parameters.vitalizationDistortion,
            effectMode: effectMode == .vitalization ? 1 : 0,
            vitalizationSeed: vitalizationSeed,
            materialOptions: SIMD4(
                materialTexture == nil ? 0 : 1,
                min(max(materialSettings.materialScale, 0.25), 3),
                TextureFillMaterialResponse.amplifiedCoverage(materialSettings.coverage),
                TextureFillMaterialResponse.amplifiedVariation(materialSettings.variation)
            ),
            materialSeed: SIMD4(
                seedLow,
                seedHigh,
                materialAngle,
                materialSettings.arrangement.colorVitalizationShaderValue
            )
        )

        encoder.setRenderPipelineState(previewPipelineState)
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<ColorAdjustmentVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(maskTexture ?? fallbackMaskTexture, index: 1)
        encoder.setFragmentTexture(materialTexture ?? fallbackMaskTexture, index: 2)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<ColorAdjustmentPreviewUniforms>.stride,
            index: 0
        )
        if let effectRegion {
            encoder.setScissorRect(
                MTLScissorRect(
                    x: effectRegion.origin.x,
                    y: effectRegion.origin.y,
                    width: effectRegion.size.width,
                    height: effectRegion.size.height
                )
            )
        }
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }

    private func makeMaterialTexture(maskData: Data) -> MTLTexture? {
        guard !maskData.isEmpty else { return nil }
        let resolution = Int(sqrt(Double(maskData.count)))
        guard resolution > 0, resolution * resolution == maskData.count else { return nil }

        if reusableMaterialTextureSize != resolution || reusableMaterialTexture == nil {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: resolution,
                height: resolution,
                mipmapped: false
            )
            descriptor.usage = .shaderRead
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
            reusableMaterialTexture = texture
            reusableMaterialTextureSize = resolution
            reusableMaterialMaskData = nil
        }
        guard let reusableMaterialTexture else { return nil }

        if reusableMaterialMaskData != maskData {
            maskData.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                reusableMaterialTexture.replace(
                    region: MTLRegionMake2D(0, 0, resolution, resolution),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: resolution
                )
            }
            reusableMaterialMaskData = maskData
        }
        return reusableMaterialTexture
    }
}
