import SwiftUI

struct ColorHueRingPickerView: View {
    let hue: Float
    let ringWidth: CGFloat
    let onUpdateHue: (Float) -> Void
    let onDragEnded: (Float) -> Void

    @State private var localHue: Float = 0
    @State private var isDragging = false

    private static let hueGradient = AngularGradient(
        stops: [
            .init(color: Color(red: 1, green: 0, blue: 0), location: 0),
            .init(color: Color(red: 1, green: 1, blue: 0), location: 1.0 / 6.0),
            .init(color: Color(red: 0, green: 1, blue: 0), location: 2.0 / 6.0),
            .init(color: Color(red: 0, green: 1, blue: 1), location: 3.0 / 6.0),
            .init(color: Color(red: 0, green: 0, blue: 1), location: 4.0 / 6.0),
            .init(color: Color(red: 1, green: 0, blue: 1), location: 5.0 / 6.0),
            .init(color: Color(red: 1, green: 0, blue: 0), location: 1)
        ],
        center: .center,
        startAngle: .degrees(0),
        endAngle: .degrees(360)
    )

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width, proxy.size.height)
            let effectiveRingWidth = min(ringWidth, diameter / 3)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let indicatorRadius = max(0, diameter / 2 - effectiveRingWidth / 2)
            let displayHue = isDragging ? localHue : ColorBlocksEngine.wrapHue(hue)
            let indicatorCenter = ColorHueWheelGeometry.indicatorCenter(
                hue: displayHue,
                center: center,
                radius: indicatorRadius
            )

            ZStack {
                Circle()
                    .stroke(
                        Self.hueGradient,
                        style: StrokeStyle(lineWidth: effectiveRingWidth, lineCap: .butt)
                    )
                    .padding(effectiveRingWidth / 2)

                Circle()
                    .fill(
                        Color(
                            hue: Double(ColorBlocksEngine.wrapHue(displayHue) / 360),
                            saturation: 1,
                            brightness: 1
                        )
                    )
                    .frame(width: 4, height: 4)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.7), radius: 0.6, x: 0, y: 0.5)
                    .position(indicatorCenter)
                    .allowsHitTesting(false)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging,
                           !ColorHueWheelGeometry.containsRingPoint(
                               value.location,
                               center: center,
                               diameter: diameter,
                               ringWidth: effectiveRingWidth
                           ) {
                            return
                        }

                        let newHue = ColorHueWheelGeometry.hue(at: value.location, center: center)
                        isDragging = true
                        localHue = newHue
                        onUpdateHue(newHue)
                    }
                    .onEnded { value in
                        guard isDragging else { return }
                        let newHue = ColorHueWheelGeometry.hue(at: value.location, center: center)
                        onDragEnded(newHue)
                        isDragging = false
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("色相环")
            .accessibilityValue("\(Int(displayHue.rounded()))度")
        }
    }
}
