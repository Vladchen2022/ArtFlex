import Foundation
import Metal

enum MetalSurfacePixelFormat: String, Sendable {
    case bgra8UnormSRGB
    case rgba16FloatLinear
}

struct MetalSurfaceDescriptor: Sendable, Equatable {
    var width: Int
    var height: Int
    var pixelFormat: MetalSurfacePixelFormat

    static func stageOneCanvas(width: Int, height: Int, format: ArtPixelFormat = .rgba8) -> MetalSurfaceDescriptor {
        MetalSurfaceDescriptor(
            width: width,
            height: height,
            pixelFormat: format == .rgba16Float ? .rgba16FloatLinear : .bgra8UnormSRGB
        )
    }
}

extension CanvasPixelEncoding {
    var metalPixelFormat: MTLPixelFormat {
        switch self {
        case .premultipliedBGRA8SRGB: .bgra8Unorm_srgb
        case .premultipliedRGBA16FloatLinear: .rgba16Float
        case .grayscale8: .r8Unorm
        }
    }

    init(metalPixelFormat: MTLPixelFormat) {
        switch metalPixelFormat {
        case .rgba16Float: self = .premultipliedRGBA16FloatLinear
        case .r8Unorm: self = .grayscale8
        default: self = .premultipliedBGRA8SRGB
        }
    }
}
