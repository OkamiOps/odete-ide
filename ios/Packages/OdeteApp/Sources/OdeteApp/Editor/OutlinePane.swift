import OdeteCore
import OdeteUI
import SwiftUI

/// Esboço do arquivo ativo: símbolos por linha; toque revela no editor.
struct OutlinePane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var filter = ""

    var body: some View {
        let path = ws.active
        let items = path.flatMap { ws.outlines[$0] } ?? []
        let shown = filter.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(filter) }
        VStack(spacing: 0) {
            PaneHeader("Esboço", detail: path.map { ($0 as NSString).lastPathComponent } ?? "")
            if path == nil {
                EmptyState(
                    "list.bullet.indent",
                    title: "Nenhum arquivo aberto",
                    text: "Abra um arquivo para ver funções, classes e títulos."
                )
            } else if items.isEmpty {
                EmptyState(
                    "list.bullet.indent",
                    title: "Sem símbolos",
                    text: "Este arquivo não tem funções, classes ou títulos que a Odete reconheça."
                )
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(theme.fgSubtle)
                    TextField("filtrar", text: $filter).textFieldStyle(.plain).font(OdeteFont.ui(12.5))
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 10).frame(height: 32)
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, Metrics.s2).padding(.vertical, Metrics.s1)
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(shown) { it in
                            Button { ws.open(path!, line: it.line) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: it.kind.symbol).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(color(it.kind)).frame(width: 16)
                                    Text(it.name).font(OdeteFont.ui(12.5)).foregroundStyle(theme.fg).lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text("\(it.line)").font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                                }
                                .padding(.leading, CGFloat(it.level) * 12 + 10).padding(.trailing, 10)
                                .frame(height: 30)
                                .background(
                                    isCurrent(it, in: items) ? theme.glassTint : .clear,
                                    in: RoundedRectangle(cornerRadius: Metrics.rControl, style: .continuous)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Metrics.s1).padding(.bottom, Metrics.s3)
                }
            }
        }
        .background(theme.surface)
    }

    /// O símbolo cujo bloco contém o cursor: o último que começa antes da linha do cursor.
    func isCurrent(_ it: OutlineItem, in items: [OutlineItem]) -> Bool {
        guard let path = ws.active else { return false }
        let line = Lint.position(of: ws.cursorOffset, in: ws.text(for: path)).0
        let before = items.filter { $0.line <= line }
        return before.last?.id == it.id
    }

    func color(_ k: OutlineItem.Kind) -> Color {
        switch k {
        case .function, .export: Color(hex: theme.palette.syntax.function)
        case .class, .struct, .enum, .protocol: Color(hex: theme.palette.syntax.type)
        case .variable, .property, .key: Color(hex: theme.palette.syntax.keyword)
        case .heading, .selector: theme.accent
        }
    }
}
