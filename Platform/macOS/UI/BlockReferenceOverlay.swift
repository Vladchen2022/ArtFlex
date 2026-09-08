import AppKit
import SwiftUI

struct BlockReferenceOverlay: View {
    let scene: BlockReferenceScene
    let editorState: BlockReferenceEditorState
    let transform: CanvasViewportTransform
    let cameraRenderState: BlockReferenceCameraRenderState
    let rendersContinuously: Bool

    var body: some View {
        ZStack {
            BlockReferenceMetalSolidView(
                scene: scene,
                editorState: editorState,
                transform: transform,
                cameraRenderState: cameraRenderState,
                rendersContinuously: rendersContinuously
            )
            .opacity(Double(scene.display.effectiveOpacity))

            if scene.display.showsPerspectiveGuides {
                TimelineView(.animation(
                    minimumInterval: 1.0 / 120.0,
                    paused: !rendersContinuously
                )) { _ in
                    Canvas { context, _ in
                        var renderScene = scene
                        if let liveCamera = cameraRenderState.camera {
                            renderScene.camera = liveCamera
                        }
                        drawLivePerspectiveEdges(in: context, scene: renderScene)
                    }
                }
            }

            if !rendersContinuously {
                Canvas { context, _ in
                    drawDraftBaseFootprint(in: context)
                    drawHumanJointHandles(in: context)
                    drawTransformGizmo(in: context)
                    drawModuleBasePointMarker(in: context)
                    drawMeasurements(in: context)
                    drawInteractionHints(in: context)
                    drawWorkingPlaneIndicator(in: context)
                }
            }
        }
    }

    private func drawLivePerspectiveEdges(
        in context: GraphicsContext,
        scene: BlockReferenceScene
    ) {
        guard !scene.display.isFrozen,
              let object = editorState.selectedObjectID.flatMap({ selectedID in
                  scene.objects.first(where: { $0.id == selectedID && $0.isVisible })
              }) ?? scene.objects.last(where: { $0.isVisible }) else { return }
        let lines = blockReferencePerspectiveEdgeLines(
            object: object,
            camera: scene.camera,
            canvasSize: transform.canvasSize,
            maximumLinesPerAxis: 2
        )
        for line in lines {
            let extensionStart = transform.canvasToViewport(line.lineStart)
            let extensionEnd = transform.canvasToViewport(line.lineEnd)
            let edgeStart = transform.canvasToViewport(line.edgeStart)
            let edgeEnd = transform.canvasToViewport(line.edgeEnd)
            let color = gizmoColor(line.axis)
            var extensionPath = Path()
            extensionPath.move(to: CGPoint(x: extensionStart.x, y: extensionStart.y))
            extensionPath.addLine(to: CGPoint(x: extensionEnd.x, y: extensionEnd.y))
            context.stroke(
                extensionPath,
                with: .color(color.opacity(0.42)),
                style: StrokeStyle(lineWidth: 1.15, dash: [7, 5])
            )
            var edgePath = Path()
            edgePath.move(to: CGPoint(x: edgeStart.x, y: edgeStart.y))
            edgePath.addLine(to: CGPoint(x: edgeEnd.x, y: edgeEnd.y))
            context.stroke(
                edgePath,
                with: .color(color.opacity(0.98)),
                style: StrokeStyle(lineWidth: 2.8, lineCap: .round)
            )
        }
    }

    private func drawWorkingPlane(in context: GraphicsContext, scene: BlockReferenceScene) {
        guard !scene.display.isFrozen else { return }
        let opacity = Double(scene.display.opacity)
        let spacing = max(scene.snap.gridSpacing, 1)
        let lineCount = 10
        for index in -lineCount...lineCount {
            let offset = Double(index) * spacing
            let isAxis = index == 0
            let isMajor = !isAxis && index.isMultiple(of: 5)
            let gridOpacity = isMajor ? 0.64 : 0.46
            let gridLineWidth = isMajor ? 1.05 : 0.85
            let uStart = scene.workingPlane.worldPoint(u: -Double(lineCount) * spacing, v: offset)
            let uEnd = scene.workingPlane.worldPoint(u: Double(lineCount) * spacing, v: offset)
            let vStart = scene.workingPlane.worldPoint(u: offset, v: -Double(lineCount) * spacing)
            let vEnd = scene.workingPlane.worldPoint(u: offset, v: Double(lineCount) * spacing)
            drawWorldLine(
                from: uStart,
                to: uEnd,
                in: context,
                color: isAxis
                    ? Color(red: 0.88, green: 0.13, blue: 0.1).opacity(0.9 * opacity)
                    : Color(white: 0.28).opacity(gridOpacity * opacity),
                lineWidth: isAxis ? 1.4 : gridLineWidth
            )
            drawWorldLine(
                from: vStart,
                to: vEnd,
                in: context,
                color: isAxis
                    ? Color(red: 0.08, green: 0.68, blue: 0.24).opacity(0.9 * opacity)
                    : Color(white: 0.28).opacity(gridOpacity * opacity),
                lineWidth: isAxis ? 1.4 : gridLineWidth
            )
        }
    }

