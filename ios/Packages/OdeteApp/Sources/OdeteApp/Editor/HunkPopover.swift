import OdeteGit
import OdeteUI
import SwiftUI

struct PathRef: Identifiable, Hashable {
    var path: String
    var id: String {
        path
    }
}

struct HunkRef: Identifiable, Hashable {
    var path: String
    var line: Int
    var id: String {
        "\(path):\(line)"
    }
}

/// Popover do gutter: o hunk do git que contém a linha, com "Descartar".
struct HunkPopover: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    var ref: HunkRef

    var body: some View {
        let found = ws.hunk(at: ref.line, in: ref.path)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(found?.1.header ?? "Sem alteração aqui").font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
                    .lineLimit(1)
                Spacer()
                if found != nil {
                    Button(role: .destructive) {
                        ws.discardHunk(at: ref.line, in: ref.path)
                        dismiss()
                    } label: { Label("Descartar", systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
            .padding(.horizontal, 12).frame(height: 40)
            if let (_, h) = found {
                ScrollPane {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(h.lines) { l in
                            HStack(spacing: 8) {
                                Text(l.kind == .addition ? "+" : l.kind == .deletion ? "−" : " ")
                                    .font(OdeteFont.mono(11.5, weight: .bold)).frame(width: 12)
                                Text(l.text).font(OdeteFont.mono(11.5)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(l.kind == .addition ? theme.ok : l.kind == .deletion ? theme.danger : theme
                                .fgMuted)
                            .padding(.horizontal, 10).frame(height: 20)
                            .background(l.kind == .addition ? theme.ok.opacity(0.1) : l.kind == .deletion ? theme.danger
                                .opacity(0.1) : .clear)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 420)
        .background(theme.surface)
        .presentationCompactAdaptation(.popover)
    }
}
