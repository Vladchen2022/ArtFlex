import CryptoKit
import Foundation

struct ProjectReferenceImageAssetID: Hashable, Codable, Sendable, Equatable, Comparable {
    var rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(encodedImageData: Data) {
        self.rawValue = "reference-\(ProjectReferenceImageHash.sha256Hex(encodedImageData))"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct ProjectReferenceImageDescriptor: Codable, Sendable, Equatable, Identifiable {
    static let maximumSlotCount = 5

    var id: UUID
    var slotIndex: Int
    var assetID: ProjectReferenceImageAssetID
    var displayName: String
    var originalFilename: String
    var typeIdentifier: String?
    var pixelWidth: Int
    var pixelHeight: Int

    init(
        id: UUID = UUID(),
        slotIndex: Int,
        assetID: ProjectReferenceImageAssetID,
        displayName: String,
        originalFilename: String,
        typeIdentifier: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.id = id
        self.slotIndex = slotIndex
        self.assetID = assetID
        self.displayName = displayName
        self.originalFilename = originalFilename
        self.typeIdentifier = typeIdentifier
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    func validate() throws {
        guard (0..<Self.maximumSlotCount).contains(slotIndex) else {
            throw ProjectReferenceImageError.invalidSlotIndex(slotIndex)
        }
        guard !assetID.rawValue.isEmpty else {
            throw ProjectReferenceImageError.invalidAssetIdentifier
        }
        guard !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectReferenceImageError.missingDisplayName
        }
        guard !originalFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectReferenceImageError.missingOriginalFilename
        }
        guard pixelWidth > 0, pixelHeight > 0 else {
            throw ProjectReferenceImageError.invalidPixelDimensions
        }
    }
}

struct ProjectReferenceImagePayload: Sendable, Equatable {
    var descriptor: ProjectReferenceImageDescriptor
    var encodedImageData: Data

    init(
        descriptor: ProjectReferenceImageDescriptor,
        encodedImageData: Data
    ) throws {
        self.descriptor = descriptor
        self.encodedImageData = encodedImageData
        try validate()
    }

    init(
        id: UUID = UUID(),
        slotIndex: Int,
        displayName: String,
        originalFilename: String,
        typeIdentifier: String? = nil,
        pixelWidth: Int,
        pixelHeight: Int,
        encodedImageData: Data
    ) throws {
        let assetID = ProjectReferenceImageAssetID(encodedImageData: encodedImageData)
        try self.init(
            descriptor: ProjectReferenceImageDescriptor(
                id: id,
                slotIndex: slotIndex,
                assetID: assetID,
                displayName: displayName,
                originalFilename: originalFilename,
                typeIdentifier: typeIdentifier,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            ),
            encodedImageData: encodedImageData
        )
    }

    func validate() throws {
        try descriptor.validate()
        guard !encodedImageData.isEmpty else {
            throw ProjectReferenceImageError.emptyEncodedImageData
        }
        let expectedID = ProjectReferenceImageAssetID(encodedImageData: encodedImageData)
        guard descriptor.assetID == expectedID else {
            throw ProjectReferenceImageError.assetIdentifierMismatch
        }
    }
}

enum ProjectReferenceImageError: LocalizedError, Sendable, Equatable {
    case invalidSlotIndex(Int)
    case invalidAssetIdentifier
    case missingDisplayName
    case missingOriginalFilename
    case invalidPixelDimensions
    case emptyEncodedImageData
    case assetIdentifierMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSlotIndex(let index):
            return "参考图槽位超出支持范围：\(index)"
        case .invalidAssetIdentifier:
            return "参考图资产标识无效"
        case .missingDisplayName:
            return "参考图显示名称不能为空"
        case .missingOriginalFilename:
            return "参考图原始文件名不能为空"
        case .invalidPixelDimensions:
            return "参考图像素尺寸无效"
        case .emptyEncodedImageData:
            return "参考图编码数据为空"
        case .assetIdentifierMismatch:
            return "参考图内容与资产标识不匹配"
        }
    }
}

enum ProjectReferenceImageHash {
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
