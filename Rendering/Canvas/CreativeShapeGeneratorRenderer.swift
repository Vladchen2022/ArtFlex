import Foundation
import Metal
import simd

private struct CreativeShapeGeneratorPolygonVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct CreativeShapeGeneratorStampVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var color: SIMD4<Float>
    var featherAmount: Float
}

private struct CreativeShapeGeneratorUniforms {
    var canvasSize: SIMD2<Float>
    var usesAlphaLock: Float
}

final class CreativeShapeGeneratorRenderer {
    private let device: MTLDevice
    private let polygonPipelineState: MTLRenderPipelineState
    private let stampPipelineState: MTLRenderPipelineState
    private let alphaLockPolygonPipelineState: MTLRenderPipelineState
    private let alphaLockStampPipelineState: MTLRenderPipelineState
    private let fallbackAlphaLockTexture: MTLTexture
    private var stampTextureCache: [BrushTipImageAssetID: MTLTexture] = [:]
    private var stampTextureCacheInsertionOrder: [BrushTipImageAssetID] = []
    private var reusablePolygonVertexBuffer: MTLBuffer?
    private var reusablePolygonVertexBufferLength = 0
    private var reusableStampVertexBuffer: MTLBuffer?
    private var reusableStampVertexBufferLength = 0

    private let stampMaskResolution = 128
    private let maximumCachedStampTextureCount = 128