    private func drawWireframeObjects(in context: GraphicsContext, scene: BlockReferenceScene) {
        var objects = scene.objects.filter(\.isVisible).map { object in
            let displayed = editorState.numericTransform?.applying(to: object) ?? object
            return (displayed, false)
        }
        if let draft = editorState.draft {
            let preview = BlockReferenceObject(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "草稿",
                kind: draft.kind,
                position: draft.center,
                rotation: blockRotation(alignedTo: draft.plane),
                dimensions: draft.dimensions
            )
            objects.append((preview, true))
        }

        struct RenderFace {
            var face: BlockMeshFace
            var points: [CanvasPoint]
            var depth: Double
            var isDraft: Bool
            var edgeMask: [Bool]
        }

        var renderFaces: [RenderFace] = []
        for (object, isDraft) in objects {
            let faces = blockObjectFaces(object)
            let featureMask = blockReferenceFeatureEdgeMask(faces: faces)
            for face in faces {
                let projected = face.vertices.compactMap {
                    projectBlockPoint(
                        $0,
                        camera: scene.camera,
                        canvasSize: transform.canvasSize
                    )
                }
                guard projected.count == face.vertices.count else { continue }
                renderFaces.append(RenderFace(
                    face: face,
                    points: projected.map { transform.canvasToViewport($0.canvasPoint) },
                    depth: projected.map(\.cameraDepth).reduce(0, +) / Double(projected.count),
                    isDraft: isDraft,
                    edgeMask: featureMask[face.faceIndex]
                        ?? Array(repeating: true, count: face.vertices.count)
                ))
            }
        }
        renderFaces.sort { $0.depth > $1.depth }

        let light = BlockVector3(x: -0.35, y: -0.55, z: 1).normalized()
        let opacity = Double(scene.display.opacity)
        let selectedIDs = blockReferenceExpandedSelectionIDs(
            in: scene,
            selection: editorState.resolvedSelectedObjectIDs
        )
        for renderFace in renderFaces {
            let path = polygonPath(renderFace.points)
            let isSelected = !scene.display.isFrozen
                && selectedIDs.contains(renderFace.face.objectID)
            let isActive = isSelected
                && renderFace.face.objectID == editorState.selectedObjectID
            let isSelectedFace = isActive
                && renderFace.face.faceIndex == editorState.selectedFaceIndex
            let lightAmount = min(
                max(renderFace.face.normal.dot(light) * 0.5 + 0.5, 0.18),
                1
            )
            if scene.display.showsFaces {
                let fill: Color
                if renderFace.isDraft {
                    fill = Color.cyan.opacity(0.22 * opacity)
                } else if isSelectedFace {
                    fill = Color.accentColor.opacity(0.48 * opacity)
                } else if isActive {
                    fill = Color(red: 0.3, green: 0.65, blue: 1)
                        .opacity((0.23 + lightAmount * 0.25) * opacity)
                } else if isSelected {
                    fill = Color.cyan.opacity((0.16 + lightAmount * 0.2) * opacity)
                } else {
                    fill = Color(white: 0.35 + lightAmount * 0.38)
                        .opacity((0.18 + lightAmount * 0.24) * opacity)
                }
                context.fill(path, with: .color(fill))
            }
            if scene.display.showsEdges {
                let edgeColor = renderFace.isDraft
                    ? Color.cyan.opacity(0.95 * opacity)
                    : (isActive
                        ? Color.accentColor.opacity(0.98 * opacity)
                        : (isSelected
                            ? Color.cyan.opacity(0.88 * opacity)
                            : Color.black.opacity(0.72 * opacity)))
                let style = StrokeStyle(
                    lineWidth: isActive || renderFace.isDraft ? 1.9 : (isSelected ? 1.5 : 1),
                    lineCap: .round,
                    lineJoin: .round,
                    dash: renderFace.isDraft ? [5, 3] : []
                )
                for index in renderFace.points.indices where renderFace.edgeMask[index] {
                    var edge = Path()
                    let start = renderFace.points[index]
                    let end = renderFace.points[(index + 1) % renderFace.points.count]
                    edge.move(to: CGPoint(x: start.x, y: start.y))
                    edge.addLine(to: CGPoint(x: end.x, y: end.y))
                    context.stroke(edge, with: .color(edgeColor), style: style)
                }
            }
        }
    }

    private func drawDraftBaseFootprint(in context: GraphicsContext) {
        guard !scene.display.isFrozen,
              let draft = editorState.draft else { return }
        let projectedCorners = draft.baseCorners.compactMap {
            projectBlockPoint(
                $0,
                camera: scene.camera,
                canvasSize: transform.canvasSize
            )
        }
        guard projectedCorners.count == draft.baseCorners.count else { return }
        let points = projectedCorners.map { transform.canvasToViewport($0.canvasPoint) }
        let path = polygonPath(points)

        context.fill(path, with: .color(Color.cyan.opacity(0.2)))
        context.stroke(
            path,
            with: .color(Color.white.opacity(0.94)),
            style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            path,
            with: .color(Color.cyan.opacity(0.98)),
            style: StrokeStyle(
                lineWidth: 2.2,
                lineCap: .round,
                lineJoin: .round,
                dash: [6, 3]
            )
        )

        for point in points {
            let handleRect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            let handle = Path(ellipseIn: handleRect)
            context.fill(handle, with: .color(Color.cyan.opacity(0.98)))
            context.stroke(handle, with: .color(Color.white.opacity(0.96)), lineWidth: 1.3)
        }
    }

