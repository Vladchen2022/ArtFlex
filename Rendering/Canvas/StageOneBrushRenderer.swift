import Foundation
import Metal
import os
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
    var paintJitterAmount: Float
    var paintContrastAmount: Float
    var stampSeed: Float
    var paintVariationSeed: UInt32
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
    var usesAlphaLock: UInt32
    var preservesAlphaLockAlpha: UInt32
    var compoundEnabled: UInt32
    var compoundMode: UInt32
    var compoundSecondaryShape: UInt32
    var compoundPrimaryMixWeight: Float
    var compoundPrimaryOpacityFactor: Float
    var compoundGlobalOpacityFactor: Float
    var buildUpOpacityCompensationAmount: Float
    var buildUpOpacitySpacingRatio: Float
    var compoundSecondaryOpacityFactor: Float
    var compoundSecondaryDiameterPx: Float
    var compoundSecondaryAdvancePx: Float
    var compoundSecondarySoftness: Float
    var compoundSecondaryRoundness: Float
    var compoundSecondaryAngleDegrees: Float
    var compoundSecondaryTileRandomRotation: Float
    var compoundArcLengthAtCenter: Float
    var compoundStrokeTangent: SIMD2<Float>
}

private struct SmudgeGatherInput {
    var center: SIMD2<Float>
}

private struct SmudgeGatherUniforms {
    var sampleCount: UInt32
    var paddingCount: SIMD3<UInt32> = .zero
    var canvasSize: SIMD2<Float>
    var paddingCanvasSize: SIMD2<Float> = .zero
}

private struct SmudgeFragmentUniforms {
    var stampIndex: UInt32
    var paddingValues: SIMD3<UInt32> = .zero
}

private struct CompositeUniforms {
    var brushColor: SIMD4<Float>
    var mode: UInt32 = 0
    var usesCompoundMask: UInt32 = 0
    var paddingValues: SIMD2<UInt32> = .zero
    var paintJitterAmount: Float = 0
    var paintContrastAmount: Float = 0
    var jitterDirectionDegrees: Float = 0
    var paintVariationSeed: UInt32 = 0
    var canvasWidth: Float = 0
    var canvasHeight: Float = 0
    var strokeCenterX: Float = 0
    var strokeCenterY: Float = 0
    var strokeRadius: Float = 0
    var usesAlphaLock: UInt32 = 0
    var paddingAlphaLock: SIMD3<UInt32> = .zero
}

struct StampSample: Equatable {
    var point: StrokePoint
    var angleDegrees: Float
    var jitterDirectionDegrees: Float
    var sizeMultiplier: Float
    var arcLengthPx: Float
    var strokeTangent: SIMD2<Float>
}

struct BrushStrokeSamplingState {
    var distanceSinceLastSample: Double = 0
    var lastSamplePoint: StrokePoint?
    var nextSampleIndex: Int = 0
    var pendingInputPoints: [StrokePoint] = []
    var nextSegmentIndexToCommit: Int = 0
    var hasEmittedLeadingStamp = false
    var isFlushing: Bool = false
    var renderedPixelBounds: BrushPixelBounds?
}

final class OpacityCapSessionResources {
    let originalTexture: MTLTexture
    let alphaTexture: MTLTexture
    let reusesCachedTextures: Bool
    var compoundSecondaryTexture: MTLTexture?
    var compoundSecondarySamplingState: BrushStrokeSamplingState?

    init(
        originalTexture: MTLTexture,
        alphaTexture: MTLTexture,
        reusesCachedTextures: Bool
    ) {
        self.originalTexture = originalTexture
        self.alphaTexture = alphaTexture
        self.reusesCachedTextures = reusesCachedTextures
    }
}

private final class UniformBufferRecycleLease: @unchecked Sendable {
    private weak var renderer: StageOneBrushRenderer?
    private let buffer: MTLBuffer

    init(renderer: StageOneBrushRenderer, buffer: MTLBuffer) {
        self.renderer = renderer
        self.buffer = buffer
    }

    func recycle() {
        renderer?.recycleUniformBuffer(buffer)
    }
}

private let customTipMaskResolution = 256

private enum CustomTipTextureRole {
    case primary
    case primaryEnvelope
    case compoundSecondary
}

enum StageOneBrushRendererInitializationError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(String, Error)
    case vertexBufferCreation
    case samplerCreation
    case defaultTipTextureCreation

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile StageOneBrushRenderer shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing StageOneBrushRenderer shader function: \(name)"
        case .pipelineState(let name, let error):
            return "Failed to create StageOneBrushRenderer pipeline (\(name)): \(error.localizedDescription)"
        case .vertexBufferCreation:
            return "Failed to create StageOneBrushRenderer vertex buffer."
        case .samplerCreation:
            return "Failed to create StageOneBrushRenderer sampler state."
        case .defaultTipTextureCreation:
            return "Failed to create StageOneBrushRenderer default tip texture."
        }
    }
}

final class StageOneBrushRenderer {
    private let brushStrokeLogger = Logger(subsystem: "ArtFlex", category: "BrushStroke")
    private let device: MTLDevice
    private let brushPipelineState: MTLRenderPipelineState
    private let alphaLockBrushPipelineState: MTLRenderPipelineState
    private let eraserPipelineState: MTLRenderPipelineState
    private let smudgePipelineState: MTLRenderPipelineState
    private let smudgeFrozenTexturePipelineState: MTLRenderPipelineState
    private let smudgeGatherPipelineState: MTLComputePipelineState
    private let opacityCapMaskPipelineState: MTLRenderPipelineState
    private let compoundPrimaryMaskPipelineState: MTLRenderPipelineState
    private let compoundSecondaryMaskPipelineState: MTLRenderPipelineState
    private let compoundPrimaryBuildUpMaskPipelineState: MTLRenderPipelineState
    private let compoundSecondaryBuildUpMaskPipelineState: MTLRenderPipelineState
    private let opacityCapCompositePipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let compositeSamplerState: MTLSamplerState
    private let tipSamplerState: MTLSamplerState
    private let defaultTipTexture: MTLTexture
    private let fallbackAlphaLockTexture: MTLTexture
    private var cachedSelectionMaskShape: SelectionShape?
    private var cachedSelectionMaskCanvasSize: CanvasSize?
    private var cachedSelectionMaskTexture: MTLTexture?
    private var cachedPrimaryCustomTipSourceData: Data?
    private var cachedPrimaryCustomTipTexture: MTLTexture?
    private var cachedPrimaryEnvelopeCustomTipSourceData: Data?
    private var cachedPrimaryEnvelopeCustomTipTexture: MTLTexture?
    private var cachedCompoundSecondaryCustomTipSourceData: Data?
    private var cachedCompoundSecondaryCustomTipTexture: MTLTexture?
    private var cachedOpacityCapOriginalTexture: MTLTexture?
    private var cachedOpacityCapAlphaTexture: MTLTexture?
    private var cachedCompoundSecondaryTexture: MTLTexture?
    private let reusableUniformBufferLock = NSLock()
    private var reusableUniformBuffers: [MTLBuffer] = []
    private var reusableUniformBufferBytes = 0
    private(set) var debugCustomTipResampleCount = 0

    init(device: MTLDevice) throws {
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
            float paintJitterAmount;
            float paintContrastAmount;
            float stampSeed;
            uint paintVariationSeed;
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
            uint usesAlphaLock;
            uint preservesAlphaLockAlpha;
            uint compoundEnabled;
            uint compoundMode;
            uint compoundSecondaryShape;
            float compoundPrimaryMixWeight;
            float compoundPrimaryOpacityFactor;
            float compoundGlobalOpacityFactor;
            float buildUpOpacityCompensationAmount;
            float buildUpOpacitySpacingRatio;
            float compoundSecondaryOpacityFactor;
            float compoundSecondaryDiameterPx;
            float compoundSecondaryAdvancePx;
            float compoundSecondarySoftness;
            float compoundSecondaryRoundness;
            float compoundSecondaryAngleDegrees;
            float compoundSecondaryTileRandomRotation;
            float compoundArcLengthAtCenter;
            float2 compoundStrokeTangent;
        };

        struct SmudgeGatherInput {
            float2 center;
        };

        struct SmudgeGatherUniforms {
            uint sampleCount;
            uint3 paddingCount;
            float2 canvasSize;
            float2 paddingCanvasSize;
        };

        struct SmudgeFragmentUniforms {
            uint stampIndex;
            uint3 paddingValues;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 localPoint;
            float2 pixelPoint;
            uint instanceID [[flat]];
        };

        struct CompositeVertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        struct CompositeUniforms {
            float4 brushColor;
            uint mode;
            uint usesCompoundMask;
            uint2 paddingValues;
            float paintJitterAmount;
            float paintContrastAmount;
            float jitterDirectionDegrees;
            uint paintVariationSeed;
            float canvasWidth;
            float canvasHeight;
            float strokeCenterX;
            float strokeCenterY;
            float strokeRadius;
            uint usesAlphaLock;
            uint3 paddingAlphaLock;
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

        float tipAlphaForDescriptor(
            float2 localPoint,
            uint tipShape,
            float tipHardness,
            float tipSoftness,
            float tipRoundness,
            float tipAngleDegrees,
            texture2d<float, access::sample> customTipMask,
            bool usesCustomMask
        ) {
            constexpr sampler tipSampler(
                coord::normalized,
                address::clamp_to_edge,
                filter::linear
            );

            float radiansValue = tipAngleDegrees * 0.017453292519943295;
            float cosine = cos(radiansValue);
            float sine = sin(radiansValue);
            float2 rotatedPoint = float2(
                (localPoint.x * cosine) + (localPoint.y * sine),
                (-localPoint.x * sine) + (localPoint.y * cosine)
            );

            if (tipShape == 2) {
                float squareDistance = max(abs(rotatedPoint.x), abs(rotatedPoint.y));
                return squareDistance <= 1.0 ? 1.0 : 0.0;
            }

            if (tipShape == 1) {
                float roundDistance = length(localPoint);
                if (roundDistance >= 1.0) {
                    return 0.0;
                }

                float feather = clamp(1.0 - roundDistance, 0.0, 1.0);
                return feather * feather;
            }

            if (tipShape == 3) {
                float roundness = clamp(tipRoundness, 0.25, 1.0);
                float2 shapedPoint = float2(rotatedPoint.x / roundness, rotatedPoint.y);
                if (max(abs(shapedPoint.x), abs(shapedPoint.y)) >= 1.0) {
                    return 0.0;
                }

                if (usesCustomMask) {
                    float2 uv = float2(
                        clamp((shapedPoint.x + 1.0) * 0.5, 0.0, 1.0),
                        clamp((shapedPoint.y + 1.0) * 0.5, 0.0, 1.0)
                    );
                    float sampledAlpha = customTipMask.sample(tipSampler, uv).r;
                    float exponent = mix(3.2, 0.75, clamp(tipSoftness, 0.0, 1.0));
                    return pow(clamp(sampledAlpha, 0.0, 1.0), exponent);
                }

                float customDistance = length(shapedPoint);
                float customHardness = (1.0 - clamp(tipSoftness, 0.0, 1.0)) * 0.995;
                return smoothHardnessAlpha(customDistance, customHardness);
            }

            float roundDistance = length(localPoint);
            return smoothHardnessAlpha(roundDistance, tipHardness);
        }

        float primaryTextureAlpha(
            float2 localPoint,
            BrushUniforms uniforms,
            texture2d<float, access::sample> customTipMask
        ) {
            return tipAlphaForDescriptor(
                localPoint,
                uniforms.tipShape,
                uniforms.tipHardness,
                uniforms.tipSoftness,
                uniforms.tipRoundness,
                uniforms.tipAngleDegrees,
                customTipMask,
                uniforms.tipShape == 3
            );
        }

        float primaryEnvelopeAlpha(
            float2 localPoint,
            BrushUniforms uniforms,
            texture2d<float, access::sample> primaryEnvelopeTipMask
        ) {
            return tipAlphaForDescriptor(
                localPoint,
                uniforms.tipShape,
                uniforms.tipHardness,
                uniforms.tipSoftness,
                uniforms.tipRoundness,
                uniforms.tipAngleDegrees,
                primaryEnvelopeTipMask,
                uniforms.tipShape == 3
            );
        }

        float compoundSecondaryTipAlpha(
            float2 localPoint,
            BrushUniforms uniforms,
            texture2d<float, access::sample> compoundSecondaryTipMask
        ) {
            if (uniforms.compoundEnabled == 0) {
                return 0.0;
            }

            return tipAlphaForDescriptor(
                localPoint,
                uniforms.compoundSecondaryShape,
                0.5,
                uniforms.compoundSecondarySoftness,
                uniforms.compoundSecondaryRoundness,
                uniforms.compoundSecondaryAngleDegrees,
                compoundSecondaryTipMask,
                uniforms.compoundSecondaryShape == 3
            );
        }

