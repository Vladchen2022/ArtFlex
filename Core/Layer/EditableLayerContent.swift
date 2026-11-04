import Foundation

/// Immutable, content-addressed input. Compressed bytes are external assets in native projects.
/// Equality uses the verified content identity, so workspace publication never scans image pixels.
struct EditableSourceAsset: Codable, Sendable, Equatable {
    var sha256: String
    var byteCount: Int
    var compressedData: Data?

    init(data: Data) throws {
        sha256 = ProjectReferenceImageHash.sha256Hex(data)
        byteCount = data.count
        compressedData = try ZlibCodec.compress(data)
    }

    func decoded(maximumBytes: Int = 512 * 1024 * 1024) throws -> Data {
        guard byteCount >= 0, byteCount <= maximumBytes, sha256.count == 64,
              let compressedData else { throw CocoaError(.fileReadCorruptFile) }
        let data = try ZlibCodec.decompress(compressedData, expectedSize: byteCount)
        guard ProjectReferenceImageHash.sha256Hex(data) == sha256 else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sha256 == rhs.sha256 && lhs.byteCount == rhs.byteCount
    }

    static func byteCounts(_ assets: [Self]) -> (archive: Int, resident: Int) {
        var seen = Set<String>(), archive = 0, resident = 0
        for source in assets where seen.insert(source.sha256).inserted {
            let a = archive.addingReportingOverflow(max(0, source.byteCount))
            let r = resident.addingReportingOverflow(max(0, source.compressedData?.count ?? source.byteCount))
            archive = a.overflow ? Int.max : a.partialValue; resident = r.overflow ? Int.max : r.partialValue
        }
        return (archive, resident)
    }
}

struct EditableImageSource: Codable, Sendable, Equatable {
    var width: Int
    var height: Int
    var encoding: CanvasPixelEncoding
    var pixels: EditableSourceAsset

    init(snapshot: LayerTextureSnapshot) throws {
        guard snapshot.width > 0, snapshot.height > 0,
              snapshot.bytesPerRow == snapshot.width * snapshot.encoding.bytesPerPixel,
              snapshot.pixelData.count == snapshot.bytesPerRow * snapshot.height else {
            throw CocoaError(.fileReadCorruptFile)
        }
        width = snapshot.width; height = snapshot.height; encoding = snapshot.encoding
        pixels = try .init(data: snapshot.pixelData)
    }

    func validate() throws {
        guard width > 0, height > 0, width <= 32768, height <= 32768,
              encoding != .grayscale8,
              width * height * encoding.bytesPerPixel == pixels.byteCount else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func snapshot() throws -> LayerTextureSnapshot {
        try validate()
        return .init(width: width, height: height, bytesPerRow: width * encoding.bytesPerPixel,
                     pixelData: try pixels.decoded(), encoding: encoding)
    }
}

struct EditableImagePlacement: Codable, Sendable, Equatable {
    var translation = CanvasPoint(x: 0, y: 0)
    var scaleX: Double = 1
    var scaleY: Double = 1
    var rotationDegrees: Double = 0

    func validate() throws {
        guard [translation.x, translation.y, scaleX, scaleY, rotationDegrees].allSatisfy(\.isFinite),
              abs(translation.x) <= 1_000_000, abs(translation.y) <= 1_000_000,
              abs(scaleX) >= 0.001, abs(scaleY) >= 0.001,
              abs(scaleX) <= 100, abs(scaleY) <= 100, abs(rotationDegrees) <= 36000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }
}

struct EditableTextureFill: Codable, Sendable, Equatable {
    var shape: SelectionShape
    var anchor: CanvasPoint
    var material: EditableSourceAsset
    var seed: UInt64
    var angle: Float
    var color: RGBAColor
    var scale: Float
    var coverage: Float
    var variation: Float
    var jitter: Float
    var contrast: Float
    var arrangement: TextureFillArrangement
    var alphaLocked: Bool
}

struct EditableGradientFill: Codable, Sendable, Equatable {
    enum Geometry: Codable, Sendable, Equatable {
        case linear(LinearGradientGeometry)
        case sector(SectorGradientGeometry)
    }
    var geometry: Geometry
    var settings: GradientSettings
    var color: RGBAColor
    var selection: SelectionShape?
    var jitter: Float
    var contrast: Float
    var distortion: Float
    var alphaLocked: Bool
}

enum EditableLayerOperation: Codable, Sendable, Equatable {
    case image(EditableImagePlacement)
    case texture(EditableTextureFill)
    case gradient(EditableGradientFill)
}

struct EditableLayerContent: Codable, Sendable, Equatable {
    var source: EditableImageSource
    var operation: EditableLayerOperation
    var canvasOrigin: CanvasPoint? = nil

