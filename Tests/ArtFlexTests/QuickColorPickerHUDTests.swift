import CoreGraphics
import Foundation
import Testing
@testable import ArtFlex

struct QuickColorPickerHUDTests {
    @Test
    func hueWheelMapsCardinalDirectionsClockwise() {
        let center = CGPoint(x: 50, y: 50)

        #expect(abs(ColorHueWheelGeometry.hue(at: CGPoint(x: 100, y: 50), center: center) - 0) < 0.001)
        #expect(abs(ColorHueWheelGeometry.hue(at: CGPoint(x: 50, y: 100), center: center) - 90) < 0.001)
        #expect(abs(ColorHueWheelGeometry.hue(at: CGPoint(x: 0, y: 50), center: center) - 180) < 0.001)
        #expect(abs(ColorHueWheelGeometry.hue(at: CGPoint(x: 50, y: 0), center: center) - 270) < 0.001)
    }

    @Test
    func hueWheelIndicatorAndInnerSquareUseMatchingGeometry() {
        let center = CGPoint(x: 90, y: 90)
        let indicator = ColorHueWheelGeometry.indicatorCenter(hue: 90, center: center, radius: 80)
        let squareSide = ColorHueWheelGeometry.innerSquareSide(diameter: 180, ringWidth: 18, gap: 4)

        #expect(abs(indicator.x - 90) < 0.001)
        #expect(abs(indicator.y - 170) < 0.001)
        #expect(abs(squareSide * sqrt(2) - 136) < 0.001)
    }

