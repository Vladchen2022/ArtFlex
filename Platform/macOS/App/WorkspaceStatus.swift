import Foundation

struct WorkspaceStatus: Equatable, Sendable {
    enum Kind: String, Sendable {
        case success
        case info
        case error
    }

    var kind: Kind
    var message: String
}
