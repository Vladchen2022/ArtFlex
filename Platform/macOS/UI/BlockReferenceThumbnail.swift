import SwiftUI

/// Small resource previews reuse the same model projection, never an unrelated symbol.
struct BlockReferenceThumbnail: View {
    var objects: [BlockReferenceObject]
    var camera: BlockReferenceCamera? = nil

    var body: some View {
        Canvas { context, size in
            let faces = objects.filter(\.isVisible).flatMap { blockObjectFaces($0) }
            let points = faces.flatMap(\.vertices)
            guard let first = points.first else { return }
            var low = first, high = first
            for p in points {
                low.x = min(low.x, p.x); low.y = min(low.y, p.y); low.z = min(low.z, p.z)
                high.x = max(high.x, p.x); high.y = max(high.y, p.y); high.z = max(high.z, p.z)
            }
            var viewCamera = camera ?? .stageOneDefault
            if camera == nil {
                viewCamera.target = (low + high) * 0.5
                viewCamera.distance = max((high - low).length * 2.1, 80)
            }
            let canvasSize = CanvasSize(width: max(1, Int(size.width)), height: max(1, Int(size.height)))
            let projected = faces.compactMap { face -> ([CGPoint], Double, Double)? in
                let projected = face.vertices.compactMap { projectBlockPoint($0, camera: viewCamera, canvasSize: canvasSize) }
                guard projected.count == face.vertices.count else { return nil }
                return (projected.map { CGPoint(x: $0.canvasPoint.x, y: $0.canvasPoint.y) },
                        projected.map(\.cameraDepth).reduce(0, +) / Double(projected.count),
                        0.5 + max(0, face.normal.dot(BlockVector3(x: -0.35, y: -0.55, z: 1).normalized())) * 0.4)
            }.sorted { $0.1 > $1.1 }
            for (vertices, _, shade) in projected {
                var path = Path()
                path.addLines(vertices); path.closeSubpath()
                context.fill(path, with: .color(Color(white: shade)))
                context.stroke(path, with: .color(.black.opacity(0.6)), lineWidth: 0.5)
            }
        }
        .background(Color.black.opacity(0.22))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityHidden(true)
    }
}