        float compoundFinalAlpha(
            float2 localPoint,
            float2 pixelPoint,
            BrushUniforms uniforms,
            texture2d<float, access::sample> customTipMask,
            texture2d<float, access::sample> primaryEnvelopeTipMask,
            texture2d<float, access::sample> compoundSecondaryTipMask
        ) {
            float primaryTexture = primaryTextureAlpha(localPoint, uniforms, customTipMask);
            float primaryEnvelope = primaryEnvelopeAlpha(localPoint, uniforms, primaryEnvelopeTipMask);

            if (uniforms.compoundEnabled == 0) {
                return primaryTexture * uniforms.compoundGlobalOpacityFactor;
            }

            float2 tangent = normalize(uniforms.compoundStrokeTangent);
            if (all(tangent == float2(0.0))) {
                tangent = float2(1.0, 0.0);
            }
            float2 normal = float2(-tangent.y, tangent.x);
            float2 deltaPx = pixelPoint - uniforms.center;
            float sPx = uniforms.compoundArcLengthAtCenter + dot(deltaPx, tangent);
            float tPx = dot(deltaPx, normal);

            float secondaryAdvancePx = max(uniforms.compoundSecondaryAdvancePx, 1.0);
            float secondaryDiameterPx = max(uniforms.compoundSecondaryDiameterPx, 1.0);
            float secondaryHalfDiameter = secondaryDiameterPx * 0.5;
            float repeatIndex = floor((sPx / secondaryAdvancePx) + 0.5);

            // Sample nearest secondary repeat centers with per-tile random rotation.
            float secondaryField = 0.0;
            for (int di = -1; di <= 1; di++) {
                float idx = repeatIndex + float(di);
                float neighborCenter = idx * secondaryAdvancePx;
                float2 neighborPoint = float2(
                    (sPx - neighborCenter) / secondaryHalfDiameter,
                    tPx / secondaryHalfDiameter
                );
                // Random rotation per tile, amount controlled by uniform (0=none, 1=full 360°)
                float tileAngle = fract(sin(idx * 127.1 + 311.7) * 43758.5453) * 6.2831853
                    * uniforms.compoundSecondaryTileRandomRotation;
                float ca = cos(tileAngle);
                float sa = sin(tileAngle);
                float2 rotated = float2(
                    neighborPoint.x * ca - neighborPoint.y * sa,
                    neighborPoint.x * sa + neighborPoint.y * ca
                );
                float sample = compoundSecondaryTipAlpha(rotated, uniforms, compoundSecondaryTipMask);
                secondaryField = max(secondaryField, sample);
            }
            secondaryField *= uniforms.compoundSecondaryOpacityFactor;

            float mixWeight = clamp(uniforms.compoundPrimaryMixWeight, 0.0, 1.0);

            // Secondary texture field (evaluated in stroke-space, continuous across stamps)
            float compoundAppearance;
            switch (uniforms.compoundMode) {
                case 1: // subtract
                    compoundAppearance = 1.0 - secondaryField;
                    break;
                case 2: // intersect
                    compoundAppearance = secondaryField;
                    break;
                default: // textureBlend
                    compoundAppearance = secondaryField;
                    break;
            }

            float interior;
            if (uniforms.compoundMode == 3) { // overlay
                // Photoshop-style dual brush: combine A and B with the configured
                // pressure-mix curve, then apply final opacity pressure once through
                // compoundGlobalOpacityFactor below.
                // `mixWeight` is the existing A/B pressure-mix curve. Raising the
                // A envelope floor with it closes the longitudinal channels only
                // as pressure becomes heavy, while light pressure remains B-led.
                float primaryAlpha = max(
                    clamp(primaryTexture, 0.0, 1.0),
                    primaryEnvelope * mixWeight * 0.92
                );
                float overlaid = primaryAlpha <= 0.5
                    ? 2.0 * secondaryField * primaryAlpha
                    : 1.0 - (2.0 * (1.0 - secondaryField) * (1.0 - primaryAlpha));
                interior = mix(secondaryField, clamp(overlaid, 0.0, 1.0), mixWeight);
            } else {
                // Pressure mix controls how much of the primary body survives versus
                // the secondary texture appearance.
                float primaryBody = uniforms.compoundPrimaryOpacityFactor * mixWeight;
                interior = primaryBody + (1.0 - primaryBody) * compoundAppearance;
            }

            // ALWAYS clip by primaryEnvelope — stroke boundary stays sharp at all pressures.
            // Max-blend (opacityCap) across overlapping stamps ensures interior texture is
            // one-layer only, while envelope overlap creates smooth interior fill.
            return interior * primaryEnvelope * uniforms.compoundGlobalOpacityFactor;
        }

