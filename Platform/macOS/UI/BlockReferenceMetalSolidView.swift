import AppKit
import MetalKit
import SwiftUI
import simd
@preconcurrency import Metal

struct BlockReferenceMetalSolidView: NSViewRepresentable {
    let scene: BlockReferenceScene
    let editorState: BlockReferenceEditorState
    let transform: CanvasViewportTransform
    let cameraRenderState: BlockReferenceCameraRenderState
    let rendersContinuously: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(cameraRenderState: cameraRenderState)
    }

    func makeNSView(context: Context) -> BlockReferenceTransparentMTKView {
        let view = BlockReferenceTransparentMTKView(frame: .zero, device: context.coordinator.device)
        view.colorPixelFormat = .bgra8Unorm_srgb
        view.depthStencilPixelFormat = .depth32Float
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.clearDepth = 1
        view.framebufferOnly = true
        view.autoResizeDrawable = true
        view.updatePreferredFramesPerSecond()
        view.enableSetNeedsDisplay = !rendersContinuously
        view.isPaused = !rendersContinuously
        view.wantsLayer = true
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.delegate = context.coordinator
        context.coordinator.update(scene: scene, editorState: editorState, transform: transform)
        return view
    }

    func updateNSView(_ view: BlockReferenceTransparentMTKView, context: Context) {
        context.coordinator.update(scene: scene, editorState: editorState, transform: transform)
        view.updatePreferredFramesPerSecond()
        view.enableSetNeedsDisplay = !rendersContinuously
        view.isPaused = !rendersContinuously
        if !rendersContinuously {
            view.setNeedsDisplay(view.bounds)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let renderer: BlockReferenceMetalSolidRenderer?
        private let cameraRenderState: BlockReferenceCameraRenderState
        private var scene: BlockReferenceScene?
        private var editorState: BlockReferenceEditorState?
        private var transform: CanvasViewportTransform?

        init(cameraRenderState: BlockReferenceCameraRenderState) {
            self.cameraRenderState = cameraRenderState
            let context = MetalDeviceContext()
            device = context?.device
            renderer = context.flatMap { try? BlockReferenceMetalSolidRenderer(context: $0) }
            super.init()
        }

        func update(
            scene: BlockReferenceScene,
            editorState: BlockReferenceEditorState,
            transform: CanvasViewportTransform
        ) {
            self.scene = scene
            self.editorState = editorState
            self.transform = transform
            cameraRenderState.rendererDidReceive(camera: scene.camera)
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            view.setNeedsDisplay(view.bounds)
        }

        func draw(in view: MTKView) {
            guard let renderer, var scene, let editorState, let transform else { return }
            if let liveCamera = cameraRenderState.camera {
                scene.camera = liveCamera
            }
            renderer.draw(
                scene: scene,
                editorState: editorState,
                transform: transform,
                in: view
            )
        }
    }
}

final class BlockReferenceTransparentMTKView: MTKView {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updatePreferredFramesPerSecond()
    }

    func updatePreferredFramesPerSecond() {
        preferredFramesPerSecond = blockReferencePreferredFramesPerSecond(
            maximumFramesPerSecond: window?.screen?.maximumFramesPerSecond
                ?? NSScreen.main?.maximumFramesPerSecond
        )
    }
}

func blockReferencePreferredFramesPerSecond(maximumFramesPerSecond: Int?) -> Int {
    min(max(maximumFramesPerSecond ?? 60, 30), 120)
}

private enum BlockReferenceMetalSolidRendererError: Error {
    case shaderLibrary(Error)
    case missingShaderFunction
    case facePipeline(Error)
    case edgePipeline(Error)
    case depthStencilState
}

private struct BlockReferenceSolidVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
}

private struct BlockReferenceProjectedSolidVertex {
    var screenPoint: SIMD2<Double>
    var depth: Double
    var normalizedDepth: Float
}

private struct BlockReferenceGridSegment {
    var start: BlockVector3
    var end: BlockVector3
    var color: SIMD4<Float>
    var lineWidth: Double
}

private struct BlockReferenceMetalGeometryCacheKey: Equatable {
    var objects: [BlockReferenceObject]
    var isFrozen: Bool
    var draft: BlockCreationDraft?
    var numericTransform: BlockReferenceNumericTransform?
}

