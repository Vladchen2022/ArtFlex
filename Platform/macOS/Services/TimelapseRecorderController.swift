import AVFoundation
import CryptoKit
import CoreVideo
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

enum RecorderFrameFormat: String, CaseIterable, Identifiable, Sendable {
    case jpeg = "JPEG"
    case png = "PNG"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        }
    }

    var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        }
    }
}

enum RecorderResolutionScale: String, CaseIterable, Identifiable, Sendable {
    case full = "原始"
    case half = "减半"
    case quarter = "四分之一"

    var id: String { rawValue }

    var divisor: Int {
        switch self {
        case .full: return 1
        case .half: return 2
        case .quarter: return 4
        }
    }

    var displayName: String {
        switch self {
        case .full: return "原始"
        case .half: return "减半"
        case .quarter: return "四分之一"
        }
    }
}

private final class RecorderTextureBox<T>: @unchecked Sendable {
    let value: T

    init(_ value: T) {
        self.value = value
    }
}

private final class RecorderSerializerBox: @unchecked Sendable {
    let value: LayerTextureSerializer

    init(_ value: LayerTextureSerializer) {
        self.value = value
    }
}

private struct RecorderLayerCaptureSource: @unchecked Sendable {
    let texture: RecorderTextureBox<MTLTexture>
    let opacity: Float
}

private struct RecorderCaptureSource: @unchecked Sendable {
    let documentName: String
    let canvasSize: CanvasSize
    let layers: [RecorderLayerCaptureSource]
}

@MainActor
final class TimelapseRecorderController: ObservableObject {
    private static let maxPendingJobs = 3

    @Published var outputDirectory: URL? {
        didSet {
            persistOutputDirectory()
            if !currentDocumentName.isEmpty {
                syncCurrentDocument(documentName: currentDocumentName, documentFileURL: currentDocumentFileURL)
            }
        }
    }
    @Published var captureInterval: Double = 5
    @Published var frameFormat: RecorderFrameFormat = .jpeg
    @Published var qualityPercent: Double = 60
    @Published var resolutionScale: RecorderResolutionScale = .half
    @Published var autoStart = false
    @Published var exportLeadInSeconds: Double = 0
    @Published var exportTailHoldSeconds: Double = 2
    @Published private(set) var isRecording = false
    @Published private(set) var currentDocumentName = ""
    @Published private(set) var currentSessionDirectory: URL?
    @Published private(set) var savedFrameCount = 0
    @Published private(set) var pendingJobCount = 0
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var isExportingVideo = false
    @Published private(set) var lastExportedVideoURL: URL?

    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let writerQueue = DispatchQueue(label: "ArtFlex.Recorder.Writer", qos: .utility)
    private let defaults: UserDefaults
    private static let outputDirectoryBookmarkKey = "ArtFlex.TimelapseRecorder.OutputDirectoryBookmark"

    private var captureTimer: Timer?
    private var pendingRevision: UInt64?
    private var lastCapturedRevision: UInt64 = 0
    private var lastCaptureDate: Date?
    private var nextFrameIndex = 0
    private var currentDocumentFileURL: URL?

    init(
        workspaceStore: WorkspaceStore,
        layerSurfaceStore: StageOneLayerSurfaceStore,
        serializer: LayerTextureSerializer,
        defaults: UserDefaults = .standard
    ) {
        self.workspaceStore = workspaceStore
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        self.defaults = defaults
        self.outputDirectory = Self.restoreOutputDirectory(from: defaults)
    }

    var outputDirectoryPath: String {
        outputDirectory?.path ?? ""
    }

    var currentSessionName: String {
        currentSessionDirectory?.lastPathComponent ?? "未准备会话"
    }

    var canExportVideo: Bool {
        currentSessionDirectory != nil && savedFrameCount > 0 && !isExportingVideo && pendingJobCount == 0
    }

    func syncCurrentDocument(documentName: String, documentFileURL: URL? = nil) {
        currentDocumentName = documentName
        currentDocumentFileURL = documentFileURL
        guard let outputDirectory else {
            currentSessionDirectory = nil
            savedFrameCount = 0
            nextFrameIndex = 0
            return
        }

        do {
            let directory = try makeSessionDirectory(
                rootDirectory: outputDirectory,
                documentName: documentName,
                documentFileURL: documentFileURL
            )
            currentSessionDirectory = directory
            let frameURLs = try Self.sortedFrameURLs(in: directory)
            savedFrameCount = frameURLs.count
            nextFrameIndex = Self.nextFrameIndex(for: frameURLs)
        } catch {
            currentSessionDirectory = nil
            savedFrameCount = 0
            nextFrameIndex = 0
        }
    }

