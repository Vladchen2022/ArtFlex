import Foundation
@preconcurrency import Metal
import Testing
@testable import ArtFlex

struct EyedropperSamplerTests {
    @Test
    func defaultSettingsUseThreeByThreeAverageOfDisplayedColor() {
        let settings = EyedropperSettings.stageOneDefault

        #expect(settings.sampleSize == .threeByThree)
        #expect(settings.statistic == .average)
        #expect(settings.source == .displayedColor)
        #expect(settings.preservesTransparency == false)
        #expect(settings.returnsToPreviousTool == false)
    }

    @Test
    func settingsRoundTripAndLegacyPayloadUsesDefaults() throws {
        var session = ToolSessionState.stageOneDefault
        session.eyedropper = EyedropperSettings(
            sampleSize: .fiveByFive,
            statistic: .median,
            source: .displayedColor,
            preservesTransparency: true,
            returnsToPreviousTool: true
        )

        let encoded = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(ToolSessionState.self, from: encoded)
        #expect(decoded.eyedropper == session.eyedropper)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "eyedropper")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyDecoded = try JSONDecoder().decode(ToolSessionState.self, from: legacyData)
        #expect(legacyDecoded.eyedropper == .stageOneDefault)
    }

    @Test
    func pointAverageAndMedianSamplingProduceExpectedValues() throws {
        let harness = try EyedropperTestHarness(canvasSize: .init(width: 5, height: 5))
        var pixels = [UInt8](repeating: 0, count: 5 * 5 * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset + 3] = 255
        }
        let centerOffset = ((2 * 5) + 2) * 4
        pixels[centerOffset] = 255
        pixels[centerOffset + 1] = 255
        pixels[centerOffset + 2] = 255
        try harness.restore(
            snapshot: makeSnapshot(width: 5, height: 5, bytes: pixels),
            to: harness.document.activeLayerID
        )

        let point = try harness.sample(
            at: .init(x: 2, y: 2),
            settings: settings(sampleSize: .point, statistic: .average)
        )
        #expect(point.red > 0.99)
        #expect(point.green > 0.99)
        #expect(point.blue > 0.99)

        let threeByThreeAverage = try harness.sample(
            at: .init(x: 2, y: 2),
            settings: settings(sampleSize: .threeByThree, statistic: .average)
        )
        let expectedThreeByThree = LinearPremultipliedColor.linearChannelToSRGB(1 / 9)
        #expect(abs(threeByThreeAverage.red - expectedThreeByThree) < 0.01)

        let fiveByFiveAverage = try harness.sample(
            at: .init(x: 2, y: 2),
            settings: settings(sampleSize: .fiveByFive, statistic: .average)
        )
        let expectedFiveByFive = LinearPremultipliedColor.linearChannelToSRGB(1 / 25)
        #expect(abs(fiveByFiveAverage.red - expectedFiveByFive) < 0.01)

