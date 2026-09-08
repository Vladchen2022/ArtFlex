import CryptoKit
import Foundation
import Metal
import Testing
@testable import ArtFlex

@Suite(.serialized)
struct BrushV2ResourceTests {
    private func brushes() throws -> [(String, BrushSettings)] {
        var result: [(String, BrushSettings)] = []
        for compound in [false, true] {
            for clipped in [false, true] {
                for overlay in [false, true] {
                    var brush = compound ? BrushSettings.v2Crayon : BrushSettings.v2Default
                    brush.size = 28
                    brush.engineV2?.clipsToRange = clipped
                    if overlay { brush.engineV2?.combination = .overlayMask }
                    result.append(("\(compound ? "dual" : "single")-\(clipped ? "range" : "free")-\(overlay ? "overlay" : "blend")", brush))
                }
            }
        }
        if let path = ProcessInfo.processInfo.environment["ARTFLEX_KRITA_REFERENCE"] {
            var brush = try KritaMaskedBrushImporter.load(url: URL(fileURLWithPath: path)).brush
            brush.size = 36
            result.append(("krita-crayon", brush))
        }
        return result
    }

    @Test func pigmentAllocationDoesNotChangeRenderedPixels() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try StageOneBrushRenderer(device: device)
        let queue = try #require(device.makeCommandQueue())
        for (name, brush) in try brushes() {
            let normal = try render(brush, side: 128, device: device, renderer: renderer, queue: queue)
            let preallocated = try render(brush, side: 128, device: device, renderer: renderer,
                                          queue: queue, preallocateAllFields: true)
            #expect(normal.pixels == preallocated.pixels, "\(name)")
            #expect(normal.pixels.contains { $0 != 0 })
            let requiredFields = 1 + (brush.compoundBrush.enabled ? 1 : 0)
                + (brush.engineV2?.clipsToRange == true ? 1 : 0)
            #expect(normal.pigmentBytes == preallocated.pigmentBytes / 3 * requiredFields)
            print("V2_PIXEL_BASELINE \(name) \(SHA256.hash(data: Data(normal.pixels)))")
        }
    }

    @Test func halfFloatTargetsSupportEveryCombinationWithoutChangingBrushIdentity() throws {
        let metal = try #require(MetalDeviceContext())
        let renderer = try StageOneBrushRenderer(device: metal.device)
        for (name, brush) in try brushes() {
            let low = try render(brush, side: 128, device: metal.device, renderer: renderer, queue: metal.commandQueue)
            let high = try render(brush, side: 128, device: metal.device, renderer: renderer, queue: metal.commandQueue,
                pixelFormat: .rgba16Float)
            let a = LayerTextureSnapshot(width: 128, height: 128, bytesPerRow: 512, pixelData: Data(low.pixels))
            let b = LayerTextureSnapshot(width: 128, height: 128, bytesPerRow: 1024,
                pixelData: Data(high.pixels), encoding: .premultipliedRGBA16FloatLinear)
            var error: Float = 0
            var painted = 0
            for y in 0..<128 { for x in 0..<128 {
                let first = a.linearPixel(x: x, y: y), second = b.linearPixel(x: x, y: y)
                if first.alpha > 0 || second.alpha > 0 {
                    error += abs(first.alpha - second.alpha) + abs(first.red - second.red)
                    painted += 1
                }
            } }
            #expect(painted > 100, "\(name)")
            #expect(error / Float(max(painted, 1)) < 0.015, "\(name)")
        }
    }

    @Test func optionalFieldsAreAllocatedOnceAndRetainedUntilStrokeEnds() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let created = BrushV2Session(device: device, width: 512, height: 512)
        let state = try #require(created)
        #expect(state.b == nil && state.range == nil)
        #expect(state.ensureFields(needsSecondary: true, needsRange: false))
        let b = try #require(state.b)
        #expect(state.range == nil)
        #expect(state.ensureFields(needsSecondary: false, needsRange: true))
        let range = try #require(state.range)
        #expect(state.b === b)
        #expect(state.ensureFields(needsSecondary: true, needsRange: true))
        #expect(state.b === b && state.range === range)
    }

    @Test func enablingFieldsAfterPaintingInitializesExistingAndNewTiles() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try StageOneBrushRenderer(device: device)
        let queue = try #require(device.makeCommandQueue())
        var single = BrushSettings.v2Default
        single.size = 28
        var dual = BrushSettings.v2Crayon
        dual.size = 28
        var clipped = dual
        clipped.engineV2?.clipsToRange = true
        let stages = [single, dual, clipped, single, clipped]
        let normal = try render(single, side: 512, device: device, renderer: renderer,
                                queue: queue, brushStages: stages)
        let preallocated = try render(single, side: 512, device: device, renderer: renderer,
                                      queue: queue, preallocateAllFields: true, brushStages: stages)
        #expect(normal.pixels == preallocated.pixels)
        #expect(normal.pixels.contains { $0 != 0 })
        #expect(normal.pigmentBytes == preallocated.pigmentBytes)
    }

    /// Opt-in: real Metal allocation sizes and completed GPU timings, not an FPS
    /// assertion. Keep large texture measurements out of parallel test runs.
    @Test func fourKResourceMeasurement() throws {
        guard ProcessInfo.processInfo.environment["ARTFLEX_MEASURE_V2_RESOURCES"] == "1" else { return }
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try StageOneBrushRenderer(device: device)
        let queue = try #require(device.makeCommandQueue())
        _ = try render(.v2Default, side: 128, device: device, renderer: renderer, queue: queue)
        for (name, brush) in try brushes() {
            var measurements: [Measurement] = []
            for _ in 0..<5 {
                measurements.append(try autoreleasepool {
                    try render(brush, side: 4096, device: device, renderer: renderer, queue: queue,
                               readsPixels: false)
                })
            }
            let cpu = measurements.map(\.cpuMilliseconds).sorted()[2]
            let gpu = measurements.map(\.gpuMilliseconds).sorted()[2]
            print("V2_RESOURCE \(device.name) \(name) side=4096 pigmentBytes=\(measurements[0].pigmentBytes) medianCPUms=\(cpu) medianGPUms=\(gpu)")
        }
    }

    private struct Measurement {
        let pixels: [UInt8]
        let pigmentBytes: Int
        let cpuMilliseconds: Double
        let gpuMilliseconds: Double
    }

    private func render(_ brush: BrushSettings, side: Int, device: MTLDevice,
                        renderer: StageOneBrushRenderer, queue: MTLCommandQueue,
                        preallocateAllFields: Bool = false, brushStages: [BrushSettings]? = nil,
                        readsPixels: Bool = true, pixelFormat: MTLPixelFormat = .bgra8Unorm_srgb) throws -> Measurement {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat, width: side, height: side, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead, .renderTarget]
        let target = try #require(device.makeTexture(descriptor: descriptor))
        let clear = try #require(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        try #require(clear.makeRenderCommandEncoder(descriptor: pass)).endEncoding()
        clear.commit(); clear.waitUntilCompleted()
        #expect(clear.status == .completed)
        let session = try #require(renderer.makeOpacityCapSession(
            for: target, commandQueue: queue, reusesCachedTextures: false))
        if preallocateAllFields {
            let allocated = BrushV2Session(device: device, width: side, height: side,
                                          needsSecondary: true, needsRange: true)
            session.v2 = try #require(allocated)
        }
        let center = Double(side) / 2
        let extent = min(Double(side) * 0.35, 150)
        let points: [StrokePoint] = (0...40).map { i in
            let x = center - extent + extent * 2 * Double(i) / 40
            let y = center + sin(Double(i) / 8) * min(extent / 2, 30)
            let pressure: Float = 0.15 + Float(i) / 40 * 0.85
            return StrokePoint(x: x, y: y, pressure: pressure)
        }
        var sampling: BrushStrokeSamplingState?
        let buffer = try #require(queue.makeCommandBuffer())
        let start = ProcessInfo.processInfo.systemUptime
        let stages = brushStages ?? [brush]
        for (index, settings) in stages.enumerated() {
            let stagePoints = points.map {
                StrokePoint(x: $0.x + Double(index * 18), y: $0.y + Double(index * 12), pressure: $0.pressure)
            }
            renderer.encodeOpacityCapStroke(stroke: StrokeDescriptor(tool: .brush,
                color: RGBAColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1), brush: settings,
                points: [stagePoints[0]] + stagePoints, skipLeadingStamp: index > 0,
                paintVariationSeed: 47), session: session,
                into: target, commandBuffer: buffer, samplingState: &sampling)
        }
        sampling?.isFlushing = true
        renderer.encodeOpacityCapStroke(stroke: StrokeDescriptor(tool: .brush,
            color: RGBAColor(red: 0.7, green: 0.2, blue: 0.1, alpha: 1), brush: stages.last ?? brush,
            points: [], skipLeadingStamp: true, paintVariationSeed: 47), session: session,
            into: target, commandBuffer: buffer, samplingState: &sampling)
        let cpu = (ProcessInfo.processInfo.systemUptime - start) * 1000
        buffer.commit(); buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        let state = try #require(session.v2)
        let pigmentBytes = [state.a, state.b, state.range].compactMap { $0 }.reduce(0) { $0 + $1.allocatedSize }
        let bpp = CanvasPixelEncoding(metalPixelFormat: pixelFormat).bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: readsPixels ? side * side * bpp : 0)
        if !pixels.isEmpty {
            pixels.withUnsafeMutableBytes {
                target.getBytes($0.baseAddress!, bytesPerRow: side * bpp,
                                from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
            }
        }
        return Measurement(pixels: pixels, pigmentBytes: pigmentBytes, cpuMilliseconds: cpu,
                           gpuMilliseconds: (buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
    }
}