    mutating func crop(originX: Int, originY: Int) {
        let old = canvasOrigin ?? .init(x: 0, y: 0)
        canvasOrigin = .init(x: old.x + Double(originX), y: old.y + Double(originY))
    }

    var displayName: String {
        switch operation { case .image: "无损图像"; case .texture: "纹理填充"; case .gradient: "渐变填充" }
    }

    var assets: [EditableSourceAsset] {
        if case .texture(let fill) = operation { return [source.pixels, fill.material] }
        return [source.pixels]
    }

    mutating func mapAssets(_ transform: (EditableSourceAsset) throws -> EditableSourceAsset) rethrows {
        source.pixels = try transform(source.pixels)
        if case .texture(var fill) = operation {
            fill.material = try transform(fill.material)
            operation = .texture(fill)
        }
    }

    func validate() throws {
        try source.validate()
        if let origin = canvasOrigin {
            guard [origin.x, origin.y].allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 && $0.rounded() == $0 }) else { throw CocoaError(.fileReadCorruptFile) }
        }
        func validPoint(_ point: CanvasPoint) -> Bool {
            point.x.isFinite && point.y.isFinite && abs(point.x) <= 1_000_000 && abs(point.y) <= 1_000_000
        }
        func validateShape(_ shape: SelectionShape, depth: Int = 0) throws {
            guard depth < 32, shape.pathPoints.count <= 1_000_000, shape.components.count <= 4096,
                  validPoint(shape.bounds.origin), validPoint(shape.bounds.size), shape.pathPoints.allSatisfy(validPoint) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let mask = shape.maskData {
                guard mask.canvasWidth > 0, mask.canvasHeight > 0, mask.canvasWidth <= 32768, mask.canvasHeight <= 32768,
                      mask.storedByteCount <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
            }
            for component in shape.components { try validateShape(component.shape, depth: depth + 1) }
        }
        switch operation {
        case .image(let placement): try placement.validate()
        case .texture(let fill):
            try validateShape(fill.shape)
            guard [fill.angle, fill.scale, fill.coverage, fill.variation, fill.jitter, fill.contrast].allSatisfy(\.isFinite),
                  fill.scale > 0, fill.scale <= 100, fill.material.byteCount <= 64 * 1024 * 1024,
                  fill.anchor.x.isFinite, fill.anchor.y.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        case .gradient(let fill):
            guard [fill.jitter, fill.contrast, fill.distortion].allSatisfy(\.isFinite) else { throw CocoaError(.fileReadCorruptFile) }
            if let selection = fill.selection { try validateShape(selection) }
            switch fill.geometry {
            case .linear(let geometry):
                guard [geometry.pointA, geometry.pointB, geometry.pointC].allSatisfy(validPoint),
                      geometry.transitionMidpoint.isFinite, (0.05...0.95).contains(geometry.transitionMidpoint) else { throw CocoaError(.fileReadCorruptFile) }
            case .sector(let geometry):
                guard validPoint(geometry.center), geometry.pathPoints.count >= 3, geometry.pathPoints.count <= 1_000_000,
                      geometry.pathPoints.allSatisfy(validPoint), geometry.maxRadius.isFinite,
                      geometry.maxRadius > 0.5, geometry.maxRadius <= 1_000_000 else { throw CocoaError(.fileReadCorruptFile) }
            }
        }
    }
}

extension ArtDocument {
    var editableSourceAssets: [EditableSourceAsset] {
        layers.flatMap { $0.editableContent?.assets ?? [] } + (storedBranches ?? []).map(\.project)
    }

    mutating func mapEditableSourceAssets(_ transform: (EditableSourceAsset) throws -> EditableSourceAsset) rethrows {
        for index in layers.indices { try layers[index].editableContent?.mapAssets(transform) }
        for index in storedBranches?.indices ?? 0..<0 {
            storedBranches![index].project = try transform(storedBranches![index].project)
        }
    }

    var editableSourceByteCounts: (archive: Int, resident: Int) {
        EditableSourceAsset.byteCounts(editableSourceAssets)
    }
}
