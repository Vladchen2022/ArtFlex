import CoreGraphics
import Foundation
import ImageIO
import ZIPFoundation

enum OpenRasterError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return "OpenRaster：\(reason)" }; return nil }
}

/// The exchange boundary is deliberately narrower than the native document format.
/// ZIP entries are streamed into bounded buffers, never extracted to external paths.
enum OpenRasterCodec {
    static let blendNames: [LayerBlendMode: String] = [.normal: "svg:src-over", .multiply: "svg:multiply",
        .screen: "svg:screen", .add: "svg:plus", .overlay: "svg:overlay", .softLight: "svg:soft-light",
        .darken: "svg:darken", .lighten: "svg:lighten"]

    static func unsupportedLayers(_ document: ArtDocument) -> [String] {
        document.layers.compactMap { layer in
            if layer.adjustment != nil { return "\(layer.name)：调整图层" }
            if layer.mask != nil { return "\(layer.name)：图层蒙版" }
            if layer.clipTargetLayerID != nil { return "\(layer.name)：剪贴关系" }
            if layer.isGroup && layer.blendMode != .normal { return "\(layer.name)：组混合" }
            return nil
        }
    }

    static func read(from url: URL, flattened: Bool = false, limits: ProjectArchiveReadLimits = .standard,
                     context: ProjectReadContext = .init()) throws -> OpenProjectResult {
        try context.check()
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Entry] = [:]
        var expanded: UInt64 = 0
        for entry in archive {
            try context.check()
            let components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !entry.path.isEmpty, entry.path.utf8.count < 4096, !entry.path.hasPrefix("/"), !entry.path.contains("\\"), !entry.path.contains("\0"),
                  !components.contains(".."), !components.contains("."),
                  entry.type != .symlink, entries[entry.path] == nil,
                  entries.count < limits.maximumLayerCount * 3 + 32,
                  entry.uncompressedSize <= UInt64(limits.maximumStoredAssetBytes) else {
                throw OpenRasterError.invalid("归档条目路径、类型或容量不合法")
            }
            expanded += entry.uncompressedSize
            guard expanded <= UInt64(limits.maximumTotalUncompressedBytes) else { throw OpenRasterError.invalid("归档解压容量超出预算") }
            entries[entry.path] = entry
        }
        func data(_ path: String, maximum: Int) throws -> Data {
            try context.check()
            guard let entry = entries[path], entry.type == .file, entry.uncompressedSize <= maximum else {
                throw OpenRasterError.invalid("缺少文件或文件过大：\(path)")
            }
            var bytes = Data()
            let checksum = try archive.extract(entry) { chunk in
                try context.check()
                guard bytes.count <= maximum - chunk.count else { throw OpenRasterError.invalid("解压超过声明容量") }
                bytes.append(chunk)
            }
            guard checksum == entry.checksum, bytes.count == entry.uncompressedSize else { throw OpenRasterError.invalid("文件校验失败：\(path)") }
            return bytes
        }
        guard try data("mimetype", maximum: 64) == Data("image/openraster".utf8) else { throw OpenRasterError.invalid("文件类型不正确") }
        let xml = try data("stack.xml", maximum: limits.maximumManifestBytes)
        let stack = try OpenRasterStack.parse(xml, maximumLayers: limits.maximumLayerCount, viewingOnly: flattened)
        let size = stack.size
        guard size.width > 0, size.height > 0, size.width <= limits.maximumCanvasEdge, size.height <= limits.maximumCanvasEdge,
              size.width * size.height <= limits.maximumCanvasPixelCount else { throw OpenRasterError.invalid("画布尺寸超出预算") }
        var state = WorkspaceState.stageOneDefault
        state.document.canvasSize = size
        state.document.metadata.name = url.deletingPathExtension().lastPathComponent
        state.document.metadata.resolutionDPI = stack.dpi
        state.document.layers = []
        var snapshots: [LayerHistorySnapshot] = []
        var decodedBytes = 0
        var wide = false
        func decode(_ path: String, x: Int, y: Int, id: LayerID) throws {
            let bytes = try data(path, maximum: limits.maximumStoredAssetBytes)
            guard path.lowercased().hasSuffix(".png"), let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == "public.png",
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
                  w > 0, h > 0, w <= limits.maximumCanvasEdge, h <= limits.maximumCanvasEdge,
                  w * h <= limits.maximumCanvasPixelCount, w * h * 8 <= limits.maximumUncompressedAssetBytes else {
                throw OpenRasterError.invalid("图层图片无效或尺寸过大")
            }
            guard x >= 0, y >= 0, x <= size.width - w, y <= size.height - h else {
                throw OpenRasterError.invalid("含画布外像素，当前分层导入不支持；可选择仅导入合并图像")
            }
            decodedBytes += w * h * 8
            guard decodedBytes <= limits.maximumTotalUncompressedBytes else { throw OpenRasterError.invalid("图层像素总量超出预算") }
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let pixels = CanonicalImageDecoder.snapshot(from: image) else { throw OpenRasterError.invalid("无法解码图层") }
            wide = wide || image.colorSpace?.isWideGamutRGB == true
            snapshots.append(.init(layerID: id, texture: pixels, originX: x, originY: y))
            context.report(.layers, completed: snapshots.count, total: flattened ? 1 : stack.layerCount)
        }
        func append(_ node: OpenRasterStack.Node, parent: LayerID?) throws {
            try context.check()
            let group = node.tag == "stack"
            if group && (node.attributes["isolation"] ?? "isolate") != "auto" {
                throw OpenRasterError.invalid("含隔离组，ArtFlex 当前组为穿透组；可选择仅导入合并图像")
            }
            guard let blend = blendNames.first(where: { $0.value == (node.attributes["composite-op"] ?? "svg:src-over") })?.key else {
                throw OpenRasterError.invalid("不支持混合模式 \(node.attributes["composite-op"] ?? "")")
            }
            guard let opacity = Float(node.attributes["opacity"] ?? "1"), opacity.isFinite, (0...1).contains(opacity),
                  ["visible", "hidden"].contains(node.attributes["visibility"] ?? "visible") else { throw OpenRasterError.invalid("图层透明度或可见性无效") }
            let layer = LayerRecord(id: .init(), name: String((node.attributes["name"] ?? "图层").prefix(256)),
                kind: group ? .group : .paint, parentID: parent, isVisible: node.attributes["visibility"] != "hidden",
                isLocked: false, locksTransparentPixels: false, opacity: opacity, blendMode: group ? .normal : blend)
            state.document.layers.append(layer)
            if group { for child in node.children.reversed() { try append(child, parent: layer.id) } }
            else {
                guard let path = node.attributes["src"], let x = Int(node.attributes["x"] ?? "0"), let y = Int(node.attributes["y"] ?? "0") else { throw OpenRasterError.invalid("缺少图层源或坐标") }
                try decode(path, x: x, y: y, id: layer.id)
            }
        }
        if flattened {
            let layer = LayerRecord.stageOneDefault()
            state.document.layers = [layer]
            try decode("mergedimage.png", x: 0, y: 0, id: layer.id)
        } else { for child in stack.root.children.reversed() { try append(child, parent: nil) } }
        guard let active = state.document.paintLayers.last else { throw OpenRasterError.invalid("没有可用像素图层") }
        let high = snapshots.contains { $0.texture.encoding == .premultipliedRGBA16FloatLinear }
        state.document.colorStandard = wide ? .wideGamut : (high ? .highPrecision : .stageOneDefault)
        for index in snapshots.indices { snapshots[index].texture = try snapshots[index].texture.converted(to: state.document.colorStandard.pixelFormat.encoding) }
        state.document.activeLayerID = active.id
        try context.check()
        return .init(workspace: state, layerSnapshots: snapshots, previewPNGData: try? data("Thumbnails/thumbnail.png", maximum: 2 * 1024 * 1024))
    }

    static func write(_ payload: ProjectArchivePayload, merged: LayerTextureSnapshot, to url: URL, flattened: Bool = false,
                      context: ProjectReadContext = .init()) throws {
        let document = payload.package.document
        let incompatible = unsupportedLayers(document)
        guard flattened || incompatible.isEmpty else { throw OpenRasterError.invalid("分层导出不能保留：\(incompatible.joined(separator: "、"))；请选择合并图像") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).ora")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try context.check()
        let archive = try Archive(url: temporary, accessMode: .create)
        func add(_ name: String, _ data: Data) throws {
            try context.check()
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) { position, count in
                try context.check()
                return data.subdata(in: Int(position)..<min(Int(position) + count, data.count))
            }
        }
        try add("mimetype", Data("image/openraster".utf8))
        let profile: ManagedRGBProfile = document.colorStandard.colorSpace == .extendedSRGB ? .displayP3 : .sRGB
        let depth: RasterExportBitDepth = document.colorStandard.pixelFormat == .rgba16Float ? .sixteen : .eight
        func png(_ pixels: LayerTextureSnapshot, thumbnail: Bool = false) throws -> Data {
            try context.check()
            return try RasterExporter().encode(snapshot: pixels, options: .init(background: .transparent,
                resize: thumbnail ? .scale(min(1, 256 / Double(max(pixels.width, pixels.height)))) : .original,
                bitDepth: thumbnail ? .eight : depth, colorProfile: thumbnail ? .sRGB : profile)).encodedData
        }
        try add("mergedimage.png", png(merged))
        try add("Thumbnails/thumbnail.png", png(merged, thumbnail: true))
        var index = 0
        func escape(_ value: String) -> String {
            value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func render(_ layers: [LayerRecord]) throws -> String {
            var xml = ""
            for layer in layers.reversed() {
                try context.check()
                let attributes = "name=\"\(escape(layer.name))\" opacity=\"\(layer.opacity)\" visibility=\"\(layer.isVisible ? "visible" : "hidden")\" composite-op=\"\(blendNames[layer.blendMode]!)\""
                if layer.isGroup {
                    xml += "<stack \(attributes) isolation=\"auto\">\(try render(document.layers.filter { $0.parentID == layer.id }))</stack>"
                } else {
                    guard let snapshot = payload.package.layerSnapshots.first(where: { $0.layerID == layer.id && $0.resourceKind == .content }) else { throw OpenRasterError.invalid("缺少图层像素") }
                    let path = "data/layer\(index).png"; index += 1
                    try add(path, png(snapshot.texture))
                    xml += "<layer \(attributes) src=\"\(path)\" x=\"\(snapshot.originX)\" y=\"\(snapshot.originY)\"/>"
                    context.report(.writing, completed: index, total: document.paintLayers.count)
                }
            }
            return xml
        }
        let content = flattened ? "<layer name=\"合并图像\" src=\"mergedimage.png\"/>" : try render(document.layers.filter { $0.parentID == nil })
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><image version=\"0.0.6\" w=\"\(document.canvasSize.width)\" h=\"\(document.canvasSize.height)\" xres=\"\(document.metadata.resolutionDPI)\" yres=\"\(document.metadata.resolutionDPI)\"><stack>\(content)</stack></image>"
        try add("stack.xml", Data(xml.utf8))
        try context.check()
        context.report(.committing)
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
}