        float buildUpVisibleAlpha(
            float targetAlpha,
            BrushUniforms uniforms
        ) {
            float clampedTarget = clamp(targetAlpha, 0.0, 1.0);
            float compensationAmount = clamp(uniforms.buildUpOpacityCompensationAmount, 0.0, 1.0);
            if (compensationAmount <= 0.0001) {
                return clampedTarget;
            }
            float advanceRatio = clamp(uniforms.buildUpOpacitySpacingRatio, 0.02, 1.0);
            if (advanceRatio >= 0.999 || clampedTarget <= 0.0) {
                return clampedTarget;
            }
            float compensated = 1.0 - pow(max(1.0 - clampedTarget, 0.0), advanceRatio);
            return mix(clampedTarget, compensated, compensationAmount);
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

        uint paintHash(uint value) {
            value ^= value >> 16;
            value *= 0x7FEB352Du;
            value ^= value >> 15;
            value *= 0x846CA68Bu;
            value ^= value >> 16;
            return value;
        }

        float paintRandom(uint seed, int index, uint salt) {
            uint laneBits = as_type<uint>(index);
            uint value = seed ^ (laneBits * 0x9E3779B9u) ^ salt;
            return float(paintHash(value) & 0x00FFFFFFu) / 16777215.0;
        }

        float paintRandom2D(uint seed, int2 index, uint salt) {
            uint xBits = as_type<uint>(index.x);
            uint yBits = as_type<uint>(index.y);
            uint value = seed ^ (xBits * 0x9E3779B9u) ^ (yBits * 0x85EBCA6Bu) ^ salt;
            return float(paintHash(value) & 0x00FFFFFFu) / 16777215.0;
        }

        float paintTriangularRandom(uint seed, int index, uint salt) {
            return paintRandom(seed, index, salt) +
                paintRandom(seed, index, salt ^ 0xA511E9B3u) - 1.0;
        }

        float paintValueNoise(float coordinate, uint seed, uint salt) {
            int cell = int(floor(coordinate));
            float fractionValue = fract(coordinate);
            float smoothValue = fractionValue * fractionValue * (3.0 - (2.0 * fractionValue));
            return mix(
                paintRandom(seed, cell, salt),
                paintRandom(seed, cell + 1, salt),
                smoothValue
            );
        }

        float paintValueNoise2D(float2 coordinate, uint seed, uint salt) {
            int2 cell = int2(floor(coordinate));
            float2 fractionValue = fract(coordinate);
            float2 smoothValue = fractionValue * fractionValue * (3.0 - (2.0 * fractionValue));
            float lower = mix(
                paintRandom2D(seed, cell, salt),
                paintRandom2D(seed, cell + int2(1, 0), salt),
                smoothValue.x
            );
            float upper = mix(
                paintRandom2D(seed, cell + int2(0, 1), salt),
                paintRandom2D(seed, cell + int2(1, 1), salt),
                smoothValue.x
            );
            return mix(lower, upper, smoothValue.y);
        }

        float3 paintLaneSrgbColor(
            float3 baseSrgb,
            int laneIndex,
            float longitudinal,
            float amount,
            float contrastAmount,
            uint variationSeed
        ) {
            float shapedAmount = pow(clamp(amount, 0.0, 1.0), 1.18);
            int groupSize = 3 + int(floor(paintRandom(variationSeed, 0, 0x6E624EB7u) * 4.0));
            int groupIndex = int(floor(float(laneIndex) / float(groupSize)));

            float groupHue = paintTriangularRandom(variationSeed, groupIndex, 0x1B56C4E9u);
            float groupSaturation = paintTriangularRandom(variationSeed, groupIndex, 0xB5297A4Du);
            float groupValue = paintTriangularRandom(variationSeed, groupIndex, 0x68E31DA4u);
            float laneHue = paintTriangularRandom(variationSeed, laneIndex, 0xA24BAED5u);
            float laneSaturation = paintTriangularRandom(variationSeed, laneIndex, 0x9FB21C65u);
            float laneValue = paintTriangularRandom(variationSeed, laneIndex, 0xC13FA9A9u);
            float slowEvolution = (paintValueNoise(
                longitudinal * 0.38 + float(laneIndex) * 0.173,
                variationSeed,
                0x91E10DA5u
            ) * 2.0) - 1.0;
            float fineEvolution = (paintValueNoise(
                longitudinal * 1.15 + float(laneIndex) * 0.619,
                variationSeed,
                0x3C6EF372u
            ) * 2.0) - 1.0;

            float accentChance = 0.012 + (0.065 * shapedAmount) + (0.08 * contrastAmount);
            float accentLane = step(
                1.0 - accentChance,
                paintRandom(variationSeed, laneIndex, 0xD1B54A35u)
            );
            float accentPulse = smoothstep(
                0.58,
                0.92,
                paintValueNoise(
                    longitudinal * 0.72 + float(laneIndex) * 2.371,
                    variationSeed,
                    0xF1357AE5u
                )
            );
            float accentWeight = accentLane * accentPulse;
            float accentSign = paintRandom(variationSeed, laneIndex, 0x94D049BBu) >= 0.5 ? 1.0 : -1.0;

            float hueRange = 0.115 * shapedAmount;
            float hueOffset = (groupHue * hueRange * 0.76) +
                (laneHue * hueRange * 0.28) +
                (slowEvolution * hueRange * 0.24) +
                (fineEvolution * hueRange * 0.08) +
                (accentWeight * accentSign * hueRange * 1.35);
            float saturationOffset = ((groupSaturation * 0.19) + (laneSaturation * 0.10)) * shapedAmount;
            float valueOffset = (
                (groupValue * 0.15) +
                (laneValue * 0.09) +
                (slowEvolution * 0.055) +
                (fineEvolution * 0.025)
            ) * shapedAmount;

            float3 hsv = rgbToHsv(baseSrgb);
            hsv.x = fract(hsv.x + hueOffset + 1.0);
            hsv.y = clamp(
                hsv.y + saturationOffset + (0.055 * shapedAmount) + (accentWeight * 0.08 * shapedAmount),
                0.0,
                1.0
            );
            hsv.z = clamp(hsv.z + valueOffset, 0.0, 1.0);
            return hsvToRgb(hsv);
        }

        float3 paintBristleSrgbColor(
            float3 baseSrgb,
            float crossStrokeCoordinate,
            float longitudinal,
            float diameterPixels,
            float jitterAmount,
            float contrastAmount,
            uint variationSeed
        ) {
            float amount = clamp(jitterAmount, 0.0, 1.0);
            float clampedContrast = clamp(contrastAmount, 0.0, 1.0);
            if (amount <= 0.001 && clampedContrast <= 0.001) {
                return baseSrgb;
            }

            float seedPhase = paintRandom(variationSeed, 0, 0xDB4F0B91u) * 19.0;
            float u = clamp(crossStrokeCoordinate, 0.0, 1.0);
            float macroWarp = paintValueNoise2D(
                float2((u * 5.0) + seedPhase, (longitudinal * 0.52) + seedPhase),
                variationSeed,
                0xBBE05633u
            ) - 0.5;
            float mediumWarp = paintValueNoise2D(
                float2((u * 16.0) + seedPhase, (longitudinal * 1.45) - seedPhase),
                variationSeed,
                0xA0F2EC75u
            ) - 0.5;
            float fineWarp = paintValueNoise((u * 41.0) + seedPhase, variationSeed, 0x89E18285u) - 0.5;
            float naturalness = 0.45 + (0.55 * amount);
            float warpedU = clamp(
                u +
                    (macroWarp * 0.085 * naturalness) +
                    (mediumWarp * 0.038 * naturalness) +
                    (fineWarp * 0.012 * naturalness),
                0.0,
                0.999999
            );

            float meanLaneWidth = mix(4.2, 2.0, sqrt(amount));
            float laneCount = clamp(max(diameterPixels, 1.0) / meanLaneWidth, 8.0, 72.0);
            float lanePosition = warpedU * laneCount;
            int laneIndex = int(floor(lanePosition));
            float laneFraction = fract(lanePosition);

            float3 currentColor = paintLaneSrgbColor(
                baseSrgb,
                laneIndex,
                longitudinal,
                amount,
                clampedContrast,
                variationSeed
            );
            float3 nextColor = paintLaneSrgbColor(
                baseSrgb,
                laneIndex + 1,
                longitudinal,
                amount,
                clampedContrast,
                variationSeed
            );
            float blendWidth = clamp(fwidth(lanePosition) * 0.72, 0.035, 0.24);
            float nextWeight = smoothstep(1.0 - blendWidth, 1.0, laneFraction);
            float3 mixedColor = mix(currentColor, nextColor, nextWeight);

            float broadField = (macroWarp * 2.0) + (mediumWarp * 0.55);
            float3 mixedHsv = rgbToHsv(mixedColor);
            mixedHsv.x = fract(mixedHsv.x + (broadField * 0.022 * amount) + 1.0);
            mixedHsv.y = clamp(mixedHsv.y + (broadField * 0.045 * amount), 0.0, 1.0);
            mixedHsv.z = clamp(mixedHsv.z + (broadField * 0.065 * amount), 0.0, 1.0);
            return hsvToRgb(mixedHsv);
        }

        float3 paintJitteredSrgbColor(
            float3 srgbColor,
            float2 localPoint,
            BrushUniforms uniforms
        ) {
            float radiansValue = uniforms.jitterDirectionDegrees * 0.017453292519943295;
            float cosine = cos(radiansValue);
            float sine = sin(radiansValue);
            float2 rotatedPoint = float2(
                (localPoint.x * cosine) + (localPoint.y * sine),
                (-localPoint.x * sine) + (localPoint.y * cosine)
            );
            float diameterPixels = max(uniforms.radius * 2.0, 1.0);
            float longitudinal = (uniforms.stampSeed / diameterPixels) + (rotatedPoint.y * 0.5);
            return paintBristleSrgbColor(
                srgbColor,
                (rotatedPoint.x + 1.0) * 0.5,
                longitudinal,
                diameterPixels,
                uniforms.paintJitterAmount,
                uniforms.paintContrastAmount,
                uniforms.paintVariationSeed
            );
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
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            uint vertexID [[vertex_id]],
            uint instanceID [[instance_id]]
        ) {
            VertexOut out;
            BrushUniforms uniforms = uniformsArray[instanceID];
            float2 local = vertices[vertexID].position;
            float2 pixel = uniforms.center + local * uniforms.radius;
            float2 ndc = float2(
                (pixel.x / uniforms.canvasSize.x) * 2.0 - 1.0,
                1.0 - (pixel.y / uniforms.canvasSize.y) * 2.0
            );
            out.position = float4(ndc, 0.0, 1.0);
            out.localPoint = local;
            out.pixelPoint = pixel;
            out.instanceID = instanceID;
            return out;
        }

        float selectionAlphaForBrushPixel(
            float2 pixelPoint,
            BrushUniforms uniforms,
            texture2d<float, access::read> selectionMask
        ) {
            if (uniforms.selectionMode == 0) {
                return 1.0;
            }

            float2 minPoint = uniforms.selectionMin;
            float2 maxPoint = uniforms.selectionMax;
            bool insideBounds =
                pixelPoint.x >= minPoint.x &&
                pixelPoint.x <= maxPoint.x &&
                pixelPoint.y >= minPoint.y &&
                pixelPoint.y <= maxPoint.y;
            if (!insideBounds) {
                return 0.0;
            }

            if (uniforms.selectionMode == 2) {
                float2 center = (minPoint + maxPoint) * 0.5;
                float2 radius = max((maxPoint - minPoint) * 0.5, float2(0.0001));
                float2 normalized = (pixelPoint - center) / radius;
                return dot(normalized, normalized) <= 1.0 ? 1.0 : 0.0;
            }
            if (uniforms.selectionMode == 3) {
                uint x = uint(clamp(pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                return selectionMask.read(uint2(x, y)).r;
            }
            return 1.0;
        }

        fragment float4 stageOneBrushFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::read> alphaLockTexture [[texture(1)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]],
            texture2d<float, access::sample> primaryEnvelopeTipMask [[texture(5)]],
            texture2d<float, access::sample> compoundSecondaryTipMask [[texture(6)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            float alphaMask = compoundFinalAlpha(
                in.localPoint,
                in.pixelPoint,
                uniforms,
                customTipMask,
                primaryEnvelopeTipMask,
                compoundSecondaryTipMask
            );
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            float selectionAlpha = selectionAlphaForBrushPixel(in.pixelPoint, uniforms, selectionMask);
            if (selectionAlpha <= 0.001) {
                discard_fragment();
            }
            alphaMask *= selectionAlpha;

            float lockedDestinationAlpha = 1.0;
            if (uniforms.usesAlphaLock != 0) {
                uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                lockedDestinationAlpha = alphaLockTexture.read(uint2(x, y)).a;
                if (lockedDestinationAlpha <= 0.001) {
                    discard_fragment();
                }
            }

            float targetAlpha = uniforms.opacity * alphaMask;
            float alpha = buildUpVisibleAlpha(targetAlpha, uniforms);

            if (uniforms.mode == 1) {
                return float4(0.0, 0.0, 0.0, alpha);
            }

            float4 inputColor = uniforms.color;
            float brushAlpha = inputColor.a * alpha;
            float3 jitteredSrgb = paintJitteredSrgbColor(inputColor.rgb, in.localPoint, uniforms);
            float3 linearRGB = srgbToLinear(jitteredSrgb);
            float rgbAlphaScale = uniforms.preservesAlphaLockAlpha != 0 ? lockedDestinationAlpha : 1.0;
            return float4(linearRGB * brushAlpha * rgbAlphaScale, brushAlpha);
        }

        fragment float4 stageOneSmudgeFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::read> alphaLockTexture [[texture(1)]],
            texture2d<float, access::read> gatheredColors [[texture(4)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]],
            texture2d<float, access::sample> primaryEnvelopeTipMask [[texture(5)]],
            texture2d<float, access::sample> compoundSecondaryTipMask [[texture(6)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            float alphaMask = compoundFinalAlpha(
                in.localPoint,
                in.pixelPoint,
                uniforms,
                customTipMask,
                primaryEnvelopeTipMask,
                compoundSecondaryTipMask
            );
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            float selectionAlpha = selectionAlphaForBrushPixel(in.pixelPoint, uniforms, selectionMask);
            if (selectionAlpha <= 0.001) {
                discard_fragment();
            }
            alphaMask *= selectionAlpha;

            if (uniforms.usesAlphaLock != 0) {
                uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                if (alphaLockTexture.read(uint2(x, y)).a <= 0.001) {
                    discard_fragment();
                }
            }

            float alpha = uniforms.opacity * alphaMask;
            if (alpha <= 0.0) {
                discard_fragment();
            }

            float4 sampled = gatheredColors.read(uint2(in.instanceID, 0));
            return float4(sampled.rgb * alpha, sampled.a * alpha);
        }

        fragment float4 stageOneSmudgeFrozenTextureFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::read> alphaLockTexture [[texture(1)]],
            texture2d<float, access::sample> sourceTexture [[texture(4)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]],
            texture2d<float, access::sample> primaryEnvelopeTipMask [[texture(5)]],
            texture2d<float, access::sample> compoundSecondaryTipMask [[texture(6)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            float alphaMask = compoundFinalAlpha(
                in.localPoint,
                in.pixelPoint,
                uniforms,
                customTipMask,
                primaryEnvelopeTipMask,
                compoundSecondaryTipMask
            );
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            float selectionAlpha = selectionAlphaForBrushPixel(in.pixelPoint, uniforms, selectionMask);
            if (selectionAlpha <= 0.001) {
                discard_fragment();
            }
            alphaMask *= selectionAlpha;

            if (uniforms.usesAlphaLock != 0) {
                uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                if (alphaLockTexture.read(uint2(x, y)).a <= 0.001) {
                    discard_fragment();
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
            return float4(sampled.rgb * alpha, sampled.a * alpha);
        }

        kernel void stageOneSmudgeGatherKernel(
            const device SmudgeGatherInput *inputs [[buffer(0)]],
            constant SmudgeGatherUniforms &uniforms [[buffer(1)]],
            texture2d<float, access::sample> sourceTexture [[texture(0)]],
            texture2d<float, access::write> gatheredColorsTexture [[texture(1)]],
            uint gid [[thread_position_in_grid]]
        ) {
            if (gid >= uniforms.sampleCount) {
                return;
            }

            float2 center = inputs[gid].center;
            float2 sampleUV = float2(
                clamp(center.x / uniforms.canvasSize.x, 0.0, 1.0),
                clamp(center.y / uniforms.canvasSize.y, 0.0, 1.0)
            );
            constexpr sampler sourceSampler(
                coord::normalized,
                address::clamp_to_edge,
                filter::linear
            );
            gatheredColorsTexture.write(sourceTexture.sample(sourceSampler, sampleUV), uint2(gid, 0));
        }

        fragment float4 stageOneOpacityCapMaskFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::read> alphaLockTexture [[texture(1)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]],
            texture2d<float, access::sample> primaryEnvelopeTipMask [[texture(5)]],
            texture2d<float, access::sample> compoundSecondaryTipMask [[texture(6)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            float alphaMask = compoundFinalAlpha(
                in.localPoint,
                in.pixelPoint,
                uniforms,
                customTipMask,
                primaryEnvelopeTipMask,
                compoundSecondaryTipMask
            );
            if (alphaMask <= 0.001) {
                discard_fragment();
            }

            float selectionAlpha = selectionAlphaForBrushPixel(in.pixelPoint, uniforms, selectionMask);
            if (selectionAlpha <= 0.001) {
                discard_fragment();
            }
            alphaMask *= selectionAlpha;

            if (uniforms.usesAlphaLock != 0) {
                uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                if (alphaLockTexture.read(uint2(x, y)).a <= 0.001) {
                    discard_fragment();
                }
            }

            float flowAlpha = uniforms.opacity * alphaMask;
            return float4(flowAlpha, flowAlpha, flowAlpha, flowAlpha);
        }

        fragment float4 stageOneCompoundPrimaryMaskFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::read> alphaLockTexture [[texture(1)]],
            texture2d<float, access::sample> customTipMask [[texture(2)]],
            texture2d<float, access::sample> primaryEnvelopeTipMask [[texture(5)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            // Preserve the real A-tip material. Replacing it with a solid envelope
            // turns opacity pressure into a uniform translucent sheet before the
            // overlay operation, which is visibly unlike Photoshop/Krita.
            float texturedPrimary = primaryTextureAlpha(
                in.localPoint,
                uniforms,
                customTipMask
            );
            float primaryEnvelope = primaryEnvelopeAlpha(
                in.localPoint,
                uniforms,
                primaryEnvelopeTipMask
            );
            float effectivePrimaryPressure = clamp(
                uniforms.compoundPrimaryOpacityFactor * uniforms.compoundGlobalOpacityFactor,
                0.0,
                1.0
            );
            // Let the real A texture appear from light pressure onward, while a
            // restrained envelope floor closes its larger channels progressively.
            // Both terms are continuous over the full pressure range: a narrow
            // high-pressure switch makes the stroke jump from sparse to dead black.
            float texturedPressure = 0.98 * pow(effectivePrimaryPressure, 0.75);
            float densityPressure = 0.92 * (
                1.0 - pow(1.0 - effectivePrimaryPressure, 1.5)
            );
            float primaryAlpha = max(
                texturedPrimary * texturedPressure,
                primaryEnvelope * densityPressure
            );
            if (primaryAlpha <= 0.001) {
                discard_fragment();
            }

            float selectionAlpha = selectionAlphaForBrushPixel(in.pixelPoint, uniforms, selectionMask);
            if (selectionAlpha <= 0.001) {
                discard_fragment();
            }
            primaryAlpha *= selectionAlpha;

            if (uniforms.usesAlphaLock != 0) {
                uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                if (alphaLockTexture.read(uint2(x, y)).a <= 0.001) {
                    discard_fragment();
                }
            }

            float flowAlpha = uniforms.opacity * primaryAlpha;
            return float4(flowAlpha, flowAlpha, flowAlpha, flowAlpha);
        }

        fragment float4 stageOneCompoundSecondaryMaskFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::sample> compoundSecondaryTipMask [[texture(6)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            float secondaryAlpha = compoundSecondaryTipAlpha(
                in.localPoint,
                uniforms,
                compoundSecondaryTipMask
            ) * uniforms.compoundSecondaryOpacityFactor;
            if (secondaryAlpha <= 0.001) {
                discard_fragment();
            }
            float flowAlpha = uniforms.opacity * secondaryAlpha;
            return float4(flowAlpha, flowAlpha, flowAlpha, flowAlpha);
        }

        fragment float4 stageOneCompoundPrimaryBuildUpMaskFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::read> selectionMask [[texture(0)]],
            texture2d<float, access::read> alphaLockTexture [[texture(1)]],
            texture2d<float, access::sample> primaryEnvelopeTipMask [[texture(5)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            // A is the dense body stream. Its saved envelope is the actual
            // footprint that can close under repeated 5% stamps; the raw A
            // grayscale texture contains fixed channels that cannot become solid
            // regardless of pressure. B remains the material/grain stream.
            float primaryAlpha = primaryEnvelopeAlpha(
                in.localPoint,
                uniforms,
                primaryEnvelopeTipMask
            );
            float pressureAlpha = uniforms.compoundPrimaryOpacityFactor
                * uniforms.compoundGlobalOpacityFactor;
            float targetAlpha = uniforms.opacity * primaryAlpha * pressureAlpha;
            float flowAlpha = buildUpVisibleAlpha(targetAlpha, uniforms);
            if (flowAlpha <= 0.001) {
                discard_fragment();
            }

            float selectionAlpha = selectionAlphaForBrushPixel(in.pixelPoint, uniforms, selectionMask);
            if (selectionAlpha <= 0.001) {
                discard_fragment();
            }
            flowAlpha *= selectionAlpha;

            if (uniforms.usesAlphaLock != 0) {
                uint x = uint(clamp(in.pixelPoint.x, 0.0, uniforms.canvasSize.x - 1.0));
                uint y = uint(clamp(in.pixelPoint.y, 0.0, uniforms.canvasSize.y - 1.0));
                if (alphaLockTexture.read(uint2(x, y)).a <= 0.001) {
                    discard_fragment();
                }
            }

            return float4(flowAlpha, flowAlpha, flowAlpha, flowAlpha);
        }

        fragment float4 stageOneCompoundSecondaryBuildUpMaskFragment(
            VertexOut in [[stage_in]],
            const device BrushUniforms *uniformsArray [[buffer(1)]],
            texture2d<float, access::sample> compoundSecondaryTipMask [[texture(6)]]
        ) {
            BrushUniforms uniforms = uniformsArray[in.instanceID];
            float secondaryAlpha = compoundSecondaryTipAlpha(
                in.localPoint,
                uniforms,
                compoundSecondaryTipMask
            );
            // B is the Dual Brush material mask, not a second coat of pressure-
            // controlled paint. Applying global transfer to both A and B squares
            // low pressure after Overlay and makes the light stroke disappear.
            // B may still have its own explicitly configured opacity response.
            float pressureAlpha = uniforms.compoundSecondaryOpacityFactor;
            float targetAlpha = uniforms.opacity * secondaryAlpha * pressureAlpha;
            float flowAlpha = buildUpVisibleAlpha(targetAlpha, uniforms);
            if (flowAlpha <= 0.001) {
                discard_fragment();
            }
            return float4(flowAlpha, flowAlpha, flowAlpha, flowAlpha);
        }

        fragment float4 stageOneOpacityCapCompositeFragment(
            CompositeVertexOut in [[stage_in]],
            texture2d<float, access::sample> originalTexture [[texture(0)]],
            texture2d<float, access::sample> alphaTexture [[texture(1)]],
            texture2d<float, access::sample> compoundSecondaryTexture [[texture(2)]],
            sampler textureSampler [[sampler(0)]],
            constant CompositeUniforms &uniforms [[buffer(0)]]
        ) {
            float4 original = originalTexture.sample(textureSampler, in.texCoord);
            float accumulatedAlpha = alphaTexture.sample(textureSampler, in.texCoord).r;
            if (uniforms.usesCompoundMask != 0) {
                float secondaryAlpha = compoundSecondaryTexture.sample(textureSampler, in.texCoord).r;
                accumulatedAlpha = accumulatedAlpha <= 0.5
                    ? 2.0 * secondaryAlpha * accumulatedAlpha
                    : 1.0 - (2.0 * (1.0 - secondaryAlpha) * (1.0 - accumulatedAlpha));
            }
            float cappedAlpha = clamp(accumulatedAlpha * uniforms.brushColor.a, 0.0, 1.0);

            if (uniforms.mode == 1) {
                if (uniforms.usesAlphaLock != 0) {
                    return float4(
                        original.rgb * (1.0 - cappedAlpha),
                        original.a
                    );
                }
                return float4(
                    original.rgb * (1.0 - cappedAlpha),
                    original.a * (1.0 - cappedAlpha)
                );
            }

            float3 brushSrgb = uniforms.brushColor.rgb;

            // Apply paint jitter in composite pass using canvas-space stripes
            float jitterAmt = uniforms.paintJitterAmount;
            float contrastAmt = uniforms.paintContrastAmount;
            if (jitterAmt > 0.001 || contrastAmt > 0.001) {
                float2 absolutePixel = float2(
                    in.texCoord.x * uniforms.canvasWidth,
                    in.texCoord.y * uniforms.canvasHeight
                );
                float2 pixelPos = absolutePixel - float2(
                    uniforms.strokeCenterX,
                    uniforms.strokeCenterY
                );
                float radiansValue = uniforms.jitterDirectionDegrees * 0.017453292519943295;
                float cosine = cos(radiansValue);
                float sine = sin(radiansValue);
                float crossPixels = (pixelPos.x * cosine) + (pixelPos.y * sine);
                float longitudinalPixels = (-absolutePixel.x * sine) + (absolutePixel.y * cosine);
                float diameterPixels = max(uniforms.strokeRadius * 2.0, 1.0);
                brushSrgb = paintBristleSrgbColor(
                    brushSrgb,
                    0.5 + (crossPixels / diameterPixels),
                    longitudinalPixels / diameterPixels,
                    diameterPixels,
                    jitterAmt,
                    contrastAmt,
                    uniforms.paintVariationSeed
                );
            }

            float3 linearRGB = srgbToLinear(brushSrgb);

            if (uniforms.usesAlphaLock != 0) {
                return float4(
                    (linearRGB * original.a * cappedAlpha) + (original.rgb * (1.0 - cappedAlpha)),
                    original.a
                );
            }

            return float4(
                (linearRGB * cappedAlpha) + (original.rgb * (1.0 - cappedAlpha)),
                cappedAlpha + (original.a * (1.0 - cappedAlpha))
            );
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw StageOneBrushRendererInitializationError.shaderLibrary(error)
        }
        guard
            let vertexFunction = library.makeFunction(name: "stageOneBrushVertex"),
            let fragmentFunction = library.makeFunction(name: "stageOneBrushFragment")
        else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneBrushVertex/stageOneBrushFragment")
        }

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
        do {
            self.brushPipelineState = try device.makeRenderPipelineState(descriptor: brushDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("brush", error)
        }

        let alphaLockBrushDescriptor = MTLRenderPipelineDescriptor()
        alphaLockBrushDescriptor.vertexFunction = vertexFunction
        alphaLockBrushDescriptor.fragmentFunction = fragmentFunction
        alphaLockBrushDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let alphaLockBrushAttachment = alphaLockBrushDescriptor.colorAttachments[0]!
        alphaLockBrushAttachment.isBlendingEnabled = true
        alphaLockBrushAttachment.rgbBlendOperation = .add
        alphaLockBrushAttachment.alphaBlendOperation = .add
        alphaLockBrushAttachment.sourceRGBBlendFactor = .one
        alphaLockBrushAttachment.sourceAlphaBlendFactor = .one
        alphaLockBrushAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        alphaLockBrushAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        alphaLockBrushAttachment.writeMask = [.red, .green, .blue]
        do {
            self.alphaLockBrushPipelineState = try device.makeRenderPipelineState(descriptor: alphaLockBrushDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("alphaLockBrush", error)
        }

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
        do {
            self.eraserPipelineState = try device.makeRenderPipelineState(descriptor: eraserDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("eraser", error)
        }

        let smudgeDescriptor = MTLRenderPipelineDescriptor()
        smudgeDescriptor.vertexFunction = vertexFunction
        guard let smudgeFunction = library.makeFunction(name: "stageOneSmudgeFragment") else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneSmudgeFragment")
        }
        smudgeDescriptor.fragmentFunction = smudgeFunction
        smudgeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let smudgeAttachment = smudgeDescriptor.colorAttachments[0]!
        smudgeAttachment.isBlendingEnabled = true
        smudgeAttachment.rgbBlendOperation = .add
        smudgeAttachment.alphaBlendOperation = .add
        smudgeAttachment.sourceRGBBlendFactor = .one
        smudgeAttachment.sourceAlphaBlendFactor = .one
        smudgeAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        smudgeAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.smudgePipelineState = try device.makeRenderPipelineState(descriptor: smudgeDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("smudge", error)
        }

        let smudgeFrozenTextureDescriptor = MTLRenderPipelineDescriptor()
        smudgeFrozenTextureDescriptor.vertexFunction = vertexFunction
        guard let smudgeFrozenTextureFunction = library.makeFunction(name: "stageOneSmudgeFrozenTextureFragment") else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneSmudgeFrozenTextureFragment")
        }
        smudgeFrozenTextureDescriptor.fragmentFunction = smudgeFrozenTextureFunction
        smudgeFrozenTextureDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let smudgeFrozenTextureAttachment = smudgeFrozenTextureDescriptor.colorAttachments[0]!
        smudgeFrozenTextureAttachment.isBlendingEnabled = true
        smudgeFrozenTextureAttachment.rgbBlendOperation = .add
        smudgeFrozenTextureAttachment.alphaBlendOperation = .add
        smudgeFrozenTextureAttachment.sourceRGBBlendFactor = .one
        smudgeFrozenTextureAttachment.sourceAlphaBlendFactor = .one
        smudgeFrozenTextureAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        smudgeFrozenTextureAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.smudgeFrozenTexturePipelineState = try device.makeRenderPipelineState(descriptor: smudgeFrozenTextureDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("smudgeFrozenTexture", error)
        }

        guard let smudgeGatherFunction = library.makeFunction(name: "stageOneSmudgeGatherKernel") else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneSmudgeGatherKernel")
        }
        do {
            self.smudgeGatherPipelineState = try device.makeComputePipelineState(function: smudgeGatherFunction)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("smudgeGather", error)
        }

        let opacityCapMaskDescriptor = MTLRenderPipelineDescriptor()
        opacityCapMaskDescriptor.vertexFunction = vertexFunction
        guard let opacityCapMaskFunction = library.makeFunction(name: "stageOneOpacityCapMaskFragment") else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneOpacityCapMaskFragment")
        }
        opacityCapMaskDescriptor.fragmentFunction = opacityCapMaskFunction
        opacityCapMaskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm

        let opacityCapMaskAttachment = opacityCapMaskDescriptor.colorAttachments[0]!
        opacityCapMaskAttachment.isBlendingEnabled = true
        opacityCapMaskAttachment.rgbBlendOperation = .max
        opacityCapMaskAttachment.alphaBlendOperation = .max
        opacityCapMaskAttachment.sourceRGBBlendFactor = .one
        opacityCapMaskAttachment.sourceAlphaBlendFactor = .one
        opacityCapMaskAttachment.destinationRGBBlendFactor = .one
        opacityCapMaskAttachment.destinationAlphaBlendFactor = .one
        do {
            self.opacityCapMaskPipelineState = try device.makeRenderPipelineState(descriptor: opacityCapMaskDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("opacityCapMask", error)
        }

        let compoundPrimaryMaskDescriptor = MTLRenderPipelineDescriptor()
        compoundPrimaryMaskDescriptor.vertexFunction = vertexFunction
        guard let compoundPrimaryMaskFunction = library.makeFunction(name: "stageOneCompoundPrimaryMaskFragment") else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneCompoundPrimaryMaskFragment")
        }
        compoundPrimaryMaskDescriptor.fragmentFunction = compoundPrimaryMaskFunction
        compoundPrimaryMaskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        let compoundPrimaryMaskAttachment = compoundPrimaryMaskDescriptor.colorAttachments[0]!
        compoundPrimaryMaskAttachment.isBlendingEnabled = true
        compoundPrimaryMaskAttachment.rgbBlendOperation = .max
        compoundPrimaryMaskAttachment.alphaBlendOperation = .max
        compoundPrimaryMaskAttachment.sourceRGBBlendFactor = .one
        compoundPrimaryMaskAttachment.sourceAlphaBlendFactor = .one
        compoundPrimaryMaskAttachment.destinationRGBBlendFactor = .one
        compoundPrimaryMaskAttachment.destinationAlphaBlendFactor = .one
        do {
            self.compoundPrimaryMaskPipelineState = try device.makeRenderPipelineState(
                descriptor: compoundPrimaryMaskDescriptor
            )
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("compoundPrimaryMask", error)
        }

        let compoundSecondaryMaskDescriptor = MTLRenderPipelineDescriptor()
        compoundSecondaryMaskDescriptor.vertexFunction = vertexFunction
        guard let compoundSecondaryMaskFunction = library.makeFunction(name: "stageOneCompoundSecondaryMaskFragment") else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneCompoundSecondaryMaskFragment")
        }
        compoundSecondaryMaskDescriptor.fragmentFunction = compoundSecondaryMaskFunction
        compoundSecondaryMaskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        let compoundSecondaryMaskAttachment = compoundSecondaryMaskDescriptor.colorAttachments[0]!
        compoundSecondaryMaskAttachment.isBlendingEnabled = true
        compoundSecondaryMaskAttachment.rgbBlendOperation = .max
        compoundSecondaryMaskAttachment.alphaBlendOperation = .max
        compoundSecondaryMaskAttachment.sourceRGBBlendFactor = .one
        compoundSecondaryMaskAttachment.sourceAlphaBlendFactor = .one
        compoundSecondaryMaskAttachment.destinationRGBBlendFactor = .one
        compoundSecondaryMaskAttachment.destinationAlphaBlendFactor = .one
        do {
            self.compoundSecondaryMaskPipelineState = try device.makeRenderPipelineState(
                descriptor: compoundSecondaryMaskDescriptor
            )
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("compoundSecondaryMask", error)
        }

        let compoundPrimaryBuildUpMaskDescriptor = MTLRenderPipelineDescriptor()
        compoundPrimaryBuildUpMaskDescriptor.vertexFunction = vertexFunction
        guard let compoundPrimaryBuildUpMaskFunction = library.makeFunction(
            name: "stageOneCompoundPrimaryBuildUpMaskFragment"
        ) else {
            throw StageOneBrushRendererInitializationError.missingFunction(
                "stageOneCompoundPrimaryBuildUpMaskFragment"
            )
        }
        compoundPrimaryBuildUpMaskDescriptor.fragmentFunction = compoundPrimaryBuildUpMaskFunction
        compoundPrimaryBuildUpMaskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        let compoundPrimaryBuildUpMaskAttachment = compoundPrimaryBuildUpMaskDescriptor.colorAttachments[0]!
        compoundPrimaryBuildUpMaskAttachment.isBlendingEnabled = true
        compoundPrimaryBuildUpMaskAttachment.rgbBlendOperation = .add
        compoundPrimaryBuildUpMaskAttachment.alphaBlendOperation = .add
        compoundPrimaryBuildUpMaskAttachment.sourceRGBBlendFactor = .one
        compoundPrimaryBuildUpMaskAttachment.sourceAlphaBlendFactor = .one
        compoundPrimaryBuildUpMaskAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        compoundPrimaryBuildUpMaskAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.compoundPrimaryBuildUpMaskPipelineState = try device.makeRenderPipelineState(
                descriptor: compoundPrimaryBuildUpMaskDescriptor
            )
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("compoundPrimaryBuildUpMask", error)
        }

        let compoundSecondaryBuildUpMaskDescriptor = MTLRenderPipelineDescriptor()
        compoundSecondaryBuildUpMaskDescriptor.vertexFunction = vertexFunction
        guard let compoundSecondaryBuildUpMaskFunction = library.makeFunction(
            name: "stageOneCompoundSecondaryBuildUpMaskFragment"
        ) else {
            throw StageOneBrushRendererInitializationError.missingFunction(
                "stageOneCompoundSecondaryBuildUpMaskFragment"
            )
        }
        compoundSecondaryBuildUpMaskDescriptor.fragmentFunction = compoundSecondaryBuildUpMaskFunction
        compoundSecondaryBuildUpMaskDescriptor.colorAttachments[0].pixelFormat = .r8Unorm
        let compoundSecondaryBuildUpMaskAttachment = compoundSecondaryBuildUpMaskDescriptor.colorAttachments[0]!
        compoundSecondaryBuildUpMaskAttachment.isBlendingEnabled = true
        compoundSecondaryBuildUpMaskAttachment.rgbBlendOperation = .add
        compoundSecondaryBuildUpMaskAttachment.alphaBlendOperation = .add
        compoundSecondaryBuildUpMaskAttachment.sourceRGBBlendFactor = .one
        compoundSecondaryBuildUpMaskAttachment.sourceAlphaBlendFactor = .one
        compoundSecondaryBuildUpMaskAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        compoundSecondaryBuildUpMaskAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            self.compoundSecondaryBuildUpMaskPipelineState = try device.makeRenderPipelineState(
                descriptor: compoundSecondaryBuildUpMaskDescriptor
            )
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("compoundSecondaryBuildUpMask", error)
        }

        let opacityCapCompositeDescriptor = MTLRenderPipelineDescriptor()
        guard
            let compositeVertexFunction = library.makeFunction(name: "stageOneCompositeVertex"),
            let opacityCapCompositeFunction = library.makeFunction(name: "stageOneOpacityCapCompositeFragment")
        else {
            throw StageOneBrushRendererInitializationError.missingFunction("stageOneCompositeVertex/stageOneOpacityCapCompositeFragment")
        }
        opacityCapCompositeDescriptor.vertexFunction = compositeVertexFunction
        opacityCapCompositeDescriptor.fragmentFunction = opacityCapCompositeFunction
        opacityCapCompositeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        opacityCapCompositeDescriptor.colorAttachments[0].isBlendingEnabled = false
        do {
            self.opacityCapCompositePipelineState = try device.makeRenderPipelineState(descriptor: opacityCapCompositeDescriptor)
        } catch {
            throw StageOneBrushRendererInitializationError.pipelineState("opacityCapComposite", error)
        }

        let vertices = [
            BrushVertex(position: SIMD2(-1, -1)),
            BrushVertex(position: SIMD2(1, -1)),
            BrushVertex(position: SIMD2(-1, 1)),
            BrushVertex(position: SIMD2(1, 1))
        ]

        guard let vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: MemoryLayout<BrushVertex>.stride * vertices.count
        ) else {
            throw StageOneBrushRendererInitializationError.vertexBufferCreation
        }
        self.vertexBuffer = vertexBuffer

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard
            let compositeSamplerState = device.makeSamplerState(descriptor: samplerDescriptor),
            let tipSamplerState = device.makeSamplerState(descriptor: samplerDescriptor)
        else {
            throw StageOneBrushRendererInitializationError.samplerCreation
        }
        self.compositeSamplerState = compositeSamplerState
        self.tipSamplerState = tipSamplerState

        let defaultTipDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        defaultTipDescriptor.usage = .shaderRead
        defaultTipDescriptor.storageMode = .shared
        guard let defaultTipTexture = device.makeTexture(descriptor: defaultTipDescriptor) else {
            throw StageOneBrushRendererInitializationError.defaultTipTextureCreation
        }
        var fullAlpha: UInt8 = 255
        defaultTipTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &fullAlpha,
            bytesPerRow: 1
        )
        self.defaultTipTexture = defaultTipTexture
        self.fallbackAlphaLockTexture = defaultTipTexture

    }

    private static let maxSetBytesLength = 4096
    private static let maxReusableUniformBufferCount = 8
    private static let maxReusableUniformBufferBytes = 16 * 1024 * 1024

    private func setInstancedUniforms(
        _ uniformsArray: inout [BrushUniforms],
        encoder: MTLRenderCommandEncoder,
        commandBuffer: MTLCommandBuffer
    ) {
        let bufferLength = MemoryLayout<BrushUniforms>.stride * uniformsArray.count
        if bufferLength <= Self.maxSetBytesLength {
            encoder.setVertexBytes(&uniformsArray, length: bufferLength, index: 1)
            encoder.setFragmentBytes(&uniformsArray, length: bufferLength, index: 1)
        } else {
            guard let buffer = leaseUniformBuffer(minimumLength: bufferLength) else {
                return
            }
            uniformsArray.withUnsafeBytes { bytes in
                guard let source = bytes.baseAddress else {
                    return
                }
                buffer.contents().copyMemory(from: source, byteCount: bufferLength)
            }
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setFragmentBuffer(buffer, offset: 0, index: 1)
            let recycleLease = UniformBufferRecycleLease(renderer: self, buffer: buffer)
            commandBuffer.addCompletedHandler { [recycleLease] _ in
                recycleLease.recycle()
            }
        }
    }

    private func leaseUniformBuffer(minimumLength: Int) -> MTLBuffer? {
        reusableUniformBufferLock.lock()
        let reusableIndex = reusableUniformBuffers.indices
            .filter { reusableUniformBuffers[$0].length >= minimumLength }
            .min { reusableUniformBuffers[$0].length < reusableUniformBuffers[$1].length }
        if let reusableIndex {
            let buffer = reusableUniformBuffers.remove(at: reusableIndex)
            reusableUniformBufferBytes -= buffer.length
            reusableUniformBufferLock.unlock()
            return buffer
        }
        reusableUniformBufferLock.unlock()

        let minimumBatchLength = MemoryLayout<BrushUniforms>.stride * 64
        let requestedLength = max(minimumLength, minimumBatchLength)
        let allocationLength = ((requestedLength + 4095) / 4096) * 4096
        return device.makeBuffer(length: allocationLength, options: .storageModeShared)
    }

    fileprivate func recycleUniformBuffer(_ buffer: MTLBuffer) {
        reusableUniformBufferLock.lock()
        defer { reusableUniformBufferLock.unlock() }
        guard
            reusableUniformBuffers.count < Self.maxReusableUniformBufferCount,
            reusableUniformBufferBytes + buffer.length <= Self.maxReusableUniformBufferBytes
        else {
            return
        }
        reusableUniformBuffers.append(buffer)
        reusableUniformBufferBytes += buffer.length
    }

    @discardableResult
    func render(
        stroke: StrokeDescriptor,
        into texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        alphaLockTexture: MTLTexture? = nil,
        preservesAlphaWhenAlphaLocked: Bool = true,
        samplingState: inout BrushStrokeSamplingState?,
        completion: (() -> Void)? = nil
    ) -> Int {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion?()
            return 0
        }
        let emitted = encodeStroke(
            stroke: stroke,
            into: texture,
            commandQueue: commandQueue,
            commandBuffer: commandBuffer,
            alphaLockTexture: alphaLockTexture,
            preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked,
            samplingState: &samplingState
        )

        if let completion {
            commandBuffer.addCompletedHandler { _ in
                completion()
            }
        }
        commandBuffer.commit()
        return emitted
    }

    func makeOpacityCapSession(
        for texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        reusesCachedTextures: Bool = true
    ) -> OpacityCapSessionResources? {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("StageOneBrushRenderer.makeOpacityCapSession", ms: ms)
            }
        }

        let originalTexture: MTLTexture
        let alphaTexture: MTLTexture

        if reusesCachedTextures,
           let cached = cachedOpacityCapOriginalTexture,
           cached.width == texture.width,
           cached.height == texture.height,
           cached.pixelFormat == texture.pixelFormat,
           let cachedAlpha = cachedOpacityCapAlphaTexture,
           cachedAlpha.width == texture.width,
           cachedAlpha.height == texture.height {
            originalTexture = cached
            alphaTexture = cachedAlpha
        } else {
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
                let newOriginal = device.makeTexture(descriptor: originalDescriptor),
                let newAlpha = device.makeTexture(descriptor: alphaDescriptor)
            else {
                return nil
            }
            originalTexture = newOriginal
            alphaTexture = newAlpha
            if reusesCachedTextures {
                cachedOpacityCapOriginalTexture = newOriginal
                cachedOpacityCapAlphaTexture = newAlpha
            }
        }

        clearTexture(alphaTexture, commandQueue: commandQueue)
        copyTexture(from: texture, to: originalTexture, commandQueue: commandQueue)
        return OpacityCapSessionResources(
            originalTexture: originalTexture,
            alphaTexture: alphaTexture,
            reusesCachedTextures: reusesCachedTextures
        )
    }

    private func ensureCompoundSecondaryTexture(
        for session: OpacityCapSessionResources,
        matching texture: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        if let existing = session.compoundSecondaryTexture {
            return existing
        }

        let secondaryTexture: MTLTexture
        if session.reusesCachedTextures,
           let cached = cachedCompoundSecondaryTexture,
           cached.width == texture.width,
           cached.height == texture.height {
            secondaryTexture = cached
        } else {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm,
                width: texture.width,
                height: texture.height,
                mipmapped: false
            )
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .private
            guard let created = device.makeTexture(descriptor: descriptor) else {
                return nil
            }
            secondaryTexture = created
            if session.reusesCachedTextures {
                cachedCompoundSecondaryTexture = created
            }
        }

        let clearPass = MTLRenderPassDescriptor()
        clearPass.colorAttachments[0].texture = secondaryTexture
        clearPass.colorAttachments[0].loadAction = .clear
        clearPass.colorAttachments[0].storeAction = .store
        clearPass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: clearPass) else {
            return nil
        }
        encoder.endEncoding()
        session.compoundSecondaryTexture = secondaryTexture
        return secondaryTexture
    }

