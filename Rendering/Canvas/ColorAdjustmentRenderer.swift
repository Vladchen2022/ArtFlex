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
    var selectedHueDegrees: Float
    var hueStrength: Float
    var brightness: Float
    var contrast: Float
    var purity: Float
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
            float selectedHueDegrees;
            float hueStrength;
            float brightness;
            float contrast;
            float purity;
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
            float3 adjustedColor = applyColorAdjustments(baseColor, uniforms);
            float4 adjustedPremultiplied = float4(adjustedColor * base.a, base.a);
            return mix(base, adjustedPremultiplied, influence);
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
        overlayOnly: Bool,
        effectRegion: MTLRegion?,
        commandBuffer: MTLCommandBuffer
    ) {
        let copyRegion = effectRegion ?? MTLRegionMake2D(0, 0, sourceTexture.width, sourceTexture.height)
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
        var uniforms = ColorAdjustmentPreviewUniforms(
            canvasSize: SIMD2(
                UInt32(sourceTexture.width),
                UInt32(sourceTexture.height)
            ),
            overlayOnly: overlayOnly || parameters.isNeutral ? 1 : 0,
            maskReadMode: maskReadMode == .maskRed ? 0 : 1,
            selectedHueDegrees: parameters.selectedHueDegrees,
            hueStrength: parameters.hueStrength,
            brightness: parameters.brightness,
            contrast: parameters.contrast,
            purity: parameters.purity
        )

        encoder.setRenderPipelineState(previewPipelineState)
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<ColorAdjustmentVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(maskTexture ?? fallbackMaskTexture, index: 1)
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
}