    private func drawHumanJointHandles(in context: GraphicsContext) {
        guard !scene.display.isFrozen,
              let selectedID = editorState.selectedObjectID,
              let object = scene.objects.first(where: {
                $0.id == selectedID && $0.moduleKind == .poseableHuman && $0.isVisible && !$0.isLocked
              }) else { return }
        let jointPoints = blockReferenceHumanJointWorldPoints(object: object)
        if let selectedJoint = editorState.selectedHumanJoint,
           let center = jointPoints[selectedJoint] {
            let axisDirections = blockReferenceHumanJointWorldAxes(
                object: object,
                joint: selectedJoint
            )
            if let layout = blockReferenceGizmoLayout(
                center: center,
                axisDirections: axisDirections,
                camera: scene.camera,
                canvasSize: transform.canvasSize,
                screenScale: transform.actualDisplayScale
            ) {
                for ring in layout.rotationRings where selectedJoint.rotationAxes.contains(ring.axis) {
                    let points = ring.points.map { transform.canvasToViewport($0) }
                    guard let first = points.first else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: first.x, y: first.y))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: point.x, y: point.y))
                    }
                    let isActive = editorState.activeHumanJointAxis == ring.axis
                    context.stroke(
                        path,
                        with: .color(gizmoColor(ring.axis).opacity(isActive ? 1 : 0.86)),
                        style: StrokeStyle(
                            lineWidth: isActive ? 4 : 2.6,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                }
            }
        }
        for (joint, worldPoint) in jointPoints {
            guard let point = viewportPoint(worldPoint) else { continue }
            let isSelected = editorState.selectedHumanJoint == joint
            let size: CGFloat = isSelected ? 16 : 12
            let rect = CGRect(
                x: point.x - size * 0.5,
                y: point.y - size * 0.5,
                width: size,
                height: size
            )
            context.fill(
                Path(ellipseIn: rect),
                with: .color(isSelected ? Color.orange.opacity(0.98) : Color.cyan.opacity(0.9))
            )
            context.stroke(Path(ellipseIn: rect), with: .color(Color.white.opacity(0.96)), lineWidth: 1.5)
            if isSelected {
                context.draw(
                    Text("\(joint.displayName) · 拖动彩色轴环")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.orange),
                    at: CGPoint(x: point.x + 64, y: point.y - 16)
                )
            }
        }
    }

    private func drawTransformGizmo(in context: GraphicsContext) {
        guard !scene.display.isFrozen,
              editorState.selectedHumanJoint == nil,
              let activeID = editorState.selectedObjectID else { return }
        let selectedIDs = blockReferenceExpandedSelectionIDs(
            in: scene,
            selection: editorState.resolvedSelectedObjectIDs
        )
        let displayedObjects = scene.objects
            .filter { $0.isVisible && !$0.isLocked && selectedIDs.contains($0.id) }
            .map { editorState.numericTransform?.applying(to: $0) ?? $0 }
        guard !displayedObjects.isEmpty,
              let activeObject = displayedObjects.first(where: { $0.id == activeID }) else { return }
        let selectionCenter: BlockVector3
        switch scene.pivotMode {
        case .selectionCenter:
            selectionCenter = displayedObjects.reduce(BlockVector3.zero) { $0 + $1.position }
                / Double(displayedObjects.count)
        case .activeObject:
            selectionCenter = activeObject.position
        case .workingPlaneOrigin:
            selectionCenter = scene.workingPlane.origin
        case .custom:
            let storedBasePoint = blockReferenceSelectedModuleBasePoint(
                in: scene,
                selection: editorState.resolvedSelectedObjectIDs,
                activeObjectID: activeID
            ) ?? scene.customPivot
            selectionCenter = editorState.numericTransform?.applying(to: storedBasePoint)
                ?? storedBasePoint
        }
        let axisDirections: [BlockReferenceAxis: BlockVector3]
        if let captured = editorState.numericTransform?.axisDirections
            ?? editorState.gizmoAdjustment?.axisDirections {
            axisDirections = captured
        } else {
            switch editorState.gizmoCoordinateSpace {
            case .world:
                axisDirections = Dictionary(uniqueKeysWithValues: BlockReferenceAxis.allCases.map {
                    ($0, $0.unitVector)
                })
            case .local:
                axisDirections = Dictionary(uniqueKeysWithValues: BlockReferenceAxis.allCases.map {
                    ($0, blockRotate($0.unitVector, rotation: activeObject.rotation))
                })
            case .workingPlane:
                axisDirections = [
                    .x: scene.workingPlane.axisU,
                    .y: scene.workingPlane.axisV,
                    .z: scene.workingPlane.normal
                ]
            }
        }
        guard let layout = blockReferenceGizmoLayout(
            center: selectionCenter,
            axisDirections: axisDirections,
            camera: scene.camera,
            canvasSize: transform.canvasSize,
            screenScale: transform.actualDisplayScale
        ) else { return }
        let activeHandle = editorState.activeGizmoHandle
            ?? editorState.hoveredGizmoHandle
            ?? editorState.gizmoAdjustment?.handle
            ?? editorState.numericTransform.flatMap { transform in
                if let axis = transform.axis {
                    return BlockReferenceGizmoHandle(kind: transform.kind, axis: axis)
                }
                return transform.kind == .scale
                    ? BlockReferenceGizmoHandle(kind: .scale, axis: .x, isUniformScale: true)
                    : nil
            }

        for ring in layout.rotationRings {
            let handle = BlockReferenceGizmoHandle(kind: .rotate, axis: ring.axis)
            let color = gizmoColor(ring.axis)
            let points = ring.points.map { transform.canvasToViewport($0) }
            guard let first = points.first else { continue }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            context.stroke(
                path,
                with: .color(color.opacity(activeHandle == nil || activeHandle == handle ? 0.9 : 0.28)),
                lineWidth: activeHandle == handle ? 3.2 : 1.8
            )
        }

        for move in layout.moveHandles {
            let handle = BlockReferenceGizmoHandle(kind: .move, axis: move.axis)
            let color = gizmoColor(move.axis)
            let start = transform.canvasToViewport(move.start)
            let end = transform.canvasToViewport(move.end)
            let opacity = activeHandle == nil || activeHandle == handle ? 0.98 : 0.32
            var path = Path()
            path.move(to: CGPoint(x: start.x, y: start.y))
            path.addLine(to: CGPoint(x: end.x, y: end.y))
            context.stroke(
                path,
                with: .color(color.opacity(opacity)),
                lineWidth: activeHandle == handle ? 4 : 2.4
            )
            drawGizmoArrowHead(
                at: CGPoint(x: end.x, y: end.y),
                from: CGPoint(x: start.x, y: start.y),
                color: color.opacity(opacity),
                in: context
            )
            context.draw(
                Text(move.axis.displayName)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(color),
                at: CGPoint(x: end.x + 9, y: end.y - 9)
            )
        }

        for scale in layout.scaleHandles {
            let handle = BlockReferenceGizmoHandle(kind: .scale, axis: scale.axis)
            let color = gizmoColor(scale.axis)
            let start = transform.canvasToViewport(scale.start)
            let end = transform.canvasToViewport(scale.end)
            let opacity = activeHandle == nil || activeHandle == handle ? 0.98 : 0.28
            var path = Path()
            path.move(to: CGPoint(x: start.x, y: start.y))
            path.addLine(to: CGPoint(x: end.x, y: end.y))
            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: activeHandle == handle ? 4 : 2)
            let rect = CGRect(x: end.x - 5, y: end.y - 5, width: 10, height: 10)
            context.fill(Path(rect), with: .color(color.opacity(opacity)))
            context.stroke(Path(rect), with: .color(Color.white.opacity(opacity)), lineWidth: 1)
        }

        let center = transform.canvasToViewport(layout.center)
        let uniformHandle = BlockReferenceGizmoHandle(kind: .scale, axis: .x, isUniformScale: true)
        let centerSize: CGFloat = activeHandle == uniformHandle ? 18 : 16
        let centerRect = CGRect(
            x: center.x - centerSize * 0.5,
            y: center.y - centerSize * 0.5,
            width: centerSize,
            height: centerSize
        )
        context.fill(Path(roundedRect: centerRect, cornerRadius: 4), with: .color(Color.white.opacity(0.96)))
        context.stroke(Path(roundedRect: centerRect, cornerRadius: 4), with: .color(Color.black.opacity(0.82)), lineWidth: 1.5)
        context.draw(
            Text("S")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(Color.black),
            at: CGPoint(x: center.x, y: center.y)
        )

        if let handle = editorState.activeGizmoHandle,
           let value = editorState.gizmoLiveValue {
            let suffix = handle.kind == .rotate ? "°" : (handle.kind == .scale ? "×" : "")
            context.draw(
                Text("\(handle.isUniformScale ? "统一" : handle.axis.displayName)  \(String(format: "%.2f", value))\(suffix)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white),
                at: CGPoint(x: center.x + 76, y: center.y - 68)
            )
        }
    }

    private func drawGizmoArrowHead(
        at end: CGPoint,
        from start: CGPoint,
        color: Color,
        in context: GraphicsContext
    ) {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let length = max(hypot(deltaX, deltaY), 0.001)
        let unitX = deltaX / length
        let unitY = deltaY / length
        let perpendicularX = -unitY
        let perpendicularY = unitX
        let arrowLength: CGFloat = 11
        let halfWidth: CGFloat = 5.5
        var path = Path()
        path.move(to: end)
        path.addLine(to: CGPoint(
            x: end.x - unitX * arrowLength + perpendicularX * halfWidth,
            y: end.y - unitY * arrowLength + perpendicularY * halfWidth
        ))
        path.addLine(to: CGPoint(
            x: end.x - unitX * arrowLength - perpendicularX * halfWidth,
            y: end.y - unitY * arrowLength - perpendicularY * halfWidth
        ))
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func gizmoColor(_ axis: BlockReferenceAxis) -> Color {
        switch axis {
        case .x: return Color(red: 0.95, green: 0.22, blue: 0.25)
        case .y: return Color(red: 0.38, green: 0.86, blue: 0.24)
        case .z: return Color(red: 0.2, green: 0.48, blue: 1)
        }
    }

    private func drawWorkingPlaneIndicator(in context: GraphicsContext) {
        guard !scene.display.isFrozen,
              let origin = viewportPoint(scene.workingPlane.origin),
              let normalEnd = viewportPoint(
                scene.workingPlane.origin
                    + scene.workingPlane.normal * max(scene.snap.gridSpacing * 2, 20)
              ) else { return }
        var path = Path()
        path.move(to: CGPoint(x: origin.x, y: origin.y))
        path.addLine(to: CGPoint(x: normalEnd.x, y: normalEnd.y))
        context.stroke(path, with: .color(Color.cyan.opacity(0.9)), lineWidth: 2)
        context.draw(
            Text("活动工作面")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.cyan),
            at: CGPoint(x: origin.x + 42, y: origin.y - 14)
        )
        let extent = max(scene.snap.gridSpacing * 3, 30)
        let corners = [(-extent, -extent), (extent, -extent), (extent, extent), (-extent, extent)]
            .compactMap { viewportPoint(scene.workingPlane.worldPoint(u: $0.0, v: $0.1)) }
        if corners.count == 4 {
            let patch = polygonPath(corners)
            context.fill(patch, with: .color(.cyan.opacity(0.06)))
            context.stroke(patch, with: .color(.cyan.opacity(0.5)), lineWidth: 1)
        }
    }

    private func drawModuleBasePointMarker(in context: GraphicsContext) {
        guard !scene.display.isFrozen,
              scene.pivotMode == .custom,
              !editorState.resolvedSelectedObjectIDs.isEmpty else { return }
        let storedBasePoint = blockReferenceSelectedModuleBasePoint(
            in: scene,
            selection: editorState.resolvedSelectedObjectIDs,
            activeObjectID: editorState.selectedObjectID
        ) ?? scene.customPivot
        let displayedBasePoint = editorState.numericTransform?.applying(to: storedBasePoint)
            ?? storedBasePoint
        guard let point = viewportPoint(displayedBasePoint) else { return }
        let center = CGPoint(x: point.x, y: point.y)
        let outer = CGRect(x: center.x - 9, y: center.y - 9, width: 18, height: 18)
        let inner = CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: outer), with: .color(Color.black.opacity(0.66)))
        context.stroke(Path(ellipseIn: outer), with: .color(Color.orange.opacity(0.98)), lineWidth: 2)
        context.fill(Path(ellipseIn: inner), with: .color(Color.orange.opacity(0.98)))
        context.draw(
            Text("模块基准点")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.orange),
            at: CGPoint(x: center.x + 48, y: center.y - 15)
        )
    }

    private func drawMeasurements(in context: GraphicsContext) {
        let opacity = Double(scene.display.opacity)
        let allMeasurements = scene.measurements + [editorState.draftMeasurement].compactMap { $0 }
        for measurement in allMeasurements {
            guard let start = viewportPoint(measurement.start),
                  let end = viewportPoint(measurement.end) else { continue }
            var path = Path()
            path.move(to: CGPoint(x: start.x, y: start.y))
            path.addLine(to: CGPoint(x: end.x, y: end.y))
            context.stroke(
                path,
                with: .color(Color.yellow.opacity(0.92 * opacity)),
                style: StrokeStyle(lineWidth: 1.4, dash: [6, 3])
            )
            let midpoint = CGPoint(x: (start.x + end.x) * 0.5, y: (start.y + end.y) * 0.5)
            context.draw(
                Text(blockMeasurementLabel(measurement))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.yellow),
                at: midpoint
            )
        }
    }

    private func drawInteractionHints(in context: GraphicsContext) {
        let opacity = Double(scene.display.opacity)
        if let snapPoint = editorState.snapPoint,
           let point = viewportPoint(snapPoint) {
            let rect = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            context.fill(Path(ellipseIn: rect), with: .color(Color.black.opacity(0.65)))
            context.stroke(Path(ellipseIn: rect), with: .color(Color.yellow.opacity(0.95)), lineWidth: 1.5)
        }

        if let draft = editorState.draft {
            drawDraftDimensions(draft, in: context)
        }

        guard let draft = editorState.draft,
              editorState.phase == .awaitingExtrusion || editorState.phase == .extruding else { return }
        let start = draft.center
        let length = max(draft.dimensions.width, draft.dimensions.depth, scene.snap.gridSpacing * 3)
        let end = start + draft.plane.normal * length
        drawWorldLine(
            from: start,
            to: end,
            in: context,
            color: Color.cyan.opacity(0.98 * opacity),
            lineWidth: 2.2
        )
        guard let arrowPoint = viewportPoint(end) else { return }
        let rect = CGRect(x: arrowPoint.x - 5, y: arrowPoint.y - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: rect), with: .color(Color.cyan.opacity(0.95)))
    }

    private func drawDraftDimensions(
        _ draft: BlockCreationDraft,
        in context: GraphicsContext
    ) {
        guard editorState.phase == .drawingBase
                || editorState.phase == .awaitingExtrusion
                || editorState.phase == .extruding else { return }
        let dimensions = draft.dimensions
        let text: String
        if draft.kind == .sphere {
            text = "直径 \(blockMeasurementText(dimensions.width))"
        } else if editorState.phase == .drawingBase {
            text = "宽 \(blockMeasurementText(dimensions.width))  深 \(blockMeasurementText(dimensions.depth))"
        } else {
            text = "宽 \(blockMeasurementText(dimensions.width))  深 \(blockMeasurementText(dimensions.depth))  高 \(blockMeasurementText(dimensions.height))"
        }

        let anchorWorld: BlockVector3
        if editorState.phase == .extruding {
            anchorWorld = draft.center + draft.plane.normal * dimensions.height
        } else {
            anchorWorld = draft.baseCorners[2]
        }
        guard let anchor = viewportPoint(anchorWorld) else { return }
        let position = CGPoint(x: anchor.x + 12, y: anchor.y - 15)
        let label = Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
        context.draw(
            label.foregroundStyle(Color.black.opacity(0.82)),
            at: CGPoint(x: position.x + 1.2, y: position.y + 1.2),
            anchor: .leading
        )
        context.draw(
            label.foregroundStyle(Color.cyan.opacity(0.98)),
            at: position,
            anchor: .leading
        )
    }

    private func drawWorldLine(
        from start: BlockVector3,
        to end: BlockVector3,
        in context: GraphicsContext,
        color: Color,
        lineWidth: CGFloat
    ) {
        guard let startPoint = viewportPoint(start),
              let endPoint = viewportPoint(end) else { return }
        var path = Path()
        path.move(to: CGPoint(x: startPoint.x, y: startPoint.y))
        path.addLine(to: CGPoint(x: endPoint.x, y: endPoint.y))
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func viewportPoint(_ point: BlockVector3) -> CanvasPoint? {
        guard let projected = projectBlockPoint(
            point,
            camera: scene.camera,
            canvasSize: transform.canvasSize
        ) else { return nil }
        return transform.canvasToViewport(projected.canvasPoint)
    }

    private func polygonPath(_ points: [CanvasPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            path.closeSubpath()
        }
    }

    private func blockMeasurementText(_ length: Double) -> String {
        if length >= 100 {
            return String(format: "%.0f", length)
        }
        return String(format: "%.1f", length)
    }

    private func blockMeasurementLabel(_ measurement: BlockMeasurementGuide) -> String {
        let delta = measurement.end - measurement.start
        let horizontal = hypot(delta.x, delta.y)
        let elevation = atan2(delta.z, max(horizontal, 0.000_001)) * 180 / .pi
        return "\(blockMeasurementText(measurement.length))  ∠\(Int(elevation.rounded()))°"
    }
}

