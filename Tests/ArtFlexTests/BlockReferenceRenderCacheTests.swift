import Foundation
import Testing
@testable import ArtFlex

@MainActor
struct BlockReferenceRenderCacheTests {
    @Test func unchangedFramesAndSingleObjectChangesAvoidUnrelatedGeometryWork() throws {
        let metal = try #require(MetalDeviceContext())
        let renderer = try BlockReferenceMetalSolidRenderer(context: metal)
        var scene = BlockReferenceScene.empty
        scene.objects = (0..<20).map { index -> BlockReferenceObject in
            let kind: BlockPrimitiveKind = index % 3 == 0 ? .cylinder : .box
            let position = BlockVector3(x: Double(index % 5) * 130, y: Double(index / 5) * 140, z: 0)
            return BlockReferenceObject(name: "Object \(index)", kind: kind,
                position: position, dimensions: .stageOneDefault)
        }
        let transform = CanvasViewportTransform(canvasSize: .init(width: 800, height: 600), viewport: .stageOneDefault,
            availableWidth: 800, availableHeight: 600)
        func render() -> (Data, Data) {
            renderer.debugGeometryBytes(scene: scene, transform: transform, viewportSize: CGSize(width: 800, height: 600))
        }
        let original = render()
        #expect(!original.0.isEmpty)
        #expect(renderer.cacheStatistics.objectGeometryBuilds == 20)
        let builds = renderer.cacheStatistics.objectProjectionBuilds
        let repeated = render()
        #expect(original.0 == repeated.0 && original.1 == repeated.1)
        #expect(renderer.cacheStatistics.objectProjectionBuilds == builds)
        #expect(renderer.cacheStatistics.frameProjectionHits == 1)
        scene.objects[0].position.x += 10
        _ = render()
        #expect(renderer.cacheStatistics.objectGeometryBuilds == 21)
        scene.camera.yawDegrees += 3
        _ = render()
        #expect(renderer.cacheStatistics.objectGeometryBuilds == 21)
        scene.objects[0].name = "Rename is not geometry"
        _ = render()
        #expect(renderer.cacheStatistics.objectGeometryBuilds == 21)
        scene.objects.removeLast()
        _ = render()
        #expect(renderer.cacheStatistics.objectGeometryBuilds == 21)
    }

    @Test func cachedGeometryMatchesUncachedForProjectionSectionStyleSelectionAndDrafts() throws {
        let metal = try #require(MetalDeviceContext())
        let cached = try BlockReferenceMetalSolidRenderer(context: metal)
        let reference = try BlockReferenceMetalSolidRenderer(context: metal)
        reference.debugDisablesRenderCaches = true
        var scene = BlockReferenceScene.empty
        scene.objects = [
            .init(name: "Box", kind: .box, position: .zero, dimensions: .stageOneDefault),
            .init(name: "Sphere", kind: .sphere, position: .init(x: 110, y: 50, z: 20), dimensions: .stageOneDefault)
        ]
        var editor = BlockReferenceEditorState()
        var selected: Set<UUID> = []
        var viewport = CanvasViewport.stageOneDefault
        for step in 0..<12 {
            switch step {
            case 1: scene.camera.yawDegrees += 15
            case 2: scene.camera.isOrthographic = true
            case 3:
                scene.section.isEnabled = true
                scene.section.plane.origin.z = 50
            case 4: scene.section.isInverted = true
            case 5:
                selected = [scene.objects[0].id]
                editor.selectedObjectID = scene.objects[0].id
                editor.selectedFaceIndex = 1
            case 6:
                scene.objects[0].style.colorTag = .red
                scene.objects[0].style.opacity = 0.6
            case 7:
                scene.display.showsFaces = false
                scene.display.mode = .wireframe
            case 8:
                scene.display.isFrozen = true
                scene.objects[1].style.includedInFrozenReference = false
            case 9:
                scene.display.isFrozen = false
                editor.draft = .init(kind: .cone, plane: .ground, baseStart: .zero,
                    baseEnd: .init(x: 90, y: 100, z: 0), height: 160)
            case 10:
                editor.placementObjects = [.init(name: "Placement", kind: .box,
                    position: .init(x: -100, y: 80, z: 0), dimensions: .stageOneDefault)]
            case 11:
                viewport.rotationDegrees = 27
                viewport.isHorizontallyFlipped = true
            default: break
            }
            let transform = CanvasViewportTransform(canvasSize: .init(width: 800, height: 600), viewport: viewport,
                availableWidth: 800, availableHeight: 600)
            let a = cached.debugGeometryBytes(scene: scene, editorState: editor, selectedObjectIDs: selected,
                transform: transform, viewportSize: CGSize(width: 800, height: 600))
            let b = reference.debugGeometryBytes(scene: scene, editorState: editor, selectedObjectIDs: selected,
                transform: transform, viewportSize: CGSize(width: 800, height: 600))
            #expect(a.0 == b.0 && a.1 == b.1, "Projection cache mismatch at step \(step)")
            let repeated = cached.debugGeometryBytes(scene: scene, editorState: editor, selectedObjectIDs: selected,
                transform: transform, viewportSize: CGSize(width: 800, height: 600))
            #expect(a.0 == repeated.0 && a.1 == repeated.1)
        }
    }
}
