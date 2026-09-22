import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI

/// Modo Diff do centro: fonte, arquivos e hunks com ações.
///
/// As linhas do diff são linhas da lista preguiçosa, uma a uma. Antes a lista preguiçosa
/// era de arquivos, e cada arquivo montava todas as suas linhas de uma vez — o diff de um
/// `package-lock.json` são dezenas de milhares de linhas, e todas viravam views antes do
/// primeiro quadro. Agora só se monta o que está perto da tela.
struct DiffPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var git: GitModel {
        ws.git
    }

    /// Binário não tem linha para contar. Somando zero por ele, um diff só de binários
    /// anunciava "+0 −0" — que se lê como "não mudou nada" bem em cima da mudança.
    var resumo: String {
        let texto = git.diff.files.filter { !$0.isBinary }
        guard !texto.isEmpty else { return git.diff.files.isEmpty ? "" : tr("binário") }
        return "+\(texto.reduce(0) { $0 + $1.additions })  −\(texto.reduce(0) { $0 + $1.deletions })"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    Button(tr("Tudo (HEAD → workdir)")) { git.setDiff(.headToWorkdir) }
                    Button(tr("Não staged (índice → workdir)")) { git.setDiff(.workdir) }
                    Button(tr("Staged (HEAD → índice)")) { git.setDiff(.index) }
                    if let a = git.compareA, let b = git.compareB {
                        Button(tr("Comparar A → B")) { git.setDiff(.commits(
                            a,
                            b
                        )) }
                    }
                } label: {
                    Label(sourceLabel, systemImage: "line.3.horizontal.decrease.circle").font(OdeteFont.ui(12))
                }
                .buttonStyle(.glass)
                if let p = git.diffPath {
                    Text(p).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted).lineLimit(1).truncationMode(.middle)
                    Button(tr("todos os arquivos")) { git.setDiff(git.diffSource) }.font(OdeteFont.ui(11))
                }
                Spacer()
                Text(resumo).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
            if !git.isRepo {
                ShellPanel(
                    "Diff",
                    symbol: "plus.forwardslash.minus",
                    phase: 2,
                    blurb: tr("Inicie um repositório no painel Git.")
                )
            } else if git.diff.files.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle").font(.system(size: 26, weight: .light))
                        .foregroundStyle(theme.fgSubtle)
                    Text(tr("sem diferenças")).font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let source = git.diffSource
                ScrollPane {
                    LazyVStack(spacing: 0) {
                        ForEach(LinhaDoDiff.linhas(de: git.diff.files)) { linha in
                            LinhaDoDiffView(linha: linha, source: source)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .background(theme.bg)
    }

    var sourceLabel: String {
        switch git.diffSource {
        case .headToWorkdir: tr("Tudo")
        case .workdir: tr("Não staged")
        case .index: tr("Staged")
        case let .commit(s): "commit \(s.prefix(7))"
        case let .commits(a, b): "\(a.prefix(7)) → \(b.prefix(7))"
        }
    }
}

/// Um arquivo só, como no histórico do arquivo: as mesmas linhas preguiçosas do modo Diff,
/// numa lista própria. Vai direto dentro de uma rolagem.
struct FileDiffView: View {
    var file: FileDiff
    var source: Repository.DiffSource

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(LinhaDoDiff.linhas(de: [file]).dropLast()) { linha in
                LinhaDoDiffView(linha: linha, source: source)
            }
        }
    }
}

/// Uma linha da lista do diff: o cabeçalho de um arquivo, o aviso de binário, o
/// cabeçalho de um hunk, uma linha de código ou o respiro entre dois arquivos.
struct LinhaDoDiff: Identifiable {
    enum Tipo {
        case arquivo
        case binario
        case hunk(Hunk)
        case codigo(DiffLine)
        case fim
    }

    let arquivo: FileDiff
    let tipo: Tipo
    let id: String
    /// É a última linha do cartão do arquivo — a que fecha os cantos de baixo.
    var ultima = false

    /// Achata os arquivos numa lista só, na ordem em que aparecem.
    static func linhas(de arquivos: [FileDiff]) -> [LinhaDoDiff] {
        var out: [LinhaDoDiff] = []
        for f in arquivos {
            out.append(LinhaDoDiff(arquivo: f, tipo: .arquivo, id: "\(f.path)#a"))
            if f.isBinary {
                out.append(LinhaDoDiff(arquivo: f, tipo: .binario, id: "\(f.path)#b"))
            }
            for (i, h) in f.hunks.enumerated() {
                out.append(LinhaDoDiff(arquivo: f, tipo: .hunk(h), id: "\(f.path)#\(i)"))
                for (j, l) in h.lines.enumerated() {
                    out.append(LinhaDoDiff(arquivo: f, tipo: .codigo(l), id: "\(f.path)#\(i)#\(j)"))
                }
            }
            out[out.count - 1].ultima = true
            out.append(LinhaDoDiff(arquivo: f, tipo: .fim, id: "\(f.path)#fim"))
        }
        return out
    }
}

