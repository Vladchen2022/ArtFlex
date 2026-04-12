import SwiftUI
import Combine

/// 🚀 高性能滑块包装器
/// 解决频繁更新导致的卡顿问题，通过以下优化：
/// 1. 拖动时使用本地状态，避免触发 ViewModel 更新
/// 2. 支持实时预览（可选）
/// 3. 仅在拖动结束时提交最终值
/// 4. 节流更新频率，避免过度渲染
struct ThrottledSlider: View {
    let title: String
    let valueText: (Double) -> String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onValueChanged: (Double) -> Void
    let enableLivePreview: Bool
    
    @State private var localValue: Double
    @State private var isEditing = false
    @State private var lastUpdateTime: Date = .distantPast
    
    // 节流间隔：拖动时最多每 16ms (60fps) 更新一次
    private let throttleInterval: TimeInterval = 0.016
    
    init(
        title: String,
        valueText: @escaping (Double) -> String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        enableLivePreview: Bool = false,
        onValueChanged: @escaping (Double) -> Void
    ) {
        self.title = title
        self.valueText = valueText
        self._value = value
        self.range = range
        self.enableLivePreview = enableLivePreview
        self.onValueChanged = onValueChanged
        self._localValue = State(initialValue: value.wrappedValue)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.84))
                .frame(width: 44, alignment: .leading)
            
            Slider(
                value: $localValue,
                in: range,
                onEditingChanged: handleEditingChanged
            )
            .onChange(of: localValue) { newValue in
                handleValueChanged(newValue)
            }
            
            Text(valueText(localValue))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(width: 48, alignment: .trailing)
        }
        .onChange(of: value) { newValue in
            // 外部值变化时同步（例如撤销/重做）
            if !isEditing {
                localValue = newValue
            }
        }
    }
    
    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing
        
        if editing {
            // 开始拖动：记录初始值
            localValue = value
        } else {
            // 结束拖动：提交最终值
            commitValue(localValue)
        }
    }
    
    private func handleValueChanged(_ newValue: Double) {
        guard isEditing else { return }
        
        if enableLivePreview {
            // 启用实时预览时，使用节流更新
            let now = Date()
            if now.timeIntervalSince(lastUpdateTime) >= throttleInterval {
                lastUpdateTime = now
                commitValue(newValue)
            }
        }
        // 不启用实时预览时，只更新本地显示，不触发回调
    }
    
    private func commitValue(_ newValue: Double) {
        value = newValue
        onValueChanged(newValue)
    }
}

/// 🚀 优化的紧凑型滑块（用于 RightInspectorView）
struct OptimizedCompactSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void
    
    @State private var localValue: Double
    @State private var isEditing = false
    
    init(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onCommit: @escaping (Double) -> Void = { _ in }
    ) {
        self.title = title
        self.valueText = valueText
        self._value = value
        self.range = range
        self.onCommit = onCommit
        self._localValue = State(initialValue: value.wrappedValue)
    }
    
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.84))
                .frame(width: 44, alignment: .leading)
            
            Slider(
                value: $localValue,
                in: range,
                onEditingChanged: handleEditingChanged
            )
            
            Text(valueText)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.96))
                .frame(width: 48, alignment: .trailing)
        }
        .onChange(of: value) { newValue in
            // 外部值变化时同步（撤销/重做等）
            if !isEditing {
                localValue = newValue
            }
        }
    }
    
    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing

        if editing {
            // 开始拖动时同步外部值
            localValue = value
        } else {
            // 结束拖动时无条件提交
            onCommit(localValue)
        }
    }
}

/// 🚀 优化的标签型滑块（用于弹出窗口）
struct OptimizedLabeledSlider: View {
    let title: String
    let valueText: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let onCommit: (Double) -> Void
    
    @State private var localValue: Double
    @State private var isEditing = false
    
    init(
        title: String,
        valueText: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        onCommit: @escaping (Double) -> Void = { _ in }
    ) {
        self.title = title
        self.valueText = valueText
        self._value = value
        self.range = range
        self.onCommit = onCommit
        self._localValue = State(initialValue: value.wrappedValue)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .foregroundStyle(Color.white.opacity(0.84))
                Spacer()
                Text(valueText)
                    .foregroundStyle(Color.white.opacity(0.96))
            }
            .font(.system(size: 11, weight: .semibold))
            
            Slider(
                value: $localValue,
                in: range,
                onEditingChanged: handleEditingChanged
            )
        }
        .onChange(of: value) { newValue in
            if !isEditing {
                localValue = newValue
            }
        }
    }
    
    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing

        if editing {
            localValue = value
        } else {
            onCommit(localValue)
        }
    }
}

// MARK: - 图层透明度专用优化滑块

/// 图层透明度滑块：需要实时预览
struct LayerOpacitySlider: View {
    let layer: LayerRecord
    let onPreview: (Float) -> Void
    let onCommit: (Float) -> Void
    
    @State private var localOpacity: Float
    @State private var isEditing = false
    @State private var lastUpdateTime: Date = .distantPast
    private let throttleInterval: TimeInterval = 0.033 // ~30fps for preview
    
    init(
        layer: LayerRecord,
        onPreview: @escaping (Float) -> Void,
        onCommit: @escaping (Float) -> Void
    ) {
        self.layer = layer
        self.onPreview = onPreview
        self.onCommit = onCommit
        self._localOpacity = State(initialValue: layer.opacity)
    }
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "drop.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.white.opacity(0.48))
                .frame(width: 12)
            
            Slider(
                value: Binding(
                    get: { Double(localOpacity) },
                    set: { localOpacity = Float($0) }
                ),
                in: 0...1,
                onEditingChanged: handleEditingChanged
            )
            .onChange(of: localOpacity) { newValue in
                handleOpacityChanged(newValue)
            }
            
            Text("\(Int(localOpacity * 100))%")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Color.white.opacity(0.68))
                .frame(width: 36, alignment: .trailing)
        }
        .onChange(of: layer.opacity) { newValue in
            if !isEditing {
                localOpacity = newValue
            }
        }
    }
    
    private func handleEditingChanged(_ editing: Bool) {
        isEditing = editing
        
        if editing {
            localOpacity = layer.opacity
        } else {
            // 拖动结束时提交最终值
            onCommit(localOpacity)
        }
    }
    
    private func handleOpacityChanged(_ newValue: Float) {
        guard isEditing else { return }
        
        // 使用节流更新预览
        let now = Date()
        if now.timeIntervalSince(lastUpdateTime) >= throttleInterval {
            lastUpdateTime = now
            onPreview(newValue)
        }
    }
}