struct BlockReferenceGestureOverlay: NSViewRepresentable {
    let transform: CanvasViewportTransform
    let onBegan: (CanvasPoint, NSEvent.ModifierFlags) -> Void
    let onChanged: (CanvasPoint) -> Void
    let onEnded: () -> Void
    let onNavigationBegan: (BlockReferenceNavigationMode) -> Void
    let onNavigationChanged: (BlockReferenceNavigationMode, Double, Double) -> Void
    let onNavigationEnded: () -> Void
    let onZoom: (Double) -> Void
    let onHover: (CanvasPoint?) -> Bool
    let contextMenuItems: (CanvasPoint) -> [BlockReferenceContextMenuItem]
    let gizmoAdjustment: BlockReferenceGizmoAdjustment?
    let gizmoPopupPoint: CGPoint?
    let onGizmoInputChanged: (String) -> Void
    let onGizmoFinish: () -> Void
    var primaryNavigationMode: BlockReferenceNavigationMode? = nil
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)? = nil

    func makeNSView(context: Context) -> BlockReferenceInteractionView {
        let view = BlockReferenceInteractionView()
        configure(view)
        return view
    }

    func updateNSView(_ view: BlockReferenceInteractionView, context: Context) {
        configure(view)
    }

    private func configure(_ view: BlockReferenceInteractionView) {
        view.transform = transform
        view.primaryNavigationMode = primaryNavigationMode
        view.onModifiersChanged = onModifiersChanged
        view.onBegan = onBegan
        view.onChanged = onChanged
        view.onEnded = onEnded
        view.onNavigationBegan = onNavigationBegan
        view.onNavigationChanged = onNavigationChanged
        view.onNavigationEnded = onNavigationEnded
        view.onZoom = onZoom
        view.onHover = onHover
        view.contextMenuItems = contextMenuItems
        view.onGizmoInputChanged = onGizmoInputChanged
        view.onGizmoFinish = onGizmoFinish
        view.configureGizmoEditor(adjustment: gizmoAdjustment, center: gizmoPopupPoint)
    }
}

