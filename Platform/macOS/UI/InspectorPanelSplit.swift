import AppKit
import SwiftUI

/// Layout-only policy. Resizing a window clamps the displayed height, never the
/// stored preference, so returning to a larger window restores the user's split.
struct InspectorSplitLayout {
    static let dividerHeight: CGFloat = 18
    static let minimumLayerHeight: CGFloat = 264
    let parameterHeight: CGFloat
    let layerHeight: CGFloat
    let parameterRange: ClosedRange<CGFloat>

    init(availableHeight: CGFloat, contentHeight: CGFloat, preferredHeight: Double) {
        let available = max(0, availableHeight.isFinite ? availableHeight : 0)
        let usable = max(0, available - Self.dividerHeight)
        let natural = max(60, contentHeight.isFinite ? contentHeight : 320)
        let layerReserve = min(Self.minimumLayerHeight, usable * 0.7)
        let upper = min(natural, max(0, usable - layerReserve))
        let lower = min(120, upper)
        parameterRange = lower...upper
        let requested = preferredHeight.isFinite && preferredHeight > 0
            ? CGFloat(preferredHeight) : min(natural, 340)
        parameterHeight = min(max(requested, lower), upper)
        layerHeight = usable - parameterHeight
    }

    func constrainedHeight(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return parameterHeight }
        return min(max(height, parameterRange.lowerBound), parameterRange.upperBound)
    }

    static func previewPanelHeight(contentHeight: CGFloat) -> CGFloat {
        guard contentHeight.isFinite else { return 264 }
        return min(264, max(160, contentHeight - 580))
    }
}

struct InspectorPanelSplit<Parameters: View, Layers: View>: View {
    @AppStorage private var preferredHeight: Double
    @GestureState private var dragOffset: CGFloat = 0
    let contentHeight: CGFloat
    let parameters: Parameters
    let layers: Layers

    init(preferenceKey: String, contentHeight: CGFloat, @ViewBuilder parameters: () -> Parameters, @ViewBuilder layers: () -> Layers) {
        _preferredHeight = AppStorage(wrappedValue: 0, preferenceKey)
        self.contentHeight = contentHeight
        self.parameters = parameters()
        self.layers = layers()
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = InspectorSplitLayout(
                availableHeight: proxy.size.height, contentHeight: contentHeight,
                preferredHeight: preferredHeight
            )
            let displayedHeight = layout.constrainedHeight(layout.parameterHeight + dragOffset)
            VStack(spacing: 0) {
                parameters.frame(height: displayedHeight)
                Capsule()
                    .fill(Color.white.opacity(dragOffset == 0 ? 0.28 : 0.65))
                    .frame(width: 36, height: 3)
                    .frame(maxWidth: .infinity)
                    .frame(height: InspectorSplitLayout.dividerHeight)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        (hovering ? NSCursor.resizeUpDown : NSCursor.arrow).set()
                    }
                    .gesture(DragGesture(coordinateSpace: .named("inspectorSplit"))
                        .updating($dragOffset) { value, state, _ in state = value.translation.height }
                        .onEnded { value in
                            preferredHeight = Double(layout.constrainedHeight(layout.parameterHeight + value.translation.height))
                        })
                    .onTapGesture(count: 2) { preferredHeight = 0 }
                    .help("上下拖动分配参数与图层空间；双击恢复自动分配")
                    .accessibilityElement()
                    .accessibilityLabel("参数与图层分隔条")
                    .accessibilityValue("参数区域 \(Int(displayedHeight)) 点")
                    .accessibilityAdjustableAction { direction in
                        let delta: CGFloat = direction == .increment ? 20 : -20
                        preferredHeight = Double(layout.constrainedHeight(layout.parameterHeight + delta))
                    }
                    .accessibilityAction(named: "恢复自动分配") { preferredHeight = 0 }
                layers.frame(height: max(0, proxy.size.height - InspectorSplitLayout.dividerHeight - displayedHeight))
            }
            .coordinateSpace(name: "inspectorSplit")
        }
    }
}
