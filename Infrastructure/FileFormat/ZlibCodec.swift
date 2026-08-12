import Foundation
import zlib

enum ZlibCodecError: LocalizedError, Sendable, Equatable {
    case invalidExpectedSize(Int)
    case compressionFailed(Int32)
    case decompressionFailed(Int32)
    case decodedSizeMismatch(expected: Int, actual: Int)
    case trailingCompressedBytes(expected: Int, consumed: Int)

    var errorDescription: String? {
        switch self {
        case .invalidExpectedSize(let size):
            return "无效的 zlib 解压目标长度：\(size)"
        case .compressionFailed(let status):
            return "zlib 压缩失败，状态码 \(status)"
        case .decompressionFailed(let status):
            return "zlib 解压失败，状态码 \(status)"
        case .decodedSizeMismatch(let expected, let actual):
            return "zlib 解压长度不匹配，预期 \(expected)，实际 \(actual)"
        case .trailingCompressedBytes(let expected, let consumed):
            return "zlib 数据包含未消费字节，总计 \(expected)，已消费 \(consumed)"
        }
    }
}

enum ZlibCodec {
    static func compress(
        _ data: Data,
        level: Int32 = Z_DEFAULT_COMPRESSION
    ) throws -> Data {
        let sourceLength = uLong(data.count)
        let destinationCapacity = compressBound(sourceLength)
        guard destinationCapacity <= uLong(Int.max) else {
            throw ZlibCodecError.compressionFailed(Z_MEM_ERROR)
        }

        var destination = Data(count: max(Int(destinationCapacity), 1))
        var destinationLength = uLongf(destinationCapacity)
        let sourceStorage = data.isEmpty ? Data([0]) : data

        let status: Int32 = destination.withUnsafeMutableBytes { destinationBuffer in
            sourceStorage.withUnsafeBytes { sourceBuffer in
                guard
                    let destinationBase = destinationBuffer.bindMemory(to: Bytef.self).baseAddress,
                    let sourceBase = sourceBuffer.bindMemory(to: Bytef.self).baseAddress
                else {
                    return Z_MEM_ERROR
                }
                return compress2(
                    destinationBase,
                    &destinationLength,
                    sourceBase,
                    sourceLength,
                    level
                )
            }
        }
        guard status == Z_OK else {
            throw ZlibCodecError.compressionFailed(status)
        }

        destination.count = Int(destinationLength)
        return destination
    }

    static func decompress(
        _ data: Data,
        expectedSize: Int
    ) throws -> Data {
        guard expectedSize >= 0 else {
            throw ZlibCodecError.invalidExpectedSize(expectedSize)
        }

        var destination = Data(count: max(expectedSize, 1))
        var destinationLength = uLongf(expectedSize)
        var sourceLength = uLong(data.count)
        let sourceStorage = data.isEmpty ? Data([0]) : data

        let status: Int32 = destination.withUnsafeMutableBytes { destinationBuffer in
            sourceStorage.withUnsafeBytes { sourceBuffer in
                guard
                    let destinationBase = destinationBuffer.bindMemory(to: Bytef.self).baseAddress,
                    let sourceBase = sourceBuffer.bindMemory(to: Bytef.self).baseAddress
                else {
                    return Z_MEM_ERROR
                }
                return uncompress2(
                    destinationBase,
                    &destinationLength,
                    sourceBase,
                    &sourceLength
                )
            }
        }
        guard status == Z_OK else {
            throw ZlibCodecError.decompressionFailed(status)
        }
        guard Int(destinationLength) == expectedSize else {
            throw ZlibCodecError.decodedSizeMismatch(
                expected: expectedSize,
                actual: Int(destinationLength)
            )
        }
        guard Int(sourceLength) == data.count else {
            throw ZlibCodecError.trailingCompressedBytes(
                expected: data.count,
                consumed: Int(sourceLength)
            )
        }

        destination.count = expectedSize
        return destination
    }
}
