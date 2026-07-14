import AppKit
import SwiftUI
import ImageIO

@MainActor
private let referenceImageEyedropperCursor: NSCursor = {
    guard let symbol = NSImage(
        systemSymbolName: "eyedropper",
        accessibilityDescription: nil
    ) else {
        return .crosshair
    }

    symbol.isTemplate = false
    symbol.size = NSSize(width: 18, height: 18)
    return NSCursor(image: symbol, hotSpot: NSPoint(x: 2, y: 15))
}()

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ReferenceImageAsset: @unchecked Sendable {
    let fileName: String
    let width: Int
    let height: Int
    let rgbaPixels: Data
    let cgImage: CGImage
    let sourceURL: URL?
    let decodedMaxDimension: Int

    init(
        fileName: String,
        width: Int,
        height: Int,
        rgbaPixels: Data,
        cgImage: CGImage,
        sourceURL: URL? = nil,
        decodedMaxDimension: Int = 0
    ) {
        self.fileName = fileName
        self.width = width
        self.height = height
        self.rgbaPixels = rgbaPixels
        self.cgImage = cgImage
        self.sourceURL = sourceURL
        self.decodedMaxDimension = decodedMaxDimension
    }

    func sampledColor(normalizedX: Double, normalizedY: Double) -> RGBAColor? {
        guard width > 0, height > 0 else { return nil }

        let clampedX = min(max(normalizedX, 0), 0.999_999)
        let clampedY = min(max(normalizedY, 0), 0.999_999)
        let pixelX = min(max(Int(clampedX * Double(width)), 0), width - 1)
        let pixelY = min(max(Int(clampedY * Double(height)), 0), height - 1)
        return sampledColor(x: pixelX, y: pixelY)
    }

    private func sampledColor(x: Int, y: Int) -> RGBAColor? {
        let offset = ((y * width) + x) * 4
        guard rgbaPixels.count >= offset + 4 else { return nil }

        return rgbaPixels.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            let alpha = Float(bytes[offset + 3]) / 255
            let red = Float(bytes[offset]) / 255
            let green = Float(bytes[offset + 1]) / 255
            let blue = Float(bytes[offset + 2]) / 255

            guard alpha > 0.0001 else {
                return RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
            }

            return RGBAColor(
                red: min(max(red / alpha, 0), 1),
                green: min(max(green / alpha, 0), 1),
                blue: min(max(blue / alpha, 0), 1),
                alpha: alpha
            )
        }
    }

    static func decode(from url: URL, maxDimension: Int = 4096) -> ReferenceImageAsset? {
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        return decode(
            from: imageSource,
            fileName: url.lastPathComponent,
            sourceURL: url,
            maxDimension: maxDimension
        )
    }

    static func decode(
        from imageData: Data,
        fileName: String,
        maxDimension: Int = 4096
    ) -> ReferenceImageAsset? {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            return nil
        }

        return decode(
            from: imageSource,
            fileName: fileName,
            sourceURL: nil,
            maxDimension: maxDimension
        )
    }

    private static func decode(
        from imageSource: CGImageSource,
        fileName: String,
        sourceURL: URL?,
        maxDimension: Int
    ) -> ReferenceImageAsset? {

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension
        ]

        guard let decodedImage = CGImageSourceCreateThumbnailAtIndex(
            imageSource,
            0,
            thumbnailOptions as CFDictionary
        ) ?? CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            return nil
        }

        let width = decodedImage.width
        let height = decodedImage.height
        guard width > 0, height > 0 else {
            return nil
        }

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return nil
        }

        context.interpolationQuality = .high
        context.draw(decodedImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else {
            return nil
        }

        let rgbaPixels = Data(bytes: data, count: width * height * 4)
        guard let previewImage = makeCGImage(width: width, height: height, rgbaPixels: rgbaPixels) else {
            return nil
        }

        return ReferenceImageAsset(
            fileName: fileName,
            width: width,
            height: height,
            rgbaPixels: rgbaPixels,
            cgImage: previewImage,
            sourceURL: sourceURL,
            decodedMaxDimension: maxDimension
        )
    }

    private static func makeCGImage(width: Int, height: Int, rgbaPixels: Data) -> CGImage? {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let provider = CGDataProvider(data: rgbaPixels as CFData)
        else {
            return nil
        }

        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

struct ReferenceImageSlotState: Identifiable {
    let id: Int
    var asset: ReferenceImageAsset?

    var labelText: String {
        "\(id + 1)"
    }

    var isLoaded: Bool {
        asset != nil
    }
}

func referenceImageDropDestinationSlotIDs(
    slots: [ReferenceImageSlotState],
    reservedSlotIDs: Set<Int>,
    maximumCount: Int
) -> [Int] {
    guard maximumCount > 0 else { return [] }

    return Array(
        slots.lazy
            .filter { $0.asset == nil && reservedSlotIDs.contains($0.id) == false }
            .prefix(maximumCount)
            .map(\.id)
    )
}

struct ReferenceImageViewer: NSViewRepresentable {
    let asset: ReferenceImageAsset?
    let backgroundColor: NSColor
    let onHoverColorChanged: (RGBAColor?) -> Void
    let onPickColor: (RGBAColor) -> Void

    func makeNSView(context: Context) -> ReferenceImageViewerNSView {
        let view = ReferenceImageViewerNSView()
        view.backgroundColor = backgroundColor
        return view
    }

    func updateNSView(_ nsView: ReferenceImageViewerNSView, context: Context) {
        nsView.asset = asset
        nsView.backgroundColor = backgroundColor
        nsView.onHoverColorChanged = onHoverColorChanged
        nsView.onPickColor = onPickColor
    }
}

final class ReferenceImageViewerNSView: NSView {
    var asset: ReferenceImageAsset? {
        didSet {
            imageLayer.contents = asset?.cgImage
            imageLayer.isHidden = asset == nil
            needsLayout = true
        }
    }

    var backgroundColor: NSColor = NSColor(calibratedWhite: 0.10, alpha: 1) {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    var onHoverColorChanged: ((RGBAColor?) -> Void)?
    var onPickColor: ((RGBAColor) -> Void)?

    private let imageLayer = CALayer()
    private var trackingAreaRef: NSTrackingArea?
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = backgroundColor.cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        imageLayer.frame = displayedImageRect()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: referenceImageEyedropperCursor)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoverColor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverColorChanged?(nil)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoverColor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if let color = sampledColor(at: location) {
            onHoverColorChanged?(color)
            onPickColor?(color)
        }
    }

    private func updateHoverColor(at location: CGPoint) {
        onHoverColorChanged?(sampledColor(at: location))
    }

    private func displayedImageRect() -> CGRect {
        guard let asset else {
            return .zero
        }

        let boundsSize = bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else {
            return .zero
        }

        let imageSize = CGSize(width: asset.width, height: asset.height)
        let fitScale = min(boundsSize.width / imageSize.width, boundsSize.height / imageSize.height)
        let displaySize = CGSize(
            width: imageSize.width * fitScale,
            height: imageSize.height * fitScale
        )

        return CGRect(
            x: bounds.midX - displaySize.width * 0.5,
            y: bounds.midY - displaySize.height * 0.5,
            width: displaySize.width,
            height: displaySize.height
        )
    }

    private func sampledColor(at location: CGPoint) -> RGBAColor? {
        guard let asset else { return nil }
        let displayRect = displayedImageRect()
        guard displayRect.width > 0, displayRect.height > 0, displayRect.contains(location) else {
            return nil
        }

        let normalizedX = (location.x - displayRect.minX) / displayRect.width
        let normalizedY = 1 - ((location.y - displayRect.minY) / displayRect.height)
        return asset.sampledColor(
            normalizedX: normalizedX,
            normalizedY: normalizedY
        )
    }

}

