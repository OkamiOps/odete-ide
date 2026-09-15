import OdeteAgent
import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Patch com diff por hunk e ações.
struct PatchCard: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let agent: AgentModel
    let patch: Patch
    @State private var open = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button { ws.openFile(patch.path) } label: {
                    HStack(spacing: 6) {
                        FileGlyph(path: patch.path, size: 12)
                        Text(patch.path).font(OdeteFont.mono(12, weight: .medium)).foregroundStyle(theme.fg)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .buttonStyle(.plain)
                HStack(spacing: 5) {
                    Text("+\(patch.additions)").foregroundStyle(theme.ok)
                    Text("−\(patch.deletions)").foregroundStyle(theme.danger)
                }
                .font(.caption.weight(.medium)).monospacedDigit().fixedSize()
                Spacer(minLength: 6)
                statusView
            }
            if open, patch.status == .pending {
                ForEach(patch.hunks) { h in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("@@ \(h.beforeStart) → \(h.afterStart)").font(OdeteFont.mono(10))
                                .foregroundStyle(theme.fgSubtle)
                            Spacer()
                            if patch.hunks.count > 1 {
                                Button(tr("Aceitar hunk")) { agent.acceptHunk(patch, h.id) }.font(.caption)
                                    .buttonStyle(.plain).foregroundStyle(theme.accent)
                            }
                        }
                        .padding(.vertical, 3)
                        ForEach(Array(h.lines.enumerated()), id: \.offset) { _, l in diffLine(l) }
                    }
                }
            }
        }
        .padding(12)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder var statusView: some View {
        switch patch.status {
        case .pending:
            Button { agent.reject(patch) } label: { Image(systemName: "xmark").font(.system(size: 11, weight: .bold)) }
                .buttonStyle(.glass).accessibilityLabel(tr("Rejeitar"))
            Button { agent.accept(patch) } label: {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
            }.buttonStyle(.glassProminent)
                .accessibilityLabel(tr("Aceitar"))
        case .accepted:
            Text(tr("aceito")).font(.caption).foregroundStyle(theme.ok)
            Button(tr("desfazer")) { agent.undoPatch(patch) }.font(.caption).buttonStyle(.plain)
                .foregroundStyle(theme.fgSubtle)
        case .rejected: Text(tr("rejeitado")).font(.caption).foregroundStyle(.secondary)
        case .undone: Text(tr("desfeito")).font(.caption).foregroundStyle(.secondary)
        }
    }

    func diffLine(_ l: Hunk.Line) -> some View {
        let (sign, text, color, bg): (String, String, Color, Color) = switch l {
        case let .context(s): (" ", s, theme.fgMuted, .clear)
        case let .removed(s): ("-", s, theme.danger, theme.danger.opacity(0.10))
        case let .added(s): ("+", s, theme.ok, theme.ok.opacity(0.10))
        }
        return Text(sign + " " + text).font(OdeteFont.mono(10.5)).foregroundStyle(color).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4).background(bg)
    }
}