final class BlockReferenceInteractionView: NSView, NSTextFieldDelegate {
    var transform: CanvasViewportTransform?
    var onBegan: ((CanvasPoint, NSEvent.ModifierFlags) -> Void)?
    var onChanged: ((CanvasPoint) -> Void)?
    var onEnded: (() -> Void)?
    var onNavigationBegan: ((BlockReferenceNavigationMode) -> Void)?
    var onNavigationChanged: ((BlockReferenceNavigationMode, Double, Double) -> Void)?
    var onNavigationEnded: (() -> Void)?
    var onZoom: ((Double) -> Void)?
    var onHover: ((CanvasPoint?) -> Bool)?
    var contextMenuItems: ((CanvasPoint) -> [BlockReferenceContextMenuItem])?
    var onGizmoInputChanged: ((String) -> Void)?
    var onGizmoFinish: (() -> Void)?

    var primaryNavigationMode: BlockReferenceNavigationMode?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    private var primaryNavigating = false
    private var isPrimaryDragging = false
    private var navigationMode: BlockReferenceNavigationMode?
    private var navigationStartLocation: CGPoint?
    private var scrollNavigationMode: BlockReferenceNavigationMode?
    private var scrollNavigationDelta = CGPoint.zero
    private var scrollEndTask: Task<Void, Never>?
    private var pointerTrackingArea: NSTrackingArea?
    private var gizmoEditorContainer: NSView?
    private var gizmoAxisLabel: NSTextField?
    private var gizmoValueField: NSTextField?
    private var gizmoUnitLabel: NSTextField?
    private let middleMouseCapture = BlockReferenceMiddleMouseCapture()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow {
            middleMouseCapture.stop()
            finishScrollNavigation()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        middleMouseCapture.onBegan = { [weak self] point, modifiers in
            self?.beginPointerNavigation(at: point, modifiers: modifiers)
        }
        middleMouseCapture.onChanged = { [weak self] point in
            self?.changePointerNavigation(to: point)
        }
        middleMouseCapture.onEnded = { [weak self] in self?.finishPointerNavigation() }
        middleMouseCapture.install(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    func configureGizmoEditor(
        adjustment: BlockReferenceGizmoAdjustment?,
        center: CGPoint?
    ) {
        guard let adjustment, let center else {
            gizmoEditorContainer?.removeFromSuperview()
            gizmoEditorContainer = nil
            gizmoAxisLabel = nil
            gizmoValueField = nil
            gizmoUnitLabel = nil
            return
        }
        let shouldFocusEditor = gizmoEditorContainer == nil
        let container = gizmoEditorContainer ?? makeGizmoEditorContainer()
        let width: CGFloat = 154
        let height: CGFloat = 32
        let resolvedCenter = CGPoint(
            x: min(max(center.x, width * 0.5 + 4), max(bounds.width - width * 0.5 - 4, width * 0.5 + 4)),
            y: min(max(center.y, height * 0.5 + 4), max(bounds.height - height * 0.5 - 4, height * 0.5 + 4))
        )
        container.frame = CGRect(
            x: resolvedCenter.x - width * 0.5,
            y: resolvedCenter.y - height * 0.5,
            width: width,
            height: height
        )
        let color = gizmoNSColor(adjustment.handle.axis)
        container.layer?.borderColor = color.cgColor
        gizmoAxisLabel?.stringValue = adjustment.handle.axis.displayName
        gizmoAxisLabel?.textColor = color
        gizmoUnitLabel?.stringValue = adjustment.handle.kind == .move ? "" : "°"
        if window?.firstResponder !== gizmoValueField,
           gizmoValueField?.stringValue != adjustment.input {
            gizmoValueField?.stringValue = adjustment.input
        }
        container.isHidden = false
        if shouldFocusEditor, let field = gizmoValueField {
            focusGizmoValueField(field)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
              field === gizmoValueField else { return }
        onGizmoInputChanged?(field.stringValue)
    }

    @objc private func finishGizmoEditor() {
        if let field = gizmoValueField {
            onGizmoInputChanged?(field.stringValue)
        }
        window?.makeFirstResponder(nil)
        onGizmoFinish?()
    }

    private func makeGizmoEditorContainer() -> NSView {
        let container = NSView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.84).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.shadowColor = NSColor.black.cgColor
        container.layer?.shadowOpacity = 0.35
        container.layer?.shadowRadius = 6
        container.layer?.shadowOffset = CGSize(width: 0, height: 3)

        let axisLabel = NSTextField(labelWithString: "X")
        axisLabel.frame = CGRect(x: 9, y: 7, width: 18, height: 18)
        axisLabel.alignment = .center
        axisLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        container.addSubview(axisLabel)

        let field = NSTextField(frame: CGRect(x: 31, y: 5, width: 82, height: 22))
        field.delegate = self
        field.target = self
        field.action = #selector(finishGizmoEditor)
        field.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        field.alignment = .right
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.placeholderString = "数值"
        container.addSubview(field)

        let unitLabel = NSTextField(labelWithString: "")
        unitLabel.frame = CGRect(x: 115, y: 7, width: 12, height: 18)
        unitLabel.textColor = NSColor.white.withAlphaComponent(0.58)
        unitLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        container.addSubview(unitLabel)

        let finishButton = NSButton(frame: CGRect(x: 128, y: 5, width: 21, height: 22))
        finishButton.title = "✓"
        finishButton.isBordered = false
        finishButton.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        finishButton.contentTintColor = .white
        finishButton.target = self
        finishButton.action = #selector(finishGizmoEditor)
        container.addSubview(finishButton)

        addSubview(container)
        gizmoEditorContainer = container
        gizmoAxisLabel = axisLabel
        gizmoValueField = field
        gizmoUnitLabel = unitLabel
        return container
    }

    private func focusGizmoValueField(_ field: NSTextField) {
        focusCurrentGizmoValueField()
        if window == nil || window?.firstResponder !== field.currentEditor() {
            perform(#selector(focusCurrentGizmoValueField), with: nil, afterDelay: 0)
        }
    }

    @objc private func focusCurrentGizmoValueField() {
        guard let field = gizmoValueField,
              let window else { return }
        guard window.makeFirstResponder(field) else { return }
        field.currentEditor()?.selectAll(nil)
    }

    private func gizmoNSColor(_ axis: BlockReferenceAxis) -> NSColor {
        switch axis {
        case .x: return NSColor(red: 0.95, green: 0.22, blue: 0.25, alpha: 1)
        case .y: return NSColor(red: 0.38, green: 0.86, blue: 0.24, alpha: 1)
        case .z: return NSColor(red: 0.2, green: 0.48, blue: 1, alpha: 1)
        }
    }

    override func flagsChanged(with event: NSEvent) { onModifiersChanged?(event.modifierFlags) }

    override func mouseMoved(with event: NSEvent) {
        onModifiersChanged?(event.modifierFlags)
        let isOverGizmo = onHover?(canvasPoint(for: event)) ?? false
        (isOverGizmo ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func mouseExited(with event: NSEvent) {
        _ = onHover?(nil)
        NSCursor.crosshair.set()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let items = contextMenuItems?(canvasPoint(for: event)) ?? []
        guard !items.isEmpty else { return nil }
        let menu = NSMenu(title: "体块")
        menu.autoenablesItems = false
        appendContextMenuItems(items, to: menu)
        return menu
    }

    override func mouseDown(with event: NSEvent) {
        finishScrollNavigation()
        window?.makeFirstResponder(self)
        onModifiersChanged?(event.modifierFlags)
        let emulatedMode = event.modifierFlags.contains(.option)
            ? Self.navigationMode(for: event.modifierFlags) : nil
        if let mode = emulatedMode ?? primaryNavigationMode {
            primaryNavigating = true
            navigationMode = mode
            navigationStartLocation = convert(event.locationInWindow, from: nil)
            onNavigationBegan?(mode)
            return
        }
        isPrimaryDragging = true
        let point = canvasPoint(for: event)
        if onHover?(point) == true {
            NSCursor.closedHand.set()
        }
        onBegan?(point, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    override func mouseDragged(with event: NSEvent) {
        onModifiersChanged?(event.modifierFlags)
        if primaryNavigating { otherMouseDragged(with: event); return }
        guard isPrimaryDragging else { return }
        onChanged?(canvasPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        if primaryNavigating { otherMouseUp(with: event); primaryNavigating = false; return }
        guard isPrimaryDragging else { return }
        onChanged?(canvasPoint(for: event))
        onEnded?()
        isPrimaryDragging = false
        let isOverGizmo = onHover?(canvasPoint(for: event)) ?? false
        (isOverGizmo ? NSCursor.openHand : NSCursor.crosshair).set()
    }

    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
        beginPointerNavigation(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    private func beginPointerNavigation(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        finishScrollNavigation()
        window?.makeFirstResponder(self)
        let mode = Self.navigationMode(for: modifiers)
        navigationMode = mode
        navigationStartLocation = point
        onNavigationBegan?(mode)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard navigationMode != nil else {
            super.otherMouseDragged(with: event)
            return
        }
        changePointerNavigation(to: convert(event.locationInWindow, from: nil))
    }

    private func changePointerNavigation(to current: CGPoint) {
        guard let mode = navigationMode, let start = navigationStartLocation else { return }
        onNavigationChanged?(mode, current.x - start.x, current.y - start.y)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard navigationMode != nil else {
            super.otherMouseUp(with: event)
            return
        }
        finishPointerNavigation()
    }

    private func finishPointerNavigation() {
        guard navigationMode != nil else { return }
        navigationMode = nil
        navigationStartLocation = nil
        onNavigationEnded?()
        NSCursor.crosshair.set()
    }

    override func scrollWheel(with event: NSEvent) {
        guard navigationMode == nil else { return }
        if event.hasPreciseScrollingDeltas {
            // NSEvent scrolling is Y-up; this view and drag callbacks are Y-down.
            updateScrollNavigation(deltaX: event.scrollingDeltaX, deltaY: -event.scrollingDeltaY,
                modifiers: event.modifierFlags)
            return
        }
        finishScrollNavigation()
        let amount: Double = min(max(-Double(event.scrollingDeltaY) * 0.11, -20), 20)
        onZoom?(exp(amount))
    }

    override func magnify(with event: NSEvent) {
        finishScrollNavigation()
        onZoom?(1 / min(max(1 + event.magnification, 0.1), 10))
    }

    static func navigationMode(for modifiers: NSEvent.ModifierFlags) -> BlockReferenceNavigationMode {
        if modifiers.contains([.control, .shift]) { return .dolly }
        if modifiers.contains(.control) { return .zoom }
        return modifiers.contains(.shift) ? .pan : .orbit
    }

    func updateScrollNavigation(deltaX: Double, deltaY: Double, modifiers: NSEvent.ModifierFlags) {
        guard deltaX.isFinite, deltaY.isFinite, abs(deltaX) + abs(deltaY) > 0 else { return }
        let mode = Self.navigationMode(for: modifiers)
        if scrollNavigationMode != mode {
            finishScrollNavigation()
            scrollNavigationMode = mode
            scrollNavigationDelta = .zero
            onNavigationBegan?(mode)
        }
        scrollNavigationDelta.x += deltaX
        scrollNavigationDelta.y += deltaY
        onNavigationChanged?(mode, scrollNavigationDelta.x, scrollNavigationDelta.y)
        // Keep trackpad momentum in one camera transaction, not one undo per event.
        scrollEndTask?.cancel()
        scrollEndTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.finishScrollNavigation()
        }
    }

    func finishScrollNavigation() {
        scrollEndTask?.cancel()
        scrollEndTask = nil
        guard scrollNavigationMode != nil else { return }
        scrollNavigationMode = nil
        scrollNavigationDelta = .zero
        onNavigationEnded?()
    }

    private func canvasPoint(for event: NSEvent) -> CanvasPoint {
        let point = convert(event.locationInWindow, from: nil)
        guard let transform else {
            return CanvasPoint(x: point.x, y: point.y)
        }
        return transform.viewportToCanvas(
            CanvasPoint(x: point.x, y: point.y),
            clamped: false
        )
    }

    private func appendContextMenuItems(
        _ items: [BlockReferenceContextMenuItem],
        to menu: NSMenu
    ) {
        for item in items {
            switch item {
            case .action(let title, let isEnabled, let perform):
                let menuItem = NSMenuItem(
                    title: title,
                    action: #selector(performBlockReferenceContextMenuAction(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.isEnabled = isEnabled
                menuItem.representedObject = BlockReferenceContextMenuActionBox(perform: perform)
                menu.addItem(menuItem)
            case .submenu(let title, let children):
                let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let submenu = NSMenu(title: title)
                submenu.autoenablesItems = false
                appendContextMenuItems(children, to: submenu)
                menuItem.submenu = submenu
                menu.addItem(menuItem)
            case .separator:
                menu.addItem(.separator())
            }
        }
    }

    @objc private func performBlockReferenceContextMenuAction(_ sender: NSMenuItem) {
        (sender.representedObject as? BlockReferenceContextMenuActionBox)?.perform()
    }
}

indirect enum BlockReferenceContextMenuItem {
    case action(title: String, isEnabled: Bool = true, perform: () -> Void)
    case submenu(title: String, items: [BlockReferenceContextMenuItem])
    case separator
}

private final class BlockReferenceContextMenuActionBox: NSObject {
    private let action: () -> Void

    init(perform action: @escaping () -> Void) {
        self.action = action
    }

    func perform() {
        action()
    }
}

func blockReferenceGizmoPopupViewportPoint(
    scene: BlockReferenceScene,
    adjustment: BlockReferenceGizmoAdjustment,
    transform: CanvasViewportTransform
) -> CGPoint? {
    var center = adjustment.pivot
    if adjustment.handle.kind == .move, let value = adjustment.value {
        let axis = adjustment.handle.axis
        center = center + (
            adjustment.axisDirections[axis]?.normalized(fallback: axis.unitVector)
                ?? axis.unitVector
        ) * value
    }
    guard let layout = blockReferenceGizmoLayout(
            center: center,
            axisDirections: adjustment.axisDirections,
            camera: scene.camera,
            canvasSize: transform.canvasSize,
            screenScale: transform.actualDisplayScale
          ) else { return nil }
    let anchor: CanvasPoint
    switch adjustment.handle.kind {
    case .move:
        anchor = layout.moveHandles.first(where: { $0.axis == adjustment.handle.axis })?.end
            ?? layout.center
    case .rotate:
        anchor = layout.rotationRings
            .first(where: { $0.axis == adjustment.handle.axis })?
            .points.min(by: { $0.y < $1.y })
            ?? layout.center
    case .scale:
        anchor = adjustment.handle.isUniformScale
            ? layout.center
            : (layout.scaleHandles.first(where: { $0.axis == adjustment.handle.axis })?.end ?? layout.center)
    }
    let point = transform.canvasToViewport(anchor)
    return CGPoint(x: point.x + 34, y: point.y - 30)
}

struct BlockReferenceHUD: View {
    let scene: BlockReferenceScene
    let editorState: BlockReferenceEditorState
    let onCancel: () -> Void
    let onFreeze: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "cube.transparent")
                .font(.system(size: 11, weight: .semibold))
            Text(
                "\(scene.objects.count) 个体块 · "
                + (editorState.numericTransform?.summary ?? editorState.instruction)
                + (editorState.snapLabel.map { " · 吸附：\($0)" } ?? "")
                + " · 中键环绕 / ⇧中键平移 / 滚轮缩放"
            )
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
            if editorState.phase != .idle {
                Button("取消") { onCancel() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10, weight: .semibold))
            }
            Button("锁定参考，返回绘画") { onFreeze() }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Capsule().fill(Color.black.opacity(0.68)))
        .frame(maxWidth: 820)
    }
}
