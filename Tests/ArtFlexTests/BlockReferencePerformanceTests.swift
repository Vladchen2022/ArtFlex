import Foundation
import Testing
@testable import ArtFlex

struct BlockReferencePerformanceTests {
    /// CPU geometry/projection baseline, not a GPU FPS measurement.
    @Test func representativeSceneGeometryAndProjection() {
        for count in [20, 100, 300] {
            let objects = (0..<count).map { index in
                var object = BlockReferenceObject(name: "基准 \(index)", kind: index % 5 == 0 ? .cylinder : .box,
                    position: .init(x: Double(index % 20) * 140, y: Double(index / 20) * 140, z: 0),
                    dimensions: .stageOneDefault)
                object.radialSegments = 24
                return object
            }
            var timings: [Double] = []
            var projectedCount = 0
            for _ in 0..<7 {
                let start = DispatchTime.now().uptimeNanoseconds
                for object in objects {
                    let faces = blockObjectFaces(object)
                    _ = blockReferenceFeatureEdgeMask(faces: faces)
                    for point in faces.flatMap(\.vertices) {
                        if projectBlockPoint(point, camera: .stageOneDefault, canvasSize: .init(width: 2000, height: 2000)) != nil {
                            projectedCount += 1
                        }
                    }
                }
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            #expect(projectedCount > 0)
            print("BlockReference CPU baseline: \(count) objects, median \(String(format: "%.2f", timings.sorted()[3])) ms")
        }
    }
}