private struct ReferenceImageBrowser: NSViewRepresentable {
    let asset: ReferenceImageAsset?
    let backgroundColor: NSColor
    let resetToFitToken: Int
    let onHoverColorChanged: (RGBAColor?) -> Void
    let onPickColor: (RGBAColor) -> Void

    func makeNSView(context: Context) -> ReferenceImageBrowserScrollView {
        let view = ReferenceImageBrowserScrollView()
        view.backgroundPanelColor = backgroundColor
        view.lastResetToFitToken = resetToFitToken
        return view
    }

    func updateNSView(_ nsView: ReferenceImageBrowserScrollView, context: Context) {
        nsView.backgroundPanelColor = backgroundColor
        nsView.onHoverColorChanged = onHoverColorChanged
        nsView.onPickColor = onPickColor
        nsView.update(asset: asset, resetToFitToken: resetToFitToken)
    }
}

private final class ReferenceImageBrowserScrollView: NSScrollView {
    var onHoverColorChanged: ((RGBAColor?) -> Void)? {
        didSet { documentImageView.onHoverColorChanged = onHoverColorChanged }
    }
    var onPickColor: ((RGBAColor) -> Void)? {
        didSet { documentImageView.onPickColor = onPickColor }
    }
    var backgroundPanelColor: NSColor = NSColor(calibratedWhite: 0.10, alpha: 1) {
        didSet {
            layer?.backgroundColor = backgroundPanelColor.cgColor
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = backgroundPanelColor.cgColor
        }
    }

