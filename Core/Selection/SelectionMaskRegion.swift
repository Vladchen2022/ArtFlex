import Foundation

struct SelectionMaskRegion: Sendable {
    var originX: Int
    var originY: Int
    var width: Int
    var height: Int
    var alphaBytes: Data

    @inline(__always)
    func withAlphaBytes<Result>(_ body: (UnsafeBufferPointer<UInt8>) -> Result) -> Result {
        alphaBytes.withUnsafeBytes { rawBuffer in
            body(rawBuffer.bindMemory(to: UInt8.self))
        }
    }
}

