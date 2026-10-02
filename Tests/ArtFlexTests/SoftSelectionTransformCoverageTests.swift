import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

@MainActor
struct SoftSelectionTransformCoverageTests {
    @Test func fractionalCutMoveOverlapAndIdentityPreserveDefinedCoverage() async throws {
        for encoding in [CanvasPixelEncoding.premultipliedBGRA8SRGB, .premultipliedRGBA16FloatLinear] {
            let metal = try #require(MetalDeviceContext())
            let serializer = LayerTextureSerializer(metalContext: metal)
            let store = StageOneLayerSurfaceStore()
            let format: MTLPixelFormat = encoding == .premultipliedRGBA16FloatLinear ? .rgba16Float : .bgra8Unorm_srgb
            let source = try #require(store.makeTexture(width: 12, height: 4, pixelFormat: format, metal: metal))
            var bytes = Data(count: 12 * 4 * encoding.bytesPerPixel)
            bytes.withUnsafeMutableBytes { output in
                for y in 0..<4 {
                    for x in 0..<12 {
                        let color = x < 6 ? LinearPremultipliedColor(red: 0.25, green: 0.03, blue: 0.01, alpha: 0.5)
                            : LinearPremultipliedColor(red: 0.02, green: 0.04, blue: 0.4, alpha: 0.8)
                        CanvasPixelCodec.write(color, into: output, offset: (y * 12 + x) * encoding.bytesPerPixel,
                            encoding: encoding)
                    }
                }
            }
            try serializer.restore(snapshot: .init(width: 12, height: 4, bytesPerRow: 12 * encoding.bytesPerPixel,
                pixelData: bytes, encoding: encoding), into: source)
            let original = try serializer.snapshot(texture: source)
            let mask = try #require(store.makeTexture(width: 4, height: 2, pixelFormat: .r8Unorm,
                storageMode: .shared, metal: metal))
            let coverage: [UInt8] = [64, 128, 192, 255, 64, 128, 192, 255]
            mask.replace(region: MTLRegionMake2D(0, 0, 4, 2), mipmapLevel: 0, withBytes: coverage, bytesPerRow: 4)
            let compositor = try TransformGPUCompositor(device: metal.device)
            let bounds = CanvasRect(origin: .init(x: 2, y: 1), size: .init(x: 4, y: 2))
            let size = CanvasSize(width: 12, height: 4)
            var prepared: (MTLTexture?, MTLTexture?) = (nil, nil)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                compositor.buildSelectionTextures(sourceTexture: source, canvasSize: size, sourceBounds: bounds,
                    maskTexture: mask, metal: metal) { base, extracted in
                    prepared = (base, extracted)
                    continuation.resume()
                }
            }
            let base = try #require(prepared.0)
            let extracted = try #require(prepared.1)
            let surfaceID = LayerSurfaceID()
            let session = TransformPreviewSession(activeLayerSurfaceID: surfaceID, mode: .selection,
                operationBounds: bounds, interactionBounds: bounds, baseTexture: base, extractedTexture: extracted,
                maskTexture: mask, originalTexture: source,
                preparedSignature: .init(activeLayerSurfaceID: surfaceID, mode: .selection,
                    canvasContentRevision: 1, selectionRevision: 1, operationBounds: bounds), revision: 1)
            func pixel(_ snapshot: LayerTextureSnapshot, _ x: Int, _ y: Int) -> LinearPremultipliedColor {
                snapshot.pixelData.withUnsafeBytes {
                    CanvasPixelCodec.read($0, offset: y * snapshot.bytesPerRow + x * snapshot.encoding.bytesPerPixel,
                        encoding: snapshot.encoding)
                }
            }
            func scaled(_ color: LinearPremultipliedColor, _ factor: Float) -> LinearPremultipliedColor {
                .init(red: color.red * factor, green: color.green * factor, blue: color.blue * factor, alpha: color.alpha * factor)
            }
            func expectClose(_ actual: LinearPremultipliedColor, _ expected: LinearPremultipliedColor) {
                let tolerance: Float = format == .rgba16Float ? 0.001 : 0.009
                #expect(abs(actual.red - expected.red) < tolerance)
                #expect(abs(actual.green - expected.green) < tolerance)
                #expect(abs(actual.blue - expected.blue) < tolerance)
                #expect(abs(actual.alpha - expected.alpha) < tolerance)
            }
            let basePixels = try serializer.snapshot(texture: base)
            let extractedPixels = try serializer.snapshot(texture: extracted)
            for x in 0..<4 {
                let factor = Float(coverage[x]) / 255
                expectClose(pixel(basePixels, x + 2, 1), scaled(pixel(original, x + 2, 1), 1 - factor))
                expectClose(pixel(extractedPixels, x, 0), scaled(pixel(original, x + 2, 1), factor))
            }
            func render(_ preview: FreeTransformPreview, mesh: MeshWarpGrid? = nil) throws -> MTLTexture {
                let command = try #require(metal.commandQueue.makeCommandBuffer())
                let output = try #require(compositor.encodeTransformedTexture(session: session, preview: preview,
                    meshWarpGrid: mesh, canvasSize: size, commandBuffer: command))
                command.commit(); command.waitUntilCompleted()
                #expect(command.status == .completed)
                return output
            }
            let unchanged = try render(.identity)
            #expect(unchanged === source)
            #expect(try serializer.snapshot(texture: unchanged) == original)
            #expect(session.unchangedSourceTexture(preview: .init(translation: .init(x: 0.4, y: 0))) == nil)
            let moved = try serializer.snapshot(texture: render(.init(translation: .init(x: 6, y: 0))))
            expectClose(pixel(moved, 2, 1), pixel(basePixels, 2, 1))
            expectClose(pixel(moved, 8, 1), pixel(extractedPixels, 0, 0).composited(over: pixel(original, 8, 1)))
            let overlapped = try serializer.snapshot(texture: render(.init(translation: .init(x: 1, y: 0))))
            expectClose(pixel(overlapped, 3, 1), pixel(extractedPixels, 0, 0).composited(over: pixel(basePixels, 3, 1)))
            var mesh = MeshWarpGrid.regular(bounds: bounds)
            #expect(try render(.identity, mesh: mesh) === source)
            mesh.controlPoints = mesh.controlPoints.map { .init(x: $0.x + 6, y: $0.y) }
            let meshMoved = try serializer.snapshot(texture: render(.identity, mesh: mesh))
            for x in 0..<12 { expectClose(pixel(meshMoved, x, 1), pixel(moved, x, 1)) }
            var committed: MTLTexture?
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                compositor.composeTransformedTexture(session: session, preview: .init(translation: .init(x: 6, y: 0)),
                    canvasSize: size, metal: metal) { texture in
                    committed = texture
                    continuation.resume()
                }
            }
            #expect(try serializer.snapshot(texture: #require(committed)) == moved)
            #expect(try serializer.snapshot(texture: source) == original)
        }
    }
}
