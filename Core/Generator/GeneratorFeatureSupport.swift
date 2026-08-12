import Foundation

enum GeneratorExecutionMode: String, Codable, Sendable, Equatable, CaseIterable {
    case directStroke
    case selectedRegion
}

struct GeneratorKindSupport: Sendable, Equatable {
    var kind: GeneratorKind
    var isUserVisible: Bool
    var executionModes: [GeneratorExecutionMode]

    func supports(_ mode: GeneratorExecutionMode) -> Bool {
        executionModes.contains(mode)
    }
}

enum GeneratorFeatureSupport {
    static let userVisibleKinds: [GeneratorKind] = GeneratorKind.allCases

    static func support(for kind: GeneratorKind) -> GeneratorKindSupport {
        GeneratorKindSupport(
            kind: kind,
            isUserVisible: true,
            executionModes: [.directStroke, .selectedRegion]
        )
    }
}
