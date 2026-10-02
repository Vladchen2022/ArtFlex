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

/// Resolves one immutable GPU readback on a worker. Forced editing boundaries may drain it
/// without waiting for a main-actor continuation; repeated consumers receive the same result.
final class DeferredLayerRegionSnapshots: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<[LayerTextureSnapshot], Error>?
    private var observers: [@Sendable () -> Void] = []

    init(resolve: @escaping () throws -> [LayerTextureSnapshot]) {
        let work = DeferredRegionSnapshotWork(resolve: resolve)
        DispatchQueue.global(qos: .userInitiated).async { [self, work] in
            let completed = Result { try autoreleasepool { try work.resolve() } }
            condition.lock()
            result = completed
            let callbacks = observers
            observers.removeAll()
            condition.broadcast()
            condition.unlock()
            for callback in callbacks { callback() }
        }
    }

    var isReady: Bool {
        condition.lock()
        defer { condition.unlock() }
        return result != nil
    }

    func read() throws -> [LayerTextureSnapshot] {
        condition.lock()
        while result == nil { condition.wait() }
        let completed = result!
        condition.unlock()
        return try completed.get()
    }

    func notifyWhenReady(_ observer: @escaping @Sendable () -> Void) {
        condition.lock()
        if result != nil {
            condition.unlock()
            observer()
        } else {
            observers.append(observer)
            condition.unlock()
        }
    }
}

private final class DeferredRegionSnapshotWork: @unchecked Sendable {
    let resolve: () throws -> [LayerTextureSnapshot]
    init(resolve: @escaping () throws -> [LayerTextureSnapshot]) { self.resolve = resolve }
}
