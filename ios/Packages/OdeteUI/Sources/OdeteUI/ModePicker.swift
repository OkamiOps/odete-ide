import OdeteCore
import SwiftUI

/// Seletor Código / Diff / Dois / Split / Preview, em vidro.
public struct ModePicker: View {
    @Environment(\.theme) private var theme
    @Binding var mode: CenterMode
    @Namespace private var ns

    public init(mode: Binding<CenterMode>) { _mode = mode }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(CenterMode.allCases, id: \.self) { m in
                Button {
                    withAnimation(.snappy(duration: 0.22)) { mode = m }
                } label: {
                    Text(m.label)
                        .font(OdeteFont.ui(12, weight: mode == m ? .semibold : .regular))
                        .foregroundStyle(mode == m ? theme.bg : theme.fgMuted)
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .background {
                            if mode == m {
                                Capsule().fill(theme.fg).matchedGeometryEffect(id: "on", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular, in: Capsule())
    }
}
