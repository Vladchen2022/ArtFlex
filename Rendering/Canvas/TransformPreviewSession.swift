import Foundation
import Metal

private final class TransformPreviewSessionBox: @unchecked Sendable {
    let value: TransformPreviewSession?

    init(_ value: TransformPreviewSession?) {
        self.value = value
    }
}

private final class TransformMaskTextureBox: @unchecked Sendable {
    let texture: MTLTexture?

    init(_ texture: MTLTexture?) {
        self.texture = texture
    }
}

enum TransformPreviewMode: Sendable, Equatable {
    case wholeLayer
    case selection
}

struct TransformPreviewPreparedSignature: Sendable, Equatable {
    let activeLayerSurfaceID: LayerSurfaceID
    let mode: TransformPreviewMode
    let canvasContentRevision: UInt64
    let selectionRevision: UInt64
    let operationBounds: CanvasRect
}

struct TransformPreviewSession {
    let activeLayerSurfaceID: LayerSurfaceID
    let mode: TransformPreviewMode
    let operationBounds: CanvasRect
    let interactionBounds: CanvasRect?
    let baseTexture: MTLTexture?
    let extractedTexture: MTLTexture
    let maskTexture: MTLTexture?
    let preparedSignature: TransformPreviewPreparedSignature
    let revision: UInt64
}

struct TransformPreviewPlan: Sendable, Equatable {
    let mode: TransformPreviewMode
    let operationBounds: CanvasRect
    let interactionBounds: CanvasRect?
    let needsMaskTexture: Bool
}

final class TransformPreviewSessionBuilder {
    private let compositor: TransformGPUCompositor?
    private let initializationError: Error?

    init(device: MTLDevice) {
        do {
            self.compositor = try TransformGPUCompositor(device: device)
            self.initializationError = nil
        } catch {
            self.compositor = nil
            self.initializationError = error
        }
    }

    func makeSession(
        activeLayerSurfaceID: LayerSurfaceID,
        sourceTexture: MTLTexture,
        canvasSize: CanvasSize,
        selectionShape: SelectionShape?,
        interactionBounds: CanvasRect?,
        selectionRevision: UInt64,
        canvasContentRevision: UInt64,
        metal: MetalDeviceContext,
        completion: @escaping @MainActor (TransformPreviewSession?) -> Void
    ) {
        guard let compositor else {
            let boxedSession = TransformPreviewSessionBox(nil)
            let _ = initializationError
            Task { @MainActor in
                completion(boxedSession.value)
            }
            return
        }
        guard let plan = Self.plan(
            canvasSize: canvasSize,
            selectionShape: selectionShape,
            interactionBounds: interactionBounds
        ) else {
            Task { @MainActor in
                completion(nil)
            }
            return
        }

        let signature = TransformPreviewPreparedSignature(
            activeLayerSurfaceID: activeLayerSurfaceID,
            mode: plan.mode,
            canvasContentRevision: canvasContentRevision,
            selectionRevision: selectionRevision,
            operationBounds: plan.operationBounds
        )

        if plan.mode == .wholeLayer {
            let session = TransformPreviewSession(
                activeLayerSurfaceID: activeLayerSurfaceID,
                mode: .wholeLayer,
                operationBounds: plan.operationBounds,
                interactionBounds: plan.interactionBounds,
                baseTexture: nil,
                extractedTexture: sourceTexture,
                maskTexture: nil,
                preparedSignature: signature,
                revision: canvasContentRevision
            )
            let boxedSession = TransformPreviewSessionBox(session)
            Task { @MainActor in
                completion(boxedSession.value)
            }
            return
        }

        let maskTexture = Self.makeMaskTexture(
            selectionShape: selectionShape,
            sourceBounds: plan.operationBounds,
            device: metal.device
        )
        let boxedMaskTexture = TransformMaskTextureBox(maskTexture)

        compositor.buildSelectionTextures(
            sourceTexture: sourceTexture,
            canvasSize: canvasSize,
            sourceBounds: plan.operationBounds,
            maskTexture: boxedMaskTexture.texture,
            metal: metal
        ) { baseTexture, extractedTexture in
            guard let extractedTexture else {
                completion(nil)
                return
            }

            let session = TransformPreviewSession(
                activeLayerSurfaceID: activeLayerSurfaceID,
                mode: .selection,
                operationBounds: plan.operationBounds,
                interactionBounds: plan.interactionBounds,
                baseTexture: baseTexture,
                extractedTexture: extractedTexture,
                maskTexture: boxedMaskTexture.texture,
                preparedSignature: signature,
                revision: canvasContentRevision
            )
            let boxedSession = TransformPreviewSessionBox(session)
            Task { @MainActor in
                completion(boxedSession.value)
            }
        }
    }

