import Foundation
import Metal

enum LayerContentBoundsResult: Sendable, Equatable {
    case empty
    case bounds(CanvasRect)
}

enum LayerContentBoundsDetectorError: LocalizedError {
    case shaderLibrary(Error)
    case missingFunction
    case pipelineState(Error)
    case commandEncoding
    case commandExecution(Error?)

    var errorDescription: String? {
        switch self {
        case .shaderLibrary(let error):
            return "Failed to compile layer bounds shader: \(error.localizedDescription)"
        case .missingFunction:
            return "Layer bounds shader function is unavailable."
        case .pipelineState(let error):
            return "Failed to create layer bounds pipeline: \(error.localizedDescription)"
        case .commandEncoding:
            return "Failed to encode layer bounds detection."
        case .commandExecution(let error):
            return error?.localizedDescription ?? "Layer bounds detection failed."
        }
    }
}

final class LayerContentBoundsDetector: @unchecked Sendable {
    private let device: MTLDevice
    private let pipelineState: MTLComputePipelineState

    init(device: MTLDevice) throws {
        self.device = device
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void detectLayerContentBounds(
            texture2d<float, access::read> source [[texture(0)]],
            device atomic_uint *bounds [[buffer(0)]],
            uint2 gid [[thread_position_in_grid]]
        ) {
            if (gid.x >= source.get_width() || gid.y >= source.get_height()) {
                return;
            }
            if (source.read(gid).a <= 0.0) {
                return;
            }
            atomic_fetch_min_explicit(&bounds[0], gid.x, memory_order_relaxed);
            atomic_fetch_min_explicit(&bounds[1], gid.y, memory_order_relaxed);
            atomic_fetch_max_explicit(&bounds[2], gid.x, memory_order_relaxed);
            atomic_fetch_max_explicit(&bounds[3], gid.y, memory_order_relaxed);
        }
        """

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: source, options: nil)
        } catch {
            throw LayerContentBoundsDetectorError.shaderLibrary(error)
        }
        guard let function = library.makeFunction(name: "detectLayerContentBounds") else {
            throw LayerContentBoundsDetectorError.missingFunction
        }
        do {
            pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw LayerContentBoundsDetectorError.pipelineState(error)
        }
    }

    func detect(
        texture: MTLTexture,
        commandQueue: MTLCommandQueue
    ) throws -> LayerContentBoundsResult {
        guard texture.width > 0, texture.height > 0 else { return .empty }
        var initialBounds = [
            UInt32(texture.width),
            UInt32(texture.height),
            UInt32(0),
            UInt32(0)
        ]
        guard
            let resultBuffer = device.makeBuffer(
                bytes: &initialBounds,
                length: MemoryLayout<UInt32>.stride * initialBounds.count,
                options: .storageModeShared
            ),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeComputeCommandEncoder()
        else {
            throw LayerContentBoundsDetectorError.commandEncoding
        }

        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(resultBuffer, offset: 0, index: 0)
        let threadWidth = max(pipelineState.threadExecutionWidth, 1)
        let threadHeight = max(
            min(pipelineState.maxTotalThreadsPerThreadgroup / threadWidth, 16),
            1
        )
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: threadWidth, height: threadHeight, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw LayerContentBoundsDetectorError.commandExecution(commandBuffer.error)
        }

        let values = resultBuffer.contents().bindMemory(to: UInt32.self, capacity: 4)
        let minX = Int(values[0])
        let minY = Int(values[1])
        guard minX < texture.width, minY < texture.height else {
            return .empty
        }
        let maxX = Int(values[2])
        let maxY = Int(values[3])
        return .bounds(
            CanvasRect(
                origin: .init(x: Double(minX), y: Double(minY)),
                size: .init(
                    x: Double((maxX - minX) + 1),
                    y: Double((maxY - minY) + 1)
                )
            )
        )
    }
}
