import Foundation
import Testing
@testable import ArtFlex

struct CanvasRenderPlanTests {
    @Test
    func executionStepsPreserveBottomToTopGroupOrder() {
        let bottomID = LayerID()
        let groupID = LayerID()
        let groupedPaintID = LayerID()
        let adjustmentID = LayerID()
        let plan = CanvasRenderPlan(
            canvasSize: .init(width: 1_024, height: 1_024),
            resources: [],
            nodes: [
                .paint(.init(layerID: bottomID, contentResourceIDs: [])),
                .group(.init(layerID: groupID, children: [
                    .paint(.init(layerID: groupedPaintID, contentResourceIDs: [])),
                    .adjustment(.init(
                        layerID: adjustmentID,
                        adjustment: .curves(.neutral)
                    ))
                ]))
            ]
        )

        #expect(plan.executionSteps == [
            .init(kind: .paint, layerID: bottomID),
            .init(kind: .beginGroup, layerID: groupID),
            .init(kind: .paint, layerID: groupedPaintID),
            .init(kind: .adjustment, layerID: adjustmentID),
            .init(kind: .endGroup, layerID: groupID)
        ])
    }

    @Test
    func standardPaintCompositionOrderIsExplicit() {
        #expect(CanvasRenderPlan.standardPaintCompositingOrder == [
            .sourcePixels,
            .layerMask,
            .layerOpacity,
            .clipTargetAlpha,
            .blendWithBackdrop
        ])
    }

    @Test
    func validPlanAcceptsTiledPaintAndSparseMaskResources() {
        let bottomLayerID = LayerID()
        let clippedLayerID = LayerID()
        let contentA = CanvasPixelResourceID()
        let contentB = CanvasPixelResourceID()
        let mask = CanvasPixelResourceID()
        let plan = CanvasRenderPlan(
            canvasSize: .init(width: 1_024, height: 512),
            resources: [
                .init(
                    id: contentA,
                    format: .bgra8UnormSRGB,
                    canvasRegion: .init(originX: 0, originY: 0, width: 512, height: 512)
                ),
                .init(
                    id: contentB,
                    format: .bgra8UnormSRGB,
                    canvasRegion: .init(originX: 512, originY: 0, width: 512, height: 512)
                ),
                .init(
                    id: mask,
                    format: .r8Unorm,
                    canvasRegion: .init(originX: 512, originY: 0, width: 512, height: 512)
                )
            ],
            nodes: [
                .paint(.init(layerID: bottomLayerID, contentResourceIDs: [contentA])),
                .paint(.init(
                    layerID: clippedLayerID,
                    contentResourceIDs: [contentB],
                    mask: .init(defaultValue: 255, resourceIDs: [mask]),
                    clipTargetLayerID: bottomLayerID
                ))
            ]
        )

        #expect(plan.validationIssues().isEmpty)
    }

    @Test
    func validationReportsResourceLayerAndOpacityErrors() {
        let duplicatedLayerID = LayerID()
        let missingClipTargetID = LayerID()
        let duplicateResourceID = CanvasPixelResourceID()
        let missingResourceID = CanvasPixelResourceID()
        let invalidPlan = CanvasRenderPlan(
            canvasSize: .init(width: 100, height: 100),
            resources: [
                .init(
                    id: duplicateResourceID,
                    format: .r8Unorm,
                    canvasRegion: .init(originX: 0, originY: 0, width: 100, height: 100)
                ),
                .init(
                    id: duplicateResourceID,
                    format: .bgra8UnormSRGB,
                    canvasRegion: .init(originX: 90, originY: 90, width: 20, height: 20)
                )
            ],
            nodes: [
                .paint(.init(
                    layerID: duplicatedLayerID,
                    contentResourceIDs: [duplicateResourceID, missingResourceID],
                    opacity: 1.2,
                    clipTargetLayerID: missingClipTargetID
                )),
                .adjustment(.init(
                    layerID: duplicatedLayerID,
                    adjustment: .curves(.neutral),
                    mask: .init(resourceIDs: [duplicateResourceID])
                ))
            ]
        )

        let issues = invalidPlan.validationIssues()
        #expect(issues.contains(.duplicateResourceID(duplicateResourceID)))
        #expect(issues.contains(.invalidResourceRegion(duplicateResourceID)))
        #expect(issues.contains(.duplicateLayerID(duplicatedLayerID)))
        #expect(issues.contains(.missingResource(missingResourceID)))
        #expect(issues.contains(.unexpectedResourceFormat(
            resourceID: duplicateResourceID,
            expected: .bgra8UnormSRGB,
            actual: .r8Unorm
        )))
        #expect(issues.contains(.invalidOpacity(duplicatedLayerID)))
        #expect(issues.contains(.missingClipTarget(
            layerID: duplicatedLayerID,
            targetLayerID: missingClipTargetID
        )))
    }

    @Test
    func renderPlanAndActiveEditTargetRoundTripThroughCodable() throws {
        let layerID = LayerID()
        let resourceID = CanvasPixelResourceID()
        var curves = CurveAdjustmentParameters.neutral
        curves.rgbCurve = CurveChannelState(points: [
            .init(x: 0, y: 0.1),
            .init(x: 1, y: 0.9)
        ])
        let plan = CanvasRenderPlan(
            canvasSize: .init(width: 256, height: 256),
            resources: [
                .init(
                    id: resourceID,
                    format: .bgra8UnormSRGB,
                    canvasRegion: .init(originX: 0, originY: 0, width: 256, height: 256)
                )
            ],
            nodes: [
                .paint(.init(layerID: layerID, contentResourceIDs: [resourceID])),
                .adjustment(.init(layerID: LayerID(), adjustment: .curves(curves)))
            ]
        )
        let target = ActiveEditTarget.layerMask(layerID)

        let planData = try JSONEncoder().encode(plan)
        let targetData = try JSONEncoder().encode(target)
        #expect(try JSONDecoder().decode(CanvasRenderPlan.self, from: planData) == plan)
        #expect(try JSONDecoder().decode(ActiveEditTarget.self, from: targetData) == target)
    }
}
