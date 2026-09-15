import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// Blame: quem escreveu cada linha. Uma faixa colorida por commit à esquerda, a ficha do
/// commit só na primeira linha do trecho e, ao tocar, o commit inteiro no alto.
struct BlameSheet: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    var path: String
    @State private var hunks: [BlameHunk] = []
    @State private var loading = true
    @State private var error: String?
    @State private var escolhido: String?

    /// Coluna do autor: no iPhone só cabe a faixa e o sha.
    var largura: CGFloat {
        sizeClass == .compact ? 96 : 200
    }

    var body: some View {
        let linhas = ws.text(for: path).components(separatedBy: "\n")
        NavigationStack {
            VStack(spacing: 0) {
                if let h = selecionado {
                    ficha(h)
                }
                Group {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error {
                        EmptyState("person.text.rectangle", title: tr("Sem blame"), text: error)
                    } else {
                        corpo(linhas)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Fechar")) { dismiss() } }
                ToolbarItem(placement: .principal) { Titulo(path: path, detalhe: tr("Blame")) }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button(tr("Histórico"), systemImage: "clock.arrow.circlepath") {
                            ws.historyPath = path
                            dismiss()
                        }
                        if let h = selecionado, !h.isUncommitted {
                            Button(tr("Copiar sha"), systemImage: "number") { UIPasteboard.general.string = h.sha }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel(tr("Mais"))
                }
            }
            .task { await load() }
        }
        .presentationDetents([.large])
        .presentationSizing(.page)
    }

    var selecionado: BlameHunk? {
        escolhido.flatMap { id in hunks.first { $0.sha == id } }
    }

    /// Ficha do commit escolhido. É onde a mensagem aparece: antes ela só existia no
    /// `help`, que num iPad ninguém vê.
    func ficha(_ h: BlameHunk) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(cor(h)).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(h.isUncommitted ? tr("Alterações locais, ainda sem commit") : h.summary)
                    .font(.subheadline.weight(.medium)).foregroundStyle(theme.fg).lineLimit(2)
                HStack(spacing: 6) {
                    if !h.isUncommitted {
                        Text(h.short).font(OdeteFont.mono(10)).foregroundStyle(theme.accent)
                        Text(h.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        Text(h.date.noIdioma(date: .abbreviated, time: .shortened))
                            .font(.caption2).foregroundStyle(theme.fgSubtle)
                    }
                }
            }
            Spacer(minLength: 8)
            Button { escolhido = nil } label: {
                Image(systemName: "xmark").font(.caption.bold()).foregroundStyle(theme.fgMuted)
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Fechar o commit"))
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    func corpo(_ linhas: [String]) -> some View {
        ScrollPane([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunks) { h in
                    ForEach(0 ..< h.lines, id: \.self) { i in
                        linha(h, i, linhas)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    func linha(_ h: BlameHunk, _ i: Int, _ linhas: [String]) -> some View {
        let n = h.startLine + i
        let aceso = escolhido == h.sha
        return Button { escolhido = aceso ? nil : h.sha } label: {
            HStack(spacing: 0) {
                Rectangle().fill(cor(h)).frame(width: 3)
                Group {
                    if i == 0 {
                        assinatura(h)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: largura, alignment: .leading)
                .padding(.leading, 8)
                Text("\(n)").font(OdeteFont.mono(10.5)).foregroundStyle(theme.fgSubtle)
                    .frame(width: 40, alignment: .trailing).padding(.trailing, 10)
                Text(linhas.indices.contains(n - 1) ? linhas[n - 1] : "")
                    .font(OdeteFont.mono(11.5)).foregroundStyle(theme.fg).lineLimit(1)
                Spacer(minLength: 20)
            }
            .frame(height: 20)
            .background(aceso ? cor(h).opacity(0.12) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func assinatura(_ h: BlameHunk) -> some View {
        HStack(spacing: 6) {
            Text(h.isUncommitted ? "local" : h.short)
                .font(OdeteFont.mono(10)).foregroundStyle(h.isUncommitted ? theme.ok : theme.accent)
            if sizeClass != .compact {
                Text(h.isUncommitted ? tr("sem commit") : h.author)
                    .font(.caption2).foregroundStyle(theme.fgMuted).lineLimit(1)
                Spacer(minLength: 4)
                if !h.isUncommitted {
                    Text(h.date.noIdioma(.dateTime.day().month(.abbreviated)))
                        .font(.caption2).foregroundStyle(theme.fgSubtle)
                }
            }
        }
        .padding(.trailing, 8)
    }

    /// Cor estável por commit. `hashValue` não serve: a semente muda a cada execução e o
    /// blame trocava de cores toda vez que o app abria.
    func cor(_ h: BlameHunk) -> Color {
        if h.isUncommitted {
            return theme.ok
        }
        var soma = 0
        for b in h.sha.utf8.prefix(8) {
            soma = (soma &* 31 &+ Int(b)) % 3600
        }
        return Color(hue: Double(soma) / 3600, saturation: theme.dark ? 0.45 : 0.55, brightness: theme.dark ? 0.8 : 0.7)
    }

    func load() async {
        guard let repo = ws.git.repo
        else { error = tr("Este projeto não é um repositório git."); loading = false; return }
        do {
            hunks = try await repo.blame(path: path)
            if hunks.isEmpty {
                error = tr("Arquivo ainda sem commits.")
            }
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}
