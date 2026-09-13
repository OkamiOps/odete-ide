import SwiftUI

/// Alça de redimensionamento entre painéis. `value` é a dimensão do painel que ela controla.
public struct Splitter: View {
    public enum Axis { case horizontal, vertical }
    @Environment(\.theme) private var theme
    @Binding var value: Double
    var axis: Axis
    var range: ClosedRange<Double>
    /// +1 quando arrastar para a direita/baixo aumenta `value`; -1 quando diminui.
    var direction: Double
    @State private var start: Double?
    @State private var hot = false

    public init(value: Binding<Double>, axis: Axis, range: ClosedRange<Double>, direction: Double = 1) {
        _value = value
        self.axis = axis
        self.range = range
        self.direction = direction
    }

    public var body: some View {
        ZStack {
            Rectangle().fill(theme.border)
                .frame(width: axis == .horizontal ? 1 : nil, height: axis == .vertical ? 1 : nil)
            Capsule()
                .fill(hot ? theme.accent : theme.borderStrong)
                .frame(width: axis == .horizontal ? 4 : 36, height: axis == .horizontal ? 36 : 4)
                .opacity(hot ? 1 : 0.6)
        }
        .frame(width: axis == .horizontal ? 12 : nil, height: axis == .vertical ? 12 : nil)
        .contentShape(Rectangle())
        .hoverEffect(.highlight)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { g in
                    if start == nil { start = value }
                    hot = true
                    let delta = axis == .horizontal ? g.translation.width : g.translation.height
                    value = min(max((start ?? value) + delta * direction, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in
                    start = nil
                    hot = false
                }
        )
        .accessibilityLabel("Redimensionar")
        .accessibilityAdjustableAction { d in
            let step: Double = d == .increment ? 24 : -24
            value = min(max(value + step, range.lowerBound), range.upperBound)
        }
    }
}
