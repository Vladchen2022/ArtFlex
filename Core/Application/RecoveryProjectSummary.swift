import Foundation

struct RecoveryProjectSummary: Sendable {
    var name: String
    var modified: Date?
    var canvasSize: CanvasSize
    var previewPNGData: Data?
}
