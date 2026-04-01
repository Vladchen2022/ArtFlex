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
    var colorJitterAmount: Float
    var usesSelectionMask: Float
}

final class LinearGradientRenderer {
    private let device: MTLDevice
    private let pipelineState: MTLRenderPipelineState
    private let fallbackSelectionMaskTexture: MTLTexture
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
            float colorJitterAmount;
            float usesSelectionMask;
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

        float hash12(float2 point) {
            return fract(sin(dot(point, float2(127.1, 311.7))) * 43758.5453123);
        }

        float3 jitteredGradientSrgbColor(
            float3 srgbColor,
            float2 noiseCoord,
            float amount
        ) {
            if (amount <= 0.001) {
                return srgbColor;
            }

            float2 macroCell = floor(noiseCoord * (3.0 + amount * 5.0));
            float2 fineCell = floor(noiseCoord * (8.0 + amount * 14.0));

            float hueRandom = mix(hash12(macroCell + float2(1.0, 7.0)), hash12(fineCell + float2(17.0, 5.0)), 0.35);
            float saturationRandom = mix(hash12(macroCell + float2(31.0, 11.0)), hash12(fineCell + float2(47.0, 19.0)), 0.45);
            float valueRandom = mix(hash12(macroCell + float2(61.0, 23.0)), hash12(fineCell + float2(79.0, 29.0)), 0.45);

            float3 hsv = rgbToHsv(srgbColor);
            float hueOffset = ((hueRandom * 2.0) - 1.0) * (0.045 * amount);
            float saturationOffset = ((saturationRandom * 2.0) - 1.0) * (0.22 * amount);
            float valueOffset = ((valueRandom * 2.0) - 1.0) * (0.28 * amount);

            hsv.x = fract(hsv.x + hueOffset + 1.0);
            hsv.y = clamp(hsv.y + saturationOffset + (0.05 * amount), 0.0, 1.0);
            hsv.z = clamp(hsv.z + valueOffset, 0.0, 1.0);
            return hsvToRgb(hsv);
        }

        fragment float4 linearGradientFragmentShader(
            VertexOut in [[stage_in]],
            constant LinearGradientUniforms &uniforms [[buffer(1)]],
            texture2d<float> selectionMask [[texture(0)]]
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
            float easedAlpha = 1.0 - smoothstep(0.0, 1.0, t);
            float alpha = easedAlpha * uniforms.color.a * maskAlpha;
            float2 axisDirection = axis / axisLength;
            float2 perpendicularDirection = float2(-axisDirection.y, axisDirection.x);
            float along = dot(in.canvasPosition - uniforms.pointA, axisDirection) / axisLength;
            float across = dot(in.canvasPosition - uniforms.pointA, perpendicularDirection) / axisLength;
            float2 noiseCoord = float2((along * 6.0) + (across * 1.75), across * 5.0);
            float3 jitteredColor = jitteredGradientSrgbColor(
                uniforms.color.rgb,
                noiseCoord,
                clamp(uniforms.colorJitterAmount, 0.0, 1.0)
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
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        pointA: CanvasPoint,
        pointB: CanvasPoint,
        pointC: CanvasPoint,
        color: RGBAColor,
        colorJitterAmount: Float = 0,
        selectionShape: SelectionShape? = nil
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
            colorJitterAmount: colorJitterAmount,
            usesSelectionMask: selectionShape == nil ? 0 : 1
        )

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBytes(vertices, length: MemoryLayout<LinearGradientVertex>.stride * vertices.count, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LinearGradientUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LinearGradientUniforms>.stride, index: 1)
        encoder.setFragmentTexture(selectionMaskTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
        encoder.endEncoding()
    }

    func render(
        into texture: MTLTexture,
        pointA: CanvasPoint,
        pointB: CanvasPoint,
        pointC: CanvasPoint,
        color: RGBAColor,
        colorJitterAmount: Float = 0,
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
            colorJitterAmount: colorJitterAmount,
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
}
