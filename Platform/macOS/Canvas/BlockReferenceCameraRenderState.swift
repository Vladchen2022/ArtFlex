import Foundation

/// A main-thread render bridge for block-reference camera navigation.
///
/// Mouse events and MTKView drawing both run on the main actor, so the renderer can
/// pull the newest camera every display frame without publishing every pointer move
/// through SwiftUI.
@MainActor
final class BlockReferenceCameraRenderState {
    private(set) var camera: BlockReferenceCamera?
    private var awaitingCommittedCamera: BlockReferenceCamera?

    func beginNavigation() {
        camera = nil
        awaitingCommittedCamera = nil
    }

    func updateNavigation(camera: BlockReferenceCamera) {
        self.camera = camera
        awaitingCommittedCamera = nil
    }

    func finishNavigation(committedCamera: BlockReferenceCamera) {
        camera = committedCamera
        awaitingCommittedCamera = committedCamera
    }

    func cancelNavigation() {
        camera = nil
        awaitingCommittedCamera = nil
    }

    func rendererDidReceive(camera committedCamera: BlockReferenceCamera) {
        guard awaitingCommittedCamera == committedCamera else { return }
        camera = nil
        awaitingCommittedCamera = nil
    }
}
