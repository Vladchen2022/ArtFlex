import Foundation

enum CanvasPixelEncoding: String, Codable, Sendable {
    case premultipliedBGRA8SRGB
    case premultipliedRGBA16FloatLinear
    case grayscale8

    var bytesPerPixel: Int {
        switch self {
        case .premultipliedBGRA8SRGB: 4
        case .premultipliedRGBA16FloatLinear: 8
        case .grayscale8: 1
        }
    }
}

/// The only CPU encoding boundary. Tool colors remain straight sRGB; stored half-floats are
/// linear premultiplied RGBA, matching what Metal samples from existing sRGB textures.
enum CanvasPixelCodec {
    static func read(_ bytes: UnsafeRawBufferPointer, offset: Int, encoding: CanvasPixelEncoding) -> LinearPremultipliedColor {
        switch encoding {
        case .premultipliedBGRA8SRGB:
            return .init(bgraBlue: bytes[offset], green: bytes[offset + 1], red: bytes[offset + 2], alpha: bytes[offset + 3])
        case .grayscale8:
            let value = Float(bytes[offset]) / 255
            return .init(red: value, green: value, blue: value, alpha: 1)
        case .premultipliedRGBA16FloatLinear:
            func channel(_ index: Int) -> Float {
                Float(Float16(bitPattern: UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset + index * 2, as: UInt16.self))))
            }
            return .init(red: channel(0), green: channel(1), blue: channel(2), alpha: channel(3))
        }
    }

    static func write(_ color: LinearPremultipliedColor, into bytes: UnsafeMutableRawBufferPointer,
                      offset: Int, encoding: CanvasPixelEncoding) {
        switch encoding {
        case .premultipliedRGBA16FloatLinear:
            for (index, value) in [color.red, color.green, color.blue, color.alpha].enumerated() {
                bytes.storeBytes(of: Float16(value).bitPattern.littleEndian, toByteOffset: offset + index * 2, as: UInt16.self)
            }
        case .premultipliedBGRA8SRGB:
            let value = color.bgra8PremultipliedBytes
            bytes[offset] = value.blue; bytes[offset + 1] = value.green
            bytes[offset + 2] = value.red; bytes[offset + 3] = value.alpha
        case .grayscale8:
            bytes[offset] = UInt8(clamping: Int((min(max(color.red, 0), 1) * 255).rounded()))
        }
    }
}
