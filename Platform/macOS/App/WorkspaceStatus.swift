import Foundation

struct WorkspaceStatus: Equatable, Sendable {
    enum Kind: String, Sendable {
        case success
        case info
        case error
    }

    var kind: Kind
    var message: String
    var shortcutLabel: String?

    init(kind: Kind, message: String, shortcutLabel: String? = nil) {
        self.kind = kind
        self.message = message
        self.shortcutLabel = shortcutLabel
    }
}
