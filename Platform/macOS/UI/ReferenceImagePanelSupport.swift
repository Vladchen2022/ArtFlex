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
            fileName: url.lastPathComponent,
            width: width,
            height: height,
            rgbaPixels: rgbaPixels,
            cgImage: previewImage,
            sourceURL: url,
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
    private var isApplyingViewportState = false
    private var currentZoomScale: Double = 1
    private var lastFitViewportSize: CGSize = .zero
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
        guard isApplyingViewportState == false else { return }
        guard currentAsset != nil else { return }
        let viewportSize = contentSize
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        applyCurrentLayout(centeredAt: currentVisibleDocumentCenter(), forceFitRebuild: false)
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
            onHoverColorChanged?(nil)
        }

        guard asset != nil else {
            lastFitViewportSize = .zero
            currentZoomScale = 1
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
        applyCurrentLayout(centeredAt: sourceChanged ? nil : preservedCenter, forceFitRebuild: true)

        if assetChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }
    }

    func resetToFit() {
        currentZoomScale = 1
        applyCurrentLayout(centeredAt: nil, forceFitRebuild: true)
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

    private func applyCurrentLayout(centeredAt point: CGPoint?, forceFitRebuild: Bool) {
        guard let currentAsset else { return }

        let viewportSize = contentSize
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }

        let viewportChanged = abs(viewportSize.width - lastFitViewportSize.width) > 0.5
            || abs(viewportSize.height - lastFitViewportSize.height) > 0.5

        if forceFitRebuild || viewportChanged {
            lastFitViewportSize = viewportSize
            let baseSize = fitDisplaySize(for: currentAsset, viewportSize: viewportSize)
            documentImageView.frame = CGRect(origin: .zero, size: baseSize)
        }

        minMagnification = 1
        maxMagnification = 16
        let anchor = point ?? CGPoint(x: documentImageView.bounds.midX, y: documentImageView.bounds.midY)
        applyZoomScale(currentZoomScale, centeredAt: anchor)
    }

    private func applyZoomScale(_ scale: Double, centeredAt point: CGPoint) {
        let resolvedZoomScale = min(max(scale, 1), 16)
        let anchorInContentView = contentView.convert(point, from: documentImageView)
        isApplyingViewportState = true
        currentZoomScale = resolvedZoomScale
        setMagnification(CGFloat(resolvedZoomScale), centeredAt: anchorInContentView)
        updateContentInsetsForCurrentState()
        reflectScrolledClipView(contentView)
        isApplyingViewportState = false
    }

    private func updateZoom(by multiplier: Double, centeredAt point: CGPoint) {
        guard currentAsset != nil else { return }

        let nextZoomScale = min(max(currentZoomScale * multiplier, 1), 16)
        let resolvedZoomScale = abs(nextZoomScale - 1) < 0.0001 ? 1 : nextZoomScale
        guard abs(resolvedZoomScale - currentZoomScale) > 0.0001 else { return }

        applyZoomScale(resolvedZoomScale, centeredAt: point)
    }

    private func pan(by delta: CGPoint) {
        guard currentAsset != nil else { return }

        let visibleRect = contentView.bounds
        let documentSize = documentImageView.frame.size
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

    private func updateContentInsetsForCurrentState() {
        let viewportSize = contentSize
        let documentSize = CGSize(
            width: documentImageView.frame.size.width * magnification,
            height: documentImageView.frame.size.height * magnification
        )
        let shouldCenter = abs(currentZoomScale - 1) < 0.0001
        contentInsets = NSEdgeInsets(
            top: shouldCenter ? max((viewportSize.height - documentSize.height) * 0.5, 0) : 0,
            left: shouldCenter ? max((viewportSize.width - documentSize.width) * 0.5, 0) : 0,
            bottom: shouldCenter ? max((viewportSize.height - documentSize.height) * 0.5, 0) : 0,
            right: shouldCenter ? max((viewportSize.width - documentSize.width) * 0.5, 0) : 0
        )
    }

    private func clampedOrigin(_ proposed: CGPoint, visibleSize: CGSize, documentSize: CGSize) -> CGPoint {
        let maxX = max(documentSize.width - visibleSize.width, 0)
        let maxY = max(documentSize.height - visibleSize.height, 0)
        return CGPoint(
            x: min(max(proposed.x, 0), maxX),
            y: min(max(proposed.y, 0), maxY)
        )
    }

    private func resolvedZoomAnchor(from event: NSEvent?) -> CGPoint {
        if let event {
            let eventPoint = documentImageView.convert(event.locationInWindow, from: nil)
            if documentImageView.bounds.contains(eventPoint) {
                return eventPoint
            }
        }

        if let window {
            let pointer = documentImageView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if documentImageView.bounds.contains(pointer) {
                return pointer
            }
        }

        let visibleRect = currentVisibleDocumentRect()
        if visibleRect.isEmpty == false {
            return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
        }

        if documentImageView.bounds.isEmpty == false {
            return CGPoint(x: documentImageView.bounds.midX, y: documentImageView.bounds.midY)
        }

        return .zero
    }

    private func currentVisibleDocumentRect() -> CGRect {
        contentView.bounds
    }

    private func currentVisibleDocumentCenter() -> CGPoint? {
        let visibleRect = currentVisibleDocumentRect()
        guard visibleRect.isEmpty == false else { return nil }
        return CGPoint(x: visibleRect.midX, y: visibleRect.midY)
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
    var asset: ReferenceImageAsset? {
        didSet {
            imageLayer.contents = asset?.cgImage
            imageLayer.isHidden = asset == nil
            needsLayout = true
            needsDisplay = true
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
    private var lastDragLocation: CGPoint = .zero
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
        onHoverColorChanged?(nil)
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
        lastDragLocation = dragStartLocation
        draggedDuringCurrentGesture = false
        resetCursorRects()
        if let color = sampledColor(at: dragStartLocation) {
            onHoverColorChanged?(color)
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
            let delta = CGPoint(x: location.x - lastDragLocation.x, y: location.y - lastDragLocation.y)
            onPan?(delta)
        } else {
            updateHoverColor(at: location)
        }

        lastDragLocation = location
    }

    override func mouseUp(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let totalDistance = hypot(location.x - dragStartLocation.x, location.y - dragStartLocation.y)
        if isPanModifierActive == false,
           let color = sampledColor(at: location),
           totalDistance <= dragThreshold {
            onHoverColorChanged?(color)
            onPickColor?(color)
        } else {
            updateHoverColor(at: location)
        }
        draggedDuringCurrentGesture = false
        resetCursorRects()
    }

    private func updateHoverColor(at location: CGPoint) {
        onHoverColorChanged?(sampledColor(at: location))
    }

    private func sampledColor(at location: CGPoint) -> RGBAColor? {
        guard let asset, bounds.width > 0, bounds.height > 0, bounds.contains(location) else {
            return nil
        }

        let normalizedX = location.x / bounds.width
        let normalizedY = 1 - (location.y / bounds.height)
        return asset.sampledColor(normalizedX: normalizedX, normalizedY: normalizedY)
    }
}

@MainActor
final class ReferenceImageFloatingPanelController: NSObject, NSWindowDelegate {
    private weak var viewModel: WorkspaceViewModel?
    private var panel: ReferenceImageFloatingPanel?
    private var spaceKeyDownMonitor: Any?
    private var spaceKeyUpMonitor: Any?

    func show(for viewModel: WorkspaceViewModel) {
        self.viewModel = viewModel

        if panel == nil {
            panel = makePanel(for: viewModel)
        }

        if let panel {
            panel.contentView = FirstMouseHostingView(
                rootView: ReferenceImageFloatingPanelContent(viewModel: viewModel)
            )
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            panel.focusBrowserIfAvailable()
            installSpaceKeyMonitorsIfNeeded()
        }
    }

    func close() {
        removeSpaceKeyMonitors()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    func windowWillClose(_ notification: Notification) {
        removeSpaceKeyMonitors()
        panel = nil
        viewModel?.referenceImageFloatingPanelDidClose()
    }

    private func installSpaceKeyMonitorsIfNeeded() {
        if spaceKeyDownMonitor == nil {
            spaceKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let panel = self.panel, panel.isKeyWindow else {
                    return event
                }
                return panel.handleSpaceKeyDown(event) ? nil : event
            }
        }

        if spaceKeyUpMonitor == nil {
            spaceKeyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
                guard let self, let panel = self.panel, panel.isKeyWindow else {
                    return event
                }
                return panel.handleSpaceKeyUp(event) ? nil : event
            }
        }
    }

    private func removeSpaceKeyMonitors() {
        if let spaceKeyDownMonitor {
            NSEvent.removeMonitor(spaceKeyDownMonitor)
            self.spaceKeyDownMonitor = nil
        }
        if let spaceKeyUpMonitor {
            NSEvent.removeMonitor(spaceKeyUpMonitor)
            self.spaceKeyUpMonitor = nil
        }
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
    override var canBecomeMain: Bool { true }

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

    func handleSpaceKeyDown(_ event: NSEvent) -> Bool {
        guard let browser = firstBrowserScrollView(in: contentView) else { return false }
        if firstResponder !== browser {
            makeFirstResponder(browser)
        }
        return browser.handleSpaceKeyDown(event)
    }

    func handleSpaceKeyUp(_ event: NSEvent) -> Bool {
        guard let browser = firstBrowserScrollView(in: contentView) else { return false }
        return browser.handleSpaceKeyUp(event)
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