    private let documentImageView = ReferenceImageBrowserDocumentView()
    private var currentAsset: ReferenceImageAsset?
    private var currentZoomScale: Double = 1
    private var baseDisplaySize: CGSize = .zero
    private var lastViewportSize: CGSize = .zero
    private var lastAppliedInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    private var isApplyingLayout = false
    var lastResetToFitToken: Int = 0
    private var isPanModifierActive = false {
        didSet {
            documentImageView.isPanModifierActive = isPanModifierActive
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = backgroundPanelColor.cgColor
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 16
        contentView = NSClipView()
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = backgroundPanelColor.cgColor
        documentView = documentImageView
        documentImageView.onPan = { [weak self] delta in
            self?.pan(by: delta)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        guard isApplyingLayout == false else { return }
        guard currentAsset != nil else { return }
        let viewportSize = resolvedViewportSize()
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let viewportChanged = abs(viewportSize.width - lastViewportSize.width) > 0.5
            || abs(viewportSize.height - lastViewportSize.height) > 0.5
        guard viewportChanged else { return }
        let preservedCenter = currentVisibleDocumentCenter()
        _ = rebuildBaseDisplaySizeIfNeeded(force: false)
        applyZoom(centeredAtContentPoint: contentPoint(forDocumentPoint: preservedCenter))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.contentView != nil else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func resignFirstResponder() -> Bool {
        isPanModifierActive = false
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleCommandKeyEquivalent(event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if handleSpaceKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if handleSpaceKeyUp(event) {
            return
        }
        super.keyUp(with: event)
    }

    override func magnify(with event: NSEvent) {
        updateZoom(
            by: max(0.25, 1 + event.magnification),
            centeredAt: resolvedZoomAnchor(from: event)
        )
    }

    override func scrollWheel(with event: NSEvent) {
        let modifiers = normalizedZoomModifiers(from: event)
        if shouldHandleZoomShortcutModifiers(modifiers) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
            guard abs(delta) > 0.0001 else {
                return
            }

            let multiplier = exp(-delta * 0.01)
            updateZoom(by: multiplier, centeredAt: resolvedZoomAnchor(from: event))
            return
        }

        super.scrollWheel(with: event)
    }

    func update(asset: ReferenceImageAsset?, resetToFitToken: Int) {
        let assetChanged = currentAsset !== asset
        let resetRequested = resetToFitToken != lastResetToFitToken
        guard assetChanged || resetRequested else {
            return
        }

        let previousAsset = currentAsset
        currentAsset = asset
        lastResetToFitToken = resetToFitToken

        if assetChanged {
            documentImageView.asset = asset
            documentImageView.resetHoverState()
            onHoverColorChanged?(nil)
        }

        guard asset != nil else {
            baseDisplaySize = .zero
            lastViewportSize = .zero
            lastAppliedInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            currentZoomScale = 1
            contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
            if documentImageView.frame != .zero {
                documentImageView.frame = .zero
            }
            return
        }

        let sourceChanged = previousAsset?.sourceURL?.standardizedFileURL != asset?.sourceURL?.standardizedFileURL
        let preservedCenter = sourceChanged ? nil : currentVisibleDocumentCenter()
        if sourceChanged || resetRequested {
            currentZoomScale = 1
        }
        _ = rebuildBaseDisplaySizeIfNeeded(force: true)
        applyZoom(centeredAtContentPoint: sourceChanged || resetRequested ? nil : contentPoint(forDocumentPoint: preservedCenter))

        if assetChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    func resetToFit() {
        currentZoomScale = 1
        _ = rebuildBaseDisplaySizeIfNeeded(force: true)
        applyZoom(centeredAtContentPoint: nil)
    }

    func handleCommandKeyEquivalent(_ event: NSEvent) -> Bool {
        let modifiers = normalizedZoomModifiers(from: event)
        guard shouldHandleZoomShortcutModifiers(modifiers) else { return false }

        switch event.charactersIgnoringModifiers {
        case "+", "=":
            updateZoom(by: 1.2, centeredAt: resolvedZoomAnchor(from: event))
            return true
        case "-", "_":
            updateZoom(by: 1.0 / 1.2, centeredAt: resolvedZoomAnchor(from: event))
            return true
        case "0":
            resetToFit()
            return true
        default:
            return false
        }
    }

    func handleSpaceKeyDown(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " " else { return false }
        isPanModifierActive = true
        return true
    }

    func handleSpaceKeyUp(_ event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " " else { return false }
        isPanModifierActive = false
        return true
    }

    @discardableResult
    private func rebuildBaseDisplaySizeIfNeeded(force: Bool) -> Bool {
        guard let currentAsset else { return false }

        let viewportSize = resolvedViewportSize()
        guard viewportSize.width > 1, viewportSize.height > 1 else { return false }

        let viewportChanged = abs(viewportSize.width - lastViewportSize.width) > 0.5
            || abs(viewportSize.height - lastViewportSize.height) > 0.5

        guard force || viewportChanged else {
            return false
        }

        lastViewportSize = viewportSize
        let nextBaseSize = fitDisplaySize(for: currentAsset, viewportSize: viewportSize)
        let sizeChanged = abs(nextBaseSize.width - baseDisplaySize.width) > 0.5
            || abs(nextBaseSize.height - baseDisplaySize.height) > 0.5
        baseDisplaySize = nextBaseSize
        if sizeChanged || documentImageView.frame.size != nextBaseSize {
            documentImageView.frame = CGRect(origin: .zero, size: nextBaseSize)
        }
        return sizeChanged || viewportChanged
    }

    private func applyZoom(centeredAtContentPoint point: CGPoint?) {
        guard currentAsset != nil else { return }
        let resolvedZoomScale = min(max(currentZoomScale, 1), 16)
        let anchorInContentView = point ?? CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        isApplyingLayout = true
        currentZoomScale = resolvedZoomScale
        setMagnification(CGFloat(resolvedZoomScale), centeredAt: anchorInContentView)
        updateContentInsetsIfNeeded()
        reflectScrolledClipView(contentView)
        isApplyingLayout = false
    }

    private func updateZoom(by multiplier: Double, centeredAt point: CGPoint) {
        guard currentAsset != nil else { return }

        let nextZoomScale = min(max(currentZoomScale * multiplier, 1), 16)
        let resolvedZoomScale = abs(nextZoomScale - 1) < 0.0001 ? 1 : nextZoomScale
        guard abs(resolvedZoomScale - currentZoomScale) > 0.0001 else { return }

        currentZoomScale = resolvedZoomScale
        applyZoom(centeredAtContentPoint: point)
    }

    private func pan(by delta: CGPoint) {
        guard currentAsset != nil else { return }

        let visibleRect = currentVisibleDocumentRect()
        let documentSize = documentImageView.bounds.size
        var nextOrigin = CGPoint(
            x: visibleRect.origin.x - delta.x,
            y: visibleRect.origin.y - delta.y
        )
        nextOrigin = clampedOrigin(nextOrigin, visibleSize: visibleRect.size, documentSize: documentSize)
        contentView.scroll(to: nextOrigin)
        reflectScrolledClipView(contentView)
    }

    private func fitDisplaySize(for asset: ReferenceImageAsset, viewportSize: CGSize) -> CGSize {
        let imageSize = CGSize(width: asset.width, height: asset.height)
        let fitScale = min(viewportSize.width / imageSize.width, viewportSize.height / imageSize.height)
        return CGSize(
            width: max((imageSize.width * fitScale).rounded(.toNearestOrAwayFromZero), 1),
            height: max((imageSize.height * fitScale).rounded(.toNearestOrAwayFromZero), 1)
        )
    }

    private func updateContentInsetsIfNeeded() {
        let viewportSize = resolvedViewportSize()
        let documentSize = CGSize(
            width: baseDisplaySize.width * currentZoomScale,
            height: baseDisplaySize.height * currentZoomScale
        )
        let shouldCenter = abs(currentZoomScale - 1) < 0.0001
        let nextInsets = NSEdgeInsets(
            top: shouldCenter ? max((viewportSize.height - documentSize.height) * 0.5, 0) : 0,
            left: shouldCenter ? max((viewportSize.width - documentSize.width) * 0.5, 0) : 0,
            bottom: shouldCenter ? max((viewportSize.height - documentSize.height) * 0.5, 0) : 0,
            right: shouldCenter ? max((viewportSize.width - documentSize.width) * 0.5, 0) : 0
        )
        guard insetsDiffer(nextInsets, lastAppliedInsets) else { return }
        contentInsets = nextInsets
        lastAppliedInsets = nextInsets
    }

    private func clampedOrigin(_ proposed: CGPoint, visibleSize: CGSize, documentSize: CGSize) -> CGPoint {
        let maxX = max(documentSize.width - visibleSize.width, 0)
        let maxY = max(documentSize.height - visibleSize.height, 0)
        return CGPoint(
            x: min(max(proposed.x, 0), maxX),
            y: min(max(proposed.y, 0), maxY)
        )
    }

    private func contentPointForCurrentPointer() -> CGPoint {
        if let window {
            let pointer = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if contentView.bounds.contains(pointer) {
                return pointer
            }
        }
        return CGPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
    }

    private func contentPointForCurrentPointer(from event: NSEvent?) -> CGPoint {
        if let event {
            let eventPoint = contentView.convert(event.locationInWindow, from: nil)
            if contentView.bounds.contains(eventPoint) {
                return eventPoint
            }
        }
        return contentPointForCurrentPointer()
    }

    private func contentPoint(forDocumentPoint point: CGPoint?) -> CGPoint? {
        guard let point else { return nil }
        return contentView.convert(point, from: documentImageView)
    }

    private func resolvedZoomAnchor(from event: NSEvent?) -> CGPoint {
        contentPointForCurrentPointer(from: event)
    }

    private func currentVisibleDocumentRect() -> CGRect {
        documentImageView.visibleRect
    }

    private func currentVisibleDocumentCenter() -> CGPoint? {
        let visibleRect = currentVisibleDocumentRect()
        guard visibleRect.isEmpty == false else { return nil }
        return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
    }

    private func resolvedViewportSize() -> CGSize {
        contentView.bounds.size
    }

    private func insetsDiffer(_ lhs: NSEdgeInsets, _ rhs: NSEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) > 0.5
            || abs(lhs.left - rhs.left) > 0.5
            || abs(lhs.bottom - rhs.bottom) > 0.5
            || abs(lhs.right - rhs.right) > 0.5
    }

    private func normalizedZoomModifiers(from event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    }

    private func shouldHandleZoomShortcutModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        guard modifiers.contains(.command) else { return false }
        guard modifiers.contains(.control) == false else { return false }
        guard modifiers.contains(.option) == false else { return false }
        let unexpected = modifiers.subtracting([.command, .shift])
        return unexpected.isEmpty
    }
}

private final class ReferenceImageBrowserDocumentView: NSView {
    private struct HoverSample: Equatable {
        let pixelX: Int
        let pixelY: Int
        let color: RGBAColor
    }

    var asset: ReferenceImageAsset? {
        didSet {
            imageLayer.contents = asset?.cgImage
            imageLayer.isHidden = asset == nil
            needsLayout = true
            needsDisplay = true
            resetHoverState()
        }
    }
    var onHoverColorChanged: ((RGBAColor?) -> Void)?
    var onPickColor: ((RGBAColor) -> Void)?
    var onPan: ((CGPoint) -> Void)?
    var isPanModifierActive = false {
        didSet {
            if isPanModifierActive == false {
                draggedDuringCurrentGesture = false
            }
            resetCursorRects()
        }
    }

    private let imageLayer = CALayer()
    private var trackingAreaRef: NSTrackingArea?
    private var dragStartLocation: CGPoint = .zero
    private var lastHoverSample: HoverSample?
    private var draggedDuringCurrentGesture = false
    private let dragThreshold: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resize
        imageLayer.isHidden = true
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func layout() {
        super.layout()
        imageLayer.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        trackingAreaRef = trackingArea
    }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor
        if isPanModifierActive {
            cursor = draggedDuringCurrentGesture ? .closedHand : .openHand
        } else {
            cursor = referenceImageEyedropperCursor
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHoverColor(at: convert(event.locationInWindow, from: nil))
        resetCursorRects()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if lastHoverSample != nil {
            onHoverColorChanged?(nil)
            lastHoverSample = nil
        }
        draggedDuringCurrentGesture = false
        resetCursorRects()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoverColor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(enclosingScrollView)
        dragStartLocation = convert(event.locationInWindow, from: nil)
        draggedDuringCurrentGesture = false
        resetCursorRects()
        if let sample = sampledColor(at: dragStartLocation) {
            lastHoverSample = sample
            onHoverColorChanged?(sample.color)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        if isPanModifierActive && draggedDuringCurrentGesture == false {
            let distance = hypot(location.x - dragStartLocation.x, location.y - dragStartLocation.y)
            if distance > dragThreshold {
                draggedDuringCurrentGesture = true
                resetCursorRects()
            }
        }

        if isPanModifierActive && draggedDuringCurrentGesture {
            let delta = CGPoint(x: event.deltaX, y: -event.deltaY)
            onPan?(delta)
        } else {
            updateHoverColor(at: location)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let totalDistance = hypot(location.x - dragStartLocation.x, location.y - dragStartLocation.y)
        if isPanModifierActive == false,
           let sample = sampledColor(at: location),
           totalDistance <= dragThreshold {
            lastHoverSample = sample
            onHoverColorChanged?(sample.color)
            onPickColor?(sample.color)
        } else {
            updateHoverColor(at: location)
        }
        draggedDuringCurrentGesture = false
        resetCursorRects()
    }

    private func updateHoverColor(at location: CGPoint) {
        let sample = sampledColor(at: location)
        if sample == lastHoverSample {
            return
        }
        lastHoverSample = sample
        onHoverColorChanged?(sample?.color)
    }

    func resetHoverState() {
        lastHoverSample = nil
    }

    private func sampledColor(at location: CGPoint) -> HoverSample? {
        guard let asset, bounds.width > 0, bounds.height > 0, bounds.contains(location) else {
            return nil
        }

        let normalizedX = location.x / bounds.width
        let normalizedY = 1 - (location.y / bounds.height)
        let clampedX = min(max(normalizedX, 0), 0.999_999)
        let clampedY = min(max(normalizedY, 0), 0.999_999)
        let pixelX = min(max(Int(clampedX * Double(asset.width)), 0), asset.width - 1)
        let pixelY = min(max(Int(clampedY * Double(asset.height)), 0), asset.height - 1)
        guard let color = asset.sampledColor(normalizedX: normalizedX, normalizedY: normalizedY) else {
            return nil
        }
        return HoverSample(pixelX: pixelX, pixelY: pixelY, color: color)
    }
}

@MainActor
final class ReferenceImageFloatingPanelController: NSObject, NSWindowDelegate {
    private weak var viewModel: WorkspaceViewModel?
    private var panel: ReferenceImageFloatingPanel?

    func show(for viewModel: WorkspaceViewModel) {
        self.viewModel = viewModel

        if panel == nil {
            panel = makePanel(for: viewModel)
        }

        if let panel {
            panel.delegate = self
            panel.contentView = FirstMouseHostingView(
                rootView: ReferenceImageFloatingPanelContent(viewModel: viewModel)
            )
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel.focusBrowserIfAvailable()
        }
    }

    func close() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        viewModel?.referenceImageFloatingPanelDidClose()
    }

    private func makePanel(for viewModel: WorkspaceViewModel) -> ReferenceImageFloatingPanel {
        let panel = ReferenceImageFloatingPanel(
            contentRect: CGRect(x: 200, y: 180, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("ReferenceImageFloatingPanel")
        panel.level = .floating
        panel.becomesKeyOnlyIfNeeded = false
        panel.isOpaque = false
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.titleVisibility = .visible
        panel.titlebarAppearsTransparent = false
        panel.title = "参考图"
        panel.minSize = CGSize(width: 420, height: 320)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        panel.contentView = FirstMouseHostingView(
            rootView: ReferenceImageFloatingPanelContent(viewModel: viewModel)
        )
        return panel
    }
}

private final class ReferenceImageFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        focusBrowserIfAvailable()
        DispatchQueue.main.async { [weak self] in
            self?.focusBrowserIfAvailable()
        }
    }

    func focusBrowserIfAvailable() {
        guard let browser = firstBrowserScrollView(in: contentView) else { return }
        makeFirstResponder(browser)
    }

    override func keyDown(with event: NSEvent) {
        if forwardSpaceEventIfNeeded(event, isKeyUp: false) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if forwardSpaceEventIfNeeded(event, isKeyUp: true) {
            return
        }
        super.keyUp(with: event)
    }

    private func forwardSpaceEventIfNeeded(_ event: NSEvent, isKeyUp: Bool) -> Bool {
        guard event.charactersIgnoringModifiers == " " else { return false }
        guard let browser = firstBrowserScrollView(in: contentView) else { return false }
        if firstResponder !== browser {
            makeFirstResponder(browser)
        }
        return isKeyUp ? browser.handleSpaceKeyUp(event) : browser.handleSpaceKeyDown(event)
    }

    private func firstBrowserScrollView(in view: NSView?) -> ReferenceImageBrowserScrollView? {
        guard let view else { return nil }
        if let browser = view as? ReferenceImageBrowserScrollView {
            return browser
        }
        for subview in view.subviews {
            if let browser = firstBrowserScrollView(in: subview) {
                return browser
            }
        }
        return nil
    }
}

private struct ReferenceImageFloatingPanelContent: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var floatingHoverColor: RGBAColor?
    @State private var resetToFitToken: Int = 0

    private var floatingPreviewColor: Color {
        let resolved = floatingHoverColor ?? viewModel.workspace.toolSession.selectedColor
        return Color(
            red: Double(resolved.red),
            green: Double(resolved.green),
            blue: Double(resolved.blue),
            opacity: Double(resolved.alpha)
        )
    }

    private var floatingPreviousColor: Color {
        viewModel.referenceImagePreviousSwiftUIColor
    }

    var body: some View {
        VStack(spacing: 10) {
            ReferenceImageBrowser(
                asset: viewModel.selectedReferenceImageSlot?.asset,
                backgroundColor: NSColor(calibratedWhite: 0.045, alpha: 1),
                resetToFitToken: resetToFitToken,
                onHoverColorChanged: { color in
                    floatingHoverColor = color
                },
                onPickColor: { color in
                    floatingHoverColor = color
                    viewModel.confirmReferenceImagePickedColor(color)
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            )

            HStack(spacing: 10) {
                Button("适合") {
                    resetToFitToken += 1
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(Color.white.opacity(0.10))
                )

                ZStack {
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(floatingPreviousColor)
                        Rectangle()
                            .fill(floatingPreviewColor)
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 1)
                }
                .frame(width: 92, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color(red: 0.12, green: 0.12, blue: 0.13))
        .onAppear {
            resetToFitToken += 1
            floatingHoverColor = nil
        }
        .onChange(of: viewModel.selectedReferenceImageSlotID) { _, _ in
            resetToFitToken += 1
            floatingHoverColor = nil
        }
    }
}
