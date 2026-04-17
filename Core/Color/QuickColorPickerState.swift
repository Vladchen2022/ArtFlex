import Foundation

struct QuickColorPickerState: Equatable {
    var anchorPoint: CanvasPoint
    var panel: ColorPanelState
    var recentBrushSelectionCount: Int = 0
    var recentBrushSelectionLimit: Int = 0
    var recentBrushOpacity: Float = 1
    var recentBrushBrightness: Float = 0
    var recentBrushSaturation: Float = 0
}