    @discardableResult
    func startRecording(documentName: String, documentFileURL: URL? = nil) throws -> URL {
        syncCurrentDocument(documentName: documentName, documentFileURL: documentFileURL)

        if isRecording, let currentSessionDirectory {
            return currentSessionDirectory
        }

        guard outputDirectory != nil, let sessionDirectory = currentSessionDirectory else {
            throw CocoaError(.fileNoSuchFile)
        }

        isRecording = true
        pendingJobCount = 0
        droppedFrameCount = 0
        pendingRevision = nil
        lastCapturedRevision = 0
        lastCaptureDate = nil
        lastExportedVideoURL = nil
        captureTimer?.invalidate()
        captureTimer = nil
        return sessionDirectory
    }

    func stopRecording() {
        isRecording = false
        captureTimer?.invalidate()
        captureTimer = nil
        pendingRevision = nil
    }

    func noteCanvasChanged(revision: UInt64, documentName: String, documentFileURL: URL? = nil) {
        guard outputDirectory != nil else { return }

        if !isRecording {
            guard autoStart else { return }
            _ = try? startRecording(documentName: documentName, documentFileURL: documentFileURL)
        }

        guard isRecording else { return }

        pendingRevision = revision
        scheduleCapture(documentName: documentName)
    }

    func exportCurrentSessionVideo(
        to outputURL: URL,
        fps: Int,
        leadInSeconds: Double,
        tailHoldSeconds: Double,
        completion: @Sendable @escaping (Result<URL, Error>) -> Void
    ) {
        guard let sessionDirectory = currentSessionDirectory else {
            completion(.failure(CocoaError(.fileNoSuchFile)))
            return
        }

        isExportingVideo = true
        writerQueue.async {
            let result = Self.exportVideo(
                from: sessionDirectory,
                to: outputURL,
                fps: max(1, fps),
                leadInSeconds: max(0, leadInSeconds),
                tailHoldSeconds: max(0, tailHoldSeconds)
            )
            DispatchQueue.main.async {
                self.isExportingVideo = false
                if case .success(let url) = result {
                    self.lastExportedVideoURL = url
                }
                completion(result)
            }
        }
    }