    init(device: MTLDevice) {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct CreativeShapeGeneratorPolygonVertex {
            float2 position;
            float4 color;
        };

        struct CreativeShapeGeneratorStampVertex {
            float2 position;
            float2 uv;
            float4 color;
            float featherAmount;
        };

        struct CreativeShapeGeneratorUniforms {
            float2 canvasSize;
            float usesAlphaLock;
        };

        struct PolygonVertexOut {
            float4 position [[position]];
            float2 canvasPosition;
            float4 color;
        };

        struct StampVertexOut {
            float4 position [[position]];
            float2 canvasPosition;
            float2 uv;
            float4 color;
            float featherAmount;
        };

        float4 alphaLockedColor(
            float4 color,
            float2 canvasPosition,
            constant CreativeShapeGeneratorUniforms &uniforms,
            texture2d<float> alphaLockTexture
        ) {
            if (uniforms.usesAlphaLock > 0.5) {
                constexpr sampler alphaSampler(coord::normalized, address::clamp_to_edge, filter::nearest);
                float2 canvasSize = max(uniforms.canvasSize, float2(1.0, 1.0));
                float2 canvasUV = canvasPosition / canvasSize;
                float lockedDestinationAlpha = alphaLockTexture.sample(alphaSampler, canvasUV).a;
                if (lockedDestinationAlpha <= 0.001) {
                    return float4(0.0);
                }
                return float4(color.rgb * lockedDestinationAlpha, color.a);
            }
            return color;
        }

        vertex PolygonVertexOut creativeShapeGeneratorPolygonVertexShader(
            const device CreativeShapeGeneratorPolygonVertex *vertices [[buffer(0)]],
            constant CreativeShapeGeneratorUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            CreativeShapeGeneratorPolygonVertex vertexData = vertices[vertexID];
            float2 normalized = float2(
                (vertexData.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (vertexData.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            PolygonVertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.canvasPosition = vertexData.position;
            out.color = vertexData.color;
            return out;
        }

        fragment float4 creativeShapeGeneratorPolygonFragmentShader(
            PolygonVertexOut in [[stage_in]],
            constant CreativeShapeGeneratorUniforms &uniforms [[buffer(1)]],
            texture2d<float> alphaLockTexture [[texture(0)]]
        ) {
            return alphaLockedColor(in.color, in.canvasPosition, uniforms, alphaLockTexture);
        }

        vertex StampVertexOut creativeShapeGeneratorStampVertexShader(
            const device CreativeShapeGeneratorStampVertex *vertices [[buffer(0)]],
            constant CreativeShapeGeneratorUniforms &uniforms [[buffer(1)]],
            uint vertexID [[vertex_id]]
        ) {
            CreativeShapeGeneratorStampVertex vertexData = vertices[vertexID];
            float2 normalized = float2(
                (vertexData.position.x / max(uniforms.canvasSize.x, 1.0)) * 2.0 - 1.0,
                1.0 - (vertexData.position.y / max(uniforms.canvasSize.y, 1.0)) * 2.0
            );

            StampVertexOut out;
            out.position = float4(normalized, 0.0, 1.0);
            out.canvasPosition = vertexData.position;
            out.uv = vertexData.uv;
            out.color = vertexData.color;
            out.featherAmount = vertexData.featherAmount;
            return out;
        }

        float sampledStampAlpha(
            texture2d<float> maskTexture,
            float2 uv,
            float featherAmount
        ) {
            constexpr sampler maskSampler(coord::normalized, address::clamp_to_edge, filter::linear);
            float alpha = maskTexture.sample(maskSampler, uv).r;
            if (featherAmount <= 0.001) {
                return alpha;
            }

            float2 texel = 1.0 / float2(
                max(float(maskTexture.get_width()), 1.0),
                max(float(maskTexture.get_height()), 1.0)
            );
            float radius = mix(0.75, 2.6, clamp(featherAmount * 2.5, 0.0, 1.0));
            float2 dx = float2(texel.x * radius, 0.0);
            float2 dy = float2(0.0, texel.y * radius);

            float blurred =
                alpha * 4.0 +
                maskTexture.sample(maskSampler, uv + dx).r * 2.0 +
                maskTexture.sample(maskSampler, uv - dx).r * 2.0 +
                maskTexture.sample(maskSampler, uv + dy).r * 2.0 +
                maskTexture.sample(maskSampler, uv - dy).r * 2.0 +
                maskTexture.sample(maskSampler, uv + dx + dy).r +
                maskTexture.sample(maskSampler, uv + dx - dy).r +
                maskTexture.sample(maskSampler, uv - dx + dy).r +
                maskTexture.sample(maskSampler, uv - dx - dy).r;
            blurred /= 16.0;

            return mix(alpha, blurred, clamp(featherAmount * 2.2, 0.0, 1.0));
        }

        fragment float4 creativeShapeGeneratorStampFragmentShader(
            StampVertexOut in [[stage_in]],
            constant CreativeShapeGeneratorUniforms &uniforms [[buffer(1)]],
            texture2d<float> alphaLockTexture [[texture(0)]],
            texture2d<float> stampMaskTexture [[texture(1)]]
        ) {
            float alpha = sampledStampAlpha(stampMaskTexture, in.uv, in.featherAmount);
            if (alpha <= 0.001) {
                return float4(0.0);
            }

            float4 premultiplied = float4(in.color.rgb * alpha, in.color.a * alpha);
            return alphaLockedColor(premultiplied, in.canvasPosition, uniforms, alphaLockTexture);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            fatalError("Failed to compile CreativeShapeGeneratorRenderer shader: \(error)")
        }

        let polygonDescriptor = MTLRenderPipelineDescriptor()
        polygonDescriptor.vertexFunction = library.makeFunction(name: "creativeShapeGeneratorPolygonVertexShader")
        polygonDescriptor.fragmentFunction = library.makeFunction(name: "creativeShapeGeneratorPolygonFragmentShader")
        polygonDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let polygonAttachment = polygonDescriptor.colorAttachments[0]!
        polygonAttachment.isBlendingEnabled = true
        polygonAttachment.rgbBlendOperation = .add
        polygonAttachment.alphaBlendOperation = .add
        polygonAttachment.sourceRGBBlendFactor = .one
        polygonAttachment.sourceAlphaBlendFactor = .one
        polygonAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        polygonAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            polygonPipelineState = try device.makeRenderPipelineState(descriptor: polygonDescriptor)
        } catch {
            fatalError("Failed to create CreativeShapeGeneratorRenderer polygon pipeline: \(error)")
        }

        let alphaLockPolygonDescriptor = MTLRenderPipelineDescriptor()
        alphaLockPolygonDescriptor.vertexFunction = polygonDescriptor.vertexFunction
        alphaLockPolygonDescriptor.fragmentFunction = polygonDescriptor.fragmentFunction
        alphaLockPolygonDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let alphaLockPolygonAttachment = alphaLockPolygonDescriptor.colorAttachments[0]!
        alphaLockPolygonAttachment.isBlendingEnabled = true
        alphaLockPolygonAttachment.rgbBlendOperation = .add
        alphaLockPolygonAttachment.alphaBlendOperation = .add
        alphaLockPolygonAttachment.sourceRGBBlendFactor = .one
        alphaLockPolygonAttachment.sourceAlphaBlendFactor = .one
        alphaLockPolygonAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        alphaLockPolygonAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        alphaLockPolygonAttachment.writeMask = [.red, .green, .blue]

        do {
            alphaLockPolygonPipelineState = try device.makeRenderPipelineState(descriptor: alphaLockPolygonDescriptor)
        } catch {
            fatalError("Failed to create CreativeShapeGeneratorRenderer alpha lock polygon pipeline: \(error)")
        }

        let stampDescriptor = MTLRenderPipelineDescriptor()
        stampDescriptor.vertexFunction = library.makeFunction(name: "creativeShapeGeneratorStampVertexShader")
        stampDescriptor.fragmentFunction = library.makeFunction(name: "creativeShapeGeneratorStampFragmentShader")
        stampDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let stampAttachment = stampDescriptor.colorAttachments[0]!
        stampAttachment.isBlendingEnabled = true
        stampAttachment.rgbBlendOperation = .add
        stampAttachment.alphaBlendOperation = .add
        stampAttachment.sourceRGBBlendFactor = .one
        stampAttachment.sourceAlphaBlendFactor = .one
        stampAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        stampAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            stampPipelineState = try device.makeRenderPipelineState(descriptor: stampDescriptor)
        } catch {
            fatalError("Failed to create CreativeShapeGeneratorRenderer stamp pipeline: \(error)")
        }

        let alphaLockStampDescriptor = MTLRenderPipelineDescriptor()
        alphaLockStampDescriptor.vertexFunction = stampDescriptor.vertexFunction
        alphaLockStampDescriptor.fragmentFunction = stampDescriptor.fragmentFunction
        alphaLockStampDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let alphaLockStampAttachment = alphaLockStampDescriptor.colorAttachments[0]!
        alphaLockStampAttachment.isBlendingEnabled = true
        alphaLockStampAttachment.rgbBlendOperation = .add
        alphaLockStampAttachment.alphaBlendOperation = .add
        alphaLockStampAttachment.sourceRGBBlendFactor = .one
        alphaLockStampAttachment.sourceAlphaBlendFactor = .one
        alphaLockStampAttachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        alphaLockStampAttachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        alphaLockStampAttachment.writeMask = [.red, .green, .blue]

        do {
            alphaLockStampPipelineState = try device.makeRenderPipelineState(descriptor: alphaLockStampDescriptor)
        } catch {
            fatalError("Failed to create CreativeShapeGeneratorRenderer alpha lock stamp pipeline: \(error)")
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = .shaderRead
        fallbackDescriptor.storageMode = .shared
        guard let fallbackTexture = device.makeTexture(descriptor: fallbackDescriptor) else {
            fatalError("Failed to create CreativeShapeGeneratorRenderer alpha fallback texture.")
        }
        let fullAlphaPixel: [UInt8] = [255, 255, 255, 255]
        fallbackTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: fullAlphaPixel,
            bytesPerRow: 4
        )
        fallbackAlphaLockTexture = fallbackTexture
    }

    func encode(
        into renderPassDescriptor: MTLRenderPassDescriptor,
        commandBuffer: MTLCommandBuffer,
        canvasSize: CanvasSize,
        plan: CreativeShapeGeneratorPlan,
        alphaLockTexture: MTLTexture? = nil
    ) {
        guard plan.shapes.isEmpty == false else { return }

        let polygonVertices = polygonVertices(for: plan.shapes)
        let stampVertexGroups = stampVertexGroups(for: plan.shapes)
        guard polygonVertices.isEmpty == false || stampVertexGroups.isEmpty == false else { return }

        var uniforms = CreativeShapeGeneratorUniforms(
            canvasSize: SIMD2(Float(canvasSize.width), Float(canvasSize.height)),
            usesAlphaLock: alphaLockTexture == nil ? 0 : 1
        )

        let materialLookup = Dictionary(uniqueKeysWithValues: plan.tipMaterials.map { ($0.id, $0.maskData) })

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            return
        }
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CreativeShapeGeneratorUniforms>.stride, index: 1)
        encoder.setFragmentTexture(alphaLockTexture ?? fallbackAlphaLockTexture, index: 0)