private final class OpenRasterStack: NSObject, XMLParserDelegate {
    final class Node {
        let tag: String
        let attributes: [String: String]
        var children: [Node] = []
        init(_ tag: String, _ attributes: [String: String]) { self.tag = tag; self.attributes = attributes }
    }
    var size = CanvasSize(width: 0, height: 0)
    var dpi = 72
    var root = Node("stack", [:])
    var layerCount = 0
    var nodes: [Node] = []
    var failure: String?
    var seenImage = false
    var seenRoot = false
    let maximum: Int
    let viewingOnly: Bool
    init(maximum: Int, viewingOnly: Bool) { self.maximum = maximum; self.viewingOnly = viewingOnly }
    static func parse(_ bytes: Data, maximumLayers: Int, viewingOnly: Bool) throws -> OpenRasterStack {
        // Reject DTDs before parsing; no external entities or entity expansion is needed by ORA.
        guard let xml = String(data: bytes, encoding: .utf8), !xml.localizedCaseInsensitiveContains("<!DOCTYPE"),
              !xml.localizedCaseInsensitiveContains("<!ENTITY") else { throw OpenRasterError.invalid("只接受无 DTD 的 UTF-8 图层描述") }
        let delegate = OpenRasterStack(maximum: maximumLayers, viewingOnly: viewingOnly)
        let parser = XMLParser(data: bytes); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), delegate.failure == nil, delegate.seenImage, delegate.seenRoot else { throw OpenRasterError.invalid(delegate.failure ?? "图层 XML 无效") }
        return delegate
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        func reject(_ reason: String) { failure = reason; parser.abortParsing() }
        guard nodes.count < 64, attributes.values.allSatisfy({ $0.utf8.count <= 4096 }) else { reject("图层层级或属性过大"); return }
        if name == "image" {
            guard !seenImage, nodes.isEmpty, let w = Int(attributes["w"] ?? ""), let h = Int(attributes["h"] ?? "") else { reject("画布定义无效"); return }
            seenImage = true; size = .init(width: w, height: h)
            if let x = attributes["xres"] {
                guard let value = Int(x), (1...9600).contains(value), attributes["yres"] == x else { reject("不支持横纵不同的分辨率"); return }
                dpi = value
            }
        } else if name == "stack" || name == "layer" {
            guard seenImage, nodes.last?.tag != "layer", !seenRoot || !nodes.isEmpty else { reject("图层结构无效"); return }
            let node = Node(name, attributes)
            if nodes.isEmpty {
                guard name == "stack" else { reject("缺少根图层组"); return }
                root = node; seenRoot = true
            } else {
                layerCount += 1
                guard layerCount <= maximum else { reject("图层数量超过限制"); return }
                nodes.last?.children.append(node)
            }
            nodes.append(node)
        } else if !viewingOnly { reject("不支持图层元素 \(name)，可选择仅导入合并图像") }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "stack" || name == "layer" { _ = nodes.popLast() }
    }
}