    private func usesIndependentCompoundMask(for stroke: StrokeDescriptor) -> Bool {
        (stroke.tool == .brush || stroke.tool == .eraser) &&
            stroke.brush.compoundBrush.enabled &&
            stroke.brush.compoundBrush.mode == .overlay
    }

    private func compoundSecondarySamplingStroke(from stroke: StrokeDescriptor) -> StrokeDescriptor {
        let secondary = stroke.brush.compoundBrush.secondary
        var samplingBrush = stroke.brush
        samplingBrush.size = secondary.resolvedBaseSize(for: stroke.brush.size)
        samplingBrush.spacingPercent = secondary.spacingPercent
        samplingBrush.scatterAmount = 0
        samplingBrush.jitterAmount = 0
        samplingBrush.sizeJitterAmount = 0
        samplingBrush.angleJitterAmount = 0
        samplingBrush.stampRotationDegrees = secondary.angleDegrees
        samplingBrush.followsStrokeDirection = secondary.followsStrokeDirection
        samplingBrush.pressureSizeAmount = secondary.pressureSizeAmount
        samplingBrush.sizeCurveLow = secondary.sizeCurveLow
        samplingBrush.sizeCurveMid = secondary.sizeCurveMid
        samplingBrush.sizeCurveHigh = secondary.sizeCurveHigh
        samplingBrush.sizePressureCurve = nil
        samplingBrush.pressureOpacityAmount = secondary.pressureOpacityAmount
        samplingBrush.opacityCurveLow = secondary.opacityCurveLow
        samplingBrush.opacityCurveMid = secondary.opacityCurveMid
        samplingBrush.opacityCurveHigh = secondary.opacityCurveHigh
        samplingBrush.opacityPressureCurve = secondary.opacityPressureCurve
        samplingBrush.compoundBrush.enabled = false

        return StrokeDescriptor(
            tool: stroke.tool,
            color: stroke.color,
            brush: samplingBrush,
            points: stroke.points,
            selectionShape: stroke.selectionShape,
            alphaLockEnabled: stroke.alphaLockEnabled,
            skipLeadingStamp: stroke.skipLeadingStamp,
            paintVariationSeed: stroke.paintVariationSeed
        )
    }