    @Test
    func hueWheelHitTestingAcceptsRingAndRejectsCenter() {
        let center = CGPoint(x: 90, y: 90)

        #expect(ColorHueWheelGeometry.containsRingPoint(
            CGPoint(x: 170, y: 90),
            center: center,
            diameter: 180,
            ringWidth: 18
        ))
        #expect(!ColorHueWheelGeometry.containsRingPoint(
            center,
            center: center,
            diameter: 180,
            ringWidth: 18
        ))
    }

    @Test
    func steppedSliderGuardRejectsDegenerateRanges() {
        #expect(quickColorPickerCanUseSteppedSlider(range: 1...1, step: 1) == false)
        #expect(quickColorPickerCanUseSteppedSlider(range: 0...0, step: 0.01) == false)
        #expect(quickColorPickerCanUseSteppedSlider(range: 1...4, step: 1) == true)
        #expect(quickColorPickerCanUseSteppedSlider(range: 0...1, step: 0.01) == true)
        #expect(quickColorPickerCanUseSteppedSlider(range: 0...1, step: 0) == false)
    }

    @Test
    func svImageBuilderMatchesPickerColorReference() throws {
        var panel = ColorPanelState.stageOneDefault
        panel.pickerHue = 217
        panel.pickerLightness = 67
        panel.pickerSaturation = 73
        panel.lightingHue = 28
        panel.lightingStrength = 42
        let size = 9

        let image = try #require(makeColorPickerSVImage(size: size, panel: panel))
        let providerData = try #require(image.dataProvider?.data)
        let actualBytes = [UInt8](providerData as Data)
        var expectedBytes: [UInt8] = []
        expectedBytes.reserveCapacity(size * size * 4)

        for y in 0..<size {
            for x in 0..<size {
                var samplePanel = panel
                samplePanel.pickerX = Float(x) / Float(size - 1)
                samplePanel.pickerY = Float(y) / Float(size - 1)
                let color = ColorBlocksEngine.pickerColor(from: samplePanel)
                expectedBytes.append(UInt8(clamping: Int((color.red * 255).rounded())))
                expectedBytes.append(UInt8(clamping: Int((color.green * 255).rounded())))
                expectedBytes.append(UInt8(clamping: Int((color.blue * 255).rounded())))
                expectedBytes.append(255)
            }
        }

        #expect(actualBytes == expectedBytes)
    }

    @Test
    func svImageBuilderHonorsCancellation() {
        let image = makeColorPickerSVImage(
            size: 288,
            panel: .stageOneDefault,
            shouldCancel: { true }
        )
        #expect(image == nil)
    }

    @Test
    @MainActor
    func svImageCacheKeepsMultiplePickerSizesWarm() throws {
        let cache = ColorPickerDisplayImageCache(svCache: ControlledSVImageCache())
        var buildCount = 0
        var panel = ColorPanelState.stageOneDefault
        panel.pickerHue = 143

        func build(size: Int) -> CGImage? {
            buildCount += 1
            return makeColorPickerSVImage(size: size, panel: panel)
        }

        _ = try #require(cache.svImage(size: 64, panel: panel) { build(size: 64) })
        _ = try #require(cache.svImage(size: 128, panel: panel) { build(size: 128) })
        _ = try #require(cache.svImage(size: 64, panel: panel) { build(size: 64) })

        #expect(buildCount == 2)
    }

    @Test
    @MainActor
    func hudSVImageCanBePreparedBeforePresentation() async throws {
        let cache = ColorPickerDisplayImageCache(svCache: ControlledSVImageCache())
        var panel = ColorPanelState.stageOneDefault
        panel.pickerHue = 271

        #expect(cache.cachedSVImage(
            size: QuickColorPickerLayout.svRasterSize,
            panel: panel
        ) == nil)

        let image = try #require(await cache.prepareSVImage(
            size: QuickColorPickerLayout.svRasterSize,
            panel: panel
        ))

        #expect(cache.cachedSVImage(
            size: QuickColorPickerLayout.svRasterSize,
            panel: panel
        ) === image)
    }

    @Test
    @MainActor
    func preparedImageRemainsCorrectEvenWhenEveryCacheInsertionIsEvicted() async throws {
        let cache = ColorPickerDisplayImageCache(svCache: ControlledSVImageCache(discardInsertions: true))
        var panel = ColorPanelState.stageOneDefault
        panel.pickerHue = 123
        panel.lightingStrength = 42
        let expected = try #require(makeColorPickerSVImage(size: 32, panel: panel))
        let prepared = try #require(await cache.prepareSVImage(size: 32, panel: panel))
        #expect(cache.cachedSVImage(size: 32, panel: panel) == nil)
        #expect(imageBytes(prepared) == imageBytes(expected))
        let rebuilt = try #require(await cache.prepareSVImage(size: 32, panel: panel))
        #expect(imageBytes(rebuilt) == imageBytes(prepared))
    }

    @Test
    @MainActor
    func nativeCacheEvictionRebuildsWithoutInvalidatingTheDisplayedImage() async throws {
        let storage = NSCache<NSString, CGImage>()
        let cache = ColorPickerDisplayImageCache(svCache: storage)
        let panel = ColorPanelState.stageOneDefault
        let displayed = try #require(await cache.prepareSVImage(size: 64, panel: panel))
        let originalBytes = try #require(imageBytes(displayed))
        storage.removeAllObjects()
        #expect(cache.cachedSVImage(size: 64, panel: panel) == nil)
        let rebuilt = try #require(await cache.prepareSVImage(size: 64, panel: panel))
        #expect(imageBytes(displayed) == originalBytes)
        #expect(imageBytes(rebuilt) == originalBytes)
    }

    @Test
    @MainActor
    func independentCachesAndDifferentColorsCannotInvalidateEachOther() async throws {
        let firstStorage = ControlledSVImageCache()
        let first = ColorPickerDisplayImageCache(svCache: firstStorage)
        let second = ColorPickerDisplayImageCache(svCache: ControlledSVImageCache())
        var panel = ColorPanelState.stageOneDefault
        panel.pickerHue = 60
        let warm = try #require(await first.prepareSVImage(size: 64, panel: panel))
        let other = try #require(await second.prepareSVImage(size: 64, panel: panel))
        firstStorage.removeAllObjects()
        #expect(first.cachedSVImage(size: 64, panel: panel) == nil)
        #expect(second.cachedSVImage(size: 64, panel: panel) === other)
        #expect(imageBytes(warm) == imageBytes(other))
        panel.pickerHue = 180
        let changed = try #require(await second.prepareSVImage(size: 64, panel: panel))
        #expect(imageBytes(changed) != imageBytes(other))
    }

    @Test(arguments: [false, true])
    @MainActor
    func cancelledPreparationDoesNotReturnOrInstallAnImage(warmCache: Bool) async throws {
        let cache = ColorPickerDisplayImageCache(svCache: ControlledSVImageCache())
        let panel = ColorPanelState.stageOneDefault
        if warmCache { _ = try #require(await cache.prepareSVImage(size: 32, panel: panel)) }
        // Cancel before the task gets a MainActor turn, independent of thread/frame timing.
        let pending = Task { @MainActor in await cache.prepareSVImage(size: 32, panel: panel) }
        pending.cancel()
        #expect(await pending.value == nil)
        #expect((cache.cachedSVImage(size: 32, panel: panel) != nil) == warmCache)
    }

    private func imageBytes(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }
}

/// Test-only deterministic retention/eviction. Production still uses Foundation's adaptive
/// NSCache; tests of our keying/hit policy must not assume the OS promises retention.
private final class ControlledSVImageCache: NSCache<NSString, CGImage>, @unchecked Sendable {
    private let lock = NSLock()
    private var images: [NSString: CGImage] = [:]
    private let discardInsertions: Bool

    init(discardInsertions: Bool = false) { self.discardInsertions = discardInsertions }

    override func object(forKey key: NSString) -> CGImage? { lock.withLock { images[key] } }
    override func setObject(_ obj: CGImage, forKey key: NSString, cost g: Int) {
        lock.withLock { if !discardInsertions { images[key] = obj } }
    }
    override func removeAllObjects() { lock.withLock { images.removeAll() } }
}
