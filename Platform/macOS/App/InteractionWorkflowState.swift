import Foundation

struct PaintingBlocker: Equatable {
    enum Action { case unlock, show, newLayer, rasterize }
    var message: String
    var action: Action
    var layerID: LayerID?
    var actionTitle: String {
        switch action { case .unlock: "解锁"; case .show: "显示图层"; case .newLayer: "新建绘画层"; case .rasterize: "栅格化图层" }
    }
}

struct SelectionRefinementDraft {
    let source: SelectionShape
    let generation: UInt64
    var kind: SelectionRefinementKind
    var radius = 16
    var preview: SelectionShape?
    var isComputing = false
    var showsOverlay = true
    var error: String?
}

extension SelectionRefinementKind {
    var title: String {
        switch self { case .invert: "反选"; case .feather: "羽化"; case .expand: "扩展"; case .contract: "收缩" }
    }
}

extension SelectionCombineMode {
    var title: String {
        switch self { case .replace: "新建"; case .add: "增选"; case .subtract: "减选"; case .intersect: "交集" }
    }
}
