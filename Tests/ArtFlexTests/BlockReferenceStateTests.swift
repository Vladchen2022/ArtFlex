import AppKit
import Foundation
import Testing
@testable import ArtFlex

struct BlockReferenceStateTests {
    @Test
    func blockReferenceDisplayModeDefaultsToSolidAndDecodesLegacySettingsAsWireframe() throws {
        #expect(BlockReferenceDisplaySettings.stageOneDefault.mode == .solid)

        let legacyJSON = Data("""
        {
          "opacity": 0.52,
          "showsFaces": true,
          "showsEdges": true,
          "isVisible": true,
          "isFrozen": false
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(BlockReferenceDisplaySettings.self, from: legacyJSON)

        #expect(decoded.mode == .wireframe)
    }

    @Test
    func cameraProjectionAndRayIntersectionRoundTripOnGroundPlane() throws {
        let canvasSize = CanvasSize(width: 1_200, height: 900)
        let camera = BlockReferenceCamera.stageOneDefault
        let point = BlockVector3(x: 85, y: -42, z: 0)
        let projected = try #require(
            projectBlockPoint(point, camera: camera, canvasSize: canvasSize)
        )
        let ray = blockCameraRay(
            canvasPoint: projected.canvasPoint,
            camera: camera,
            canvasSize: canvasSize
        )
        let resolved = try #require(intersectBlockRay(ray, with: .ground))

        #expect(abs(resolved.x - point.x) < 0.000_1)
        #expect(abs(resolved.y - point.y) < 0.000_1)
        #expect(abs(resolved.z - point.z) < 0.000_1)
    }

    @Test
    func metalSolidDepthMappingIsMonotonicForBothCameraModes() throws {
        for isOrthographic in [false, true] {
            let near = try #require(blockReferenceMetalNormalizedDepth(
                cameraDepth: 10,
                nearDepth: 10,
                farDepth: 1_000,
                isOrthographic: isOrthographic
            ))
            let middle = try #require(blockReferenceMetalNormalizedDepth(
                cameraDepth: 250,
                nearDepth: 10,
                farDepth: 1_000,
                isOrthographic: isOrthographic
            ))
            let far = try #require(blockReferenceMetalNormalizedDepth(
                cameraDepth: 1_000,
                nearDepth: 10,
                farDepth: 1_000,
                isOrthographic: isOrthographic
            ))

            #expect(abs(near) < 0.000_001)
            #expect(middle > near)
            #expect(far > middle)
            #expect(abs(far - 1) < 0.000_001)
        }
    }

    @Test
    func metalSolidEdgesDoNotAdvanceInFrontOfOccludingFaces() {
        let faceDepth: Float = 0.75
        let hiddenEdgeDepth: Float = 0.750_005

        #expect(blockReferenceMetalOcclusionPreservingEdgeDepth(faceDepth) == faceDepth)
        #expect(blockReferenceMetalOcclusionPreservingEdgeDepth(hiddenEdgeDepth) > faceDepth)
    }

    @Test
    func displayModesHaveDistinctFaceRenderingAndUseTheDisplayRefreshRate() {
        var display = BlockReferenceDisplaySettings.stageOneDefault
        #expect(blockReferenceShouldRenderFaces(display: display))

        display.mode = .wireframe
        #expect(!blockReferenceShouldRenderFaces(display: display))

        display.mode = .solid
        display.showsFaces = false
        #expect(!blockReferenceShouldRenderFaces(display: display))

        #expect(blockReferencePreferredFramesPerSecond(maximumFramesPerSecond: nil) == 60)
        #expect(blockReferencePreferredFramesPerSecond(maximumFramesPerSecond: 60) == 60)
        #expect(blockReferencePreferredFramesPerSecond(maximumFramesPerSecond: 120) == 120)
        #expect(blockReferencePreferredFramesPerSecond(maximumFramesPerSecond: 240) == 120)
        #expect(blockReferenceMetalBufferCapacity(requiredByteCount: 0) == 0)
        #expect(blockReferenceMetalBufferCapacity(requiredByteCount: 1) == 4_096)
        #expect(blockReferenceMetalBufferCapacity(requiredByteCount: 4_096) == 4_096)
        #expect(blockReferenceMetalBufferCapacity(requiredByteCount: 4_097) == 8_192)
    }

    @Test
    @MainActor
    func liveCameraRenderStateHandsOffOnlyAfterRendererReceivesCommittedCamera() throws {
        let stored = BlockReferenceCamera.stageOneDefault
        var live = stored
        live.target = BlockVector3(x: 40, y: -25, z: 90)
        live.yawDegrees += 18

        let state = BlockReferenceCameraRenderState()
        state.beginNavigation()
        state.updateNavigation(camera: live)
        #expect(state.camera == live)

        state.finishNavigation(committedCamera: live)
        state.rendererDidReceive(camera: stored)
        #expect(state.camera == live)

        state.rendererDidReceive(camera: live)
        #expect(state.camera == nil)
    }

    @Test
    func solidRendererUsesPerPixelDepthWithoutBackFaceCulling() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let rendererSource = try String(
            contentsOf: root.appendingPathComponent(
                "Platform/macOS/UI/BlockReferenceMetalSolidView.swift"
            ),
            encoding: .utf8
        )
        let overlaySource = try String(
            contentsOf: root.appendingPathComponent(
                "Platform/macOS/UI/BlockReferenceOverlay.swift"
            ),
            encoding: .utf8
        )

        #expect(rendererSource.contains("depthStencilPixelFormat = .depth32Float"))
        #expect(rendererSource.contains("faceDepthDescriptor.depthCompareFunction = .less"))
        #expect(rendererSource.contains("faceDepthDescriptor.isDepthWriteEnabled = true"))
        #expect(rendererSource.contains("encoder.setCullMode(.none)"))
        #expect(rendererSource.contains("view.setNeedsDisplay(view.bounds)"))
        #expect(rendererSource.contains("presentsWithTransaction") == false)
        #expect(rendererSource.contains("blockReferencePreferredFramesPerSecond("))
        #expect(rendererSource.contains("view.isPaused = !rendersContinuously"))
        #expect(rendererSource.contains("cameraRenderState.camera"))
        #expect(rendererSource.contains("inFlightBufferSemaphore"))
        #expect(rendererSource.contains("makeBuffer(\n               bytes: geometry") == false)
        #expect(rendererSource.contains("makeGridSegments(scene: scene)"))
        #expect(overlaySource.contains("BlockReferenceMetalSolidView("))
        #expect(overlaySource.contains("if scene.display.mode == .wireframe") == false)
        #expect(overlaySource.contains("TimelineView(.animation("))
    }

    @Test
    func gridSnapUsesTheActiveWorkingPlaneCoordinates() {
        var scene = BlockReferenceScene.empty
        scene.snap.enabledKinds = [.grid]
        scene.snap.gridSpacing = 20
        scene.snap.screenTolerancePoints = 100
        let candidate = scene.workingPlane.worldPoint(u: 37, v: 63)

        let snapped = snappedBlockPoint(
            candidate,
            scene: scene,
            canvasSize: .init(width: 1_200, height: 900),
            screenScale: 1
        )

        #expect(snapped.kind == .grid)
        #expect(snapped.point == BlockVector3(x: 40, y: 60, z: 0))
    }

    @Test
    func extrusionHeightSnapsToAVisibleObjectVertexBeforeGrid() throws {
        let source = BlockReferenceObject(
            name: "高度参照",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 80, depth: 80, height: 83)
        )
        var scene = BlockReferenceScene.empty
        scene.objects = [source]
        scene.snap.enabledKinds = [.grid, .vertex]
        scene.snap.gridSpacing = 20
        let draft = BlockCreationDraft(
            kind: .box,
            plane: .ground,
            baseStart: BlockVector3(x: -20, y: -20, z: 0),
            baseEnd: BlockVector3(x: 20, y: 20, z: 0),
            height: 1
        )

        let snapped = snappedBlockExtrusionHeight(
            82,
            draft: draft,
            scene: scene,
            canvasSize: .init(width: 1_200, height: 900),
            screenScale: 1
        )

        #expect(snapped.kind == .vertex)
        #expect(abs(snapped.height - 83) < 0.000_001)
        #expect(try #require(snapped.snapPoint).z == 83)
    }

    @Test
    func extrusionHeightUsesTheConstructionPlaneNormalOnSlantedPlanes() {
        let plane = BlockWorkingPlane(
            origin: .zero,
            axisU: .unitY,
            axisV: .unitZ,
            normal: .unitX
        )
        let source = BlockReferenceObject(
            name: "侧向高度参照",
            kind: .box,
            position: BlockVector3(x: 110, y: 0, z: 0),
            dimensions: .init(width: 20, depth: 40, height: 40)
        )
        var scene = BlockReferenceScene.empty
        scene.objects = [source]
        scene.snap.enabledKinds = [.vertex]
        scene.snap.screenTolerancePoints = 40
        let draft = BlockCreationDraft(
            kind: .box,
            plane: plane,
            baseStart: plane.worldPoint(u: -10, v: -10),
            baseEnd: plane.worldPoint(u: 10, v: 10),
            height: 1
        )

        let snapped = snappedBlockExtrusionHeight(
            99,
            draft: draft,
            scene: scene,
            canvasSize: .init(width: 1_200, height: 900),
            screenScale: 1
        )

        #expect(snapped.kind == .vertex)
        #expect(abs(snapped.height - 100) < 0.000_001)
    }

    @Test
    func faceCanBecomeAWorkingPlaneAndAlignANewObject() throws {
        let source = BlockReferenceObject(
            name: "斜方块",
            kind: .box,
            position: .zero,
            rotation: .init(xDegrees: 24, yDegrees: -18, zDegrees: 31),
            dimensions: .init(width: 100, depth: 80, height: 60)
        )
        let face = try #require(blockObjectFaces(source).first(where: { $0.faceIndex == 1 }))
        let plane = try #require(blockWorkingPlane(from: face))
        let rotation = blockRotation(alignedTo: plane)
        let rotatedNormal = blockRotate(.unitZ, rotation: rotation).normalized()

        #expect(rotatedNormal.dot(plane.normal) > 0.999)
        #expect(plane.sourceObjectID == source.id)
        #expect(plane.sourceFaceIndex == face.faceIndex)
    }

    @Test
    func primitiveMeshesRespectRequestedDimensions() {
        for kind in BlockPrimitiveKind.allCases {
            let object = BlockReferenceObject(
                name: kind.displayName,
                kind: kind,
                position: .zero,
                dimensions: .init(width: 120, depth: 80, height: 160)
            )
            let vertices = blockObjectFaces(object).flatMap(\.vertices)
            #expect(vertices.isEmpty == false)
            #expect(vertices.map(\.z).min() ?? 1 >= -0.000_1)
            #expect(vertices.map(\.z).max() ?? 0 <= 160.000_1)
            #expect(vertices.map(\.x).min() ?? 1 >= -60.000_1)
            #expect(vertices.map(\.x).max() ?? 0 <= 60.000_1)
        }
    }

    @Test
    func curvedPrimitivesUseEightSegmentCrossSections() {
        let dimensions = BlockDimensions(width: 120, depth: 80, height: 160)
        let cylinder = BlockReferenceObject(
            name: "圆柱",
            kind: .cylinder,
            position: .zero,
            dimensions: dimensions
        )
        let cone = BlockReferenceObject(
            name: "圆锥",
            kind: .cone,
            position: .zero,
            dimensions: dimensions
        )
        let sphere = BlockReferenceObject(
            name: "球体",
            kind: .sphere,
            position: .zero,
            dimensions: dimensions
        )

        #expect(blockObjectFaces(cylinder).count == 10)
        #expect(blockObjectFaces(cone).count == 9)
        #expect(blockObjectFaces(sphere).count == 32)
    }

    @Test
    func surfaceConstructionPlaneUsesTheHitFaceOnlyWhenEnabled() throws {
        let source = BlockReferenceObject(
            name: "承载方块",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 100, depth: 100, height: 100)
        )
        var scene = BlockReferenceScene.empty
        scene.objects = [source]
        let canvasSize = CanvasSize(width: 1_200, height: 900)
        let projectedTopCenter = try #require(projectBlockPoint(
            BlockVector3(x: 0, y: 0, z: 100),
            camera: scene.camera,
            canvasSize: canvasSize
        ))

        let directPlane = blockReferenceConstructionPlane(
            scene: scene,
            canvasPoint: projectedTopCenter.canvasPoint,
            canvasSize: canvasSize,
            buildsDirectlyOnSurfaces: true
        )
        let ordinaryPlane = blockReferenceConstructionPlane(
            scene: scene,
            canvasPoint: projectedTopCenter.canvasPoint,
            canvasSize: canvasSize,
            buildsDirectlyOnSurfaces: false
        )

        #expect(directPlane.sourceObjectID == source.id)
        #expect(abs(directPlane.origin.z - 100) < 0.000_1)
        #expect(ordinaryPlane == scene.workingPlane)
    }

    @Test
    func parameterScrubbingUsesHorizontalDirectionPrecisionAndMinimums() {
        #expect(blockReferenceScrubbedParameterValue(
            startValue: 10,
            horizontalTranslation: 25,
            sensitivity: 0.2
        ) == 15)
        #expect(blockReferenceScrubbedParameterValue(
            startValue: 10,
            horizontalTranslation: -25,
            sensitivity: 0.2
        ) == 5)
        #expect(blockReferenceScrubbedParameterValue(
            startValue: 10,
            horizontalTranslation: 25,
            sensitivity: 0.2,
            precisionScale: 0.1
        ) == 10.5)
        #expect(blockReferenceScrubbedParameterValue(
            startValue: 2,
            horizontalTranslation: -100,
            sensitivity: 0.2,
            minimumValue: 1
        ) == 1)
    }

    @Test
    func creationDraftExposesAnExactWorkingPlaneFootprint() {
        let plane = BlockWorkingPlane(
            origin: BlockVector3(x: 5, y: 7, z: 11),
            axisU: .unitY,
            axisV: .unitZ,
            normal: .unitX
        )
        let draft = BlockCreationDraft(
            kind: .box,
            plane: plane,
            baseStart: plane.worldPoint(u: 30, v: -10),
            baseEnd: plane.worldPoint(u: -20, v: 40),
            height: 1
        )

        #expect(draft.baseCorners.count == 4)
        #expect(draft.baseCorners.allSatisfy {
            abs(($0 - plane.origin).dot(plane.normal)) < 0.000_001
        })
        let coordinates = draft.baseCorners.map(plane.coordinates(of:))
        #expect(coordinates.map(\.u).min() == -20)
        #expect(coordinates.map(\.u).max() == 30)
        #expect(coordinates.map(\.v).min() == -10)
        #expect(coordinates.map(\.v).max() == 40)
    }

    @Test
    func fixedHumanModulesUseExpectedProportionsAndRejectBooleanEditing() throws {
        let standing = blockReferenceModuleObject(
            kind: .standingHuman,
            name: "站姿",
            position: .zero
        )
        let seated = blockReferenceModuleObject(
            kind: .seatedHuman,
            name: "坐姿",
            position: .zero
        )
        let standingVertices = blockObjectFaces(standing).flatMap(\.vertices)
        let seatedVertices = blockObjectFaces(seated).flatMap(\.vertices)

        #expect(standing.moduleKind == .standingHuman)
        #expect(seated.moduleKind == .seatedHuman)
        #expect(standing.customMesh?.faces.count == 42)
        #expect(seated.customMesh?.faces.count == 42)
        #expect(standing.dimensions.height == 170)
        #expect(seated.dimensions.height == 132)
        #expect(abs((standingVertices.map(\.z).min() ?? -1) - 0) < 0.000_1)
        #expect(abs((standingVertices.map(\.z).max() ?? -1) - 170) < 0.000_1)
        #expect(abs((seatedVertices.map(\.z).min() ?? -1) - 0) < 0.000_1)
        #expect(abs((seatedVertices.map(\.z).max() ?? -1) - 132) < 0.000_1)
        #expect(seated.dimensions.depth > standing.dimensions.depth)
        #expect(standing.allowsGeometryEditing == false)
        #expect(standing.allowsBooleanOperations == false)

        let box = BlockReferenceObject(
            name: "方块",
            kind: .box,
            position: .zero,
            dimensions: .stageOneDefault
        )
        #expect(throws: BlockReferenceBooleanError.invalidInput) {
            try blockReferenceBooleanObject(
                active: standing,
                other: box,
                operation: .union,
                name: "不允许"
            )
        }
    }

    @Test
    func booleanOperationsCreateEditableArtFlexOwnedMeshes() throws {
        let active = BlockReferenceObject(
            name: "主体",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 100, depth: 100, height: 100)
        )
        let other = BlockReferenceObject(
            name: "工具体",
            kind: .box,
            position: .init(x: 50, y: 0, z: 0),
            dimensions: .init(width: 100, depth: 100, height: 100)
        )

        let union = try blockReferenceBooleanObject(
            active: active,
            other: other,
            operation: .union,
            name: "合并"
        )
        let intersection = try blockReferenceBooleanObject(
            active: active,
            other: other,
            operation: .intersection,
            name: "相交"
        )
        let subtraction = try blockReferenceBooleanObject(
            active: active,
            other: other,
            operation: .subtract,
            name: "减去"
        )

        #expect(union.customMesh?.faces.isEmpty == false)
        #expect(abs(union.dimensions.width - 150) < 0.001)
        #expect(abs(intersection.dimensions.width - 50) < 0.001)
        #expect(abs(subtraction.dimensions.width - 50) < 0.001)
        #expect(union.geometryDisplayName == "布尔结果")

        var mirrored = union
        mirrored.name = "方块 1 镜像"
        #expect(mirrored.geometryDisplayName == "镜像体块")

        var scaled = union
        scaled.dimensions.width *= 2
        let scaledVertices = blockObjectFaces(scaled).flatMap(\.vertices)
        let scaledWidth = try #require(scaledVertices.map(\.x).max())
            - (try #require(scaledVertices.map(\.x).min()))
        #expect(abs(scaledWidth - 300) < 0.001)

        let encoded = try JSONEncoder().encode(union)
        let decoded = try JSONDecoder().decode(BlockReferenceObject.self, from: encoded)
        #expect(decoded == union)
        #expect(decoded.customMesh != nil)
    }

    @Test
    func booleanIntersectionRejectsSeparatedObjectsWithoutChangingInputs() {
        let active = BlockReferenceObject(
            name: "主体",
            kind: .box,
            position: .zero,
            dimensions: .stageOneDefault
        )
        let other = BlockReferenceObject(
            name: "远处",
            kind: .box,
            position: .init(x: 1_000, y: 0, z: 0),
            dimensions: .stageOneDefault
        )

        #expect(throws: BlockReferenceBooleanError.emptyResult) {
            try blockReferenceBooleanObject(
                active: active,
                other: other,
                operation: .intersection,
                name: "空"
            )
        }
    }

    @Test
    func everyLowPolyPrimitiveCanEnterTheBooleanPipeline() throws {
        for kind in BlockPrimitiveKind.allCases {
            let active = BlockReferenceObject(
                name: "A",
                kind: kind,
                position: .zero,
                dimensions: .init(width: 100, depth: 100, height: 100)
            )
            let other = BlockReferenceObject(
                name: "B",
                kind: kind,
                position: .init(x: 20, y: 0, z: 0),
                dimensions: .init(width: 100, depth: 100, height: 100)
            )
            let result = try blockReferenceBooleanObject(
                active: active,
                other: other,
                operation: .union,
                name: kind.displayName
            )
            #expect(result.customMesh?.faces.isEmpty == false)
        }
    }

    @Test
    func booleanResultCanBeUsedAsTheInputOfAnotherBoolean() throws {
        let box = BlockReferenceObject(
            name: "方块",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 80, depth: 80, height: 80)
        )
        let sphere = BlockReferenceObject(
            name: "球体",
            kind: .sphere,
            position: .zero,
            dimensions: .init(width: 100, depth: 100, height: 100)
        )
        let firstResult = try blockReferenceBooleanObject(
            active: box,
            other: sphere,
            operation: .subtract,
            name: "第一次结果"
        )
        let remoteBox = BlockReferenceObject(
            name: "另一个方块",
            kind: .box,
            position: .init(x: 180, y: 0, z: 0),
            dimensions: .init(width: 40, depth: 40, height: 40)
        )

        let secondResult = try blockReferenceBooleanObject(
            active: firstResult,
            other: remoteBox,
            operation: .union,
            name: "第二次结果"
        )

        #expect(secondResult.customMesh?.faces.isEmpty == false)
    }

    @Test
    func cylinderCanSubtractAnOverlappingBox() throws {
        let cylinder = BlockReferenceObject(
            name: "圆柱",
            kind: .cylinder,
            position: .zero,
            dimensions: .init(width: 80, depth: 80, height: 220)
        )
        let box = BlockReferenceObject(
            name: "方块",
            kind: .box,
            position: .init(x: 20, y: 0, z: 60),
            dimensions: .init(width: 80, depth: 100, height: 100)
        )

        let result = try blockReferenceBooleanObject(
            active: cylinder,
            other: box,
            operation: .subtract,
            name: "圆柱减方块"
        )

        #expect(result.customMesh?.faces.isEmpty == false)
        #expect(result.dimensions.height > 100)
        #expect(result.dimensions.width <= cylinder.dimensions.width + 0.001)
    }

    @Test
    func transformGizmoKeepsAStableScreenSizeAndHitTestsMoveAndRotationHandles() throws {
        let canvasSize = CanvasSize(width: 1_200, height: 900)
        let object = BlockReferenceObject(
            name: "方块",
            kind: .box,
            position: BlockVector3(x: 0, y: 0, z: 70),
            dimensions: .stageOneDefault
        )
        let layout = try #require(blockReferenceGizmoLayout(
            object: object,
            camera: .stageOneDefault,
            canvasSize: canvasSize,
            screenScale: 2
        ))
        let xMove = try #require(layout.moveHandles.first(where: { $0.axis == .x }))
        #expect(abs(hypot(xMove.end.x - xMove.start.x, xMove.end.y - xMove.start.y) * 2 - 66) < 0.001)
        #expect(blockReferenceGizmoHitTest(
            point: xMove.end,
            layout: layout,
            screenScale: 2
        ) == BlockReferenceGizmoHandle(kind: .move, axis: .x))

        let xScale = try #require(layout.scaleHandles.first(where: { $0.axis == .x }))
        #expect(blockReferenceGizmoHitTest(
            point: xScale.end,
            layout: layout,
            screenScale: 2
        ) == BlockReferenceGizmoHandle(kind: .scale, axis: .x))

        let zRing = try #require(layout.rotationRings.first(where: { $0.axis == .z }))
        let zRotationPoint = try #require(zRing.points.first(where: { point in
            blockReferenceGizmoHitTest(
                point: point,
                layout: layout,
                screenScale: 2
            ) == BlockReferenceGizmoHandle(kind: .rotate, axis: .z)
        }))
        #expect(blockReferenceGizmoHitTest(
            point: zRotationPoint,
            layout: layout,
            screenScale: 2
        ) == BlockReferenceGizmoHandle(kind: .rotate, axis: .z))
    }

    @Test
    func gizmoRotationAngleUsesTheRequestedWorldAxis() {
        let angle = blockReferenceGizmoSignedAngleDegrees(
            from: .unitX,
            to: .unitY,
            around: .z
        )
        #expect(abs(angle - 90) < 0.000_001)
        let reverse = blockReferenceGizmoSignedAngleDegrees(
            from: .unitY,
            to: .unitX,
            around: .z
        )
        #expect(abs(reverse + 90) < 0.000_001)
    }

    @Test
    func numericTransformsPreviewSignedMovementAndAxisRotation() {
        let object = BlockReferenceObject(
            name: "方块",
            kind: .box,
            position: .init(x: 10, y: 20, z: 30),
            rotation: .init(xDegrees: 5, yDegrees: 10, zDegrees: 15),
            dimensions: .stageOneDefault
        )
        let move = BlockReferenceNumericTransform(
            objectID: object.id,
            kind: .move,
            axis: .x,
            input: "-45.5",
            originalPosition: object.position,
            originalRotation: object.rotation
        )
        let moved = move.applying(to: object)
        #expect(moved.position == BlockVector3(x: -35.5, y: 20, z: 30))

        let rotate = BlockReferenceNumericTransform(
            objectID: object.id,
            kind: .rotate,
            axis: .z,
            input: "30",
            originalPosition: object.position,
            originalRotation: object.rotation
        )
        let rotated = rotate.applying(to: object)
        #expect(abs(rotated.rotation.xDegrees - 5) < 1e-9)
        #expect(abs(rotated.rotation.yDegrees - 10) < 1e-9)
        #expect(abs(rotated.rotation.zDegrees - 45) < 1e-9)
    }

    @Test
    func numericRotationComposesAroundTheRequestedWorldAxis() {
        let original = BlockEulerRotation(xDegrees: 23, yDegrees: -31, zDegrees: 47)
        let delta = BlockEulerRotation(xDegrees: 38, yDegrees: 0, zDegrees: 0)
        let resolved = blockRotation(applyingWorldAxis: .x, degrees: 38, to: original)

        for basis in [BlockVector3.unitX, .unitY, .unitZ] {
            let expected = blockRotate(blockRotate(basis, rotation: original), rotation: delta)
            let actual = blockRotate(basis, rotation: resolved)
            #expect(actual.distance(to: expected) < 0.000_001)
        }
    }

    @Test
    func groupNumericTransformUsesOneSharedPivot() {
        let first = BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: BlockVector3(x: 0, y: 0, z: 0),
            dimensions: .stageOneDefault
        )
        let second = BlockReferenceObject(
            name: "方块 2",
            kind: .box,
            position: BlockVector3(x: 10, y: 0, z: 0),
            dimensions: .stageOneDefault
        )
        let snapshots = Dictionary(uniqueKeysWithValues: [first, second].map {
            ($0.id, BlockReferenceObjectTransformSnapshot(position: $0.position, rotation: $0.rotation))
        })
        let transform = BlockReferenceNumericTransform(
            objectID: second.id,
            kind: .rotate,
            axis: .z,
            input: "90",
            originalPosition: second.position,
            originalRotation: second.rotation,
            originalTransforms: snapshots,
            pivot: BlockVector3(x: 5, y: 0, z: 0)
        )

        let rotatedFirst = transform.applying(to: first)
        let rotatedSecond = transform.applying(to: second)
        #expect(rotatedFirst.position.distance(to: BlockVector3(x: 5, y: -5, z: 0)) < 0.000_001)
        #expect(rotatedSecond.position.distance(to: BlockVector3(x: 5, y: 5, z: 0)) < 0.000_001)
        #expect(abs(rotatedFirst.rotation.zDegrees - 90) < 0.000_001)
        #expect(abs(rotatedSecond.rotation.zDegrees - 90) < 0.000_001)
    }

    @Test
    func legacyBlockReferenceObjectDefaultsToVisibleAndUnlocked() throws {
        let object = BlockReferenceObject(
            name: "旧方块",
            kind: .box,
            position: .zero,
            dimensions: .stageOneDefault
        )
        let encoded = try JSONEncoder().encode(object)
        var payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        payload.removeValue(forKey: "isVisible")
        payload.removeValue(forKey: "isLocked")
        payload.removeValue(forKey: "moduleKind")
        let legacyData = try JSONSerialization.data(withJSONObject: payload)

        let decoded = try JSONDecoder().decode(BlockReferenceObject.self, from: legacyData)
        #expect(decoded.isVisible)
        #expect(decoded.isLocked == false)
        #expect(decoded.customMesh == nil)
        #expect(decoded.moduleKind == nil)
    }

    @Test
    @MainActor
    func interactionViewRoutesShiftMiddleDragToScenePan() throws {
        let view = BlockReferenceInteractionView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        var beganMode: BlockReferenceNavigationMode?
        var changedMode: BlockReferenceNavigationMode?
        var changedDelta = CGPoint.zero
        var didEnd = false
        view.onNavigationBegan = { beganMode = $0 }
        view.onNavigationChanged = { mode, deltaX, deltaY in
            changedMode = mode
            changedDelta = CGPoint(x: deltaX, y: deltaY)
        }
        view.onNavigationEnded = { didEnd = true }

        // NSEvent.mouseEvent reports buttonNumber 0 even for .otherMouseDown.
        // Construct an actual center-button event; do not post it to the system.
        let middleDown = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
            mouseCursorPosition: CGPoint(x: 100, y: 100), mouseButton: .center))
        middleDown.flags = .maskShift
        let down = try #require(NSEvent(cgEvent: middleDown))
        let dragged = try #require(NSEvent.mouseEvent(
            with: .otherMouseDragged,
            location: CGPoint(x: 145, y: 130),
            modifierFlags: [.shift],
            timestamp: 2,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .otherMouseUp,
            location: CGPoint(x: 145, y: 130),
            modifierFlags: [.shift],
            timestamp: 3,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 0
        ))

        view.otherMouseDown(with: down)
        view.otherMouseDragged(with: dragged)
        view.otherMouseUp(with: up)

        #expect(beganMode == .pan)
        #expect(changedMode == .pan)
        #expect(abs(changedDelta.x) > 1)
        #expect(abs(changedDelta.y) > 1)
        #expect(didEnd)
    }

    @Test
    @MainActor
    func interactionViewOwnsAFocusableNativeGizmoValueField() throws {
        let view = BlockReferenceInteractionView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let keyboardBridge = KeyboardBridgeView(frame: .zero)
        let rootView = NSView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 500, height: 400),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        rootView.addSubview(view)
        rootView.addSubview(keyboardBridge)
        window.contentView = rootView
        let adjustment = BlockReferenceGizmoAdjustment(
            objectID: UUID(),
            handle: BlockReferenceGizmoHandle(kind: .move, axis: .x),
            input: "12",
            originalPosition: .zero,
            originalRotation: .zero
        )
        var changedInput: String?
        view.onGizmoInputChanged = { changedInput = $0 }
        view.configureGizmoEditor(adjustment: adjustment, center: CGPoint(x: 250, y: 200))

        let field = try #require(
            view.subviews
                .flatMap(\.subviews)
                .compactMap { $0 as? NSTextField }
                .first(where: { $0.isEditable })
        )
        #expect(window.firstResponder === field.currentEditor())
        #expect(field.currentEditor()?.selectedRange.length == field.stringValue.utf16.count)
        keyboardBridge.activateIfNeeded()
        #expect(window.firstResponder === field.currentEditor())
        field.stringValue = "25"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(changedInput == "25")
    }

    @Test
    @MainActor
    func interactionViewBuildsAndDispatchesTheNativeBlockContextMenu() throws {
        let view = BlockReferenceInteractionView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        var requestedPoint: CanvasPoint?
        var didPerform = false
        view.contextMenuItems = { point in
            requestedPoint = point
            return [
                .action(title: "拾取模块基准点…", isEnabled: true) {
                    didPerform = true
                }
            ]
        }
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: CGPoint(x: 145, y: 130),
            modifierFlags: [],
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))

        let menu = try #require(view.menu(for: event))
        #expect(requestedPoint == CanvasPoint(x: 145, y: 270))
        #expect(menu.items.map(\.title) == ["拾取模块基准点…"])
        let item = try #require(menu.items.first)
        let action = try #require(item.action)
        _ = (item.target as? NSObject)?.perform(action, with: item)
        #expect(didPerform)
    }

    @Test
    func rightInspectorUsesStructuredWorkspaceOnlyForTheBlockReferenceTool() {
        #expect(rightInspectorUsesStructuredBlockReferenceWorkspace(activeTool: .blockReference))
        #expect(rightInspectorUsesStructuredBlockReferenceWorkspace(activeTool: .brush) == false)
        #expect(rightInspectorUsesStructuredBlockReferenceWorkspace(activeTool: .perspective) == false)
        #expect(BlockReferencePanelPresentation.allCases == [
            .library,
            .context,
            .objects,
            .cameraSlots
        ])
    }

    @Test
    func sceneRoundTripsAndLegacyDocumentWithoutSceneStillDecodes() throws {
        var document = ArtDocument.stageOneDefault()
        var scene = BlockReferenceScene.empty
        scene.objects.append(BlockReferenceObject(
            name: "方块 1",
            kind: .box,
            position: .init(x: 20, y: 40, z: 0),
            dimensions: .init(width: 80, depth: 100, height: 120)
        ))
        scene.measurements.append(.init(start: .zero, end: .init(x: 30, y: 40, z: 0)))
        document.blockReferenceScene = scene

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ArtDocument.self, from: data)
        #expect(decoded.blockReferenceScene == scene)

        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "blockReferenceScene")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let legacy = try JSONDecoder().decode(ArtDocument.self, from: legacyData)
        #expect(legacy.blockReferenceScene == nil)
    }

    @Test
    func advancedSceneFieldsRoundTripAndLegacySceneUsesSafeDefaults() throws {
        var scene = BlockReferenceScene.empty
        let group = BlockReferenceGroup(name: "建筑组", pivot: .zero)
        var object = BlockReferenceObject(
            name: "蓝色方块",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 40, depth: 50, height: 60),
            groupID: group.id
        )
        object.style.colorTag = .blue
        scene.objects = [object]
        scene.groups = [group]
        scene.cameraSlots = [.init(index: 1, name: "主视角", camera: scene.camera, isLocked: true)]
        scene.constructionLines = [.init(name: "X 辅助", origin: .zero, direction: .unitX)]
        scene.savedWorkingPlanes = [.init(name: "地面", plane: .ground)]
        scene.section = .init(isEnabled: true, plane: .ground, isInverted: true)
        scene.snapshots = [blockReferenceSceneSnapshot(name: "方案 A", scene: scene)]

        let encoded = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(BlockReferenceScene.self, from: encoded)
        #expect(decoded == scene)

        var legacyObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["groups", "cameraSlots", "constructionLines", "savedWorkingPlanes", "section", "snapshots"] {
            legacyObject.removeValue(forKey: key)
        }
        if var objects = legacyObject["objects"] as? [[String: Any]], !objects.isEmpty {
            for key in ["groupID", "style", "humanPose", "moduleParameters"] {
                objects[0].removeValue(forKey: key)
            }
            legacyObject["objects"] = objects
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(BlockReferenceScene.self, from: legacyData)
        #expect(legacy.groups.isEmpty)
        #expect(legacy.cameraSlots.isEmpty)
        #expect(legacy.section == .disabled)
        #expect(legacy.objects[0].style == .default)
    }

    @Test
    func numericScaleSupportsUniformAndAxisConstrainedGroups() {
        let first = BlockReferenceObject(
            name: "A",
            kind: .box,
            position: .init(x: -10, y: 0, z: 0),
            dimensions: .init(width: 20, depth: 30, height: 40)
        )
        let second = BlockReferenceObject(
            name: "B",
            kind: .box,
            position: .init(x: 10, y: 0, z: 0),
            dimensions: .init(width: 10, depth: 12, height: 14)
        )
        let snapshots = Dictionary(uniqueKeysWithValues: [first, second].map {
            ($0.id, BlockReferenceObjectTransformSnapshot(
                position: $0.position,
                rotation: $0.rotation,
                dimensions: $0.dimensions
            ))
        })
        let uniform = BlockReferenceNumericTransform(
            objectID: first.id,
            kind: .scale,
            axis: nil,
            input: "2",
            originalPosition: first.position,
            originalRotation: first.rotation,
            originalTransforms: snapshots,
            pivot: .zero
        )
        let scaled = uniform.applying(to: first)
        #expect(scaled.position.x == -20)
        #expect(scaled.dimensions == .init(width: 40, depth: 60, height: 80))

        var axisScale = uniform
        axisScale.axis = .x
        let constrained = axisScale.applying(to: second)
        #expect(constrained.position.x == 20)
        #expect(constrained.dimensions.width == 20)
        #expect(constrained.dimensions.depth == 12)
    }

    @Test
    func enhancedSnapPointsIncludeVerticesMidpointsAndFaceCenters() {
        let object = BlockReferenceObject(
            name: "方块",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 20, depth: 30, height: 40)
        )
        let kinds = Set(blockObjectSnapPoints(object).map(\.kind))
        #expect(kinds.contains(.center))
        #expect(kinds.contains(.vertex))
        #expect(kinds.contains(.midpoint))
        #expect(kinds.contains(.faceCenter))
    }

    @Test
    func parametricModulesAndPoseableHumanStayLowPolygonAndBounded() throws {
        for kind in [
            BlockReferenceModuleKind.poseableHuman,
            .stairs, .doorFrame, .roomBox, .table
        ] {
            let object = blockReferenceModuleObject(
                kind: kind,
                name: kind.displayName,
                position: .zero
            )
            let mesh = try #require(object.customMesh)
            #expect(mesh.faces.isEmpty == false)
            #expect(mesh.faces.count <= BlockReferenceCustomMesh.maximumFaceCount)
            #expect(object.dimensions.width > 0)
            #expect(object.moduleKind == kind)
        }
    }

    @Test
    func requestedPrimitiveModulesAreClosedLowPolygonMeshesWithBottomCenterAnchors() throws {
        let specifications: [(
            kind: BlockReferenceModuleKind,
            dimensions: BlockDimensions,
            faceCount: Int
        )] = [
            (.squareFrustum, .init(width: 120, depth: 120, height: 60), 6),
            (.squarePyramid, .init(width: 120, depth: 120, height: 120), 5),
            (.hemisphere, .init(width: 120, depth: 120, height: 60), 17),
            (.torus, .init(width: 160, depth: 160, height: 40), 32),
            (.hollowCylinder, .init(width: 120, depth: 120, height: 120), 32)
        ]

        for specification in specifications {
            let geometry = try #require(blockReferenceAdvancedModuleGeometry(kind: specification.kind))
            #expect(geometry.dimensions == specification.dimensions)
            #expect(geometry.faces.count == specification.faceCount)
            #expect(geometry.faces.allSatisfy { $0.count >= 3 })
            #expect(geometry.faces.allSatisfy { face in
                (face[1] - face[0]).cross(face[2] - face[0]).length > 0.000_001
            })
            #expect(blockReferenceTestEdgeUseCounts(geometry.faces).values.allSatisfy { $0 == 2 })

            let bounds = blockReferenceTestBounds(geometry.faces)
            #expect(abs(bounds.minX + specification.dimensions.width * 0.5) < 0.000_001)
            #expect(abs(bounds.maxX - specification.dimensions.width * 0.5) < 0.000_001)
            #expect(abs(bounds.minY + specification.dimensions.depth * 0.5) < 0.000_001)
            #expect(abs(bounds.maxY - specification.dimensions.depth * 0.5) < 0.000_001)
            #expect(abs(bounds.minZ) < 0.000_001)
            #expect(abs(bounds.maxZ - specification.dimensions.height) < 0.000_001)

            let object = blockReferenceModuleObject(
                kind: specification.kind,
                name: specification.kind.displayName,
                position: .init(x: 40, y: 50, z: 60)
            )
            #expect(object.moduleKind == specification.kind)
            #expect(object.moduleBasePointOffset == .zero)
            #expect(blockReferenceObjectModuleBasePoint(object) == object.position)
            #expect(object.allowsGeometryEditing)
        }

        let frustum = try #require(blockReferenceAdvancedModuleGeometry(kind: .squareFrustum))
        let frustumBottom = blockReferenceTestBounds([frustum.faces[0]])
        let frustumTop = blockReferenceTestBounds([frustum.faces[1]])
        #expect(frustumBottom.maxX - frustumBottom.minX == 120)
        #expect(frustumTop.maxX - frustumTop.minX == 72)

        let hemisphere = try #require(blockReferenceAdvancedModuleGeometry(kind: .hemisphere))
        let hemisphereLevels = Set(hemisphere.faces.flatMap { $0 }.map(\.z))
        #expect(hemisphereLevels.count == 3)

        let torus = try #require(blockReferenceAdvancedModuleGeometry(kind: .torus))
        let torusVertices = torus.faces.flatMap { $0 }
        #expect(torusVertices.contains { abs($0.x - 80) < 0.000_001 && abs($0.y) < 0.000_001 && abs($0.z - 20) < 0.000_001 })
        #expect(torusVertices.contains { abs($0.x - 60) < 0.000_001 && abs($0.y) < 0.000_001 && abs($0.z - 40) < 0.000_001 })
        #expect(torusVertices.contains { abs($0.x - 40) < 0.000_001 && abs($0.y) < 0.000_001 && abs($0.z - 20) < 0.000_001 })
        #expect(torusVertices.contains { abs($0.x - 60) < 0.000_001 && abs($0.y) < 0.000_001 && abs($0.z) < 0.000_001 })

        let hollowCylinder = try #require(blockReferenceAdvancedModuleGeometry(kind: .hollowCylinder))
        let cylinderRadii = hollowCylinder.faces.flatMap { $0 }.map { hypot($0.x, $0.y) }
        #expect(cylinderRadii.contains { abs($0 - 60) < 0.000_001 })
        #expect(cylinderRadii.contains { abs($0 - 36) < 0.000_001 })
    }

    @Test
    func transportationModulesUseClosedLowPolygonGeometryAndReasonableProportions() throws {
        let specifications: [(
            kind: BlockReferenceModuleKind,
            bodyPartCount: Int,
            wheelCount: Int,
            expectedFaceCount: Int
        )] = [
            (.sedan, 3, 4, 146),
            (.suv, 4, 4, 152),
            (.smallTruck, 3, 4, 146),
            (.largeTruck, 3, 6, 210),
            (.bicycle, 4, 2, 88),
            (.motorcycle, 4, 2, 88)
        ]

        for specification in specifications {
            let geometry = try #require(blockReferenceAdvancedModuleGeometry(kind: specification.kind))
            #expect(specification.bodyPartCount <= 4)
            #expect(geometry.faces.count == specification.expectedFaceCount)
            #expect(geometry.faces.count == specification.bodyPartCount * 6 + specification.wheelCount * 32)
            #expect(geometry.faces.allSatisfy { $0.count >= 3 })
            #expect(geometry.faces.allSatisfy { face in
                (face[1] - face[0]).cross(face[2] - face[0]).length > 0.000_001
            })
            #expect(blockReferenceTestEdgeUseCounts(geometry.faces).values.allSatisfy { $0 == 2 })

            let bounds = blockReferenceTestBounds(geometry.faces)
            #expect(abs(bounds.minX + geometry.dimensions.width * 0.5) < 0.000_001)
            #expect(abs(bounds.maxX - geometry.dimensions.width * 0.5) < 0.000_001)
            #expect(abs(bounds.minY + geometry.dimensions.depth * 0.5) < 0.000_001)
            #expect(abs(bounds.maxY - geometry.dimensions.depth * 0.5) < 0.000_001)
            #expect(abs(bounds.minZ) < 0.000_001)
            #expect(abs(bounds.maxZ - geometry.dimensions.height) < 0.000_001)

            let position = BlockVector3(x: 40, y: 50, z: 60)
            let object = blockReferenceModuleObject(
                kind: specification.kind,
                name: specification.kind.displayName,
                position: position
            )
            #expect(object.moduleKind == specification.kind)
            #expect(object.moduleBasePointOffset == .zero)
            #expect(blockReferenceObjectModuleBasePoint(object) == position)
            #expect(!object.allowsGeometryEditing)
            #expect(specification.kind.isTransportationReference)
        }

        let sedan = try #require(blockReferenceAdvancedModuleGeometry(kind: .sedan))
        let suv = try #require(blockReferenceAdvancedModuleGeometry(kind: .suv))
        let smallTruck = try #require(blockReferenceAdvancedModuleGeometry(kind: .smallTruck))
        let largeTruck = try #require(blockReferenceAdvancedModuleGeometry(kind: .largeTruck))
        let bicycle = try #require(blockReferenceAdvancedModuleGeometry(kind: .bicycle))
        let motorcycle = try #require(blockReferenceAdvancedModuleGeometry(kind: .motorcycle))

        #expect(sedan.dimensions.depth / sedan.dimensions.width > 2)
        #expect(sedan.dimensions.height / sedan.dimensions.width > 0.7)
        #expect(sedan.dimensions.height / sedan.dimensions.width < 1)
        #expect(suv.dimensions.depth / suv.dimensions.width > 2)
        #expect(suv.dimensions.height > sedan.dimensions.height)
        #expect(smallTruck.dimensions.depth / smallTruck.dimensions.width > 2)
        #expect(smallTruck.dimensions.height > sedan.dimensions.height)
        #expect(largeTruck.dimensions.depth / largeTruck.dimensions.width > 2.5)
        #expect(largeTruck.dimensions.height > smallTruck.dimensions.height)
        #expect(bicycle.dimensions.width < 20)
        #expect(bicycle.dimensions.depth > bicycle.dimensions.height * 1.8)
        #expect(motorcycle.dimensions.depth > motorcycle.dimensions.width * 3)
        #expect(motorcycle.dimensions.height > motorcycle.dimensions.width * 1.5)
    }

    @Test
    func transportationWheelDimensionsMatchReferenceTireSpecifications() throws {
        struct WheelExpectation {
            let kind: BlockReferenceModuleKind
            let faceOffset: Int
            let outsideDiameter: Double
            let overallWidth: Double
        }

        let expectations: [WheelExpectation] = [
            .init(kind: .sedan, faceOffset: 18, outsideDiameter: 63.19, overallWidth: 20.5),
            .init(kind: .suv, faceOffset: 24, outsideDiameter: 72.43, overallWidth: 22.5),
            .init(kind: .smallTruck, faceOffset: 18, outsideDiameter: 77.19, overallWidth: 21.5),
            .init(kind: .largeTruck, faceOffset: 18, outsideDiameter: 42.2 * 2.54, overallWidth: 10.8 * 2.54),
            .init(kind: .bicycle, faceOffset: 24, outsideDiameter: 69.2, overallWidth: 3.5),
            .init(kind: .motorcycle, faceOffset: 24, outsideDiameter: 62.38, overallWidth: 16),
            .init(kind: .motorcycle, faceOffset: 56, outsideDiameter: 59.98, overallWidth: 12)
        ]

        for expectation in expectations {
            let geometry = try #require(blockReferenceAdvancedModuleGeometry(kind: expectation.kind))
            let wheelFaces = Array(geometry.faces[expectation.faceOffset..<(expectation.faceOffset + 32)])
            let bounds = blockReferenceTestBounds(wheelFaces)
            #expect(abs((bounds.maxX - bounds.minX) - expectation.overallWidth) < 0.000_001)
            #expect(abs((bounds.maxY - bounds.minY) - expectation.outsideDiameter) < 0.000_001)
            #expect(abs((bounds.maxZ - bounds.minZ) - expectation.outsideDiameter) < 0.000_001)
        }
    }

    @Test
    func architecturalModuleComponentsMeetAtTheirBoundariesWithoutCrossing() throws {
        let door = try #require(blockReferenceAdvancedModuleGeometry(kind: .doorFrame))
        #expect(door.faces.count == 18)
        let leftPost = blockReferenceTestBounds(Array(door.faces[0..<6]))
        let rightPost = blockReferenceTestBounds(Array(door.faces[6..<12]))
        let lintel = blockReferenceTestBounds(Array(door.faces[12..<18]))
        #expect(leftPost.maxZ == lintel.minZ)
        #expect(rightPost.maxZ == lintel.minZ)
        #expect(lintel.minX == leftPost.minX)
        #expect(lintel.maxX == rightPost.maxX)

        let table = try #require(blockReferenceAdvancedModuleGeometry(kind: .table))
        #expect(table.faces.count == 30)
        let tabletop = blockReferenceTestBounds(Array(table.faces[0..<6]))
        for start in stride(from: 6, to: 30, by: 6) {
            let leg = blockReferenceTestBounds(Array(table.faces[start..<(start + 6)]))
            #expect(leg.maxZ == tabletop.minZ)
            #expect(leg.minX >= tabletop.minX)
            #expect(leg.maxX <= tabletop.maxX)
            #expect(leg.minY >= tabletop.minY)
            #expect(leg.maxY <= tabletop.maxY)
        }

        let room = try #require(blockReferenceAdvancedModuleGeometry(kind: .roomBox))
        #expect(room.faces.count == 18)
        let floor = blockReferenceTestBounds(Array(room.faces[0..<6]))
        let backWall = blockReferenceTestBounds(Array(room.faces[6..<12]))
        let sideWall = blockReferenceTestBounds(Array(room.faces[12..<18]))
        #expect(floor.maxZ == backWall.minZ)
        #expect(floor.maxZ == sideWall.minZ)
        #expect(sideWall.maxY == backWall.minY)
        #expect(sideWall.minX == backWall.minX)

        let extremeParameters = BlockReferenceModuleParameters(
            count: 5,
            secondarySize: 1,
            thickness: 10_000
        )
        for kind in [
            BlockReferenceModuleKind.doorFrame,
            .roomBox,
            .table
        ] {
            let geometry = try #require(blockReferenceAdvancedModuleGeometry(
                kind: kind,
                parameters: extremeParameters
            ))
            let bounds = blockReferenceTestBounds(geometry.faces)
            #expect(bounds.minX >= -(geometry.dimensions.width * 0.5))
            #expect(bounds.maxX <= geometry.dimensions.width * 0.5)
            #expect(bounds.minY >= -(geometry.dimensions.depth * 0.5))
            #expect(bounds.maxY <= geometry.dimensions.depth * 0.5)
            #expect(bounds.minZ >= 0)
            #expect(bounds.maxZ <= geometry.dimensions.height)
        }
    }

    @Test
    func decodingAStoredParametricModuleRegeneratesItsDerivedMesh() throws {
        let staleMesh = BlockReferenceCustomMesh(
            faces: blockBoxFaces(dimensions: .init(width: 2, depth: 2, height: 2)),
            baseDimensions: .init(width: 2, depth: 2, height: 2)
        )
        let stored = BlockReferenceObject(
            name: "旧门框",
            kind: .box,
            position: .init(x: 40, y: 50, z: 60),
            rotation: .init(xDegrees: 10, yDegrees: 20, zDegrees: 30),
            dimensions: .init(width: 200, depth: 60, height: 440),
            customMesh: staleMesh,
            moduleKind: .doorFrame,
            moduleParameters: .default
        )

        let decoded = try JSONDecoder().decode(
            BlockReferenceObject.self,
            from: JSONEncoder().encode(stored)
        )
        let mesh = try #require(decoded.customMesh)
        let leftPost = blockReferenceTestBounds(Array(mesh.faces[0..<6]))
        let rightPost = blockReferenceTestBounds(Array(mesh.faces[6..<12]))
        let lintel = blockReferenceTestBounds(Array(mesh.faces[12..<18]))

        #expect(decoded.position == stored.position)
        #expect(decoded.rotation == stored.rotation)
        #expect(decoded.dimensions == stored.dimensions)
        #expect(mesh.baseDimensions == .init(width: 100, depth: 30, height: 220))
        #expect(leftPost.maxZ == lintel.minZ)
        #expect(rightPost.maxZ == lintel.minZ)
    }

    @Test
    func sectionPlaneClipsCrossingFacesWithoutProducingInvalidPolygons() {
        let face = [
            BlockVector3(x: -10, y: -10, z: -10),
            BlockVector3(x: 10, y: -10, z: -10),
            BlockVector3(x: 10, y: 10, z: 10),
            BlockVector3(x: -10, y: 10, z: 10)
        ]
        let clipped = blockReferenceClipFace(
            face,
            section: .init(isEnabled: true, plane: .ground, isInverted: false)
        )
        #expect(clipped.count >= 3)
        #expect(clipped.allSatisfy { $0.z >= -0.000_001 })
    }

    @Test
    func cameraAndThreePointGuideRoundTripWithinDrawingTolerance() throws {
        let canvasSize = CanvasSize(width: 1_600, height: 1_000)
        var camera = BlockReferenceCamera.stageOneDefault
        camera.yawDegrees = -38
        camera.pitchDegrees = 24
        camera.fieldOfViewDegrees = 48
        let x = try #require(blockReferenceVanishingPoint(direction: .unitX, camera: camera, canvasSize: canvasSize))
        let y = try #require(blockReferenceVanishingPoint(direction: .unitY, camera: camera, canvasSize: canvasSize))
        let z = try #require(blockReferenceVanishingPoint(direction: .unitZ, camera: camera, canvasSize: canvasSize))
        var guide = PerspectiveGuideState.initial(canvasSize: canvasSize)
        guide.leftVanishingPoint = x
        guide.rightVanishingPoint = y
        guide.verticalVanishingPoint = z
        let recovered = try #require(blockReferenceCameraMatchingPerspectiveGuide(
            guide,
            currentCamera: camera,
            canvasSize: canvasSize
        ))
        #expect(abs(recovered.yawDegrees - camera.yawDegrees) < 0.5)
        #expect(abs(recovered.pitchDegrees - camera.pitchDegrees) < 0.5)
        #expect(abs(recovered.fieldOfViewDegrees - camera.fieldOfViewDegrees) < 0.5)
    }

    @Test
    func offCenterRolledCameraAndThreePointGuideRoundTripExactly() throws {
        let canvasSize = CanvasSize(width: 1_600, height: 1_000)
        var camera = BlockReferenceCamera.stageOneDefault
        camera.yawDegrees = -41
        camera.pitchDegrees = 18
        camera.rollDegrees = 13
        camera.fieldOfViewDegrees = 54
        camera.principalPointNormalized = CanvasPoint(x: 0.47, y: 0.31)
        let x = try #require(blockReferenceVanishingPoint(
            direction: .unitX,
            camera: camera,
            canvasSize: canvasSize
        ))
        let y = try #require(blockReferenceVanishingPoint(
            direction: .unitY,
            camera: camera,
            canvasSize: canvasSize
        ))
        let z = try #require(blockReferenceVanishingPoint(
            direction: .unitZ,
            camera: camera,
            canvasSize: canvasSize
        ))
        var guide = PerspectiveGuideState.initial(canvasSize: canvasSize)
        let horizontal = [x, y].sorted { $0.x < $1.x }
        guide.leftVanishingPoint = horizontal[0]
        guide.rightVanishingPoint = horizontal[1]
        guide.verticalVanishingPoint = z

        let recovered = try #require(blockReferenceCameraMatchingPerspectiveGuide(
            guide,
            currentCamera: camera,
            canvasSize: canvasSize
        ))
        #expect(abs(recovered.yawDegrees - camera.yawDegrees) < 0.001)
        #expect(abs(recovered.pitchDegrees - camera.pitchDegrees) < 0.001)
        #expect(abs(recovered.rollDegrees - camera.rollDegrees) < 0.001)
        #expect(abs(recovered.fieldOfViewDegrees - camera.fieldOfViewDegrees) < 0.001)
        #expect(abs(recovered.principalPointNormalized.x - camera.principalPointNormalized.x) < 0.000_001)
        #expect(abs(recovered.principalPointNormalized.y - camera.principalPointNormalized.y) < 0.000_001)

        for direction in [BlockVector3.unitX, .unitY, .unitZ] {
            let expected = try #require(blockReferenceVanishingPoint(
                direction: direction,
                camera: camera,
                canvasSize: canvasSize
            ))
            let actual = try #require(blockReferenceVanishingPoint(
                direction: direction,
                camera: recovered,
                canvasSize: canvasSize
            ))
            #expect(hypot(actual.x - expected.x, actual.y - expected.y) < 0.001)
        }
    }

    @Test
    func legacyCameraDecodingDefaultsToCenteredPrincipalPointAndZeroRoll() throws {
        let encoded = try JSONEncoder().encode(BlockReferenceCamera.stageOneDefault)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "rollDegrees")
        object.removeValue(forKey: "principalPointNormalized")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BlockReferenceCamera.self, from: legacy)
        #expect(decoded.rollDegrees == 0)
        #expect(decoded.principalPointNormalized == CanvasPoint(x: 0.5, y: 0.5))
    }

    @Test
    func perspectiveMatchLinesRecoverVanishingPointsAndCamera() throws {
        let canvasSize = CanvasSize(width: 1_600, height: 1_000)
        var camera = BlockReferenceCamera.stageOneDefault
        camera.yawDegrees = -38
        camera.pitchDegrees = 24
        camera.fieldOfViewDegrees = 48

        func matchLine(
            axis: BlockReferenceAxis,
            start: CanvasPoint,
            vanishingPoint: CanvasPoint
        ) -> BlockReferencePerspectiveMatchLine {
            BlockReferencePerspectiveMatchLine(
                axis: axis,
                start: start,
                end: CanvasPoint(
                    x: start.x + (vanishingPoint.x - start.x) * 0.2,
                    y: start.y + (vanishingPoint.y - start.y) * 0.2
                )
            )
        }

        let vanishingPoints = try Dictionary(uniqueKeysWithValues: BlockReferenceAxis.allCases.map { axis in
            let point = try #require(blockReferenceVanishingPoint(
                direction: axis.unitVector,
                camera: camera,
                canvasSize: canvasSize
            ))
            return (axis, point)
        })
        var state = BlockReferencePerspectiveMatchState()
        for axis in BlockReferenceAxis.allCases {
            let point = try #require(vanishingPoints[axis])
            state.lines.append(matchLine(
                axis: axis,
                start: CanvasPoint(x: 260, y: 310 + Double(state.lines.count * 35)),
                vanishingPoint: point
            ))
            state.lines.append(matchLine(
                axis: axis,
                start: CanvasPoint(x: 1_120, y: 620 - Double(state.lines.count * 24)),
                vanishingPoint: point
            ))
            let recoveredPoint = try #require(state.vanishingPoint(for: axis))
            #expect(hypot(recoveredPoint.x - point.x, recoveredPoint.y - point.y) < 0.01)
        }

        let guide = try #require(blockReferencePerspectiveMatchGuide(
            state: state,
            canvasSize: canvasSize
        ))
        let recoveredCamera = try #require(blockReferenceCameraMatchingPerspectiveGuide(
            guide,
            currentCamera: camera,
            canvasSize: canvasSize
        ))
        #expect(abs(recoveredCamera.yawDegrees - camera.yawDegrees) < 0.5)
        #expect(abs(recoveredCamera.pitchDegrees - camera.pitchDegrees) < 0.5)
        #expect(abs(recoveredCamera.fieldOfViewDegrees - camera.fieldOfViewDegrees) < 0.5)
        #expect(guide.anchors.count == 6)
        let assessment = try #require(makeBlockReferencePerspectiveMatchAssessment(
            state: state,
            currentCamera: camera,
            canvasSize: canvasSize
        ))
        #expect(assessment.quality == .stable)
    }

    @Test
    func perspectiveMatchRejectsCoincidentParallelImageLines() {
        let lines = [
            BlockReferencePerspectiveMatchLine(
                axis: .x,
                start: CanvasPoint(x: 10, y: 10),
                end: CanvasPoint(x: 110, y: 10)
            ),
            BlockReferencePerspectiveMatchLine(
                axis: .x,
                start: CanvasPoint(x: 10, y: 40),
                end: CanvasPoint(x: 110, y: 40)
            )
        ]
        #expect(blockReferencePerspectiveMatchVanishingPoint(lines: lines) == nil)
    }

    @Test
    func perspectiveMatchLocatesTheTargetPlaneCenterFromXYEdgeFamilies() throws {
        let canvasSize = CanvasSize(width: 1_000, height: 800)
        let xLines = [
            BlockReferencePerspectiveMatchLine(
                axis: .x,
                start: .init(x: 180, y: 240),
                end: .init(x: 820, y: 320)
            ),
            BlockReferencePerspectiveMatchLine(
                axis: .x,
                start: .init(x: 260, y: 560),
                end: .init(x: 740, y: 500)
            )
        ]
        let yLines = [
            BlockReferencePerspectiveMatchLine(
                axis: .y,
                start: .init(x: 180, y: 240),
                end: .init(x: 260, y: 560)
            ),
            BlockReferencePerspectiveMatchLine(
                axis: .y,
                start: .init(x: 820, y: 320),
                end: .init(x: 740, y: 500)
            )
        ]
        let anchor = try #require(blockReferencePerspectiveMatchPlaneAnchor(
            xLines: xLines,
            yLines: yLines,
            canvasSize: canvasSize
        ))
        #expect(abs(anchor.x - 500) < 0.001)
        #expect(abs(anchor.y - 410) < 0.001)
    }

    @Test
    func cameraFramingPlacesAWorldPointExactlyAtTheRequestedCanvasAnchor() throws {
        let canvasSize = CanvasSize(width: 1_200, height: 800)
        var camera = BlockReferenceCamera.stageOneDefault
        camera.yawDegrees = -32
        camera.pitchDegrees = 26
        camera.fieldOfViewDegrees = 55
        let canvasAnchor = CanvasPoint(x: 790, y: 510)
        let worldAnchor = BlockVector3(x: 0, y: 0, z: 0)

        let anchored = blockReferenceCamera(
            anchoring: worldAnchor,
            at: canvasAnchor,
            camera: camera,
            canvasSize: canvasSize
        )
        let projected = try #require(projectBlockPoint(
            worldAnchor,
            camera: anchored,
            canvasSize: canvasSize
        ))
        #expect(hypot(
            projected.canvasPoint.x - canvasAnchor.x,
            projected.canvasPoint.y - canvasAnchor.y
        ) < 0.001)
        #expect(anchored.yawDegrees == camera.yawDegrees)
        #expect(anchored.pitchDegrees == camera.pitchDegrees)
        #expect(anchored.fieldOfViewDegrees == camera.fieldOfViewDegrees)
    }

    @Test
    func centerGizmoHandlePerformsUniformScale() throws {
        let layout = try #require(blockReferenceGizmoLayout(
            object: BlockReferenceObject(
                name: "方块",
                kind: .box,
                position: .init(x: 0, y: 0, z: 20),
                dimensions: .init(width: 40, depth: 50, height: 60)
            ),
            camera: .stageOneDefault,
            canvasSize: .init(width: 800, height: 600),
            screenScale: 1
        ))
        let handle = try #require(blockReferenceGizmoHitTest(
            point: layout.center,
            layout: layout,
            screenScale: 1
        ))
        #expect(handle.isUniformScale)
        let adjustment = BlockReferenceGizmoAdjustment(
            objectID: UUID(),
            handle: handle,
            input: "2",
            originalPosition: .zero,
            originalRotation: .zero
        )
        #expect(adjustment.numericTransform.axis == nil)
    }

    @Test
    func geometricMirrorReflectsVerticesInsteadOfOnlyDuplicatingTransform() throws {
        let source = BlockReferenceObject(
            name: "不对称体",
            kind: .box,
            position: .zero,
            dimensions: .init(width: 4, depth: 3, height: 2),
            customMesh: .init(
                faces: [[
                    .init(x: 0, y: 0, z: 0),
                    .init(x: 3, y: 0, z: 0),
                    .init(x: 1, y: 2, z: 1)
                ]],
                baseDimensions: .init(width: 4, depth: 3, height: 2)
            )
        )
        let mirrored = try #require(blockReferenceMirroredObject(
            source,
            pivot: .zero,
            normal: .unitX,
            name: "镜像"
        ))
        let originalX = blockObjectFaces(source).flatMap(\.vertices).map(\.x).sorted()
        let mirroredX = blockObjectFaces(mirrored).flatMap(\.vertices).map(\.x).sorted()
        #expect(mirrored.customMesh != nil)
        #expect(zip(originalX.reversed(), mirroredX).allSatisfy { abs(-$0.0 - $0.1) < 0.000_001 })
    }

    @Test
    func featureEdgesHideCoplanarBooleanSubdivisionButKeepOuterBoundary() {
        let id = UUID()
        let a = BlockVector3(x: 0, y: 0, z: 0)
        let b = BlockVector3(x: 10, y: 0, z: 0)
        let c = BlockVector3(x: 10, y: 10, z: 0)
        let d = BlockVector3(x: 0, y: 10, z: 0)
        let faces = [
            BlockMeshFace(objectID: id, faceIndex: 0, vertices: [a, b, c], normal: .unitZ),
            BlockMeshFace(objectID: id, faceIndex: 1, vertices: [a, c, d], normal: .unitZ)
        ]
        let mask = blockReferenceFeatureEdgeMask(faces: faces)
        #expect(mask[0] == [true, true, false])
        #expect(mask[1] == [false, true, true])
    }

    @Test
    func nearClippedPolygonDoesNotIndexOriginalFeatureMask() {
        let originalMask = [true, false, true, true]

        #expect(blockReferenceShouldRenderProjectedEdge(
            featureMask: originalMask,
            projectedEdgeIndex: 1,
            preservesOriginalTopology: true
        ) == false)
        #expect(blockReferenceShouldRenderProjectedEdge(
            featureMask: originalMask,
            projectedEdgeIndex: 4,
            preservesOriginalTopology: false
        ))
        #expect(blockReferenceShouldRenderProjectedEdge(
            featureMask: originalMask,
            projectedEdgeIndex: 4,
            preservesOriginalTopology: true
        ))
    }

    @Test
    func poseableHumanHasPelvisMultiAxisShouldersAndPosteriorKneeFlexion() throws {
        var pose = BlockHumanPose.standing
        pose.leftShoulderFlexionDegrees = 90
        pose.leftKneeDegrees = 90
        let rig = blockReferencePoseableHumanRig(pose: pose)
        let leftShoulder = try #require(rig.joints[.leftShoulder])
        let leftElbow = try #require(rig.joints[.leftElbow])
        #expect(leftElbow.y > leftShoulder.y + 20)
        #expect(rig.geometry.faces.flatMap { $0 }.map(\.y).min() ?? 0 < -35)
        #expect(rig.geometry.faces.contains { face in
            face.count == 4
                && face.allSatisfy { abs($0.z - 89.5) < 0.000_001 }
                && (face.map(\.x).max() ?? 0) >= 14.5
                && (face.map(\.x).min() ?? 0) <= -14.5
        })
    }

    @Test
    func humanJointAxisControlsRespectAnatomicalDegreesOfFreedom() {
        let shoulder = blockReferenceHumanPose(
            .standing,
            rotating: .rightShoulder,
            around: .y,
            by: 25
        )
        #expect(shoulder.rightShoulderDegrees == -19)

        let elbow = blockReferenceHumanPose(
            .standing,
            rotating: .leftElbow,
            around: .x,
            by: 40
        )
        #expect(elbow.leftElbowDegrees == 40)

        let knee = blockReferenceHumanPose(
            .standing,
            rotating: .leftKnee,
            around: .x,
            by: -55
        )
        #expect(knee.leftKneeDegrees == 55)
        #expect(BlockHumanJoint.leftKnee.rotationAxes == [.x])
        #expect(BlockHumanJoint.leftHip.rotationAxes == [.x, .y, .z])
        #expect(BlockHumanJoint.pelvis.rotationAxes == [.z])
    }

    @Test
    func poseableHumanUsesParentedJointFramesAndPelvisHorizontalRotation() throws {
        var pose = BlockHumanPose.standing
        pose.pelvisYawDegrees = 90
        pose.torsoYawDegrees = 25
        pose.leftShoulderFlexionDegrees = 40
        pose.leftShoulderTwistDegrees = 30
        let rig = blockReferencePoseableHumanRig(pose: pose)
        let hip = try #require(rig.joints[.leftHip])
        let shoulder = try #require(rig.joints[.leftShoulder])
        let elbowAxis = try #require(rig.jointAxes[.leftElbow]?[.x])

        #expect(abs(hip.x) < 0.000_001)
        #expect(hip.y < -10)
        #expect(abs(shoulder.y) > 10)
        #expect(elbowAxis.distance(to: .unitX) > 0.1)
        #expect(rig.jointAxes[.pelvis]?[.z] == .unitZ)
    }

    @Test
    func livePerspectiveLinesComeFromActualEdgesAndFollowCameraOrbit() throws {
        let canvasSize = CanvasSize(width: 800, height: 600)
        let object = BlockReferenceObject(
            name: "旋转方块",
            kind: .box,
            position: .init(x: 0, y: 0, z: 40),
            rotation: .init(xDegrees: 10, yDegrees: 20, zDegrees: 25),
            dimensions: .init(width: 120, depth: 90, height: 80)
        )
        let camera = BlockReferenceCamera.stageOneDefault
        let lines = blockReferencePerspectiveEdgeLines(
            object: object,
            camera: camera,
            canvasSize: canvasSize
        )
        #expect(Set(lines.map(\.axis)) == Set(BlockReferenceAxis.allCases))
        #expect(lines.allSatisfy {
            $0.edgeStart != $0.edgeEnd && $0.lineStart != $0.lineEnd
        })

        var orbited = camera
        orbited.yawDegrees += 24
        let changed = blockReferencePerspectiveEdgeLines(
            object: object,
            camera: orbited,
            canvasSize: canvasSize
        )
        #expect(changed != lines)
    }
}

private struct BlockReferenceTestBounds {
    var minX: Double
    var maxX: Double
    var minY: Double
    var maxY: Double
    var minZ: Double
    var maxZ: Double
}

private func blockReferenceTestBounds(_ faces: [[BlockVector3]]) -> BlockReferenceTestBounds {
    let vertices = faces.flatMap { $0 }
    return BlockReferenceTestBounds(
        minX: vertices.map(\.x).min() ?? 0,
        maxX: vertices.map(\.x).max() ?? 0,
        minY: vertices.map(\.y).min() ?? 0,
        maxY: vertices.map(\.y).max() ?? 0,
        minZ: vertices.map(\.z).min() ?? 0,
        maxZ: vertices.map(\.z).max() ?? 0
    )
}

private struct BlockReferenceTestEdge: Hashable {
    var first: BlockVector3
    var second: BlockVector3

    init(_ first: BlockVector3, _ second: BlockVector3) {
        if Self.isOrdered(first, before: second) {
            self.first = first
            self.second = second
        } else {
            self.first = second
            self.second = first
        }
    }

    private static func isOrdered(_ lhs: BlockVector3, before rhs: BlockVector3) -> Bool {
        if lhs.x != rhs.x { return lhs.x < rhs.x }
        if lhs.y != rhs.y { return lhs.y < rhs.y }
        return lhs.z < rhs.z
    }
}

private func blockReferenceTestEdgeUseCounts(
    _ faces: [[BlockVector3]]
) -> [BlockReferenceTestEdge: Int] {
    var counts: [BlockReferenceTestEdge: Int] = [:]
    for face in faces {
        for index in face.indices {
            let next = (index + 1) % face.count
            counts[BlockReferenceTestEdge(face[index], face[next]), default: 0] += 1
        }
    }
    return counts
}