private struct BlockReferenceMetalGeometrySource {
    var renderedFaces: [(face: BlockMeshFace, isDraft: Bool, style: BlockReferenceObjectStyle)]
    var featureMasks: [UUID: [Int: [Bool]]]
}

@MainActor
private final class BlockReferenceMetalSolidRenderer {
    private let context: MetalDeviceContext
    private let facePipeline: MTLRenderPipelineState
    private let edgePipeline: MTLRenderPipelineState
    private let faceDepthState: MTLDepthStencilState
    private let edgeDepthState: MTLDepthStencilState
    private var geometryCacheKey: BlockReferenceMetalGeometryCacheKey?
    private var geometrySource: BlockReferenceMetalGeometrySource?

    init(context: MetalDeviceContext) throws {
        self.context = context

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct BlockReferenceSolidVertex {
            float4 position;
            float4 color;
        };

        struct BlockReferenceSolidVarying {
            float4 position [[position]];
            float4 color;
        };

        vertex BlockReferenceSolidVarying blockReferenceSolidVertex(
            const device BlockReferenceSolidVertex *vertices [[buffer(0)]],
            uint vertexID [[vertex_id]]
        ) {
            BlockReferenceSolidVarying result;
            result.position = vertices[vertexID].position;
            result.color = vertices[vertexID].color;
            return result;
        }

        fragment float4 blockReferenceSolidFragment(BlockReferenceSolidVarying input [[stage_in]]) {
            return input.color;
        }
        """

        let library: MTLLibrary
        do {
            library = try context.device.makeLibrary(source: source, options: nil)
        } catch {
            throw BlockReferenceMetalSolidRendererError.shaderLibrary(error)
        }
        guard let vertexFunction = library.makeFunction(name: "blockReferenceSolidVertex"),
              let fragmentFunction = library.makeFunction(name: "blockReferenceSolidFragment") else {
            throw BlockReferenceMetalSolidRendererError.missingShaderFunction
        }

        let faceDescriptor = MTLRenderPipelineDescriptor()
        faceDescriptor.label = "Block Reference Solid Faces"
        faceDescriptor.vertexFunction = vertexFunction
        faceDescriptor.fragmentFunction = fragmentFunction
        faceDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        faceDescriptor.depthAttachmentPixelFormat = .depth32Float
        configureAlphaBlending(faceDescriptor.colorAttachments[0])
        do {
            facePipeline = try context.device.makeRenderPipelineState(descriptor: faceDescriptor)
        } catch {
            throw BlockReferenceMetalSolidRendererError.facePipeline(error)
        }

        let edgeDescriptor = MTLRenderPipelineDescriptor()
        edgeDescriptor.label = "Block Reference Solid Edges"
        edgeDescriptor.vertexFunction = vertexFunction
        edgeDescriptor.fragmentFunction = fragmentFunction
        edgeDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        edgeDescriptor.depthAttachmentPixelFormat = .depth32Float
        configureAlphaBlending(edgeDescriptor.colorAttachments[0])
        do {
            edgePipeline = try context.device.makeRenderPipelineState(descriptor: edgeDescriptor)
        } catch {
            throw BlockReferenceMetalSolidRendererError.edgePipeline(error)
        }

        let faceDepthDescriptor = MTLDepthStencilDescriptor()
        faceDepthDescriptor.label = "Block Reference Face Depth"
        faceDepthDescriptor.depthCompareFunction = .less
        faceDepthDescriptor.isDepthWriteEnabled = true

        let edgeDepthDescriptor = MTLDepthStencilDescriptor()
        edgeDepthDescriptor.label = "Block Reference Edge Depth"
        edgeDepthDescriptor.depthCompareFunction = .lessEqual
        edgeDepthDescriptor.isDepthWriteEnabled = false

        guard let faceDepthState = context.device.makeDepthStencilState(descriptor: faceDepthDescriptor),
              let edgeDepthState = context.device.makeDepthStencilState(descriptor: edgeDepthDescriptor) else {
            throw BlockReferenceMetalSolidRendererError.depthStencilState
        }
        self.faceDepthState = faceDepthState
        self.edgeDepthState = edgeDepthState
    }

    func draw(
        scene: BlockReferenceScene,
        editorState: BlockReferenceEditorState,
        transform: CanvasViewportTransform,
        in view: MTKView
    ) {
        guard let renderPass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              view.bounds.width > 0,
              view.bounds.height > 0 else { return }

        let geometry = makeGeometry(
            scene: scene,
            editorState: editorState,
            transform: transform,
            viewportSize: view.bounds.size
        )
        guard !geometry.faces.isEmpty || !geometry.edges.isEmpty else {
            clear(renderPass: renderPass, drawable: drawable)
            return
        }

        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        commandBuffer.label = "Block Reference Solid"
        encoder.label = "Block Reference Solid Depth Pass"
        encoder.setCullMode(.none)

        if !geometry.faces.isEmpty,
           let faceBuffer = context.device.makeBuffer(
               bytes: geometry.faces,
               length: geometry.faces.count * MemoryLayout<BlockReferenceSolidVertex>.stride,
               options: .storageModeShared
           ) {
            faceBuffer.label = "Block Reference Face Vertices"
            encoder.setRenderPipelineState(facePipeline)
            encoder.setDepthStencilState(faceDepthState)
            encoder.setVertexBuffer(faceBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.faces.count)
        }

        if !geometry.edges.isEmpty,
           let edgeBuffer = context.device.makeBuffer(
               bytes: geometry.edges,
               length: geometry.edges.count * MemoryLayout<BlockReferenceSolidVertex>.stride,
               options: .storageModeShared
           ) {
            edgeBuffer.label = "Block Reference Edge Vertices"
            encoder.setRenderPipelineState(edgePipeline)
            encoder.setDepthStencilState(edgeDepthState)
            encoder.setVertexBuffer(edgeBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: geometry.edges.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func clear(renderPass: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        guard let commandBuffer = context.commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeGeometry(
        scene: BlockReferenceScene,
        editorState: BlockReferenceEditorState,
        transform: CanvasViewportTransform,
        viewportSize: CGSize
    ) -> (faces: [BlockReferenceSolidVertex], edges: [BlockReferenceSolidVertex]) {
        let source = geometrySource(scene: scene, editorState: editorState)
        let renderedFaces = source.renderedFaces
        let featureMasks = source.featureMasks
        let gridSegments = scene.display.isFrozen
            ? []
            : makeGridSegments(scene: scene) + makeConstructionSegments(scene: scene)

        let cameraBasis = blockCameraBasis(scene.camera)
        let positiveDepths = (
            renderedFaces.flatMap { $0.face.vertices }
                + gridSegments.flatMap { [$0.start, $0.end] }
        )
            .map { ($0 - cameraBasis.position).dot(cameraBasis.forward) }
            .filter { $0 > 0.01 }
        guard let minimumDepth = positiveDepths.min(),
              let maximumDepth = positiveDepths.max() else { return ([], []) }
        let depthSpan = max(maximumDepth - minimumDepth, 1)
        let nearDepth = max(0.01, minimumDepth - depthSpan * 0.25)
        let farDepth = max(maximumDepth + depthSpan * 0.25, nearDepth + 1)
        let selectedIDs = blockReferenceExpandedSelectionIDs(
            in: scene,
            selection: editorState.resolvedSelectedObjectIDs
        )
        let accent = blockReferenceAccentColor()

        var faceVertices: [BlockReferenceSolidVertex] = []
        var edgeVertices: [BlockReferenceSolidVertex] = []
        for renderedFace in renderedFaces {
            let face = renderedFace.face
            let isDraft = renderedFace.isDraft
            let style = renderedFace.style
            let sectionClipped = blockReferenceClipFace(face.vertices, section: scene.section)
            let nearClipChangedTopology = sectionClipped.contains { vertex in
                (vertex - cameraBasis.position).dot(cameraBasis.forward) < nearDepth
            }
            let clipped = clip(
                polygon: sectionClipped,
                toNearDepth: nearDepth,
                cameraBasis: cameraBasis
            )
            guard clipped.count >= 3 else { continue }
            let projected = clipped.compactMap {
                project(
                    $0,
                    camera: scene.camera,
                    cameraBasis: cameraBasis,
                    nearDepth: nearDepth,
                    farDepth: farDepth,
                    transform: transform,
                    viewportSize: viewportSize
                )
            }
            guard projected.count == clipped.count else { continue }

            let isSelected = !scene.display.isFrozen && selectedIDs.contains(face.objectID)
            let isActive = isSelected && face.objectID == editorState.selectedObjectID
            let isSelectedFace = isActive && face.faceIndex == editorState.selectedFaceIndex
            if blockReferenceShouldRenderFaces(display: scene.display) {
                let faceColor = blockReferenceFaceColor(
                    normal: face.normal,
                    isDraft: isDraft,
                    isSelected: isSelected,
                    isActive: isActive,
                    isSelectedFace: isSelectedFace,
                    accent: accent,
                    style: style
                )
                for index in 1..<(projected.count - 1) {
                    faceVertices.append(solidVertex(projected[0], color: faceColor, viewportSize: viewportSize))
                    faceVertices.append(solidVertex(projected[index], color: faceColor, viewportSize: viewportSize))
                    faceVertices.append(solidVertex(projected[index + 1], color: faceColor, viewportSize: viewportSize))
                }
            }

            guard scene.display.showsEdges else { continue }
            let edgeColor = blockReferenceEdgeColor(
                isDraft: isDraft,
                isSelected: isSelected,
                isActive: isActive,
                accent: accent,
                style: style
            )
            let lineWidth: Double = isActive || isDraft ? 1.9 : (isSelected ? 1.5 : 1)
            let featureMask = featureMasks[face.objectID]?[face.faceIndex]
            let preservesOriginalEdgeTopology = !scene.section.isEnabled && !nearClipChangedTopology
            for index in projected.indices {
                if !blockReferenceShouldRenderProjectedEdge(
                    featureMask: featureMask,
                    projectedEdgeIndex: index,
                    preservesOriginalTopology: preservesOriginalEdgeTopology
                ) {
                    continue
                }
                appendEdgeQuad(
                    from: projected[index],
                    to: projected[(index + 1) % projected.count],
                    lineWidth: lineWidth,
                    color: edgeColor,
                    viewportSize: viewportSize,
                    to: &edgeVertices
                )
            }
        }

        for segment in gridSegments {
            guard let clipped = clip(
                segment: (segment.start, segment.end),
                toNearDepth: nearDepth,
                cameraBasis: cameraBasis
            ),
            let start = project(
                clipped.0,
                camera: scene.camera,
                cameraBasis: cameraBasis,
                nearDepth: nearDepth,
                farDepth: farDepth,
                transform: transform,
                viewportSize: viewportSize
            ),
            let end = project(
                clipped.1,
                camera: scene.camera,
                cameraBasis: cameraBasis,
                nearDepth: nearDepth,
                farDepth: farDepth,
                transform: transform,
                viewportSize: viewportSize
            ) else { continue }
            appendEdgeQuad(
                from: start,
                to: end,
                lineWidth: segment.lineWidth,
                color: segment.color,
                viewportSize: viewportSize,
                to: &edgeVertices
            )
        }
        return (faceVertices, edgeVertices)
    }

    private func geometrySource(
        scene: BlockReferenceScene,
        editorState: BlockReferenceEditorState
    ) -> BlockReferenceMetalGeometrySource {
        let key = BlockReferenceMetalGeometryCacheKey(
            objects: scene.objects,
            isFrozen: scene.display.isFrozen,
            draft: editorState.draft,
            numericTransform: editorState.numericTransform
        )
        if key == geometryCacheKey, let geometrySource {
            return geometrySource
        }

        var objects = scene.objects.filter {
            $0.isVisible && (!scene.display.isFrozen || $0.style.includedInFrozenReference)
        }.map { object in
            (editorState.numericTransform?.applying(to: object) ?? object, false)
        }
        if let draft = editorState.draft {
            objects.append((BlockReferenceObject(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "草稿",
                kind: draft.kind,
                position: draft.center,
                rotation: blockRotation(alignedTo: draft.plane),
                dimensions: draft.dimensions
            ), true))
        }

        let renderedFaces = objects.flatMap { object, isDraft in
            blockObjectFaces(object).map { ($0, isDraft, object.style) }
        }
        let facesByObjectID = Dictionary(grouping: renderedFaces, by: { $0.0.objectID })
        let featureMasks = Dictionary(uniqueKeysWithValues: objects.map { object, _ in
            let faces = facesByObjectID[object.id]?.map(\.0) ?? []
            return (object.id, blockReferenceFeatureEdgeMask(faces: faces))
        })
        let source = BlockReferenceMetalGeometrySource(
            renderedFaces: renderedFaces.map { (face: $0.0, isDraft: $0.1, style: $0.2) },
            featureMasks: featureMasks
        )
        geometryCacheKey = key
        geometrySource = source
        return source
    }

    private func makeGridSegments(scene: BlockReferenceScene) -> [BlockReferenceGridSegment] {
        let spacing = max(scene.snap.gridSpacing, 1)
        let lineCount = 10
        return (-lineCount...lineCount).flatMap { index -> [BlockReferenceGridSegment] in
            let offset = Double(index) * spacing
            let extent = Double(lineCount) * spacing
            let isAxis = index == 0
            let isMajor = !isAxis && index.isMultiple(of: 5)
            let gridColor: SIMD4<Float> = isMajor
                ? SIMD4(0.28, 0.28, 0.28, 0.64)
                : SIMD4(0.28, 0.28, 0.28, 0.46)
            let gridLineWidth = isMajor ? 1.05 : 0.85
            return [
                BlockReferenceGridSegment(
                    start: scene.workingPlane.worldPoint(u: -extent, v: offset),
                    end: scene.workingPlane.worldPoint(u: extent, v: offset),
                    color: isAxis
                        ? SIMD4(0.88, 0.13, 0.1, 0.9)
                        : gridColor,
                    lineWidth: isAxis ? 1.4 : gridLineWidth
                ),
                BlockReferenceGridSegment(
                    start: scene.workingPlane.worldPoint(u: offset, v: -extent),
                    end: scene.workingPlane.worldPoint(u: offset, v: extent),
                    color: isAxis
                        ? SIMD4(0.08, 0.68, 0.24, 0.9)
                        : gridColor,
                    lineWidth: isAxis ? 1.4 : gridLineWidth
                )
            ]
        }
    }

    private func makeConstructionSegments(scene: BlockReferenceScene) -> [BlockReferenceGridSegment] {
        let extent = max(scene.camera.distance * 3, 1_000)
        return scene.constructionLines.filter(\.isVisible).map { line in
            BlockReferenceGridSegment(
                start: line.origin - line.direction * extent,
                end: line.origin + line.direction * extent,
                color: SIMD4(0.12, 0.48, 0.95, 0.82),
                lineWidth: 1.2
            )
        }
    }

    private func project(
        _ point: BlockVector3,
        camera: BlockReferenceCamera,
        cameraBasis: BlockCameraBasis,
        nearDepth: Double,
        farDepth: Double,
        transform: CanvasViewportTransform,
        viewportSize: CGSize
    ) -> BlockReferenceProjectedSolidVertex? {
        let relative = point - cameraBasis.position
        let depth = relative.dot(cameraBasis.forward)
        guard depth >= nearDepth, farDepth > nearDepth else { return nil }
        let width = Double(max(transform.canvasSize.width, 1))
        let height = Double(max(transform.canvasSize.height, 1))
        let aspect = width / height
        let fovScale = tan(camera.fieldOfViewDegrees * .pi / 360)
        let ndcX: Double
        let ndcY: Double
        if camera.isOrthographic {
            let verticalSpan = max(camera.distance * fovScale, 1)
            ndcX = relative.dot(cameraBasis.right) / (verticalSpan * aspect)
            ndcY = relative.dot(cameraBasis.up) / verticalSpan
        } else {
            ndcX = relative.dot(cameraBasis.right) / (depth * fovScale * aspect)
            ndcY = relative.dot(cameraBasis.up) / (depth * fovScale)
        }
        guard let normalizedDepth = blockReferenceMetalNormalizedDepth(
            cameraDepth: depth,
            nearDepth: nearDepth,
            farDepth: farDepth,
            isOrthographic: camera.isOrthographic
        ) else { return nil }
        let canvasPoint = CanvasPoint(
            x: (camera.principalPointNormalized.x + ndcX * 0.5) * width,
            y: (camera.principalPointNormalized.y - ndcY * 0.5) * height
        )
        let viewportPoint = transform.canvasToViewport(canvasPoint)
        guard viewportPoint.x.isFinite,
              viewportPoint.y.isFinite,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return nil }
        return BlockReferenceProjectedSolidVertex(
            screenPoint: SIMD2(viewportPoint.x, viewportPoint.y),
            depth: depth,
            normalizedDepth: normalizedDepth
        )
    }

    private func clip(
        polygon: [BlockVector3],
        toNearDepth nearDepth: Double,
        cameraBasis: BlockCameraBasis
    ) -> [BlockVector3] {
        guard let last = polygon.last else { return [] }
        var result: [BlockVector3] = []
        var previous = last
        var previousDepth = (previous - cameraBasis.position).dot(cameraBasis.forward)
        var previousIsInside = previousDepth >= nearDepth

        for current in polygon {
            let currentDepth = (current - cameraBasis.position).dot(cameraBasis.forward)
            let currentIsInside = currentDepth >= nearDepth
            if currentIsInside != previousIsInside {
                let denominator = currentDepth - previousDepth
                if abs(denominator) > 0.000_000_1 {
                    let amount = (nearDepth - previousDepth) / denominator
                    result.append(previous + (current - previous) * amount)
                }
            }
            if currentIsInside {
                result.append(current)
            }
            previous = current
            previousDepth = currentDepth
            previousIsInside = currentIsInside
        }
        return result
    }

    private func clip(
        segment: (BlockVector3, BlockVector3),
        toNearDepth nearDepth: Double,
        cameraBasis: BlockCameraBasis
    ) -> (BlockVector3, BlockVector3)? {
        var start = segment.0
        var end = segment.1
        let startDepth = (start - cameraBasis.position).dot(cameraBasis.forward)
        let endDepth = (end - cameraBasis.position).dot(cameraBasis.forward)
        guard startDepth >= nearDepth || endDepth >= nearDepth else { return nil }
        if startDepth < nearDepth {
            let amount = (nearDepth - startDepth) / (endDepth - startDepth)
            start = start + (end - start) * amount
        } else if endDepth < nearDepth {
            let amount = (nearDepth - endDepth) / (startDepth - endDepth)
            end = end + (start - end) * amount
        }
        return (start, end)
    }

    private func solidVertex(
        _ projected: BlockReferenceProjectedSolidVertex,
        color: SIMD4<Float>,
        viewportSize: CGSize,
        depthBias: Float = 0
    ) -> BlockReferenceSolidVertex {
        let clipX = Float(projected.screenPoint.x / Double(viewportSize.width) * 2 - 1)
        let clipY = Float(1 - projected.screenPoint.y / Double(viewportSize.height) * 2)
        return BlockReferenceSolidVertex(
            position: SIMD4(clipX, clipY, max(projected.normalizedDepth - depthBias, 0), 1),
            color: color
        )
    }

    private func appendEdgeQuad(
        from start: BlockReferenceProjectedSolidVertex,
        to end: BlockReferenceProjectedSolidVertex,
        lineWidth: Double,
        color: SIMD4<Float>,
        viewportSize: CGSize,
        to vertices: inout [BlockReferenceSolidVertex]
    ) {
        let delta = end.screenPoint - start.screenPoint
        let length = simd_length(delta)
        guard length > 0.000_1 else { return }
        let perpendicular = SIMD2(-delta.y, delta.x) / length * (lineWidth * 0.5)
        let startPositive = BlockReferenceProjectedSolidVertex(
            screenPoint: start.screenPoint + perpendicular,
            depth: start.depth,
            normalizedDepth: start.normalizedDepth
        )
        let startNegative = BlockReferenceProjectedSolidVertex(
            screenPoint: start.screenPoint - perpendicular,
            depth: start.depth,
            normalizedDepth: start.normalizedDepth
        )
        let endPositive = BlockReferenceProjectedSolidVertex(
            screenPoint: end.screenPoint + perpendicular,
            depth: end.depth,
            normalizedDepth: end.normalizedDepth
        )
        let endNegative = BlockReferenceProjectedSolidVertex(
            screenPoint: end.screenPoint - perpendicular,
            depth: end.depth,
            normalizedDepth: end.normalizedDepth
        )
        let depthBias: Float = 0.000_01
        vertices.append(solidVertex(startPositive, color: color, viewportSize: viewportSize, depthBias: depthBias))
        vertices.append(solidVertex(startNegative, color: color, viewportSize: viewportSize, depthBias: depthBias))
        vertices.append(solidVertex(endPositive, color: color, viewportSize: viewportSize, depthBias: depthBias))
        vertices.append(solidVertex(endPositive, color: color, viewportSize: viewportSize, depthBias: depthBias))
        vertices.append(solidVertex(startNegative, color: color, viewportSize: viewportSize, depthBias: depthBias))
        vertices.append(solidVertex(endNegative, color: color, viewportSize: viewportSize, depthBias: depthBias))
    }
}

func blockReferenceShouldRenderFaces(display: BlockReferenceDisplaySettings) -> Bool {
    display.mode == .solid && display.showsFaces
}

func blockReferenceShouldRenderProjectedEdge(
    featureMask: [Bool]?,
    projectedEdgeIndex: Int,
    preservesOriginalTopology: Bool
) -> Bool {
    guard preservesOriginalTopology,
          let featureMask,
          featureMask.indices.contains(projectedEdgeIndex) else {
        return true
    }
    return featureMask[projectedEdgeIndex]
}

private func configureAlphaBlending(_ attachment: MTLRenderPipelineColorAttachmentDescriptor?) {
    guard let attachment else { return }
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add
    attachment.sourceRGBBlendFactor = .sourceAlpha
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
}

func blockReferenceMetalNormalizedDepth(
    cameraDepth: Double,
    nearDepth: Double,
    farDepth: Double,
    isOrthographic: Bool
) -> Float? {
    guard cameraDepth.isFinite,
          nearDepth.isFinite,
          farDepth.isFinite,
          nearDepth > 0,
          farDepth > nearDepth,
          cameraDepth >= nearDepth else { return nil }
    let normalized: Double
    if isOrthographic {
        normalized = (cameraDepth - nearDepth) / (farDepth - nearDepth)
    } else {
        normalized = farDepth / (farDepth - nearDepth)
            - (farDepth * nearDepth) / ((farDepth - nearDepth) * cameraDepth)
    }
    guard normalized.isFinite else { return nil }
    return Float(min(max(normalized, 0), 1))
}

private func blockReferenceAccentColor() -> SIMD4<Float> {
    guard let accent = NSColor.controlAccentColor.usingColorSpace(.deviceRGB) else {
        return SIMD4(0.16, 0.5, 1, 1)
    }
    return SIMD4(
        Float(accent.redComponent),
        Float(accent.greenComponent),
        Float(accent.blueComponent),
        1
    )
}

private func blockReferenceFaceColor(
    normal: BlockVector3,
    isDraft: Bool,
    isSelected: Bool,
    isActive: Bool,
    isSelectedFace: Bool,
    accent: SIMD4<Float>,
    style: BlockReferenceObjectStyle
) -> SIMD4<Float> {
    let light = BlockVector3(x: -0.35, y: -0.55, z: 1).normalized()
    let lightAmount = Float(min(max(normal.dot(light) * 0.5 + 0.5, 0.18), 1))
    if isDraft {
        return SIMD4(0.24, 0.82, 0.9, 0.62)
    }
    if isSelectedFace {
        return SIMD4(accent.x, accent.y, accent.z, style.opacity)
    }
    if isActive {
        return SIMD4(
            0.2 + lightAmount * 0.12,
            0.48 + lightAmount * 0.2,
            0.74 + lightAmount * 0.22,
            style.opacity
        )
    }
    if isSelected {
        return SIMD4(
            0.18 + lightAmount * 0.12,
            0.62 + lightAmount * 0.18,
            0.68 + lightAmount * 0.2,
            style.opacity
        )
    }
    let base = blockReferenceObjectBaseColor(style.colorTag)
    let shade = 0.58 + lightAmount * 0.42
    return SIMD4(base.x * shade, base.y * shade, base.z * shade, style.opacity)
}

private func blockReferenceEdgeColor(
    isDraft: Bool,
    isSelected: Bool,
    isActive: Bool,
    accent: SIMD4<Float>,
    style: BlockReferenceObjectStyle
) -> SIMD4<Float> {
    if isDraft {
        return SIMD4(0, 1, 1, 0.95)
    }
    if isActive {
        return SIMD4(accent.x, accent.y, accent.z, 0.98)
    }
    if isSelected {
        return SIMD4(0, 1, 1, 0.88)
    }
    return SIMD4(0, 0, 0, 0.72 * style.opacity)
}

private func blockReferenceObjectBaseColor(_ tag: BlockReferenceColorTag) -> SIMD3<Float> {
    switch tag {
    case .neutral: return SIMD3(0.82, 0.82, 0.82)
    case .red: return SIMD3(0.92, 0.42, 0.4)
    case .orange: return SIMD3(0.94, 0.6, 0.3)
    case .yellow: return SIMD3(0.9, 0.78, 0.28)
    case .green: return SIMD3(0.38, 0.76, 0.45)
    case .blue: return SIMD3(0.34, 0.62, 0.92)
    case .purple: return SIMD3(0.68, 0.48, 0.88)
    }
}
