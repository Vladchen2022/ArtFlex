import SwiftUI

/// One serial utility queue prevents a scrolling grid from blocking the main
/// thread or starting a GPU job for every cell at once. NSCache is owned by the
/// existing rasterizer; image state belongs to this cell's exact saved brush.
private enum BrushLibraryThumbnailLoader {
    static let queue = DispatchQueue(label: "ArtFlex.brush-library-thumbnails", qos: .utility)

    static func image(for brush: BrushSettings) async -> CGImage? {
        let cancellation = WorkCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    guard !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let image = StageOneBrushPreviewRasterizer.libraryStrokePreviewImage(for: brush)
                    continuation.resume(returning: cancellation.isCancelled ? nil : image)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct BrushLibraryStrokeThumbnail: View {
    let brush: BrushSettings
    @State private var image: CGImage?
    @State private var didFinish = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else if didFinish {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: brush) {
            image = nil
            didFinish = false
            let rendered = await BrushLibraryThumbnailLoader.image(for: brush)
            guard !Task.isCancelled else { return }
            image = rendered
            didFinish = true
        }
    }
}