/// Uma linha do diff, desenhada como parte do cartão do arquivo: as bordas laterais em
/// cada linha, os cantos de cima no cabeçalho e os de baixo na última.
struct LinhaDoDiffView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let linha: LinhaDoDiff
    var source: Repository.DiffSource

    var git: GitModel {
        ws.git
    }

    var file: FileDiff {
        linha.arquivo
    }

    var canStage: Bool {
        if case .workdir = source {
            return true
        }; if case .headToWorkdir = source {
            return true
        }; return false
    }

    var canUnstage: Bool {
        if case .index = source {
            return true
        }; return false
    }

    var body: some View {
        switch linha.tipo {
        case .fim:
            Color.clear.frame(height: 14)
        default:
            conteudo
                .background(theme.bg)
                .clipShape(forma)
                .overlay(forma.stroke(theme.border))
                // O traço de cima e de baixo só existe nas pontas do cartão; entre linhas
                // ele vira um fio duplo. A máscara corta o que sobra fora das laterais.
                .padding(.top, emCima ? 0 : -1)
                .padding(.bottom, linha.ultima ? 0 : -1)
                .clipped()
        }
    }

    var emCima: Bool {
        if case .arquivo = linha.tipo {
            return true
        }
        return false
    }

    var forma: UnevenRoundedRectangle {
        let r: CGFloat = 12
        return UnevenRoundedRectangle(
            topLeadingRadius: emCima ? r : 0,
            bottomLeadingRadius: linha.ultima ? r : 0,
            bottomTrailingRadius: linha.ultima ? r : 0,
            topTrailingRadius: emCima ? r : 0,
            style: .continuous
        )
    }

    @ViewBuilder var conteudo: some View {
        switch linha.tipo {
        case .arquivo:
            HStack(spacing: 8) {
                FileGlyph(path: file.path, size: 13)
                Text(file.path).font(OdeteFont.mono(12, weight: .medium)).foregroundStyle(theme.fg).lineLimit(1)
                    .truncationMode(.middle)
                if let old = file.oldPath {
                    Text("← \(old)").font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                }
                Spacer()
                if !file.isBinary {
                    Text("+\(file.additions)").font(OdeteFont.mono(11)).foregroundStyle(theme.ok)
                    Text("−\(file.deletions)").font(OdeteFont.mono(11)).foregroundStyle(theme.danger)
                }
                HeaderButton("doc.text", label: tr("Abrir")) { ws.openFile(file.path) }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .frame(maxWidth: .infinity)
            .background(theme.bgElevated)
        case .binario:
            Text(tr("arquivo binário")).font(OdeteFont.mono(11)).foregroundStyle(theme.fgSubtle).padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .hunk(h):
            HStack {
                Text(h.header).font(OdeteFont.mono(11)).foregroundStyle(theme.accent).lineLimit(1)
                Spacer()
                if canStage {
                    Button(tr("Stage hunk")) { git.stageHunk(h, in: file) }.font(OdeteFont.ui(11))
                    Button(tr("Descartar")) { git.discardHunk(h, in: file) }.font(OdeteFont.ui(11))
                        .foregroundStyle(theme.danger)
                }
                if canUnstage {
                    Button(tr("Unstage hunk")) { git.unstageHunk(h, in: file) }.font(OdeteFont.ui(11))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(theme.bgSubtle.opacity(0.6))
        case let .codigo(l):
            HStack(spacing: 0) {
                Text(l.oldLine.map(String.init) ?? "").font(OdeteFont.mono(11))
                    .foregroundStyle(theme.fgSubtle).frame(
                        width: 38,
                        alignment: .trailing
                    )
                Text(l.newLine.map(String.init) ?? "").font(OdeteFont.mono(11))
                    .foregroundStyle(theme.fgSubtle).frame(
                        width: 38,
                        alignment: .trailing
                    )
                Text(l.kind == .addition ? "+" : l.kind == .deletion ? "−" : " ").font(OdeteFont.mono(12))
                    .frame(width: 18)
                    .foregroundStyle(l.kind == .addition ? theme.ok : l.kind == .deletion ? theme
                        .danger : theme.fgSubtle)
                Text(l.text.isEmpty ? " " : l.text).font(OdeteFont.mono(12)).foregroundStyle(theme.fg)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 20)
            .background(l.kind == .addition ? theme.ok.opacity(0.10) : l.kind == .deletion ? theme.danger
                .opacity(0.10) : .clear)
        case .fim:
            EmptyView()
        }
    }
}