    static func plan(
        canvasSize: CanvasSize,
        selectionShape: SelectionShape?,
        interactionBounds: CanvasRect? = nil
    ) -> TransformPreviewPlan? {
        let fullBounds = fullCanvasBounds(canvasSize: canvasSize)
        guard let selectionShape else {
            return TransformPreviewPlan(
                mode: .wholeLayer,
                operationBounds: fullBounds,
                interactionBounds: interactionBounds,
                needsMaskTexture: false
            )
        }

        let clamped = selectionShape.clamped(to: canvasSize)
        guard !clamped.isEmpty else {
            return nil
        }

        let bounds = clamped.bounds.clamped(to: canvasSize).pixelAligned()
        guard !bounds.isEmpty else {
            return nil
        }

        let isWholeLayerRect =
            clamped.kind == .rectangle &&
            bounds.minX <= 0 &&
            bounds.minY <= 0 &&
            Int(bounds.maxX.rounded(.up)) >= canvasSize.width &&
            Int(bounds.maxY.rounded(.up)) >= canvasSize.height

        return TransformPreviewPlan(
            mode: isWholeLayerRect ? .wholeLayer : .selection,
            operationBounds: isWholeLayerRect ? fullBounds : bounds,
            interactionBounds: isWholeLayerRect ? interactionBounds : bounds,
            needsMaskTexture: !isWholeLayerRect && clamped.kind != .rectangle
        )
    }

    static func fullCanvasBounds(canvasSize: CanvasSize) -> CanvasRect {
        CanvasRect(
            origin: .init(x: 0, y: 0),
            size: .init(x: Double(canvasSize.width), y: Double(canvasSize.height))
        )
    }

    private static func makeMaskTexture(
        selectionShape: SelectionShape?,
        sourceBounds: CanvasRect,
        device: MTLDevice
    ) -> MTLTexture? {
        guard let selectionShape else { return nil }
        guard selectionShape.kind != .rectangle else { return nil }

        let width = max(Int(sourceBounds.size.x.rounded(.up)), 1)
        let height = max(Int(sourceBounds.size.y.rounded(.up)), 1)
        let maskBytes = localMaskBytes(
            for: selectionShape,
            sourceBounds: sourceBounds
        )

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            return nil
        }

        maskBytes.withUnsafeBytes { rawBuffer in
            if let baseAddress = rawBuffer.baseAddress {
                texture.replace(
                    region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0,
                    withBytes: baseAddress,
                    bytesPerRow: width
                )
            }
        }
        return texture
    }

    static func localMaskBytes(
        for selectionShape: SelectionShape,
        sourceBounds: CanvasRect
    ) -> [UInt8] {
        let clampedBounds = sourceBounds.pixelAligned()
        let width = max(Int(clampedBounds.size.x.rounded(.up)), 1)
        let height = max(Int(clampedBounds.size.y.rounded(.up)), 1)

        if let maskData = selectionShape.maskData {
            var localBytes = [UInt8](repeating: 0, count: width * height)
            let originX = max(Int(clampedBounds.minX.rounded(.down)), 0)
            let originY = max(Int(clampedBounds.minY.rounded(.down)), 0)
            maskData.withAlphaBytes { sourceBytes in
                for localY in 0..<height {
                    let canvasY = originY + localY
                    guard canvasY < maskData.canvasHeight else { continue }
                    for localX in 0..<width {
                        let canvasX = originX + localX
                        guard canvasX < maskData.canvasWidth else { continue }
                        let sourceIndex = (canvasY * maskData.canvasWidth) + canvasX
                        localBytes[(localY * width) + localX] = sourceBytes[sourceIndex]
                    }
                }
            }
            return localBytes
        }

        var bytes = [UInt8](repeating: 0, count: width * height)
        let originX = clampedBounds.minX
        let originY = clampedBounds.minY
        for localY in 0..<height {
            for localX in 0..<width {
                let point = CanvasPoint(
                    x: originX + Double(localX) + 0.5,
                    y: originY + Double(localY) + 0.5
                )
                if selectionShape.contains(point) {
                    bytes[(localY * width) + localX] = 255
                }
            }
        }
        return bytes
    }
}

private extension CanvasRect {
    func pixelAligned() -> CanvasRect {
        let minX = floor(self.minX)
        let minY = floor(self.minY)
        let maxX = ceil(self.maxX)
        let maxY = ceil(self.maxY)
        return CanvasRect(
            origin: .init(x: minX, y: minY),
            size: .init(x: max(maxX - minX, 0), y: max(maxY - minY, 0))
        )
    }
}
