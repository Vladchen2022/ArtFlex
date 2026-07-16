import Euclid
import Foundation

enum BlockReferenceBooleanOperation: String, Sendable, Equatable, CaseIterable {
    case union
    case subtract
    case intersection

    var displayName: String {
        switch self {
        case .union: return "合并"
        case .subtract: return "减去"
        case .intersection: return "相交"
        }
    }
}

enum BlockReferenceBooleanError: Error, Sendable, Equatable {
    case invalidInput
    case invalidResult
    case emptyResult
    case resultTooComplex
}

func blockReferenceBooleanObject(
    active: BlockReferenceObject,
    other: BlockReferenceObject,
    operation: BlockReferenceBooleanOperation,
    name: String
) throws -> BlockReferenceObject {
    guard active.allowsBooleanOperations,
          other.allowsBooleanOperations else {
        throw BlockReferenceBooleanError.invalidInput
    }
    let activeMesh = try blockReferenceEuclidMesh(from: active)
    let otherMesh = try blockReferenceEuclidMesh(from: other)
    let rawResult: Mesh
    switch operation {
    case .union:
        rawResult = activeMesh.union(otherMesh)
    case .subtract:
        rawResult = activeMesh.subtracting(otherMesh)
    case .intersection:
        rawResult = activeMesh.intersection(otherMesh)
    }

    guard !rawResult.isEmpty else { throw BlockReferenceBooleanError.emptyResult }
    let result = rawResult.isWatertight ? rawResult : rawResult.makeWatertight()
    guard result.isWatertight else { throw BlockReferenceBooleanError.invalidResult }
    let worldFaces = result.polygons.map { polygon in
        polygon.vertices.map { vertex in
            BlockVector3(
                x: vertex.position.x,
                y: vertex.position.y,
                z: vertex.position.z
            )
        }
    }.filter { $0.count >= 3 }
    guard !worldFaces.isEmpty else { throw BlockReferenceBooleanError.emptyResult }
    guard worldFaces.count <= BlockReferenceCustomMesh.maximumFaceCount,
          worldFaces.allSatisfy({
              $0.count <= BlockReferenceCustomMesh.maximumVerticesPerFace
          }) else {
        throw BlockReferenceBooleanError.resultTooComplex
    }

    let vertices = worldFaces.flatMap { $0 }
    guard let first = vertices.first else { throw BlockReferenceBooleanError.emptyResult }
    var minimum = first
    var maximum = first
    for point in vertices.dropFirst() {
        minimum.x = min(minimum.x, point.x)
        minimum.y = min(minimum.y, point.y)
        minimum.z = min(minimum.z, point.z)
        maximum.x = max(maximum.x, point.x)
        maximum.y = max(maximum.y, point.y)
        maximum.z = max(maximum.z, point.z)
    }
    let center = (minimum + maximum) * 0.5
    var dimensions = BlockDimensions(
        width: maximum.x - minimum.x,
        depth: maximum.y - minimum.y,
        height: maximum.z - minimum.z
    )
    dimensions.normalize()
    let localFaces = worldFaces.map { face in face.map { $0 - center } }
    let customMesh = BlockReferenceCustomMesh(
        faces: localFaces,
        baseDimensions: dimensions
    )
    guard !customMesh.faces.isEmpty else { throw BlockReferenceBooleanError.emptyResult }

    return BlockReferenceObject(
        name: name,
        kind: active.kind,
        position: center,
        dimensions: dimensions,
        customMesh: customMesh
    )
}

private func blockReferenceEuclidMesh(from object: BlockReferenceObject) throws -> Mesh {
    guard object.allowsBooleanOperations else {
        throw BlockReferenceBooleanError.invalidInput
    }
    let faces = blockObjectFaces(object)
    guard !faces.isEmpty, faces.count <= BlockReferenceCustomMesh.maximumFaceCount else {
        throw BlockReferenceBooleanError.invalidInput
    }
    let polygons = faces.compactMap { face in
        Polygon(face.vertices.map { point in Vector(point.x, point.y, point.z) })
    }
    guard polygons.count == faces.count else { throw BlockReferenceBooleanError.invalidInput }
    let rawMesh = Mesh(polygons)
    let mesh = rawMesh.isWatertight ? rawMesh : rawMesh.makeWatertight()
    guard mesh.isWatertight,
          mesh.polygons.count <= BlockReferenceCustomMesh.maximumFaceCount else {
        throw BlockReferenceBooleanError.invalidInput
    }
    return mesh
}
