import Foundation

enum MetalSurfacePixelFormat: String, Sendable {
    case bgra8UnormSRGB
}

struct MetalSurfaceDescriptor: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixelFormat: MetalSurfacePixelFormat

    static func stageOneCanvas(width: Int, height: Int) -> MetalSurfaceDescriptor {
        MetalSurfaceDescriptor(
            width: width,
            height: height,
            pixelFormat: .bgra8UnormSRGB
        )
    }
}
