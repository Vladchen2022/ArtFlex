import Foundation
import Metal

enum LABLuminosityPostProcessorError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction(String)
    case pipelineState(Error)

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile LABLuminosityPostProcessor shader library: \(error.localizedDescription)"
        case .missingFunction(let name):
            return "Missing LABLuminosityPostProcessor shader function: \(name)"
        case .pipelineState(let error):
            return "Failed to create LABLuminosityPostProcessor pipeline: \(error.localizedDescription)"
        }
    }
}

private struct FullscreenVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
}

final class LABLuminosityPostProcessor {
    private let pipelineState: MTLRenderPipelineState
    private let samplerState: MTLSamplerState

    init(device: MTLDevice) throws {
        // sRGB → linear → XYZ → LAB L channel
        // CIE standard: L* = 116 * f(Y/Yn) - 16, where f(t) = t^(1/3) if t > (6/29)^3 else (29/6)^2 * t/3 + 4/29
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct FullscreenVertex {
            float2 position;
            float2 texCoord;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
        };

        vertex VertexOut labLuminosityVertex(
            const device FullscreenVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            VertexOut out;
            out.position = float4(vertices[vertexID].position, 0.0, 1.0);
            out.texCoord = vertices[vertexID].texCoord;
            return out;
        }

        // sRGB companding → linear
        static float srgbToLinear(float c) {
            return (c <= 0.04045f) ? (c / 12.92f) : pow((c + 0.055f) / 1.055f, 2.4f);
        }

        // CIE LAB f function
        static float labF(float t) {
            const float delta = 6.0f / 29.0f;
            const float delta3 = delta * delta * delta; // (6/29)^3
            return (t > delta3) ? pow(t, 1.0f / 3.0f) : (t / (3.0f * delta * delta) + 4.0f / 29.0f);
        }

        fragment float4 labLuminosityFragment(
            VertexOut in [[stage_in]],
            texture2d<float> sourceTexture [[texture(0)]],
            sampler sourceSampler [[sampler(0)]]
        ) {
            float4 color = sourceTexture.sample(sourceSampler, in.texCoord);

            // sRGB → linear RGB
            float r = srgbToLinear(color.r);
            float g = srgbToLinear(color.g);
            float b = srgbToLinear(color.b);

            // Linear RGB → CIE XYZ (D65 illuminant)
            // We only need Y for L* calculation
            float Y = 0.2126729f * r + 0.7151522f * g + 0.0721750f * b;

            // Y → L* (D65 reference white Yn = 1.0)
            float Lstar = 116.0f * labF(Y) - 16.0f;

            // L* range is [0, 100], normalize to [0, 1]
            float luminance = Lstar / 100.0f;

            // Re-encode to sRGB gamma for display
            float displayValue = (luminance <= 0.0031308f)
                ? (luminance * 12.92f)
                : (1.055f * pow(luminance, 1.0f / 2.4f) - 0.055f);

            return float4(displayValue, displayValue, displayValue, color.a);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw LABLuminosityPostProcessorError.shaderLibrary(error)
        }

        guard
            let vertexFunction = library.makeFunction(name: "labLuminosityVertex"),
            let fragmentFunction = library.makeFunction(name: "labLuminosityFragment")
        else {
            throw LABLuminosityPostProcessorError.missingFunction("labLuminosityVertex/labLuminosityFragment")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.colorAttachments[0].isBlendingEnabled = false

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw LABLuminosityPostProcessorError.pipelineState(error)
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .nearest
        samplerDescriptor.magFilter = .nearest
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            throw LABLuminosityPostProcessorError.pipelineState(
                NSError(domain: "LABLuminosityPostProcessor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create sampler state"])
            )
        }
        self.samplerState = sampler
    }

    /// Encodes a fullscreen pass that reads from `sourceTexture` and writes LAB L-channel grayscale
    /// into the render pass described by `renderPassDescriptor`.
    func encode(
        sourceTexture: MTLTexture,
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        let vertices: [FullscreenVertex] = [
            FullscreenVertex(position: SIMD2(-1, -1), texCoord: SIMD2(0, 1)),
            FullscreenVertex(position: SIMD2(1, -1), texCoord: SIMD2(1, 1)),
            FullscreenVertex(position: SIMD2(-1, 1), texCoord: SIMD2(0, 0)),
            FullscreenVertex(position: SIMD2(1, 1), texCoord: SIMD2(1, 0))
        ]

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(
            vertices,
            length: MemoryLayout<FullscreenVertex>.stride * vertices.count,
            index: 0
        )
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
    }
}
