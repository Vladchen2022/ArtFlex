import AppKit
import SwiftUI
import ImageIO

struct ReferenceImageViewportState: Equatable, Sendable {
    var zoomScale: Double
    var contentOffset: CanvasPoint

    static let fit = ReferenceImageViewportState(
        zoomScale: 1,
        contentOffset: .init(x: 0, y: 0)
    )
}

final class ReferenceImageAsset: @unchecked Sendable {
    let fileName: String
    let width: Int
    let height: Int
    let rgbaPixels: Data
    let cgImage: CGImage

    init(
        fileName: String,
        width: Int,
        height: Int,
        rgbaPixels: Data,
        cgImage: CGImage
    ) {
        self.fileName = fileName
        self.width = width
        self.height = height
        self.rgbaPixels = rgbaPixels
        self.cgImage = cgImage
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
            cgImage: previewImage
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
    var viewport: ReferenceImageViewportState = .fit

    var labelText: String {
        "\(id + 1)"
    }

    var isLoaded: Bool {
        asset != nil
    }
}

struct ReferenceImageViewer: NSViewRepresentable {
    let asset: ReferenceImageAsset?
    let viewport: ReferenceImageViewportState
    let backgroundColor: NSColor
    let onViewportChanged: (ReferenceImageViewportState) -> Void
    let onHoverColorChanged: (RGBAColor?) -> Void
    let onPickColor: (RGBAColor) -> Void

    func makeNSView(context: Context) -> ReferenceImageViewerNSView {
        let view = ReferenceImageViewerNSView()
        view.backgroundColor = backgroundColor
        return view
    }

    func updateNSView(_ nsView: ReferenceImageViewerNSView, context: Context) {
        nsView.asset = asset
        nsView.viewport = viewport
        nsView.backgroundColor = backgroundColor
        nsView.onViewportChanged = onViewportChanged
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

    var viewport: ReferenceImageViewportState = .fit {
        didSet {
            guard viewport != oldValue else { return }
            needsLayout = true
        }
    }

    var backgroundColor: NSColor = NSColor(calibratedWhite: 0.10, alpha: 1) {
        didSet {
            layer?.backgroundColor = backgroundColor.cgColor
        }
    }

    var onViewportChanged: ((ReferenceImageViewportState) -> Void)?
    var onHoverColorChanged: ((RGBAColor?) -> Void)?
    var onPickColor: ((RGBAColor) -> Void)?

    private let imageLayer = CALayer()
    private var trackingAreaRef: NSTrackingArea?
    private var isSpacePressed = false
    private var isMouseInside = false
    private var isPanning = false
    private var panStartLocation: CGPoint = .zero
    private var panStartOffset = CanvasPoint(x: 0, y: 0)
    private var keyDownMonitor: Any?
    private var keyUpMonitor: Any?

    override var acceptsFirstResponder: Bool { true }

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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            tearDownEventMonitors()
        }
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
        let cursor = isSpacePressed ? NSCursor.openHand : Self.eyedropperCursor
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isMouseInside = true
        window?.makeFirstResponder(self)
        setUpEventMonitorsIfNeeded()
        updateHoverColor(at: convert(event.locationInWindow, from: nil))
        resetCursorRects()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isMouseInside = false
        isPanning = false
        isSpacePressed = false
        onHoverColorChanged?(nil)
        resetCursorRects()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHoverColor(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        setUpEventMonitorsIfNeeded()
        let location = convert(event.locationInWindow, from: nil)

        if isSpacePressed {
            isPanning = true
            panStartLocation = location
            panStartOffset = viewport.contentOffset
            NSCursor.closedHand.set()
            return
        }

        if let color = sampledColor(at: location) {
            onHoverColorChanged?(color)
            onPickColor?(color)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)

        if isSpacePressed || isPanning {
            var next = viewport
            next.contentOffset = CanvasPoint(
                x: panStartOffset.x + (location.x - panStartLocation.x),
                y: panStartOffset.y + (location.y - panStartLocation.y)
            )
            onViewportChanged?(next)
            return
        }

        updateHoverColor(at: location)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        isPanning = false
        resetCursorRects()
    }

