import Foundation
import Testing
@testable import ArtFlex

struct RemovedStrokeAssistCompatibilityTests {
    @Test
    func legacyToolSessionWithStrokeAssistStillDecodesAndDropsTheRemovedField() throws {
        let encoded = try JSONEncoder().encode(ToolSessionState.stageOneDefault)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["strokeAssist"] = [
            "stabilizationStrength": 0.75,
            "symmetryMode": "fourWay",
            "normalizedSymmetryAxis": ["x": 0.3, "y": 0.7]
        ]
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(ToolSessionState.self, from: legacyData)
        let reencodedObject = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )

        #expect(reencodedObject["strokeAssist"] == nil)
    }
}
