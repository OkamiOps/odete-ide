import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Bloco de conflito: `<<<<<<< ours … ======= … >>>>>>> theirs`.
struct ConflictBlock: Identifiable {
    var id: Int
    var before: [String]
    var ours: [String]
    var theirs: [String]
    var oursLabel: String
    var theirsLabel: String
}

enum ConflictParser {
    static func parse(_ text: String) -> (blocks: [ConflictBlock], tail: [String])? {
        var blocks: [ConflictBlock] = []
        var before: [String] = []
        var ours: [String] = [], theirs: [String] = []
        var state = 0
        var oursLabel = "meu", theirsLabel = "deles"
        var found = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            switch state {
            case 0 where line.hasPrefix("<<<<<<<"):
                state = 1; found = true; ours = []; theirs = []
                oursLabel = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
            case 1 where line.hasPrefix("======="): state = 2
            case 2 where line.hasPrefix(">>>>>>>"):
                theirsLabel = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
                blocks.append(ConflictBlock(
                    id: blocks.count,
                    before: before,
                    ours: ours,
                    theirs: theirs,
                    oursLabel: oursLabel,
                    theirsLabel: theirsLabel
                ))
                before = []; state = 0
            case 0: before.append(line)
            case 1: ours.append(line)
            default: theirs.append(line)
            }
        }
        return found ? (blocks, before) : nil
    }

    static func hasMarkers(_ text: String) -> Bool {
        parse(text) != nil
    }
}

/// Resolve conflitos bloco a bloco.
struct ConflictView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var path: String
    @State private var choices: [Int: [String]] = [:]

    var text: String {
        ws.text(for: path)
    }

    var parsed: (blocks: [ConflictBlock], tail: [String])? {
        ConflictParser.parse(text)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
                Text(tr("Conflito em %1$@", "\(path)")).font(OdeteFont.ui(13, weight: .medium))
                    .foregroundStyle(theme.fg)
                Spacer()
                Button(tr("Editar como texto")) { ws.forceTextEdit.insert(path) }.font(OdeteFont.ui(12))
                Button { apply() } label: { Label(tr("Marcar resolvido"), systemImage: "checkmark") }
                    .buttonStyle(.glassProminent)
                    .disabled(parsed.map { choices.count < $0.blocks.count } ?? true)
            }
            .padding(.horizontal, 12)
            .frame(height: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            ScrollPane {
                if let p = parsed {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(p.blocks) { b in
                            context(b.before)
                            block(b)
                        }
                        context(p.tail)
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.bg)
    }

    func context(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.suffix(6).enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : l).font(OdeteFont.mono(12)).foregroundStyle(theme.fgSubtle).lineLimit(1)
            }
        }
    }

    func block(_ b: ConflictBlock) -> some View {
        let chosen = choices[b.id]
        return VStack(alignment: .leading, spacing: 0) {
            side(tr("Meu (%1$@)", b.oursLabel), b.ours, color: theme.accent, on: chosen == b.ours) {
                choices[b.id] = b.ours
            }
            Rectangle().fill(theme.border).frame(height: 1)
            side(tr("Deles (%1$@)", b.theirsLabel), b.theirs, color: theme.ok, on: chosen == b.theirs) {
                choices[b.id] = b.theirs
            }
            HStack(spacing: 8) {
                Button(tr("Ambos (meu, deles)")) { choices[b.id] = b.ours + b.theirs }.font(OdeteFont.ui(11))
                Button(tr("Ambos (deles, meu)")) { choices[b.id] = b.theirs + b.ours }.font(OdeteFont.ui(11))
                Spacer()
                if chosen !=
                    nil
                {
                    Label(tr("escolhido"), systemImage: "checkmark.circle.fill").font(OdeteFont.ui(11))
                        .foregroundStyle(theme.ok)
                }
            }
            .padding(8)
            .background(theme.bgSubtle.opacity(0.5))
        }
        .background(theme.bgElevated)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(chosen == nil ? theme.danger.opacity(0.6) : theme.border))
    }

    func side(_ title: String, _ lines: [String], color: Color, on: Bool, pick: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(OdeteFont.ui(11, weight: .medium)).foregroundStyle(color)
                Spacer()
                Button(on ? tr("escolhido") : tr("manter este")) { pick() }.font(OdeteFont.ui(11)).buttonStyle(.glass)
            }
            .padding(.horizontal, 10).frame(height: 32)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                Text(l.isEmpty ? " " : l).font(OdeteFont.mono(12)).foregroundStyle(theme.fg).lineLimit(1)
                    .padding(.horizontal, 10)
            }
            .padding(.bottom, 6)
        }
        .background(on ? color.opacity(0.10) : .clear)
    }

    func apply() {
        guard let p = parsed else { return }
        var out: [String] = []
        for b in p.blocks {
            out += b.before
            out += choices[b.id] ?? b.ours
        }
        out += p.tail
        let text = out.joined(separator: "\n")
        ws.setText(text, for: path)
        ws.save(path)
        ws.git.resolve(path: path, contents: text)
        choices = [:]
    }
}