    @discardableResult
    func renderOpacityCap(
        stroke: StrokeDescriptor,
        session: OpacityCapSessionResources,
        into texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        alphaLockTexture: MTLTexture? = nil,
        preservesAlphaWhenAlphaLocked: Bool = true,
        samplingState: inout BrushStrokeSamplingState?,
        completion: (() -> Void)? = nil
    ) -> Int {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            completion?()
            return 0
        }

        let emitted = encodeOpacityCapStroke(
            stroke: stroke,
            session: session,
            into: texture,
            commandBuffer: commandBuffer,
            alphaLockTexture: alphaLockTexture,
            preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked,
            samplingState: &samplingState
        )

        if let completion {
            commandBuffer.addCompletedHandler { _ in
                completion()
            }
        }
        commandBuffer.commit()
        return emitted
    }

    @discardableResult
    func encodeStroke(
        stroke: StrokeDescriptor,
        into texture: MTLTexture,
        commandQueue: MTLCommandQueue,
        commandBuffer: MTLCommandBuffer,
        alphaLockTexture: MTLTexture? = nil,
        preservesAlphaWhenAlphaLocked: Bool = true,
        samplingState: inout BrushStrokeSamplingState?
    ) -> Int {
        let samples = interpolatedPoints(for: stroke, samplingState: &samplingState)
        guard !samples.isEmpty else {
            return 0
        }
        recordRenderedPixelBounds(
            for: samples,
            stroke: stroke,
            texture: texture,
            samplingState: &samplingState
        )

        if stroke.tool == .smudge {
            guard let smudgeGatheredColorsTexture = makeSmudgeGatheredColorsTexture(
                from: texture,
                samples: samples,
                commandBuffer: commandBuffer
            ) else {
                return 0
            }
            return encodeSmudgeStroke(
                samples: samples,
                stroke: stroke,
                into: texture,
                commandBuffer: commandBuffer,
                alphaLockTexture: alphaLockTexture,
                preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked,
                gatheredColorsTexture: smudgeGatheredColorsTexture,
                frozenSourceTexture: nil
            )
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .load
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return 0
        }

        let pipelineState: MTLRenderPipelineState
        switch stroke.tool {
        case .eraser:
            pipelineState = eraserPipelineState
        default:
            pipelineState = alphaLockTexture != nil && preservesAlphaWhenAlphaLocked
                ? alphaLockBrushPipelineState
                : brushPipelineState
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let selectionShape = stroke.selectionShape?.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        if let selectionShape, selectionShape.isEmpty {
            encoder.endEncoding()
            return 0
        }

        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: CanvasSize(width: texture.width, height: texture.height)
        )
        let primaryCustomTipTexture =
            customTipTexture(for: primaryCustomTipMaskData(for: stroke), role: .primary) ?? defaultTipTexture
        let primaryEnvelopeTipTexture =
            customTipTexture(for: primaryEnvelopeCustomTipMaskData(for: stroke), role: .primaryEnvelope) ??
            primaryCustomTipTexture
        let compoundSecondaryTipTexture =
            customTipTexture(for: compoundSecondaryCustomTipMaskData(for: stroke), role: .compoundSecondary) ??
            defaultTipTexture
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
        encoder.setFragmentTexture(primaryCustomTipTexture, index: 2)
        encoder.setFragmentTexture(primaryEnvelopeTipTexture, index: 5)
        encoder.setFragmentTexture(compoundSecondaryTipTexture, index: 6)
        encoder.setFragmentSamplerState(tipSamplerState, index: 1)

        var uniformsArray = samples.map {
            makeUniforms(
                for: $0,
                stroke: stroke,
                texture: texture,
                selectionShape: selectionShape,
                preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked
            )
        }
        setInstancedUniforms(&uniformsArray, encoder: encoder, commandBuffer: commandBuffer)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: uniformsArray.count)

        encoder.endEncoding()
        return samples.count
    }

    @discardableResult
    func encodeOpacityCapStroke(
        stroke: StrokeDescriptor,
        session: OpacityCapSessionResources,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        alphaLockTexture: MTLTexture? = nil,
        preservesAlphaWhenAlphaLocked: Bool = true,
        samplingState: inout BrushStrokeSamplingState?
    ) -> Int {
        let usesIndependentCompoundMask = usesIndependentCompoundMask(for: stroke)
        let usesCompoundBuildUp = usesIndependentCompoundMask && stroke.brush.buildMode == .buildUp
        if usesIndependentCompoundMask, samplingState?.isFlushing == true {
            session.compoundSecondarySamplingState?.isFlushing = true
        }

        let samples = interpolatedPoints(for: stroke, samplingState: &samplingState)
        var secondarySamples: [StampSample] = []
        let secondaryStroke = usesIndependentCompoundMask
            ? compoundSecondarySamplingStroke(from: stroke)
            : nil
        if let secondaryStroke {
            secondarySamples = interpolatedPoints(
                for: secondaryStroke,
                samplingState: &session.compoundSecondarySamplingState
            )
        }
        guard !samples.isEmpty || !secondarySamples.isEmpty else {
            return 0
        }
        if !samples.isEmpty {
            recordRenderedPixelBounds(
                for: samples,
                stroke: stroke,
                texture: texture,
                samplingState: &samplingState
            )
        }
        if !secondarySamples.isEmpty, let secondaryStroke {
            recordRenderedPixelBounds(
                for: secondarySamples,
                stroke: secondaryStroke,
                texture: texture,
                samplingState: &samplingState
            )
        }

        let selectionShape = stroke.selectionShape?.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: CanvasSize(width: texture.width, height: texture.height)
        )
        let primaryDirtyRect = samples.isEmpty
            ? nil
            : opacityCapDirtyRect(for: samples, stroke: stroke, texture: texture)
        let secondaryDirtyRect: MTLScissorRect? = if let secondaryStroke, !secondarySamples.isEmpty {
            opacityCapDirtyRect(for: secondarySamples, stroke: secondaryStroke, texture: texture)
        } else {
            nil
        }
        guard let dirtyRect = unionScissorRects(primaryDirtyRect, secondaryDirtyRect) else {
            return 0
        }

        let compoundSecondaryTexture = usesIndependentCompoundMask
            ? ensureCompoundSecondaryTexture(
                for: session,
                matching: texture,
                commandBuffer: commandBuffer
            )
            : nil
        if usesIndependentCompoundMask, compoundSecondaryTexture == nil {
            return 0
        }

        let accumulationPassDescriptor = MTLRenderPassDescriptor()
        accumulationPassDescriptor.colorAttachments[0].texture = session.alphaTexture
        accumulationPassDescriptor.colorAttachments[0].loadAction = .load
        accumulationPassDescriptor.colorAttachments[0].storeAction = .store

        if !samples.isEmpty,
           let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: accumulationPassDescriptor) {
            let primaryMaskPipelineState: MTLRenderPipelineState
            if usesCompoundBuildUp {
                primaryMaskPipelineState = compoundPrimaryBuildUpMaskPipelineState
            } else if usesIndependentCompoundMask {
                primaryMaskPipelineState = compoundPrimaryMaskPipelineState
            } else {
                primaryMaskPipelineState = opacityCapMaskPipelineState
            }
            encoder.setRenderPipelineState(primaryMaskPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            let primaryCustomTipTexture =
                customTipTexture(for: primaryCustomTipMaskData(for: stroke), role: .primary) ?? defaultTipTexture
            let primaryEnvelopeTipTexture =
                customTipTexture(for: primaryEnvelopeCustomTipMaskData(for: stroke), role: .primaryEnvelope) ??
                primaryCustomTipTexture
            let compoundSecondaryTipTexture =
                customTipTexture(for: compoundSecondaryCustomTipMaskData(for: stroke), role: .compoundSecondary) ??
                defaultTipTexture
            encoder.setFragmentTexture(selectionMaskTexture, index: 0)
            encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
            encoder.setFragmentTexture(primaryCustomTipTexture, index: 2)
            encoder.setFragmentTexture(primaryEnvelopeTipTexture, index: 5)
            encoder.setFragmentTexture(compoundSecondaryTipTexture, index: 6)
            encoder.setFragmentSamplerState(tipSamplerState, index: 1)
            encoder.setScissorRect(dirtyRect)

            var uniformsArray = samples.map {
                makeUniforms(
                    for: $0,
                    stroke: stroke,
                    texture: texture,
                    selectionShape: selectionShape,
                    modeOverride: 0,
                    includeBrushOpacity: true,
                    preservesAlphaWhenAlphaLocked: preservesAlphaWhenAlphaLocked
                )
            }
            setInstancedUniforms(&uniformsArray, encoder: encoder, commandBuffer: commandBuffer)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: uniformsArray.count)

            encoder.endEncoding()
        }

        if usesIndependentCompoundMask,
           secondarySamples.isEmpty == false,
           let compoundSecondaryTexture {
            let secondaryPassDescriptor = MTLRenderPassDescriptor()
            secondaryPassDescriptor.colorAttachments[0].texture = compoundSecondaryTexture
            secondaryPassDescriptor.colorAttachments[0].loadAction = .load
            secondaryPassDescriptor.colorAttachments[0].storeAction = .store

            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: secondaryPassDescriptor) {
                encoder.setRenderPipelineState(
                    usesCompoundBuildUp
                        ? compoundSecondaryBuildUpMaskPipelineState
                        : compoundSecondaryMaskPipelineState
                )
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                let compoundSecondaryTipTexture =
                    customTipTexture(
                        for: compoundSecondaryCustomTipMaskData(for: stroke),
                        role: .compoundSecondary
                    ) ?? defaultTipTexture
                encoder.setFragmentTexture(compoundSecondaryTipTexture, index: 6)
                encoder.setFragmentSamplerState(tipSamplerState, index: 1)
                encoder.setScissorRect(dirtyRect)

                var secondaryUniforms = secondarySamples.map {
                    makeCompoundSecondaryUniforms(
                        for: $0,
                        stroke: stroke,
                        texture: texture,
                        selectionShape: selectionShape
                    )
                }
                setInstancedUniforms(
                    &secondaryUniforms,
                    encoder: encoder,
                    commandBuffer: commandBuffer
                )
                encoder.drawPrimitives(
                    type: .triangleStrip,
                    vertexStart: 0,
                    vertexCount: 4,
                    instanceCount: secondaryUniforms.count
                )
                encoder.endEncoding()
            }
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
            encoder.setFragmentTexture(compoundSecondaryTexture ?? defaultTipTexture, index: 2)
            encoder.setFragmentSamplerState(compositeSamplerState, index: 0)
            encoder.setScissorRect(dirtyRect)

            // Keep the material frame stable for straight segments while avoiding angle wraparound.
            let strokeCenterX: Float
            let strokeCenterY: Float
            let strokeRadius: Float
            let avgJitterDir: Float
            if !samples.isEmpty {
                var sumX: Float = 0
                var sumY: Float = 0
                var sumTangentX: Float = 0
                var sumTangentY: Float = 0
                for s in samples {
                    sumX += Float(s.point.x)
                    sumY += Float(s.point.y)
                    sumTangentX += s.strokeTangent.x
                    sumTangentY += s.strokeTangent.y
                }
                let n = Float(samples.count)
                strokeCenterX = sumX / n
                strokeCenterY = sumY / n
                avgJitterDir = atan2(sumTangentY, sumTangentX) * 180 / .pi + 90
                strokeRadius = max(Float(stroke.brush.size) * 0.5, 0.5)
            } else {
                strokeCenterX = 0; strokeCenterY = 0; strokeRadius = 1; avgJitterDir = 0
            }

            var uniforms = CompositeUniforms(
                brushColor: SIMD4(
                    stroke.color.red,
                    stroke.color.green,
                    stroke.color.blue,
                    stroke.color.alpha
                ),
                mode: stroke.tool == .eraser ? 1 : 0,
                usesCompoundMask: usesIndependentCompoundMask ? 1 : 0,
                paintJitterAmount: stroke.brush.effectivePaintJitterAmount,
                paintContrastAmount: stroke.brush.effectivePaintContrastAmount,
                jitterDirectionDegrees: avgJitterDir,
                paintVariationSeed: stroke.paintVariationSeed,
                canvasWidth: Float(texture.width),
                canvasHeight: Float(texture.height),
                strokeCenterX: strokeCenterX,
                strokeCenterY: strokeCenterY,
                strokeRadius: strokeRadius,
                usesAlphaLock: alphaLockTexture != nil && preservesAlphaWhenAlphaLocked ? 1 : 0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
        }

        return max(samples.count, secondarySamples.count)
    }

    func debugInterpolatedStrokeSamples(
        for stroke: StrokeDescriptor,
        samplingState: inout BrushStrokeSamplingState?
    ) -> [StampSample] {
        interpolatedPoints(for: stroke, samplingState: &samplingState)
    }

    func debugInterpolatedCompoundSecondarySamples(
        for stroke: StrokeDescriptor,
        samplingState: inout BrushStrokeSamplingState?
    ) -> [StampSample] {
        interpolatedPoints(
            for: compoundSecondarySamplingStroke(from: stroke),
            samplingState: &samplingState
        )
    }

    private func opacityCapDirtyRect(
        for samples: [StampSample],
        stroke: StrokeDescriptor,
        texture: MTLTexture
    ) -> MTLScissorRect? {
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

        let unclampedOriginX = Int(floor(minX)) - 1
        let unclampedOriginY = Int(floor(minY)) - 1
        let unclampedEndX = Int(ceil(maxX)) + 1
        let unclampedEndY = Int(ceil(maxY)) + 1

        let originX = min(max(unclampedOriginX, 0), texture.width)
        let originY = min(max(unclampedOriginY, 0), texture.height)
        let endX = min(max(unclampedEndX, 0), texture.width)
        let endY = min(max(unclampedEndY, 0), texture.height)

        guard originX < endX, originY < endY else {
            return nil
        }

        return MTLScissorRect(
            x: originX,
            y: originY,
            width: endX - originX,
            height: endY - originY
        )
    }

    private func unionScissorRects(
        _ lhs: MTLScissorRect?,
        _ rhs: MTLScissorRect?
    ) -> MTLScissorRect? {
        guard let lhs else { return rhs }
        guard let rhs else { return lhs }
        let originX = min(lhs.x, rhs.x)
        let originY = min(lhs.y, rhs.y)
        let endX = max(lhs.x + lhs.width, rhs.x + rhs.width)
        let endY = max(lhs.y + lhs.height, rhs.y + rhs.height)
        return MTLScissorRect(
            x: originX,
            y: originY,
            width: endX - originX,
            height: endY - originY
        )
    }

    private func recordRenderedPixelBounds(
        for samples: [StampSample],
        stroke: StrokeDescriptor,
        texture: MTLTexture,
        samplingState: inout BrushStrokeSamplingState?
    ) {
        guard let dirtyRect = opacityCapDirtyRect(
            for: samples,
            stroke: stroke,
            texture: texture
        ) else {
            return
        }
        let bounds = BrushPixelBounds(
            originX: dirtyRect.x,
            originY: dirtyRect.y,
            width: dirtyRect.width,
            height: dirtyRect.height
        )
        guard !bounds.isEmpty else { return }
        var state = samplingState ?? BrushStrokeSamplingState()
        state.renderedPixelBounds = state.renderedPixelBounds.map {
            $0.union(bounds)
        } ?? bounds
        samplingState = state
    }

    private func makeUniforms(
        for sample: StampSample,
        stroke: StrokeDescriptor,
        texture: MTLTexture,
        selectionShape: SelectionShape?,
        modeOverride: UInt32? = nil,
        includeBrushOpacity: Bool = true,
        preservesAlphaWhenAlphaLocked: Bool = true
    ) -> BrushUniforms {
        let point = sample.point
        let effectivePressure = min(max(point.pressure, 0), 1)
        let sizePressure = max(effectivePressure, 0.01)
        let opacityPressure = max(effectivePressure, 0.005)
        let compoundEnabled = stroke.brush.compoundBrush.enabled && (stroke.tool == .brush || stroke.tool == .eraser)
        let primarySizeResponse = min(max(stroke.brush.pressureSizeAmount, 0), 1)
        let globalSizeResponse = compoundEnabled
            ? min(max(stroke.brush.compoundBrush.globalPressureSizeAmount, 0), 1)
            : 0
        let primaryOpacityResponse = min(max(stroke.brush.pressureOpacityAmount, 0), 1)
        let globalOpacityResponse = compoundEnabled
            ? min(max(stroke.brush.compoundBrush.globalPressureOpacityAmount, 0), 1)
            : primaryOpacityResponse
        let curvedSizePressure = sizeCurvePressure(for: sizePressure, stroke: stroke)
        let primarySizeFactor = (1 - primarySizeResponse) + (primarySizeResponse * curvedSizePressure)
        let globalSizeFactor = compoundEnabled
            ? ((1 - globalSizeResponse) + (globalSizeResponse * curvedSizePressure))
            : 1
        let sizeFactor = (primarySizeFactor * globalSizeFactor) * sample.sizeMultiplier
        let curvedOpacityPressure = opacityCurvePressure(for: opacityPressure, stroke: stroke)
        let compoundPrimaryOpacityFactor = BrushSettings.resolvedPressureFactor(
            responseAmount: primaryOpacityResponse,
            curvedPressure: curvedOpacityPressure
        )
        let compoundGlobalOpacityFactor = compoundEnabled
            ? BrushSettings.resolvedPressureFactor(
                responseAmount: globalOpacityResponse,
                curvedPressure: curvedOpacityPressure
            )
            : compoundPrimaryOpacityFactor
        let compoundSecondary = stroke.brush.compoundBrush.secondary
        let tangent = normalizedStrokeTangent(sample.strokeTangent)
        let tangentDegrees = Float(atan2(tangent.y, tangent.x) * 180.0 / .pi)
        let compoundSecondarySizeFactor = compoundSecondary.resolvedSizeFactor(for: effectivePressure) * globalSizeFactor
        let compoundSecondaryOpacityFactor = compoundSecondary.resolvedOpacityFactor(
            for: opacityPressure,
            pressureSensitivity: stroke.brush.pressureSensitivity
        )
        let compoundSecondaryBaseSize = compoundSecondary.resolvedBaseSize(for: stroke.brush.size)
        let compoundSecondaryDiameterPx = max(compoundSecondaryBaseSize * compoundSecondarySizeFactor, 1)
        let compoundSecondaryAdvancePx = max(
            compoundSecondaryDiameterPx * max(compoundSecondary.spacingPercent, 1) / 100,
            1
        )
        let primarySpacingPx = max(Float(Double(stroke.brush.size) * Double(stroke.brush.spacingPercent) / 100.0), 0.5)
        let primaryStampDiameterPx = max(stroke.brush.size * sizeFactor, 1)
        let automaticBuildUpOpacityCompensationAmount: Float =
            (stroke.tool == .brush || stroke.tool == .eraser) && stroke.brush.buildMode == .buildUp
            ? 1
            : 0
        let buildUpOpacityCompensationAmount = BrushSettings.resolvedBuildUpCompensationAmount(
            automaticCompensationAmount: automaticBuildUpOpacityCompensationAmount,
            brushCompensationAmount: stroke.brush.buildUpOpacityCompensationAmount
        )
        let buildUpOpacitySpacingRatio: Float =
            (stroke.tool == .brush || stroke.tool == .eraser) && stroke.brush.buildMode == .buildUp
            ? min(max(primarySpacingPx / primaryStampDiameterPx, 0.02), 1)
            : 1
        let compoundSecondaryAngleDegrees = compoundSecondary.angleDegrees +
            (compoundSecondary.followsStrokeDirection ? tangentDegrees : 0)
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

        let resolvedOpacity = min(max(includeBrushOpacity ? stroke.brush.opacity : 1, 0), 1)

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
            paintJitterAmount: stroke.brush.effectivePaintJitterAmount,
            paintContrastAmount: stroke.brush.effectivePaintContrastAmount,
            stampSeed: sample.arcLengthPx,
            paintVariationSeed: stroke.paintVariationSeed,
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
            selectionMax: selectionMax,
            usesAlphaLock: stroke.alphaLockEnabled ? 1 : 0,
            preservesAlphaLockAlpha: stroke.alphaLockEnabled && preservesAlphaWhenAlphaLocked ? 1 : 0,
            compoundEnabled: compoundEnabled ? 1 : 0,
            compoundMode: compoundBrushModeCode(stroke.brush.compoundBrush.mode),
            compoundSecondaryShape: brushTipShapeCode(compoundSecondary.tipShape),
            compoundPrimaryMixWeight: stroke.brush.compoundBrush.pressureMix.resolvedPrimaryWeight(for: effectivePressure),
            compoundPrimaryOpacityFactor: compoundPrimaryOpacityFactor,
            compoundGlobalOpacityFactor: compoundGlobalOpacityFactor,
            buildUpOpacityCompensationAmount: buildUpOpacityCompensationAmount,
            buildUpOpacitySpacingRatio: buildUpOpacitySpacingRatio,
            compoundSecondaryOpacityFactor: compoundSecondaryOpacityFactor,
            compoundSecondaryDiameterPx: compoundSecondaryDiameterPx,
            compoundSecondaryAdvancePx: compoundSecondaryAdvancePx,
            compoundSecondarySoftness: compoundSecondary.softness,
            compoundSecondaryRoundness: compoundSecondary.roundness,
            compoundSecondaryAngleDegrees: compoundSecondaryAngleDegrees,
            compoundSecondaryTileRandomRotation: compoundSecondary.tileRandomRotation,
            compoundArcLengthAtCenter: sample.arcLengthPx,
            compoundStrokeTangent: tangent
        )
    }

    private func makeCompoundSecondaryUniforms(
        for sample: StampSample,
        stroke: StrokeDescriptor,
        texture: MTLTexture,
        selectionShape: SelectionShape?
    ) -> BrushUniforms {
        var uniforms = makeUniforms(
            for: sample,
            stroke: stroke,
            texture: texture,
            selectionShape: selectionShape,
            modeOverride: 0,
            includeBrushOpacity: true
        )
        uniforms.radius = max(uniforms.compoundSecondaryDiameterPx * 0.5, 0.5)

        let advance = max(uniforms.compoundSecondaryAdvancePx, 1)
        if stroke.brush.buildMode == .buildUp {
            uniforms.buildUpOpacitySpacingRatio = min(
                max(advance / max(uniforms.compoundSecondaryDiameterPx, 1), 0.02),
                1
            )
        }
        let stampIndex = Int((sample.arcLengthPx / advance).rounded())
        let randomRotation = Float(stableScatterRandom(
            x: sample.point.x,
            y: sample.point.y,
            index: stampIndex,
            salt: 0xA24B_AED4
        ))
        uniforms.compoundSecondaryAngleDegrees +=
            ((randomRotation * 2) - 1) * 180 * uniforms.compoundSecondaryTileRandomRotation
        return uniforms
    }

    private func brushTipShapeCode(_ shape: BrushTipShape) -> UInt32 {
        switch shape {
        case .hardRound:
            return 0
        case .softRound:
            return 1
        case .square:
            return 2
        case .customRound:
            return 3
        }
    }

    private func compoundBrushModeCode(_ mode: CompoundBrushMode) -> UInt32 {
        switch mode {
        case .textureBlend:
            return 0
        case .subtract:
            return 1
        case .intersect:
            return 2
        case .overlay:
            return 3
        }
    }

    private func normalizedStrokeTangent(_ tangent: SIMD2<Float>) -> SIMD2<Float> {
        let length = simd_length(tangent)
        guard length > 0.0001 else {
            return SIMD2<Float>(1, 0)
        }
        return tangent / length
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
                let loggedIndex = sampleIndex
                if RuntimeDiagnostics.brushHotPathLoggingEnabled, loggedIndex < 10 {
                    brushStrokeLogger.debug(
                        "[stamp] index=\(loggedIndex, privacy: .public) x=\(stamped.x, privacy: .public) y=\(stamped.y, privacy: .public) pressure=\(stamped.pressure, privacy: .public)"
                    )
                }
                sampleIndex += 1
                lastSamplePoint = stamped
                distanceSinceLastSample = 0
            }
            distanceSinceLastSample += max(segLen - traveled, 0)
            prevPoint = curPoint
        }
    }

    private static let hermiteLUT: [(h00: Double, h10: Double, h01: Double, h11: Double, t: Double)] = {
        (1...16).map { step in
            let t = Double(step) / 16.0
            let tt = t * t
            let ttt = tt * t
            return (
                h00: (2 * ttt) - (3 * tt) + 1,
                h10: ttt - (2 * tt) + t,
                h01: (-2 * ttt) + (3 * tt),
                h11: ttt - tt,
                t: t
            )
        }
    }()

    private func sampleHermiteSegment(
        start: StrokePoint,
        end: StrokePoint,
        startTangent: SIMD2<Double>,
        endTangent: SIMD2<Double>,
        spacing: Double,
        distanceSinceLastSample: inout Double,
        lastSamplePoint: inout StrokePoint,
        sampleIndex: inout Int,
        baseAngle: Float,
        stroke: StrokeDescriptor,
        result: inout [StampSample]
    ) {
        var prevPoint = start
        for coeffs in Self.hermiteLUT {
            let curPoint = StrokePoint(
                x: (coeffs.h00 * start.x) + (coeffs.h10 * startTangent.x) + (coeffs.h01 * end.x) + (coeffs.h11 * endTangent.x),
                y: (coeffs.h00 * start.y) + (coeffs.h10 * startTangent.y) + (coeffs.h01 * end.y) + (coeffs.h11 * endTangent.y),
                pressure: start.pressure + ((end.pressure - start.pressure) * Float(coeffs.t))
            )
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
                let loggedIndex = sampleIndex
                if RuntimeDiagnostics.brushHotPathLoggingEnabled, loggedIndex < 10 {
                    brushStrokeLogger.debug(
                        "[stamp] index=\(loggedIndex, privacy: .public) x=\(stamped.x, privacy: .public) y=\(stamped.y, privacy: .public) pressure=\(stamped.pressure, privacy: .public)"
                    )
                }
                sampleIndex += 1
                lastSamplePoint = stamped
                distanceSinceLastSample = 0
            }
            distanceSinceLastSample += max(segLen - traveled, 0)
            prevPoint = curPoint
        }
    }

    private func sampleStartSegment(
        a: StrokePoint,
        b: StrokePoint,
        c: StrokePoint,
        spacing: Double,
        distanceSinceLastSample: inout Double,
        lastSamplePoint: inout StrokePoint,
        sampleIndex: inout Int,
        baseAngle: Float,
        stroke: StrokeDescriptor,
        result: inout [StampSample]
    ) {
        let startTangent = SIMD2(
            ((-3 * a.x) + (4 * b.x) - c.x) / 2,
            ((-3 * a.y) + (4 * b.y) - c.y) / 2
        )
        let endTangent = SIMD2(
            (c.x - a.x) / 2,
            (c.y - a.y) / 2
        )
        sampleHermiteSegment(
            start: a,
            end: b,
            startTangent: startTangent,
            endTangent: endTangent,
            spacing: spacing,
            distanceSinceLastSample: &distanceSinceLastSample,
            lastSamplePoint: &lastSamplePoint,
            sampleIndex: &sampleIndex,
            baseAngle: baseAngle,
            stroke: stroke,
            result: &result
        )
    }

    private func sampleTailSegment(
        a: StrokePoint,
        b: StrokePoint,
        c: StrokePoint,
        spacing: Double,
        distanceSinceLastSample: inout Double,
        lastSamplePoint: inout StrokePoint,
        sampleIndex: inout Int,
        baseAngle: Float,
        stroke: StrokeDescriptor,
        result: inout [StampSample]
    ) {
        let startTangent = SIMD2(
            (c.x - a.x) / 2,
            (c.y - a.y) / 2
        )
        let endTangent = SIMD2(
            ((3 * c.x) - (4 * b.x) + a.x) / 2,
            ((3 * c.y) - (4 * b.y) + a.y) / 2
        )
        sampleHermiteSegment(
            start: b,
            end: c,
            startTangent: startTangent,
            endTangent: endTangent,
            spacing: spacing,
            distanceSinceLastSample: &distanceSinceLastSample,
            lastSamplePoint: &lastSamplePoint,
            sampleIndex: &sampleIndex,
            baseAngle: baseAngle,
            stroke: stroke,
            result: &result
        )
    }

    private func sampleLinearSegment(
        start: StrokePoint,
        end: StrokePoint,
        spacing: Double,
        distanceSinceLastSample: inout Double,
        lastSamplePoint: inout StrokePoint,
        sampleIndex: inout Int,
        baseAngle: Float,
        stroke: StrokeDescriptor,
        result: inout [StampSample]
    ) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let segLen = sqrt(dx * dx + dy * dy)
        guard segLen > 1e-6 else { return }

        let dirDeg = Float(atan2(dy, dx) * 180.0 / .pi)
        let segAngleDeg = baseAngle + (stroke.brush.followsStrokeDirection ? dirDeg : 0)

        var traveled = 0.0
        while distanceSinceLastSample + (segLen - traveled) >= spacing {
            let remaining = spacing - distanceSinceLastSample
            traveled += remaining
            let f = traveled / segLen
            let stamped = StrokePoint(
                x: start.x + dx * f,
                y: start.y + dy * f,
                pressure: start.pressure + (end.pressure - start.pressure) * Float(f)
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
            let loggedIndex = sampleIndex
            if RuntimeDiagnostics.brushHotPathLoggingEnabled, loggedIndex < 10 {
                brushStrokeLogger.debug(
                    "[stamp] index=\(loggedIndex, privacy: .public) x=\(stamped.x, privacy: .public) y=\(stamped.y, privacy: .public) pressure=\(stamped.pressure, privacy: .public)"
                )
            }
            sampleIndex += 1
            lastSamplePoint = stamped
            distanceSinceLastSample = 0
        }
        distanceSinceLastSample += max(segLen - traveled, 0)
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

        var state = samplingState ?? BrushStrokeSamplingState()
        if !stroke.skipLeadingStamp {
            state = BrushStrokeSamplingState()
        }

        // 把本次收到的所有点追加进 look-ahead 缓冲。
        // mouseDragged が lastSample を先頭に付けて送ってくるので、
        // pendingInputPoints の末尾点と stroke.points[0] が同一点になる場合がある。
        // その重複を除去してから追加する。
        let incomingPoints = stroke.points
        var incomingStartIndex = incomingPoints.startIndex
        if let tail = state.pendingInputPoints.last,
           let head = incomingPoints.first,
           abs(tail.x - head.x) < 0.001, abs(tail.y - head.y) < 0.001 {
            incomingStartIndex = incomingPoints.index(after: incomingStartIndex)
        }
        if incomingStartIndex < incomingPoints.endIndex {
            state.pendingInputPoints.append(contentsOf: incomingPoints[incomingStartIndex...])
        }
        PerformanceAuditStore.shared.recordInt(
            "StageOneBrushRenderer.pendingInputPoints.count",
            value: state.pendingInputPoints.count
        )

        var result: [StampSample] = []
        let pts = state.pendingInputPoints
        let shouldEmitLeadingStamp = !state.hasEmittedLeadingStamp && pts.count >= 2
        if shouldEmitLeadingStamp {
            let firstDir = strokeDirectionDegrees(from: pts[0], to: pts[1])
            result.append(makeStampSample(
                point: pts[0],
                index: state.nextSampleIndex,
                segmentAngleDegrees: baseAngle + (stroke.brush.followsStrokeDirection ? firstDir : 0),
                jitterDirectionDegrees: firstDir,
                stroke: stroke
            ))
            if RuntimeDiagnostics.brushHotPathLoggingEnabled, state.nextSampleIndex < 10 {
                brushStrokeLogger.debug(
                    "[stamp] index=\(state.nextSampleIndex, privacy: .public) x=\(pts[0].x, privacy: .public) y=\(pts[0].y, privacy: .public) pressure=\(pts[0].pressure, privacy: .public)"
                )
            }
            state.nextSampleIndex += 1
            state.distanceSinceLastSample = spacing * 0.5
            state.lastSamplePoint = pts[0]
            state.hasEmittedLeadingStamp = true
        }

        if pts.count < 2 {
            if state.isFlushing, let only = pts.first, !state.hasEmittedLeadingStamp {
                result.append(StampSample(
                    point: only,
                    angleDegrees: baseAngle,
                    jitterDirectionDegrees: 0,
                    sizeMultiplier: 1,
                    arcLengthPx: Float(state.nextSampleIndex) * Float(spacing),
                    strokeTangent: SIMD2<Float>(1, 0)
                ))
                if RuntimeDiagnostics.brushHotPathLoggingEnabled, state.nextSampleIndex < 10 {
                    brushStrokeLogger.debug(
                        "[stamp] index=\(state.nextSampleIndex, privacy: .public) x=\(only.x, privacy: .public) y=\(only.y, privacy: .public) pressure=\(only.pressure, privacy: .public)"
                    )
                }
                state.hasEmittedLeadingStamp = true
                state.nextSampleIndex += 1
            }
            if state.isFlushing {
                state = BrushStrokeSamplingState()
            }
            samplingState = state
            return stabilizedPressureSamples(result, stroke: stroke)
        }

        while state.nextSegmentIndexToCommit < pts.count - 1 {
            let segmentIndex = state.nextSegmentIndexToCommit

            if !state.isFlushing {
                if segmentIndex == 0 {
                    guard pts.count >= 3 else { break }
                } else {
                    guard segmentIndex + 2 < pts.count else { break }
                }
            }

            var localDistanceSinceLastSample = state.distanceSinceLastSample
            var localSampleIndex = state.nextSampleIndex
            var localLastSamplePoint: StrokePoint = state.lastSamplePoint ?? pts[segmentIndex]

            if segmentIndex == 0 {
                if pts.count >= 3 {
                    sampleStartSegment(
                        a: pts[0],
                        b: pts[1],
                        c: pts[2],
                        spacing: spacing,
                        distanceSinceLastSample: &localDistanceSinceLastSample,
                        lastSamplePoint: &localLastSamplePoint,
                        sampleIndex: &localSampleIndex,
                        baseAngle: baseAngle,
                        stroke: stroke,
                        result: &result
                    )
                } else if state.isFlushing {
                    sampleLinearSegment(
                        start: pts[0],
                        end: pts[1],
                        spacing: spacing,
                        distanceSinceLastSample: &localDistanceSinceLastSample,
                        lastSamplePoint: &localLastSamplePoint,
                        sampleIndex: &localSampleIndex,
                        baseAngle: baseAngle,
                        stroke: stroke,
                        result: &result
                    )
                } else {
                    break
                }
            } else if state.isFlushing && segmentIndex == pts.count - 2 {
                sampleTailSegment(
                    a: pts[segmentIndex - 1],
                    b: pts[segmentIndex],
                    c: pts[segmentIndex + 1],
                    spacing: spacing,
                    distanceSinceLastSample: &localDistanceSinceLastSample,
                    lastSamplePoint: &localLastSamplePoint,
                    sampleIndex: &localSampleIndex,
                    baseAngle: baseAngle,
                    stroke: stroke,
                    result: &result
                )
            } else {
                let p0 = pts[segmentIndex - 1]
                let p1 = pts[segmentIndex]
                let p2 = pts[segmentIndex + 1]
                let p3 = pts[segmentIndex + 2]
                sampleCatmullSegment(
                    p0: p0,
                    p1: p1,
                    p2: p2,
                    p3: p3,
                    spacing: spacing,
                    distanceSinceLastSample: &localDistanceSinceLastSample,
                    lastSamplePoint: &localLastSamplePoint,
                    sampleIndex: &localSampleIndex,
                    baseAngle: baseAngle,
                    stroke: stroke,
                    result: &result
                )
            }

            state.distanceSinceLastSample = localDistanceSinceLastSample
            state.nextSampleIndex = localSampleIndex
            state.lastSamplePoint = localLastSamplePoint
            state.nextSegmentIndexToCommit += 1
        }

        trimPendingInputPoints(&state)

        if state.isFlushing {
            state = BrushStrokeSamplingState(
                renderedPixelBounds: state.renderedPixelBounds
            )
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

        let compoundEnabled = stroke.brush.compoundBrush.enabled
        let opacityWeight = compoundEnabled
            ? max(
                min(max(stroke.brush.compoundBrush.globalPressureOpacityAmount, 0), 1),
                max(
                    min(max(stroke.brush.pressureOpacityAmount, 0), 1),
                    min(max(stroke.brush.compoundBrush.secondary.pressureOpacityAmount, 0), 1)
                )
            )
            : min(max(stroke.brush.pressureOpacityAmount, 0), 1)
        let sizeWeight = compoundEnabled
            ? max(
                min(max(stroke.brush.compoundBrush.globalPressureSizeAmount, 0), 1),
                max(
                    min(max(stroke.brush.pressureSizeAmount, 0), 1),
                    min(max(stroke.brush.compoundBrush.secondary.pressureSizeAmount, 0), 1)
                )
            )
            : min(max(stroke.brush.pressureSizeAmount, 0), 1)
        let smoothingStrength = max(opacityWeight * 0.7, sizeWeight * 0.45)
        guard smoothingStrength > 0.0001 else {
            return samples
        }

        let previousWeight = min(max(0.08 + (0.14 * smoothingStrength), 0), 0.20)
        var stabilized = samples

        for index in samples.indices {
            guard index > samples.startIndex else {
                stabilized[index].point.pressure = min(max(samples[index].point.pressure, 0), 1)
                continue
            }

            let currentPressure = samples[index].point.pressure
            let previousPressure = stabilized[index - 1].point.pressure
            let pressureDelta = currentPressure - previousPressure

            // Keep smoothing causal so later heavier pressure never lifts earlier
            // light-touch stamps. Also reduce carry-over aggressively when the
            // user is easing off pressure, so the stroke can get light quickly.
            let carriedWeight: Float
            switch pressureDelta {
            case ..<(-0.06):
                carriedWeight = previousWeight * 0.12
            case ..<0:
                carriedWeight = previousWeight * 0.30
            case ..<0.08:
                carriedWeight = previousWeight * 0.72
            default:
                carriedWeight = previousWeight
            }

            let stabilizedPressure = (currentPressure * (1 - carriedWeight)) + (previousPressure * carriedWeight)
            stabilized[index].point.pressure = min(max(stabilizedPressure, 0), 1)
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
        let sizeJitterAmount = min(max(stroke.brush.sizeJitterAmount, 0), 1)
        let angleJitterAmount = min(max(stroke.brush.angleJitterAmount, 0), 1)
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
        let sizeMultiplier = BrushSettings.resolvedSizeJitterMultiplier(
            randomUnitValue: sizeRandom,
            amount: sizeJitterAmount
        )
        let angleJitter = (rotationRandom * 2 - 1) * 180 * angleJitterAmount
        let offsetPoint = StrokePoint(
            x: point.x + offsetX,
            y: point.y + offsetY,
            pressure: point.pressure
        )
        let radians = Double(jitterDirectionDegrees) * (.pi / 180.0)
        let spacingPx = max(Float(Double(stroke.brush.size) * Double(stroke.brush.spacingPercent) / 100.0), 0.5)
        return StampSample(
            point: offsetPoint,
            angleDegrees: segmentAngleDegrees + angleJitter,
            jitterDirectionDegrees: jitterDirectionDegrees,
            sizeMultiplier: sizeMultiplier,
            arcLengthPx: Float(index) * spacingPx,
            strokeTangent: SIMD2(Float(cos(radians)), Float(sin(radians)))
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
        BrushSettings.resolvedOpacityCurvePressure(
            pressure: pressure,
            pressureSensitivity: stroke.brush.pressureSensitivity,
            state: stroke.brush.resolvedOpacityPressureCurveState
        )
    }

    private func pressureResponsePressure(for pressure: Float, stroke: StrokeDescriptor) -> Float {
        BrushSettings.remappedOpacityPressure(
            pressure: pressure,
            pressureSensitivity: stroke.brush.pressureSensitivity
        )
    }

    private func sizeCurvePressure(for pressure: Float, stroke: StrokeDescriptor) -> Float {
        BrushSettings.resolvedSizeCurvePressure(
            pressure: pressure,
            pressureSensitivity: stroke.brush.pressureSensitivity,
            sizeLowerBound: stroke.brush.sizeLowerBound,
            state: stroke.brush.resolvedSizePressureCurveState
        )
    }

    private func opacityCapRadius(for point: StrokePoint, stroke: StrokeDescriptor) -> Double {
        let effectivePressure = min(max(point.pressure, 0), 1)
        let sizePressure = max(effectivePressure, 0.01)
        let primarySizeResponse = min(max(stroke.brush.pressureSizeAmount, 0), 1)
        let globalSizeResponse = stroke.brush.compoundBrush.enabled
            ? min(max(stroke.brush.compoundBrush.globalPressureSizeAmount, 0), 1)
            : 0
        let curvedSizePressure = sizeCurvePressure(for: sizePressure, stroke: stroke)
        let primarySizeFactor = (1 - primarySizeResponse) + (primarySizeResponse * curvedSizePressure)
        let globalSizeFactor = stroke.brush.compoundBrush.enabled
            ? ((1 - globalSizeResponse) + (globalSizeResponse * curvedSizePressure))
            : 1
        let sizeFactor = primarySizeFactor * globalSizeFactor
        return max(Double((stroke.brush.size * sizeFactor) / 2), 0.5)
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

    @discardableResult
    func debugEncodeSmudgeStrokeUsingFrozenTexture(
        stroke: StrokeDescriptor,
        frozenSourceTexture: MTLTexture,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        samplingState: inout BrushStrokeSamplingState?
    ) -> Int {
        let samples = interpolatedPoints(for: stroke, samplingState: &samplingState)
        return encodeSmudgeStroke(
            samples: samples,
            stroke: stroke,
            into: texture,
            commandBuffer: commandBuffer,
            alphaLockTexture: nil,
            gatheredColorsTexture: nil,
            frozenSourceTexture: frozenSourceTexture
        )
    }

    private func makeSmudgeGatheredColorsTexture(
        from texture: MTLTexture,
        samples: [StampSample],
        commandBuffer: MTLCommandBuffer
    ) -> MTLTexture? {
        let auditEnabled = PerformanceAuditStore.shared.isRecordingEnabled
        let startNs = auditEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        defer {
            if auditEnabled {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000
                PerformanceAuditStore.shared.recordDuration("StageOneBrushRenderer.smudgeGatherPass", ms: ms)
            }
        }

        guard !samples.isEmpty else {
            return nil
        }

        let gatherInputs = samples.map { sample in
            SmudgeGatherInput(
                center: SIMD2(
                    Float(sample.point.x),
                    Float(sample.point.y)
                )
            )
        }
        let inputBufferLength = MemoryLayout<SmudgeGatherInput>.stride * gatherInputs.count
        let gatherUniforms = SmudgeGatherUniforms(
            sampleCount: UInt32(samples.count),
            canvasSize: SIMD2(Float(texture.width), Float(texture.height))
        )

        let inputBuffer = gatherInputs.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let baseAddress = bytes.baseAddress else { return nil }
            return device.makeBuffer(
                bytes: baseAddress,
                length: inputBufferLength,
                options: .storageModeShared
            )
        }

        let outputTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: samples.count,
            height: 1,
            mipmapped: false
        )
        outputTextureDescriptor.usage = [.shaderRead, .shaderWrite]
        outputTextureDescriptor.storageMode = .private

        guard
            let inputBuffer,
            let gatheredColorsTexture = device.makeTexture(descriptor: outputTextureDescriptor),
            let computeEncoder = commandBuffer.makeComputeCommandEncoder()
        else {
            return nil
        }

        PerformanceAuditStore.shared.recordInt(
            "StageOneBrushRenderer.smudgeGather.sampleCount",
            value: samples.count
        )

        computeEncoder.setComputePipelineState(smudgeGatherPipelineState)
        computeEncoder.setBuffer(inputBuffer, offset: 0, index: 0)
        var mutableGatherUniforms = gatherUniforms
        computeEncoder.setBytes(
            &mutableGatherUniforms,
            length: MemoryLayout<SmudgeGatherUniforms>.stride,
            index: 1
        )
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setTexture(gatheredColorsTexture, index: 1)

        let threadWidth = min(smudgeGatherPipelineState.maxTotalThreadsPerThreadgroup, samples.count)
        computeEncoder.dispatchThreads(
            MTLSize(width: samples.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: max(threadWidth, 1), height: 1, depth: 1)
        )
        computeEncoder.endEncoding()
        return gatheredColorsTexture
    }

    private func encodeSmudgeStroke(
        samples: [StampSample],
        stroke: StrokeDescriptor,
        into texture: MTLTexture,
        commandBuffer: MTLCommandBuffer,
        alphaLockTexture: MTLTexture?,
        preservesAlphaWhenAlphaLocked: Bool = true,
        gatheredColorsTexture: MTLTexture?,
        frozenSourceTexture: MTLTexture?
    ) -> Int {
        guard !samples.isEmpty else {
            return 0
        }

        let passDescriptor = MTLRenderPassDescriptor()
        passDescriptor.colorAttachments[0].texture = texture
        passDescriptor.colorAttachments[0].loadAction = .load
        passDescriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return 0
        }

        let selectionShape = stroke.selectionShape?.clamped(
            to: CanvasSize(width: texture.width, height: texture.height)
        )
        if let selectionShape, selectionShape.isEmpty {
            encoder.endEncoding()
            return 0
        }

        encoder.setRenderPipelineState(
            frozenSourceTexture == nil ? smudgePipelineState : smudgeFrozenTexturePipelineState
        )
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)

        let selectionMaskTexture = makeSelectionMaskTexture(
            for: selectionShape,
            canvasSize: CanvasSize(width: texture.width, height: texture.height)
        )
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 1)
        if let frozenSourceTexture {
            encoder.setFragmentTexture(frozenSourceTexture, index: 4)
        } else if let gatheredColorsTexture {
            encoder.setFragmentTexture(gatheredColorsTexture, index: 4)
        }
        let primaryCustomTipTexture =
            customTipTexture(for: primaryCustomTipMaskData(for: stroke), role: .primary) ?? defaultTipTexture
        let primaryEnvelopeTipTexture =
            customTipTexture(for: primaryEnvelopeCustomTipMaskData(for: stroke), role: .primaryEnvelope) ??
            primaryCustomTipTexture
        let compoundSecondaryTipTexture =
            customTipTexture(for: compoundSecondaryCustomTipMaskData(for: stroke), role: .compoundSecondary) ??
            defaultTipTexture
        encoder.setFragmentTexture(primaryCustomTipTexture, index: 2)
        encoder.setFragmentTexture(primaryEnvelopeTipTexture, index: 5)
        encoder.setFragmentTexture(compoundSecondaryTipTexture, index: 6)
        encoder.setFragmentSamplerState(tipSamplerState, index: 1)

        var uniformsArray = samples.map {
            makeUniforms(for: $0, stroke: stroke, texture: texture, selectionShape: selectionShape)
        }
        setInstancedUniforms(&uniformsArray, encoder: encoder, commandBuffer: commandBuffer)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: uniformsArray.count)

        encoder.endEncoding()
        return samples.count
    }

    private func trimPendingInputPoints(_ state: inout BrushStrokeSamplingState) {
        guard !state.isFlushing else {
            return
        }
        let retainStartIndex = max(state.nextSegmentIndexToCommit - 1, 0)
        let maxPendingInputPoints = 64
        var trimCount = retainStartIndex
        if state.pendingInputPoints.count - trimCount > maxPendingInputPoints {
            let overflow = state.pendingInputPoints.count - trimCount - maxPendingInputPoints
            trimCount += overflow
        }
        guard trimCount > 0 else {
            return
        }
        if trimCount >= state.pendingInputPoints.count / 2 {
            state.pendingInputPoints = Array(state.pendingInputPoints.dropFirst(trimCount))
        } else {
            state.pendingInputPoints.removeFirst(trimCount)
        }
        state.nextSegmentIndexToCommit = max(0, state.nextSegmentIndexToCommit - trimCount)
    }

    private func primaryCustomTipMaskData(for stroke: StrokeDescriptor) -> Data? {
        guard stroke.brush.tipShape == .customRound else {
            return nil
        }
        return stroke.brush.customTipMaskData
    }

    private func primaryEnvelopeCustomTipMaskData(for stroke: StrokeDescriptor) -> Data? {
        guard stroke.brush.tipShape == .customRound else {
            return nil
        }
        return stroke.brush.customTipEnvelopeMaskData
    }

    private func compoundSecondaryCustomTipMaskData(for stroke: StrokeDescriptor) -> Data? {
        guard stroke.brush.compoundBrush.secondary.tipShape == .customRound else {
            return nil
        }
        return stroke.brush.compoundBrush.secondary.customTipMaskData
    }

    private func customTipTexture(for data: Data?, role: CustomTipTextureRole) -> MTLTexture? {
        guard let sourceData = data else {
            switch role {
            case .primary:
                cachedPrimaryCustomTipSourceData = nil
                cachedPrimaryCustomTipTexture = nil
            case .primaryEnvelope:
                cachedPrimaryEnvelopeCustomTipSourceData = nil
                cachedPrimaryEnvelopeCustomTipTexture = nil
            case .compoundSecondary:
                cachedCompoundSecondaryCustomTipSourceData = nil
                cachedCompoundSecondaryCustomTipTexture = nil
            }
            return nil
        }

        switch role {
        case .primary:
            if cachedPrimaryCustomTipSourceData == sourceData, let cachedPrimaryCustomTipTexture {
                return cachedPrimaryCustomTipTexture
            }
        case .primaryEnvelope:
            if cachedPrimaryEnvelopeCustomTipSourceData == sourceData, let cachedPrimaryEnvelopeCustomTipTexture {
                return cachedPrimaryEnvelopeCustomTipTexture
            }
        case .compoundSecondary:
            if cachedCompoundSecondaryCustomTipSourceData == sourceData, let cachedCompoundSecondaryCustomTipTexture {
                return cachedCompoundSecondaryCustomTipTexture
            }
        }

        guard let data = resampledCustomTipData(sourceData) else {
            switch role {
            case .primary:
                cachedPrimaryCustomTipSourceData = nil
                cachedPrimaryCustomTipTexture = nil
            case .primaryEnvelope:
                cachedPrimaryEnvelopeCustomTipSourceData = nil
                cachedPrimaryEnvelopeCustomTipTexture = nil
            case .compoundSecondary:
                cachedCompoundSecondaryCustomTipSourceData = nil
                cachedCompoundSecondaryCustomTipTexture = nil
            }
            return nil
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

        switch role {
        case .primary:
            cachedPrimaryCustomTipSourceData = sourceData
            cachedPrimaryCustomTipTexture = texture
        case .primaryEnvelope:
            cachedPrimaryEnvelopeCustomTipSourceData = sourceData
            cachedPrimaryEnvelopeCustomTipTexture = texture
        case .compoundSecondary:
            cachedCompoundSecondaryCustomTipSourceData = sourceData
            cachedCompoundSecondaryCustomTipTexture = texture
        }
        return texture
    }

    private func resampledCustomTipData(_ data: Data?) -> Data? {
        guard let data else { return nil }
        let side = Int(Double(data.count).squareRoot())
        guard side > 0, side * side == data.count else { return nil }

        if side == customTipMaskResolution {
            return data
        }

        debugCustomTipResampleCount += 1

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