    private func scheduleCapture(documentName: String) {
        guard pendingRevision != nil else { return }

        captureTimer?.invalidate()
        let now = Date()
        let elapsed = lastCaptureDate.map { now.timeIntervalSince($0) } ?? captureInterval
        let delay = max(0, captureInterval - elapsed)

        if delay <= 0.001 {
            capturePendingFrame(documentName: documentName)
            return
        }

        captureTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.captureTimer = nil
                self.capturePendingFrame(documentName: documentName)
            }
        }
    }

    private func persistOutputDirectory() {
        guard let outputDirectory else {
            defaults.removeObject(forKey: Self.outputDirectoryBookmarkKey)
            return
        }

        do {
            let bookmark = try outputDirectory.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(bookmark, forKey: Self.outputDirectoryBookmarkKey)
        } catch {
            defaults.set(outputDirectory.path, forKey: Self.outputDirectoryBookmarkKey)
        }
    }

    private static func restoreOutputDirectory(from defaults: UserDefaults) -> URL? {
        if let bookmark = defaults.data(forKey: outputDirectoryBookmarkKey) {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        if let legacyPath = defaults.string(forKey: outputDirectoryBookmarkKey) {
            return URL(fileURLWithPath: legacyPath)
        }

        return nil
    }

    private func capturePendingFrame(documentName: String) {
        guard
            let revision = pendingRevision,
            revision != lastCapturedRevision,
            let sessionDirectory = currentSessionDirectory,
            let captureSource = makeCaptureSource(documentName: documentName)
        else {
            return
        }

        pendingRevision = nil
        lastCapturedRevision = revision
        lastCaptureDate = Date()

        let format = frameFormat
        let scale = resolutionScale
        let quality = qualityPercent

        if pendingJobCount >= Self.maxPendingJobs {
            droppedFrameCount += 1
            return
        }

        let frameIndex = nextFrameIndex
        nextFrameIndex += 1
        pendingJobCount += 1

        let outputURL = sessionDirectory.appendingPathComponent(
            String(format: "frame_%06d.%@", frameIndex, format.fileExtension)
        )
        let serializer = RecorderSerializerBox(self.serializer)

        writerQueue.async {
            let result = Result {
                let image = try Self.makeCompositeImage(
                    from: captureSource,
                    serializer: serializer.value,
                    scale: scale
                )
                try Self.writeImage(
                    image,
                    to: outputURL,
                    format: format,
                    qualityPercent: quality
                )
            }

            DispatchQueue.main.async {
                self.pendingJobCount = max(0, self.pendingJobCount - 1)
                if case .success = result {
                    self.savedFrameCount += 1
                }
            }
        }
    }

    private func makeCaptureSource(documentName: String) -> RecorderCaptureSource? {
        let workspace = workspaceStore.state
        let layers = workspace.document.layers.compactMap { layer -> RecorderLayerCaptureSource? in
            guard layer.isVisible, layer.opacity > 0 else { return nil }
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                let texture = layerSurfaceStore.texture(for: surfaceID)
            else {
                return nil
            }

            return RecorderLayerCaptureSource(
                texture: RecorderTextureBox(texture),
                opacity: layer.opacity
            )
        }

        guard !layers.isEmpty else { return nil }
        return RecorderCaptureSource(
            documentName: documentName,
            canvasSize: workspace.document.canvasSize,
            layers: layers
        )
    }

    private func makeSessionDirectory(rootDirectory: URL, documentName: String, documentFileURL: URL?) throws -> URL {
        let safeName = documentName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let baseName = safeName.isEmpty ? "Untitled" : safeName
        let folderName: String
        if let documentFileURL {
            folderName = "\(baseName)-\(Self.shortPathHash(for: documentFileURL))"
        } else {
            folderName = baseName
        }
        let sessionDirectory = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        return sessionDirectory
    }

    nonisolated private static func shortPathHash(for url: URL) -> String {
        let normalizedPath = url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
        let digest = Insecure.MD5.hash(data: Data(normalizedPath.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func makeCompositeImage(
        from source: RecorderCaptureSource,
        serializer: LayerTextureSerializer,
        scale: RecorderResolutionScale
    ) throws -> CGImage {
        let width = source.canvasSize.width
        let height = source.canvasSize.height
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var mergedBytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        for layer in source.layers {
            let snapshot = try serializer.snapshot(texture: layer.texture.value)
            let layerBytes = [UInt8](snapshot.pixelData)
            let effectiveOpacity = min(max(layer.opacity, 0), 1)
            guard effectiveOpacity > 0 else { continue }

            for offset in stride(from: 0, to: layerBytes.count, by: bytesPerPixel) {
                let destination = LinearPremultipliedColor(
                    bgraBlue: mergedBytes[offset],
                    green: mergedBytes[offset + 1],
                    red: mergedBytes[offset + 2],
                    alpha: mergedBytes[offset + 3]
                )

                let sourceColor = LinearPremultipliedColor(
                    bgraBlue: layerBytes[offset],
                    green: layerBytes[offset + 1],
                    red: layerBytes[offset + 2],
                    alpha: layerBytes[offset + 3]
                ).applyingOpacity(effectiveOpacity)

                let merged = sourceColor.composited(over: destination)
                let output = merged.bgra8PremultipliedBytes
                mergedBytes[offset] = output.blue
                mergedBytes[offset + 1] = output.green
                mergedBytes[offset + 2] = output.red
                mergedBytes[offset + 3] = output.alpha
            }
        }

        var outputBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)
                let composited = LinearPremultipliedColor(
                    bgraBlue: mergedBytes[offset],
                    green: mergedBytes[offset + 1],
                    red: mergedBytes[offset + 2],
                    alpha: mergedBytes[offset + 3]
                )
                .composited(over: .white)
                .srgbUnpremultipliedOverOpaqueBackground

                outputBytes[offset] = UInt8(clamping: Int((composited.red * 255).rounded()))
                outputBytes[offset + 1] = UInt8(clamping: Int((composited.green * 255).rounded()))
                outputBytes[offset + 2] = UInt8(clamping: Int((composited.blue * 255).rounded()))
                outputBytes[offset + 3] = 255
            }
        }

        let fullImage = try makeCGImage(
            rgbaBytes: outputBytes,
            width: width,
            height: height
        )

        guard scale.divisor > 1 else {
            return fullImage
        }

        let scaledWidth = max(1, width / scale.divisor)
        let scaledHeight = max(1, height / scale.divisor)
        return try scaleImage(fullImage, width: scaledWidth, height: scaledHeight)
    }

    nonisolated private static func makeCGImage(
        rgbaBytes: [UInt8],
        width: Int,
        height: Int
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)

        guard
            let provider = CGDataProvider(data: Data(rgbaBytes) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        return image
    }

    nonisolated private static func scaleImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let scaled = context.makeImage() else {
            throw CocoaError(.fileWriteUnknown)
        }
        return scaled
    }

    nonisolated private static func writeImage(
        _ image: CGImage,
        to fileURL: URL,
        format: RecorderFrameFormat,
        qualityPercent: Double
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                fileURL as CFURL,
                format.utType.identifier as CFString,
                1,
                nil
            )
        else {
            throw CocoaError(.fileWriteUnknown)
        }

        let clampedQuality = min(max(qualityPercent / 100, 0), 1)
        let properties: CFDictionary?
        switch format {
        case .jpeg:
            properties = [
                kCGImageDestinationLossyCompressionQuality: clampedQuality
            ] as CFDictionary
        case .png:
            properties = nil
        }

        CGImageDestinationAddImage(destination, image, properties)
        if !CGImageDestinationFinalize(destination) {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    nonisolated private static func exportVideo(
        from sessionDirectory: URL,
        to outputURL: URL,
        fps: Int,
        leadInSeconds: Double,
        tailHoldSeconds: Double
    ) -> Result<URL, Error> {
        Result {
            let frameURLs = try sortedFrameURLs(in: sessionDirectory)
            guard let firstURL = frameURLs.first else {
                throw CocoaError(.fileNoSuchFile)
            }

            guard
                let source = CGImageSourceCreateWithURL(firstURL as CFURL, nil),
                let firstImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                throw CocoaError(.fileReadCorruptFile)
            }

            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: firstImage.width,
                AVVideoHeightKey: firstImage.height
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = false

            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: firstImage.width,
                kCVPixelBufferHeightKey as String: firstImage.height
            ]
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: attributes
            )

            guard writer.canAdd(input) else {
                throw CocoaError(.fileWriteUnknown)
            }

            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            writer.startSession(atSourceTime: .zero)

            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
            let leadInFrames = max(0, Int((leadInSeconds * Double(fps)).rounded()))
            let tailHoldFrames = max(0, Int((tailHoldSeconds * Double(fps)).rounded()))
            var presentationIndex = 0

            func appendFrame(url: URL) throws {
                autoreleasepool {
                    while !input.isReadyForMoreMediaData {
                        Thread.sleep(forTimeInterval: 0.002)
                    }

                    guard
                        let frameSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                        let frameImage = CGImageSourceCreateImageAtIndex(frameSource, 0, nil),
                        let pixelBuffer = makePixelBuffer(
                            from: frameImage,
                            width: firstImage.width,
                            height: firstImage.height
                        )
                    else {
                        return
                    }

                    let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(presentationIndex))
                    adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                    presentationIndex += 1
                }
            }

            for _ in 0..<leadInFrames {
                try appendFrame(url: firstURL)
            }
            for url in frameURLs {
                try appendFrame(url: url)
            }
            if let lastURL = frameURLs.last {
                for _ in 0..<tailHoldFrames {
                    try appendFrame(url: lastURL)
                }
            }

            input.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            var exportError: Error?
            writer.finishWriting {
                exportError = writer.error
                semaphore.signal()
            }
            semaphore.wait()

            if let exportError {
                throw exportError
            }

            return outputURL
        }
    }

    nonisolated private static func sortedFrameURLs(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        return urls
            .filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    nonisolated private static func nextFrameIndex(for urls: [URL]) -> Int {
        urls.compactMap { url in
            let stem = url.deletingPathExtension().lastPathComponent
            guard let suffix = stem.split(separator: "_").last else { return nil }
            return Int(suffix)
        }
        .max()
        .map { $0 + 1 } ?? 0
    }

    nonisolated private static func makePixelBuffer(
        from image: CGImage,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard
            let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
            let context = CGContext(
                data: baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else {
            return nil
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let scale = min(
            CGFloat(width) / CGFloat(max(image.width, 1)),
            CGFloat(height) / CGFloat(max(image.height, 1))
        )
        let drawWidth = CGFloat(image.width) * scale
        let drawHeight = CGFloat(image.height) * scale
        context.draw(
            image,
            in: CGRect(
                x: (CGFloat(width) - drawWidth) / 2,
                y: (CGFloat(height) - drawHeight) / 2,
                width: drawWidth,
                height: drawHeight
            )
        )
        return pixelBuffer
    }
}