        let median = try harness.sample(
            at: .init(x: 2, y: 2),
            settings: settings(sampleSize: .threeByThree, statistic: .median)
        )
        #expect(median.red < 0.01)
        #expect(median.green < 0.01)
        #expect(median.blue < 0.01)
    }

    @Test
    func sourceModesAndTransparencyMatchTheirDefinitions() throws {
        let bottom = LayerRecord(
            id: LayerID(),
            name: "Bottom",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        let top = LayerRecord(
            id: LayerID(),
            name: "Top",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        let document = makeDocument(
            canvasSize: .init(width: 3, height: 3),
            layers: [bottom, top],
            activeLayerID: top.id
        )
        let harness = try EyedropperTestHarness(document: document)
        try harness.restore(
            snapshot: renderedColorSnapshot(
                width: 3,
                height: 3,
                color: .init(red: 1, green: 0, blue: 0, alpha: 1)
            ),
            to: bottom.id
        )
        try harness.restore(
            snapshot: renderedColorSnapshot(
                width: 3,
                height: 3,
                color: .init(red: 0, green: 1, blue: 0, alpha: 128 / 255)
            ),
            to: top.id
        )

        var currentLayerSettings = settings(sampleSize: .point, statistic: .average)
        currentLayerSettings.source = .currentLayer
        currentLayerSettings.preservesTransparency = true
        let currentLayerColor = try harness.sample(at: .init(x: 1, y: 1), settings: currentLayerSettings)
        #expect(currentLayerColor.red < 0.01)
        #expect(currentLayerColor.green > 0.99)
        #expect(abs(currentLayerColor.alpha - (128 / 255)) < 0.01)

        currentLayerSettings.preservesTransparency = false
        let flattenedCurrentLayerColor = try harness.sample(
            at: .init(x: 1, y: 1),
            settings: currentLayerSettings
        )
        #expect(flattenedCurrentLayerColor.red > 0.72)
        #expect(flattenedCurrentLayerColor.green > 0.99)
        #expect(flattenedCurrentLayerColor.blue > 0.72)
        #expect(flattenedCurrentLayerColor.alpha == 1)

        var allVisibleSettings = currentLayerSettings
        allVisibleSettings.source = .allVisibleLayers
        let allVisibleColor = try harness.sample(at: .init(x: 1, y: 1), settings: allVisibleSettings)
        #expect(allVisibleColor.red > 0.72)
        #expect(allVisibleColor.green > 0.72)
        #expect(allVisibleColor.blue < 0.01)
        #expect(allVisibleColor.alpha == 1)

        let displayedTexture = try harness.makeTexture()
        try harness.serializer.restore(
            snapshot: solidSnapshot(width: 3, height: 3, blue: 255, alpha: 255),
            into: displayedTexture
        )
        var displayedSettings = allVisibleSettings
        displayedSettings.source = .displayedColor
        let displayedColor = try harness.sample(
            at: .init(x: 1, y: 1),
            settings: displayedSettings,
            displayTextureForLayer: { layerID in
                layerID == top.id ? displayedTexture : nil
            }
        )
        #expect(displayedColor.red < 0.01)
        #expect(displayedColor.green < 0.01)
        #expect(displayedColor.blue > 0.99)
    }

    @Test
    func preservingTransparencyRestoresNonSaturatedRenderedColor() throws {
        let harness = try EyedropperTestHarness(canvasSize: .init(width: 3, height: 3))
        let sourceColor = RGBAColor(red: 0.23, green: 0.57, blue: 0.81, alpha: 0.4)
        try harness.restore(
            snapshot: renderedColorSnapshot(width: 3, height: 3, color: sourceColor),
            to: harness.document.activeLayerID
        )
        var sampleSettings = settings(sampleSize: .point, statistic: .average)
        sampleSettings.source = .currentLayer
        sampleSettings.preservesTransparency = true

        let sampledColor = try harness.sample(at: .init(x: 1, y: 1), settings: sampleSettings)

        #expect(abs(sampledColor.red - sourceColor.red) < 0.02)
        #expect(abs(sampledColor.green - sourceColor.green) < 0.02)
        #expect(abs(sampledColor.blue - sourceColor.blue) < 0.02)
        #expect(abs(sampledColor.alpha - sourceColor.alpha) < 0.01)
    }

    @Test
    func currentLayerSamplingAppliesEnabledLayerMask() throws {
        let layer = LayerRecord(
            id: LayerID(),
            name: "Masked",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1,
            mask: .init(isEnabled: true)
        )
        let document = makeDocument(
            canvasSize: .init(width: 2, height: 1),
            layers: [layer],
            activeLayerID: layer.id
        )
        let harness = try EyedropperTestHarness(document: document)
        try harness.restore(
            snapshot: solidSnapshot(width: 2, height: 1, red: 255, alpha: 255),
            to: layer.id
        )
        try harness.restoreMask(
            snapshot: makeMaskSnapshot(width: 2, height: 1, bytes: [0, 255]),
            to: layer.id
        )

        var sampleSettings = settings(sampleSize: .point, statistic: .average)
        sampleSettings.source = .currentLayer
        sampleSettings.preservesTransparency = true
        let maskedOut = try harness.sample(at: .init(x: 0, y: 0), settings: sampleSettings)
        let maskedIn = try harness.sample(at: .init(x: 1, y: 0), settings: sampleSettings)

        #expect(maskedOut.alpha < 0.01)
        #expect(maskedIn.red > 0.99)
        #expect(maskedIn.green < 0.01)
        #expect(maskedIn.blue < 0.01)
        #expect(maskedIn.alpha > 0.99)
    }

    @Test
    func clippedLayerSamplingUsesTargetLayerMask() throws {
        let target = LayerRecord(
            id: LayerID(),
            name: "Target",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1,
            mask: .init(isEnabled: true)
        )
        let clipped = LayerRecord(
            id: LayerID(),
            name: "Clipped",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1,
            clipTargetLayerID: target.id
        )
        let document = makeDocument(
            canvasSize: .init(width: 2, height: 1),
            layers: [target, clipped],
            activeLayerID: clipped.id
        )
        let harness = try EyedropperTestHarness(document: document)
        try harness.restore(
            snapshot: solidSnapshot(width: 2, height: 1, blue: 255, alpha: 255),
            to: target.id
        )
        try harness.restore(
            snapshot: solidSnapshot(width: 2, height: 1, red: 255, alpha: 255),
            to: clipped.id
        )
        try harness.restoreMask(
            snapshot: makeMaskSnapshot(width: 2, height: 1, bytes: [0, 255]),
            to: target.id
        )

        var sampleSettings = settings(sampleSize: .point, statistic: .average)
        sampleSettings.preservesTransparency = true
        let maskedOut = try harness.sample(at: .init(x: 0, y: 0), settings: sampleSettings)
        let maskedIn = try harness.sample(at: .init(x: 1, y: 0), settings: sampleSettings)

        #expect(maskedOut.alpha < 0.01)
        #expect(maskedIn.red > 0.99)
        #expect(maskedIn.blue < 0.01)
        #expect(maskedIn.alpha > 0.99)
    }

    @Test
    func visibleSamplingAppliesCurveAdjustmentInDocumentOrder() throws {
        let bottom = LayerRecord(
            id: LayerID(),
            name: "Bottom",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        var parameters = CurveAdjustmentParameters.neutral
        parameters.redCurve = CurveChannelState(points: [
            .init(x: 0, y: 1),
            .init(x: 1, y: 1)
        ])
        let adjustment = LayerRecord(
            id: LayerID(),
            name: "Adjustment",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1,
            adjustment: .curves(parameters)
        )
        let top = LayerRecord(
            id: LayerID(),
            name: "Top",
            isVisible: true,
            isLocked: false,
            locksTransparentPixels: false,
            opacity: 1
        )
        let document = makeDocument(
            canvasSize: .init(width: 2, height: 1),
            layers: [bottom, adjustment, top],
            activeLayerID: top.id
        )
        let harness = try EyedropperTestHarness(document: document)
        try harness.restore(
            snapshot: solidSnapshot(width: 2, height: 1, alpha: 255),
            to: bottom.id
        )
        try harness.restore(
            snapshot: makeSnapshot(
                width: 2,
                height: 1,
                bytes: [0, 0, 0, 0, 0, 255, 0, 255]
            ),
            to: top.id
        )

        for source in [EyedropperSampleSource.allVisibleLayers, .displayedColor] {
            var sampleSettings = settings(sampleSize: .point, statistic: .average)
            sampleSettings.source = source
            sampleSettings.preservesTransparency = true
            let adjustedBottom = try harness.sample(
                at: .init(x: 0, y: 0),
                settings: sampleSettings
            )
            let unadjustedTop = try harness.sample(
                at: .init(x: 1, y: 0),
                settings: sampleSettings
            )

            #expect(adjustedBottom.red > 0.99)
            #expect(adjustedBottom.green < 0.01)
            #expect(unadjustedTop.red < 0.01)
            #expect(unadjustedTop.green > 0.99)
        }
    }

    @Test
    func averageAtCanvasEdgeUsesOnlyValidPixels() throws {
        let harness = try EyedropperTestHarness(canvasSize: .init(width: 3, height: 3))
        try harness.restore(
            snapshot: solidSnapshot(width: 3, height: 3, red: 255, alpha: 255),
            to: harness.document.activeLayerID
        )

        let color = try harness.sample(
            at: .init(x: 0, y: 0),
            settings: settings(sampleSize: .threeByThree, statistic: .average)
        )
        #expect(color.red > 0.99)
        #expect(color.green < 0.01)
        #expect(color.blue < 0.01)
    }
}

private final class EyedropperTestHarness {
    let metalContext: MetalDeviceContext
    let document: ArtDocument
    let layerSurfaceStore: StageOneLayerSurfaceStore
    let serializer: LayerTextureSerializer
    let sampler: EyedropperSampler

    convenience init(canvasSize: CanvasSize) throws {
        let layer = LayerRecord.stageOneDefault()
        try self.init(
            document: makeDocument(
                canvasSize: canvasSize,
                layers: [layer],
                activeLayerID: layer.id
            )
        )
    }

    init(document: ArtDocument) throws {
        guard let metalContext = MetalDeviceContext() else {
            throw EyedropperTestError.metalUnavailable
        }
        let layerSurfaceStore = StageOneLayerSurfaceStore()
        layerSurfaceStore.prepareTextures(for: document, metal: metalContext)
        let serializer = LayerTextureSerializer(metalContext: metalContext)
        self.metalContext = metalContext
        self.document = document
        self.layerSurfaceStore = layerSurfaceStore
        self.serializer = serializer
        sampler = EyedropperSampler(serializer: serializer)
    }

    func makeTexture() throws -> MTLTexture {
        guard let texture = layerSurfaceStore.makeTexture(
            width: document.canvasSize.width,
            height: document.canvasSize.height,
            metal: metalContext
        ) else {
            throw EyedropperTestError.textureUnavailable
        }
        return texture
    }

    func restore(snapshot: LayerTextureSnapshot, to layerID: LayerID) throws {
        guard
            let surfaceID = layerSurfaceStore.surfaceID(for: layerID),
            let texture = layerSurfaceStore.texture(for: surfaceID)
        else {
            throw EyedropperTestError.textureUnavailable
        }
        try serializer.restore(snapshot: snapshot, into: texture)
    }

    func restoreMask(snapshot: LayerTextureSnapshot, to layerID: LayerID) throws {
        guard let texture = layerSurfaceStore.maskTexture(for: layerID) else {
            throw EyedropperTestError.textureUnavailable
        }
        try serializer.restore(snapshot: snapshot, into: texture)
    }

    func sample(
        at point: CanvasPoint,
        settings: EyedropperSettings,
        contentTextureForLayer: ((LayerID) -> MTLTexture?)? = nil,
        displayTextureForLayer: ((LayerID) -> MTLTexture?)? = nil
    ) throws -> RGBAColor {
        try sampler.sampleVisibleColor(
            at: point,
            document: document,
            layerSurfaceStore: layerSurfaceStore,
            settings: settings,
            contentTextureForLayer: contentTextureForLayer,
            displayTextureForLayer: displayTextureForLayer
        )
    }
}

private func settings(
    sampleSize: EyedropperSampleSize,
    statistic: EyedropperSampleStatistic
) -> EyedropperSettings {
    EyedropperSettings(
        sampleSize: sampleSize,
        statistic: statistic,
        source: .allVisibleLayers,
        preservesTransparency: false,
        returnsToPreviousTool: false
    )
}

private func makeDocument(
    canvasSize: CanvasSize,
    layers: [LayerRecord],
    activeLayerID: LayerID
) -> ArtDocument {
    let now = Date()
    return ArtDocument(
        metadata: DocumentMetadata(name: "Eyedropper Test", createdAt: now, updatedAt: now),
        canvasSize: canvasSize,
        layers: layers,
        activeLayerID: activeLayerID
    )
}

private func solidSnapshot(
    width: Int,
    height: Int,
    blue: UInt8 = 0,
    green: UInt8 = 0,
    red: UInt8 = 0,
    alpha: UInt8
) -> LayerTextureSnapshot {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: bytes.count, by: 4) {
        bytes[offset] = blue
        bytes[offset + 1] = green
        bytes[offset + 2] = red
        bytes[offset + 3] = alpha
    }
    return makeSnapshot(width: width, height: height, bytes: bytes)
}

private func renderedColorSnapshot(
    width: Int,
    height: Int,
    color: RGBAColor
) -> LayerTextureSnapshot {
    let alpha = min(max(color.alpha, 0), 1)
    let bytes = LinearPremultipliedColor(
        red: LinearPremultipliedColor.srgbChannelToLinear(color.red) * alpha,
        green: LinearPremultipliedColor.srgbChannelToLinear(color.green) * alpha,
        blue: LinearPremultipliedColor.srgbChannelToLinear(color.blue) * alpha,
        alpha: alpha
    ).bgra8PremultipliedBytes
    return solidSnapshot(
        width: width,
        height: height,
        blue: bytes.blue,
        green: bytes.green,
        red: bytes.red,
        alpha: bytes.alpha
    )
}

private func makeSnapshot(width: Int, height: Int, bytes: [UInt8]) -> LayerTextureSnapshot {
    LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: width * 4,
        pixelData: Data(bytes)
    )
}

private func makeMaskSnapshot(width: Int, height: Int, bytes: [UInt8]) -> LayerTextureSnapshot {
    LayerTextureSnapshot(
        width: width,
        height: height,
        bytesPerRow: width,
        pixelData: Data(bytes)
    )
}

private enum EyedropperTestError: Error {
    case metalUnavailable
    case textureUnavailable
}
