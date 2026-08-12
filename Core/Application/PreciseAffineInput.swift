import Foundation

struct PreciseAffineInput: Codable, Sendable, Equatable {
    var centerX: Double
    var centerY: Double
    var width: Double
    var height: Double
    var rotationDegrees: Double
    var isHorizontallyFlipped: Bool
    var isVerticallyFlipped: Bool
    var locksAspectRatio: Bool

    init(
        centerX: Double,
        centerY: Double,
        width: Double,
        height: Double,
        rotationDegrees: Double,
        isHorizontallyFlipped: Bool = false,
        isVerticallyFlipped: Bool = false,
        locksAspectRatio: Bool = true
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.isHorizontallyFlipped = isHorizontallyFlipped
        self.isVerticallyFlipped = isVerticallyFlipped
        self.locksAspectRatio = locksAspectRatio
    }

    init(
        bounds: CanvasRect,
        preview: FreeTransformPreview,
        pivotBounds: CanvasRect? = nil,
        locksAspectRatio: Bool = true
    ) {
        let sourceCenter = Self.center(of: bounds)
        let pivotCenter = Self.center(of: pivotBounds ?? bounds)
        let transformedCenter = Self.transformedCenter(
            sourceCenter: sourceCenter,
            pivotCenter: pivotCenter,
            scaleX: preview.scaleX,
            scaleY: preview.scaleY,
            rotationRadians: preview.rotationRadians,
            translation: preview.translation
        )

        self.init(
            centerX: transformedCenter.x,
            centerY: transformedCenter.y,
            width: abs(bounds.maxX - bounds.minX) * abs(preview.scaleX),
            height: abs(bounds.maxY - bounds.minY) * abs(preview.scaleY),
            rotationDegrees: preview.rotationRadians * 180 / .pi,
            isHorizontallyFlipped: preview.scaleX < 0,
            isVerticallyFlipped: preview.scaleY < 0,
            locksAspectRatio: locksAspectRatio
        )
    }

    var center: CanvasPoint {
        CanvasPoint(x: centerX, y: centerY)
    }

    var hasValidFiniteGeometry: Bool {
        centerX.isFinite &&
            centerY.isFinite &&
            width.isFinite &&
            height.isFinite &&
            rotationDegrees.isFinite &&
            width > 0 &&
            height > 0
    }

    mutating func updateWidth(_ newWidth: Double, sourceAspectRatio: Double) {
        guard newWidth.isFinite, newWidth > 0 else { return }
        width = newWidth
        if locksAspectRatio, sourceAspectRatio.isFinite, sourceAspectRatio > 0 {
            height = newWidth / sourceAspectRatio
        }
    }

    mutating func updateHeight(_ newHeight: Double, sourceAspectRatio: Double) {
        guard newHeight.isFinite, newHeight > 0 else { return }
        height = newHeight
        if locksAspectRatio, sourceAspectRatio.isFinite, sourceAspectRatio > 0 {
            width = newHeight * sourceAspectRatio
        }
    }

    mutating func flipHorizontally() {
        isHorizontallyFlipped.toggle()
    }

    mutating func flipVertically() {
        isVerticallyFlipped.toggle()
    }

    func resolvedPreview(
        bounds: CanvasRect,
        pivotBounds: CanvasRect? = nil
    ) -> FreeTransformPreview? {
        guard hasValidFiniteGeometry else { return nil }

        let sourceWidth = abs(bounds.maxX - bounds.minX)
        let sourceHeight = abs(bounds.maxY - bounds.minY)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        let scaleXMagnitude = width / sourceWidth
        let scaleYMagnitude = height / sourceHeight
        let scaleX = isHorizontallyFlipped ? -scaleXMagnitude : scaleXMagnitude
        let scaleY = isVerticallyFlipped ? -scaleYMagnitude : scaleYMagnitude
        let rotationRadians = rotationDegrees * .pi / 180
        let sourceCenter = Self.center(of: bounds)
        let pivotCenter = Self.center(of: pivotBounds ?? bounds)
        let centerWithoutTranslation = Self.transformedCenter(
            sourceCenter: sourceCenter,
            pivotCenter: pivotCenter,
            scaleX: scaleX,
            scaleY: scaleY,
            rotationRadians: rotationRadians,
            translation: .init(x: 0, y: 0)
        )

        return FreeTransformPreview(
            translation: CanvasPoint(
                x: centerX - centerWithoutTranslation.x,
                y: centerY - centerWithoutTranslation.y
            ),
            scaleX: scaleX,
            scaleY: scaleY,
            rotationRadians: rotationRadians
        )
    }

    private static func center(of bounds: CanvasRect) -> CanvasPoint {
        CanvasPoint(
            x: (bounds.minX + bounds.maxX) / 2,
            y: (bounds.minY + bounds.maxY) / 2
        )
    }

    private static func transformedCenter(
        sourceCenter: CanvasPoint,
        pivotCenter: CanvasPoint,
        scaleX: Double,
        scaleY: Double,
        rotationRadians: Double,
        translation: CanvasPoint
    ) -> CanvasPoint {
        let relativeX = (sourceCenter.x - pivotCenter.x) * scaleX
        let relativeY = (sourceCenter.y - pivotCenter.y) * scaleY
        let cosine = cos(rotationRadians)
        let sine = sin(rotationRadians)
        return CanvasPoint(
            x: pivotCenter.x + translation.x + (relativeX * cosine) - (relativeY * sine),
            y: pivotCenter.y + translation.y + (relativeX * sine) + (relativeY * cosine)
        )
    }
}