        if polygonVertices.isEmpty == false,
           let vertexBuffer = makePolygonVertexBuffer(vertices: polygonVertices) {
            encoder.setRenderPipelineState(alphaLockTexture == nil ? polygonPipelineState : alphaLockPolygonPipelineState)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CreativeShapeGeneratorUniforms>.stride, index: 1)
            let scissorRect = bounds(for: polygonVertices, canvasSize: canvasSize)
            if scissorRect.width > 0, scissorRect.height > 0 {
                encoder.setScissorRect(scissorRect)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: polygonVertices.count)
            }
        }

        if stampVertexGroups.isEmpty == false {
            encoder.setRenderPipelineState(alphaLockTexture == nil ? stampPipelineState : alphaLockStampPipelineState)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<CreativeShapeGeneratorUniforms>.stride, index: 1)
            let sortedMaterialIDs = stampVertexGroups.keys.sorted()
            let stampBufferInfo = makeStampVertexBuffer(
                groups: stampVertexGroups,
                sortedMaterialIDs: sortedMaterialIDs
            )
            for materialID in sortedMaterialIDs {
                guard
                    let vertices = stampVertexGroups[materialID],
                    vertices.isEmpty == false,
                    let maskData = materialLookup[materialID],
                    let maskTexture = stampTexture(for: materialID, maskData: maskData),
                    let stampBufferInfo,
                    let bufferOffset = stampBufferInfo.offsets[materialID]
                else {
                    continue
                }

                encoder.setVertexBuffer(stampBufferInfo.buffer, offset: bufferOffset, index: 0)
                encoder.setFragmentTexture(maskTexture, index: 1)
                let scissorRect = bounds(for: vertices, canvasSize: canvasSize)
                if scissorRect.width > 0, scissorRect.height > 0 {
                    encoder.setScissorRect(scissorRect)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
                }
            }
        }

        encoder.endEncoding()
    }

    private func makePolygonVertexBuffer(
        vertices: [CreativeShapeGeneratorPolygonVertex]
    ) -> MTLBuffer? {
        let length = MemoryLayout<CreativeShapeGeneratorPolygonVertex>.stride * vertices.count
        guard length > 0 else { return nil }

        if reusablePolygonVertexBuffer == nil || reusablePolygonVertexBufferLength < length {
            let capacity = max(length, 16 * 1024)
            reusablePolygonVertexBuffer = device.makeBuffer(length: capacity, options: .storageModeShared)
            reusablePolygonVertexBufferLength = capacity
        }

        guard let reusablePolygonVertexBuffer else { return nil }
        vertices.withUnsafeBytes { rawBuffer in
            guard let sourceBaseAddress = rawBuffer.baseAddress else { return }
            reusablePolygonVertexBuffer.contents().copyMemory(
                from: sourceBaseAddress,
                byteCount: rawBuffer.count
            )
        }
        return reusablePolygonVertexBuffer
    }

    private func makeStampVertexBuffer(
        groups: [BrushTipImageAssetID: [CreativeShapeGeneratorStampVertex]],
        sortedMaterialIDs: [BrushTipImageAssetID]
    ) -> (buffer: MTLBuffer, offsets: [BrushTipImageAssetID: Int])? {
        let totalVertexCount = sortedMaterialIDs.reduce(0) { partialResult, materialID in
            partialResult + (groups[materialID]?.count ?? 0)
        }
        let requiredLength = MemoryLayout<CreativeShapeGeneratorStampVertex>.stride * totalVertexCount
        guard requiredLength > 0 else { return nil }

        if reusableStampVertexBuffer == nil || reusableStampVertexBufferLength < requiredLength {
            let capacity = max(requiredLength, 16 * 1024)
            reusableStampVertexBuffer = device.makeBuffer(length: capacity, options: .storageModeShared)
            reusableStampVertexBufferLength = capacity
        }

        guard let reusableStampVertexBuffer else { return nil }
        var offsets: [BrushTipImageAssetID: Int] = [:]
        var currentOffset = 0

        for materialID in sortedMaterialIDs {
            guard let vertices = groups[materialID], vertices.isEmpty == false else { continue }
            offsets[materialID] = currentOffset
            vertices.withUnsafeBytes { rawBuffer in
                guard let sourceBaseAddress = rawBuffer.baseAddress else { return }
                reusableStampVertexBuffer.contents().advanced(by: currentOffset).copyMemory(
                    from: sourceBaseAddress,
                    byteCount: rawBuffer.count
                )
                currentOffset += rawBuffer.count
            }
        }

        return (reusableStampVertexBuffer, offsets)
    }

    private func polygonVertices(for shapes: [CreativeShapeGeneratedShape]) -> [CreativeShapeGeneratorPolygonVertex] {
        var vertices: [CreativeShapeGeneratorPolygonVertex] = []
        for shape in shapes {
            guard case let .polygon(boundaryPoints) = shape.geometry, boundaryPoints.count >= 3 else { continue }
            let premultiplied = shape.color.premultiplied
            let color = SIMD4(premultiplied.red, premultiplied.green, premultiplied.blue, premultiplied.alpha)
            let transparentColor = SIMD4<Float>(repeating: 0)
            let center = SIMD2(Float(shape.center.x), Float(shape.center.y))
            let featherAmount = max(0, min(shape.featherAmount, 0.45))

            if featherAmount > 0.001 {
                let innerPoints: [SIMD2<Float>] = boundaryPoints.map { point in
                    let outer = SIMD2(Float(point.x), Float(point.y))
                    let delta = outer - center
                    return center + (delta * (1 - featherAmount))
                }

                for index in 0..<boundaryPoints.count {
                    let currentInner = innerPoints[index]
                    let nextInner = innerPoints[(index + 1) % boundaryPoints.count]
                    vertices.append(.init(position: center, color: color))
                    vertices.append(.init(position: currentInner, color: color))
                    vertices.append(.init(position: nextInner, color: color))
                }

                for index in 0..<boundaryPoints.count {
                    let currentOuter = SIMD2(Float(boundaryPoints[index].x), Float(boundaryPoints[index].y))
                    let nextOuter = SIMD2(Float(boundaryPoints[(index + 1) % boundaryPoints.count].x), Float(boundaryPoints[(index + 1) % boundaryPoints.count].y))
                    let currentInner = innerPoints[index]
                    let nextInner = innerPoints[(index + 1) % boundaryPoints.count]

                    vertices.append(.init(position: currentInner, color: color))
                    vertices.append(.init(position: currentOuter, color: transparentColor))
                    vertices.append(.init(position: nextOuter, color: transparentColor))

                    vertices.append(.init(position: currentInner, color: color))
                    vertices.append(.init(position: nextOuter, color: transparentColor))
                    vertices.append(.init(position: nextInner, color: color))
                }
            } else {
                for index in 0..<boundaryPoints.count {
                    let current = boundaryPoints[index]
                    let next = boundaryPoints[(index + 1) % boundaryPoints.count]
                    vertices.append(.init(position: center, color: color))
                    vertices.append(.init(position: SIMD2(Float(current.x), Float(current.y)), color: color))
                    vertices.append(.init(position: SIMD2(Float(next.x), Float(next.y)), color: color))
                }
            }
        }
        return vertices
    }

    private func stampVertexGroups(
        for shapes: [CreativeShapeGeneratedShape]
    ) -> [BrushTipImageAssetID: [CreativeShapeGeneratorStampVertex]] {
        var groups: [BrushTipImageAssetID: [CreativeShapeGeneratorStampVertex]] = [:]

        for shape in shapes {
            guard case let .tipStamp(stamp) = shape.geometry else { continue }
            let premultiplied = shape.color.premultiplied
            let color = SIMD4(premultiplied.red, premultiplied.green, premultiplied.blue, premultiplied.alpha)
            let featherAmount = max(0, min(shape.featherAmount, 0.45))

            let halfWidth = Float(max(stamp.size.x, 1) * 0.5)
            let halfHeight = Float(max(stamp.size.y, 1) * 0.5)
            let radians = stamp.rotationDegrees * .pi / 180
            let cosine = cos(radians)
            let sine = sin(radians)
            let center = SIMD2(Float(shape.center.x), Float(shape.center.y))

            func rotated(_ point: SIMD2<Float>) -> SIMD2<Float> {
                SIMD2(
                    (point.x * cosine) - (point.y * sine),
                    (point.x * sine) + (point.y * cosine)
                ) + center
            }

            let topLeft = rotated(SIMD2(-halfWidth, -halfHeight))
            let topRight = rotated(SIMD2(halfWidth, -halfHeight))
            let bottomRight = rotated(SIMD2(halfWidth, halfHeight))
            let bottomLeft = rotated(SIMD2(-halfWidth, halfHeight))

            let vertices: [CreativeShapeGeneratorStampVertex] = [
                .init(position: topLeft, uv: SIMD2(0, 0), color: color, featherAmount: featherAmount),
                .init(position: topRight, uv: SIMD2(1, 0), color: color, featherAmount: featherAmount),
                .init(position: bottomRight, uv: SIMD2(1, 1), color: color, featherAmount: featherAmount),
                .init(position: topLeft, uv: SIMD2(0, 0), color: color, featherAmount: featherAmount),
                .init(position: bottomRight, uv: SIMD2(1, 1), color: color, featherAmount: featherAmount),
                .init(position: bottomLeft, uv: SIMD2(0, 1), color: color, featherAmount: featherAmount)
            ]
            groups[stamp.materialID, default: []].append(contentsOf: vertices)
        }

        return groups
    }

    private func stampTexture(
        for materialID: BrushTipImageAssetID,
        maskData: Data
    ) -> MTLTexture? {
        if let cached = stampTextureCache[materialID] {
            return cached
        }

        guard let resampled = resampledMaskData(maskData) else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: stampMaskResolution,
            height: stampMaskResolution,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        resampled.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, stampMaskResolution, stampMaskResolution),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: stampMaskResolution
            )
        }

        stampTextureCache[materialID] = texture
        stampTextureCacheInsertionOrder.append(materialID)
        while stampTextureCacheInsertionOrder.count > maximumCachedStampTextureCount {
            let expiredID = stampTextureCacheInsertionOrder.removeFirst()
            stampTextureCache.removeValue(forKey: expiredID)
        }
        return texture
    }

    private func resampledMaskData(_ data: Data) -> Data? {
        let side = Int(Double(data.count).squareRoot())
        guard side > 0, side * side == data.count else { return nil }

        if side == stampMaskResolution {
            return data
        }

        var destination = Data(count: stampMaskResolution * stampMaskResolution)
        data.withUnsafeBytes { sourceRawBuffer in
            destination.withUnsafeMutableBytes { destinationRawBuffer in
                guard
                    let sourceBase = sourceRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let destinationBase = destinationRawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else {
                    return
                }

                for y in 0..<stampMaskResolution {
                    let sourceY = min(Int((Double(y) / Double(stampMaskResolution)) * Double(side)), side - 1)
                    for x in 0..<stampMaskResolution {
                        let sourceX = min(Int((Double(x) / Double(stampMaskResolution)) * Double(side)), side - 1)
                        destinationBase[(y * stampMaskResolution) + x] = sourceBase[(sourceY * side) + sourceX]
                    }
                }
            }
        }

        return destination
    }

    private func bounds(for vertices: [CreativeShapeGeneratorPolygonVertex], canvasSize: CanvasSize) -> MTLScissorRect {
        bounds(for: vertices.map(\.position), canvasSize: canvasSize)
    }

    private func bounds(for vertices: [CreativeShapeGeneratorStampVertex], canvasSize: CanvasSize) -> MTLScissorRect {
        bounds(for: vertices.map(\.position), canvasSize: canvasSize)
    }

    private func bounds(for positions: [SIMD2<Float>], canvasSize: CanvasSize) -> MTLScissorRect {
        guard let first = positions.first else {
            return MTLScissorRect(x: 0, y: 0, width: 0, height: 0)
        }

        var minX = Int(floor(Double(first.x)))
        var minY = Int(floor(Double(first.y)))
        var maxX = Int(ceil(Double(first.x)))
        var maxY = Int(ceil(Double(first.y)))

        for position in positions.dropFirst() {
            minX = min(minX, Int(floor(Double(position.x))))
            minY = min(minY, Int(floor(Double(position.y))))
            maxX = max(maxX, Int(ceil(Double(position.x))))
            maxY = max(maxY, Int(ceil(Double(position.y))))
        }

        minX = max(minX, 0)
        minY = max(minY, 0)
        maxX = min(maxX, canvasSize.width)
        maxY = min(maxY, canvasSize.height)

        return MTLScissorRect(
            x: max(minX, 0),
            y: max(minY, 0),
            width: max(maxX - minX, 0),
            height: max(maxY - minY, 0)
        )
    }
}
