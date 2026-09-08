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
    let compositeTexture: RecorderTextureBox<MTLTexture>?
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
    @Published var captureInterval: Double = 5 { didSet { persistSettings() } }
    @Published var frameFormat: RecorderFrameFormat = .jpeg { didSet { persistSettings() } }
    @Published var qualityPercent: Double = 60 { didSet { persistSettings() } }
    @Published var resolutionScale: RecorderResolutionScale = .half { didSet { persistSettings() } }
    @Published var autoStart = false { didSet { persistSettings() } }
    @Published var exportFPS: Double = 12 { didSet { persistSettings() } }
    @Published var exportLeadInSeconds: Double = 0 { didSet { persistSettings() } }
    @Published var exportTailHoldSeconds: Double = 2 { didSet { persistSettings() } }
    @Published private(set) var isRecording = false
    @Published private(set) var currentDocumentName = ""
    @Published private(set) var currentSessionDirectory: URL?
    @Published private(set) var savedFrameCount = 0
    @Published private(set) var pendingJobCount = 0
    @Published private(set) var droppedFrameCount = 0
    @Published private(set) var isExportingVideo = false
    @Published private(set) var lastExportedVideoURL: URL?
    @Published private(set) var lastFailureMessage: String?

    private let workspaceStore: WorkspaceStore
    private let layerSurfaceStore: StageOneLayerSurfaceStore
    private let serializer: LayerTextureSerializer
    private let writerQueue = DispatchQueue(label: "ArtFlex.Recorder.Writer", qos: .utility)
    private let defaults: UserDefaults
    private static let outputDirectoryBookmarkKey = "ArtFlex.TimelapseRecorder.OutputDirectoryBookmark"
    private static let settingsKey = "ArtFlex.TimelapseRecorder.Settings"

    private var captureTimer: Timer?
    private var pendingRevision: UInt64?
    private var lastCapturedRevision: UInt64?
    private var lastCaptureDate: Date?
    private var nextFrameIndex = 0
    private var currentDocumentFileURL: URL?
    private var currentDocumentID: UUID?
    private var reservedFrameIndices: [URL: Int] = [:]
    private var autoStartSuspended = false

    /// Installed by the workspace so recording consumes the same visible composite
    /// as the canvas, export and eyedropper paths. The legacy layer fallback is kept
    /// for isolated controller tests and bootstrap-time use.
    var compositeTextureProvider: (() throws -> MTLTexture)?
    var shouldDeferCapture: (() -> Bool)?
    var onBecameIdle: (() -> Void)?

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
        if let settings = defaults.dictionary(forKey: Self.settingsKey) {
            func number(_ key: String, default fallback: Double, range: ClosedRange<Double>) -> Double {
                guard let value = settings[key] as? Double, value.isFinite else { return fallback }
                return min(max(value, range.lowerBound), range.upperBound)
            }
            captureInterval = number("interval", default: 5, range: 1...10)
            qualityPercent = number("quality", default: 60, range: 20...100)
            frameFormat = RecorderFrameFormat(rawValue: settings["format"] as? String ?? "") ?? .jpeg
            resolutionScale = RecorderResolutionScale(rawValue: settings["scale"] as? String ?? "") ?? .half
            autoStart = settings["autoStart"] as? Bool ?? false
            exportFPS = number("fps", default: 12, range: 6...30)
            exportLeadInSeconds = number("leadIn", default: 0, range: 0...5)
            exportTailHoldSeconds = number("tailHold", default: 2, range: 0...5)
        }
    }

    var outputDirectoryPath: String {
        outputDirectory?.path ?? ""
    }

    var currentSessionName: String {
        currentSessionDirectory?.lastPathComponent ?? "未准备会话"
    }

    var canExportVideo: Bool {
        currentSessionDirectory != nil && savedFrameCount > 0 && !isRecording && !isBusy
    }

    var isBusy: Bool {
        pendingJobCount > 0 || isExportingVideo
    }

    func syncCurrentDocument(documentName: String, documentFileURL: URL? = nil) {
        let documentID = workspaceStore.state.document.metadata.drawingStatsID
        let sameDocument = currentDocumentID == documentID
        currentDocumentName = documentName
        currentDocumentFileURL = documentFileURL
        currentDocumentID = documentID
        if !sameDocument { autoStartSuspended = false }
        // Saving/renaming the active painting must not split an ongoing recording.
        if sameDocument, isRecording,
           currentSessionDirectory?.deletingLastPathComponent() == outputDirectory { return }
        captureTimer?.invalidate()
        captureTimer = nil
        pendingRevision = nil
        lastCapturedRevision = nil
        lastCaptureDate = nil
        guard let outputDirectory else {
            currentSessionDirectory = nil
            savedFrameCount = 0
            nextFrameIndex = 0
            return
        }

        do {
            let directory = sessionDirectoryURL(
                rootDirectory: outputDirectory,
                documentName: documentName,
                documentFileURL: documentFileURL
            )
            guard directory != currentSessionDirectory else { return }
            currentSessionDirectory = directory
            lastExportedVideoURL = nil
            lastFailureMessage = nil
            droppedFrameCount = 0
            let frameURLs = FileManager.default.fileExists(atPath: directory.path)
                ? try Self.sortedFrameURLs(in: directory) : []
            savedFrameCount = frameURLs.count
            nextFrameIndex = max(Self.nextFrameIndex(for: frameURLs), reservedFrameIndices[directory] ?? 0)
        } catch {
            currentSessionDirectory = nil
            savedFrameCount = 0
            nextFrameIndex = 0
            lastFailureMessage = "无法读取录像目录：\(error.localizedDescription)"
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
        guard !isExportingVideo else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        isRecording = true
        autoStartSuspended = false
        droppedFrameCount = 0
        pendingRevision = 0
        lastCapturedRevision = nil
        lastCaptureDate = nil
        lastExportedVideoURL = nil
        lastFailureMessage = nil
        captureTimer?.invalidate()
        captureTimer = nil
        capturePendingFrame(documentName: documentName)
        return sessionDirectory
    }

    func stopRecording(suppressAutoStart: Bool = false) {
        isRecording = false
        if suppressAutoStart { autoStartSuspended = true }
        captureTimer?.invalidate()
        captureTimer = nil
        // Capture an immutable composite now, before a caller replaces the document.
        // One final job may exceed the normal queue limit; it must not be dropped.
        capturePendingFrame(documentName: currentDocumentName, isFinalFrame: true)
    }

    func noteCanvasChanged(revision: UInt64, documentName: String, documentFileURL: URL? = nil) {
        guard outputDirectory != nil else { return }

        if !isRecording {
            guard autoStart, !autoStartSuspended else { return }
            do {
                _ = try startRecording(documentName: documentName, documentFileURL: documentFileURL)
            } catch {
                autoStartSuspended = true
                lastFailureMessage = "无法自动开始录像：\(error.localizedDescription)"
            }
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
        guard canExportVideo, let sessionDirectory = currentSessionDirectory else {
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
                    if self.currentSessionDirectory == sessionDirectory {
                        self.lastExportedVideoURL = url
                    }
                }
                completion(result)
                self.notifyIfIdle()
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

    private func persistSettings() {
        defaults.set([
            "interval": captureInterval, "format": frameFormat.rawValue,
            "quality": qualityPercent, "scale": resolutionScale.rawValue,
            "autoStart": autoStart, "fps": exportFPS,
            "leadIn": exportLeadInSeconds, "tailHold": exportTailHoldSeconds
        ], forKey: Self.settingsKey)
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

    private func capturePendingFrame(documentName: String, isFinalFrame: Bool = false) {
        guard let revision = pendingRevision, revision != lastCapturedRevision,
              let sessionDirectory = currentSessionDirectory else { return }
        if !isFinalFrame && (shouldDeferCapture?() == true || pendingJobCount >= Self.maxPendingJobs) {
            captureTimer?.invalidate()
            captureTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.captureTimer = nil
                    self.capturePendingFrame(documentName: documentName)
                }
            }
            return
        }
        guard Self.hasSafeDiskReserve(at: sessionDirectory) else {
            isRecording = false
            captureTimer?.invalidate()
            captureTimer = nil
            pendingRevision = nil
            droppedFrameCount += 1
            lastFailureMessage = "磁盘可用空间低于 512 MB，已停止录像以保护工程保存"
            autoStartSuspended = true
            return
        }
        guard
            let captureSource = makeCaptureSource(documentName: documentName)
        else {
            isRecording = false
            autoStartSuspended = true
            pendingRevision = nil
            lastFailureMessage = "无法获取当前画面，录像已停止；请重新开始录制"
            return
        }

        pendingRevision = nil
        lastCapturedRevision = revision
        lastCaptureDate = Date()

        let format = frameFormat
        let scale = resolutionScale
        let quality = qualityPercent

        let frameIndex = nextFrameIndex
        nextFrameIndex += 1
        reservedFrameIndices[sessionDirectory] = nextFrameIndex
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
                if self.currentSessionDirectory == sessionDirectory {
                    if case .success = result {
                        self.savedFrameCount += 1
                    } else if case .failure(let error) = result {
                        self.isRecording = false
                        self.autoStartSuspended = true
                        self.captureTimer?.invalidate()
                        self.captureTimer = nil
                        self.pendingRevision = nil
                        self.droppedFrameCount += 1
                        self.lastFailureMessage = "录像帧写入失败，已停止：\(error.localizedDescription)"
                    }
                }
                self.notifyIfIdle()
            }
        }
    }

    private func notifyIfIdle() {
        guard !isBusy else { return }
        onBecameIdle?()
    }

    nonisolated private static func hasSafeDiskReserve(at url: URL) -> Bool {
        guard let available = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage else {
            return true
        }
        return available >= 512 * 1024 * 1024
    }

    private func makeCaptureSource(documentName: String) -> RecorderCaptureSource? {
        let workspace = workspaceStore.state
        if let compositeTextureProvider {
            // Never substitute a different compositor when the canonical one fails.
            // The legacy fallback cannot represent masks, clipping or blend modes.
            guard let texture = try? compositeTextureProvider() else { return nil }
            return RecorderCaptureSource(
                documentName: documentName,
                canvasSize: workspace.document.canvasSize,
                compositeTexture: RecorderTextureBox(texture),
                layers: []
            )
        }

        let layers = workspace.document.layers.compactMap { layer -> RecorderLayerCaptureSource? in
            guard layer.isVisible, layer.opacity > 0 else { return nil }
            guard
                let surfaceID = layerSurfaceStore.surfaceID(for: layer.id),
                let texture = layerSurfaceStore.readTexture(for: surfaceID)
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
            compositeTexture: nil,
            layers: layers
        )
    }

    private func sessionDirectoryURL(rootDirectory: URL, documentName: String, documentFileURL: URL?) -> URL {
        let safeName = documentName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let baseName = safeName.isEmpty ? "Untitled" : safeName
        let folderName: String
        if let documentFileURL {
            folderName = "\(baseName)-\(Self.shortPathHash(for: documentFileURL))"
        } else {
            folderName = "\(baseName)-\(workspaceStore.state.document.metadata.drawingStatsID.uuidString.prefix(8).lowercased())"
        }
        // Merely opening a painting or inspecting this panel must not create folders.
        return rootDirectory.appendingPathComponent(folderName, isDirectory: true)
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
        let usesGPUDownsample = source.compositeTexture != nil && scale.divisor > 1
        let divisor = usesGPUDownsample ? scale.divisor : 1
        let width = max(1, source.canvasSize.width / divisor)
        let height = max(1, source.canvasSize.height / divisor)
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let mergedBytes: [UInt8]
        if let compositeTexture = source.compositeTexture {
            let snapshot = try serializer.downsampledSnapshot(texture: compositeTexture.value, divisor: divisor).converted(to: .premultipliedBGRA8SRGB)
            mergedBytes = [UInt8](snapshot.pixelData)
        } else {
            var legacyMergedBytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            for layer in source.layers {
                let snapshot = try serializer.snapshot(texture: layer.texture.value).converted(to: .premultipliedBGRA8SRGB)
                let layerBytes = [UInt8](snapshot.pixelData)
                let effectiveOpacity = min(max(layer.opacity, 0), 1)
                guard effectiveOpacity > 0 else { continue }

                for offset in stride(from: 0, to: layerBytes.count, by: bytesPerPixel) {
                    let destination = LinearPremultipliedColor(
                        bgraBlue: legacyMergedBytes[offset],
                        green: legacyMergedBytes[offset + 1],
                        red: legacyMergedBytes[offset + 2],
                        alpha: legacyMergedBytes[offset + 3]
                    )
                    let sourceColor = LinearPremultipliedColor(
                        bgraBlue: layerBytes[offset],
                        green: layerBytes[offset + 1],
                        red: layerBytes[offset + 2],
                        alpha: layerBytes[offset + 3]
                    ).applyingOpacity(effectiveOpacity)
                    let output = sourceColor.composited(over: destination).bgra8PremultipliedBytes
                    legacyMergedBytes[offset] = output.blue
                    legacyMergedBytes[offset + 1] = output.green
                    legacyMergedBytes[offset + 2] = output.red
                    legacyMergedBytes[offset + 3] = output.alpha
                }
            }
            mergedBytes = legacyMergedBytes
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

        guard scale.divisor > 1, !usesGPUDownsample else {
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
        let temporaryURL = fileURL.deletingLastPathComponent()
            .appendingPathComponent(".recorder-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard
            let destination = CGImageDestinationCreateWithURL(
                temporaryURL as CFURL,
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
        // Only complete images become visible to the exporter. moveItem refuses
        // to overwrite an existing frame, even if a second app uses this folder.
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
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

            let temporaryURL = outputURL.deletingLastPathComponent()
                .appendingPathComponent(".recorder-export-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
            defer { if writer.status == .writing { writer.cancelWriting() } }
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
                try autoreleasepool {
                    let deadline = ProcessInfo.processInfo.systemUptime + 30
                    while !input.isReadyForMoreMediaData {
                        guard writer.status == .writing,
                              ProcessInfo.processInfo.systemUptime < deadline else {
                            throw writer.error ?? CocoaError(.fileWriteUnknown)
                        }
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
                        throw CocoaError(.fileReadCorruptFile)
                    }

                    let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(presentationIndex))
                    guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                        throw writer.error ?? CocoaError(.fileWriteUnknown)
                    }
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
            writer.finishWriting {
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 60) == .success else {
                writer.cancelWriting()
                throw CocoaError(.fileWriteUnknown)
            }

            guard writer.status == .completed else {
                throw writer.error ?? CocoaError(.fileWriteUnknown)
            }
            if FileManager.default.fileExists(atPath: outputURL.path) {
                _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
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
            .filter {
                $0.lastPathComponent.hasPrefix("frame_") &&
                ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased())
            }
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
