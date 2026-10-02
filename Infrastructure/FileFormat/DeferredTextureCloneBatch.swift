import Foundation
import Metal

/// Private clones are inaccessible until their submitted copy has completed successfully.
/// This value may cross threads; it never exposes or mutates the live source textures.
struct DeferredTextureCloneBatch: @unchecked Sendable {
    private let textures: [MTLTexture]
    private let commandBuffer: MTLCommandBuffer?
    private let auditStore: PerformanceAuditStore?
    private let rejectsCompletion: Bool

    init(textures: [MTLTexture], commandBuffer: MTLCommandBuffer? = nil,
         auditStore: PerformanceAuditStore? = nil, rejectsCompletion: Bool = false) {
        self.textures = textures
        self.commandBuffer = commandBuffer
        self.auditStore = auditStore
        self.rejectsCompletion = rejectsCompletion
    }

    func waitUntilReady() throws -> [MTLTexture] {
        let start = auditStore == nil ? 0 : DispatchTime.now().uptimeNanoseconds
        commandBuffer?.waitUntilCompleted()
        if let auditStore {
            auditStore.recordDuration("SaveCapture.wait", ms: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        if let commandBuffer, commandBuffer.status != .completed {
            throw commandBuffer.error ?? CocoaError(.fileWriteUnknown)
        }
        guard !rejectsCompletion else { throw CocoaError(.fileWriteUnknown) }
        return textures
    }
}

/// Explicitly retain sparse heaps as well as textures until Metal invokes the completion handler.
/// No shared-copy store is needed: all private source writes are ordered on the canvas queue.
final class MetalCloneSourceLifetime: @unchecked Sendable {
    let textures: [MTLTexture]
    let heaps: [MTLHeap]
    init(_ textures: [MTLTexture]) {
        self.textures = textures
        self.heaps = textures.compactMap(\.heap)
    }
}