    override func keyDown(with event: NSEvent) {
        if handleLocalKeyDown(event) {
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if handleLocalKeyUp(event) {
            return
        }

        super.keyUp(with: event)
    }

    private func updateZoom(by multiplier: Double) {
        var next = viewport
        next.zoomScale = min(max(next.zoomScale * multiplier, 0.2), 16)
        if abs(next.zoomScale - 1) < 0.0001 {
            next = .fit
        }
        onViewportChanged?(next)
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
            width: imageSize.width * fitScale * viewport.zoomScale,
            height: imageSize.height * fitScale * viewport.zoomScale
        )
        let center = CGPoint(
            x: bounds.midX + viewport.contentOffset.x,
            y: bounds.midY + viewport.contentOffset.y
        )

        return CGRect(
            x: center.x - displaySize.width * 0.5,
            y: center.y - displaySize.height * 0.5,
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

    private func setUpEventMonitorsIfNeeded() {
        guard keyDownMonitor == nil else { return }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyDown(event) ? nil : event
        }

        keyUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { [weak self] event in
            guard let self else { return event }
            return self.handleLocalKeyUp(event) ? nil : event
        }
    }

    private func tearDownEventMonitors() {
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }

        if let keyUpMonitor {
            NSEvent.removeMonitor(keyUpMonitor)
            self.keyUpMonitor = nil
        }
    }

    private func handleLocalKeyDown(_ event: NSEvent) -> Bool {
        guard isMouseInside else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if modifiers == .command {
            let chars = event.charactersIgnoringModifiers ?? ""
            switch chars {
            case "+", "=":
                updateZoom(by: 1.2)
                return true
            case "-", "_":
                updateZoom(by: 1.0 / 1.2)
                return true
            case "0":
                onViewportChanged?(.fit)
                return true
            default:
                break
            }
        }

        if modifiers.isEmpty, event.keyCode == 49 {
            isSpacePressed = true
            resetCursorRects()
            return true
        }

        return false
    }

    private func handleLocalKeyUp(_ event: NSEvent) -> Bool {
        guard isMouseInside || isSpacePressed || isPanning else { return false }

        if event.keyCode == 49 {
            isSpacePressed = false
            isPanning = false
            resetCursorRects()
            return true
        }

        return false
    }

    private static let eyedropperCursor: NSCursor = {
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
            panel.contentView = NSHostingView(
                rootView: ReferenceImageFloatingPanelContent(
                    viewModel: viewModel,
                    onClose: { [weak self] in
                        self?.close()
                    }
                )
            )
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
            styleMask: [.borderless, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.minSize = CGSize(width: 420, height: 320)
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: ReferenceImageFloatingPanelContent(
                viewModel: viewModel,
                onClose: { [weak self] in
                    self?.close()
                }
            )
        )
        return panel
    }
}

private final class ReferenceImageFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ReferenceImageFloatingPanelContent: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                ReferenceImageViewer(
                    asset: viewModel.selectedReferenceImageSlot?.asset,
                    viewport: viewModel.selectedReferenceImageSlot?.viewport ?? .fit,
                    backgroundColor: NSColor(calibratedWhite: 0.08, alpha: 1),
                    onViewportChanged: { next in
                        viewModel.updateSelectedReferenceImageViewport(next)
                    },
                    onHoverColorChanged: { color in
                        viewModel.updateReferenceImagePreviewColor(color)
                    },
                    onPickColor: { color in
                        viewModel.confirmReferenceImagePickedColor(color)
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )

                HStack(spacing: 10) {
                    Button("适合") {
                        viewModel.resetSelectedReferenceImageViewportToFit()
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

                    RoundedRectangle(cornerRadius: 9)
                        .fill(viewModel.referenceImagePreviewSwiftUIColor)
                        .frame(width: 92, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .stroke(Color.white.opacity(0.08), lineWidth: 1)
                        )

                    Spacer(minLength: 0)
                }
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(red: 0.12, green: 0.12, blue: 0.13).opacity(0.98))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Color.white.opacity(0.92))
                    .frame(width: 24, height: 24)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.28))
                    )
            }
            .buttonStyle(.plain)
            .padding(12)
        }
        .padding(10)
        .background(Color.clear)
    }
}
