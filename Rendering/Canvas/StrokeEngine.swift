import Foundation

struct StrokePoint: Sendable, Equatable {
    var x: Double
    var y: Double
    var pressure: Float
}

struct StrokeDescriptor: Sendable, Equatable {
    var tool: ToolKind
    var color: RGBAColor
    var brush: BrushSettings
    var points: [StrokePoint]
    var selectionShape: SelectionShape?
}

protocol StrokeEngine {
    func applyStroke(_ stroke: StrokeDescriptor, to layerID: LayerID)
}
