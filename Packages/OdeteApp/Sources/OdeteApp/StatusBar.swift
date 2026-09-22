import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Barra de status do workspace: branch, problemas, posição do cursor, indentação, codificação, linguagem.
///
/// Medido digitando num arquivo de 60 linhas, a barra era a view mais cara do app: o
/// corpo dela aparecia em 43 amostras por tecla. Ela lia o texto e o cursor no corpo, e
/// montava as três versões (completa, média, mínima) a cada atualização — então a conta
/// de linha e coluna, que varria o arquivo do começo, rodava três vezes por tecla, e a
/// contagem de problemas, que lê o console do preview, também.
///
/// Agora cada pedaço é uma view própria que lê só o que mostra, e o que muda a cada tecla
/// mora em três folhas pequenas: a posição do cursor, o fim de linha e o problema da
/// linha. Uma tecla refaz essas folhas e mais nada. E só uma versão da barra é montada:
/// a largura de cada versão é medida por cópias escondidas que não leem nada que muda
/// com a tecla, e a barra escolhe a maior que cabe.
struct StatusBar: View {
    /// Quanto detalhe cabe.
    ///
    /// Não é um limiar fixo de largura: um limiar mantinha tudo e deixava cada rótulo virar
    /// reticências — "maste…", "sem pr…", "Ln 1, Co…". A escolha compara a largura que cada
    /// versão pede com a que existe.
    enum Nivel: CaseIterable {
        case completo, medio, minimo

        var roomy: Bool {
            self == .completo
        }
    }

    @State private var disponivel: CGFloat = 0
    @State private var larguras: [Nivel: CGFloat] = [:]

    /// A maior versão que cabe. Antes de medir, a completa — igual ao que era.
    var nivel: Nivel {
        Nivel.allCases.first { (larguras[$0] ?? 0) <= disponivel } ?? .minimo
    }

    var body: some View {
        LinhaDeStatus(nivel: nivel, medindo: false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { disponivel = $0 }
            .background(alignment: .topLeading) { medidas }
            .padding(.horizontal, Metrics.s2)
            .frame(height: 26)
            .font(OdeteFont.mono(11))
            .lineLimit(1)
            .clipped()
    }

    /// As três versões, escondidas e no tamanho que pedem. Não leem cursor nem texto: a
    /// posição do cursor entra como um molde da largura máxima dela, e o problema da linha
    /// fica de fora (ele ocupa a sobra, não entra na conta).
    var medidas: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Nivel.allCases, id: \.self) { n in
                LinhaDeStatus(nivel: n, medindo: true)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { larguras[n] = $0 }
            }
        }
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Uma versão da barra.
private struct LinhaDeStatus: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    let nivel: StatusBar.Nivel
    /// Cópia escondida que só mede: nada que muda a cada tecla entra nela.
    let medindo: Bool

    var body: some View {
        HStack(spacing: 2) {
            if ws.git.isRepo {
                Ramo()
            }
            Problemas(roomy: nivel.roomy)
            if ws.agent.running {
                BotaoDeStatus(symbol: "sparkles", text: tr("agente trabalhando"), tint: theme.accent) {
                    chrome.snapshot.agentVisible = true
                }
                .symbolEffect(.pulse)
            }
            if !ws.run.servers.isEmpty {
                BotaoDeStatus(
                    symbol: "bolt.horizontal.circle",
                    text: ws.run.servers.map { ":\($0.port)" }.joined(separator: " "),
                    tint: theme.ok
                ) {
                    chrome.snapshot.center = .preview
                }
                .help(tr("Servidores no ar · abrir preview"))
            }
            if !medindo, let path = ws.active, !ws.naoEhTexto.contains(path) {
                // Ocupa a sobra no lugar do espaçador: sem problema na linha, é só espaço.
                ProblemaDaLinha(path: path)
                    .padding(.leading, Metrics.s1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Spacer(minLength: Metrics.s2)
            }
            direita
            BotaoDeStatus(symbol: "gearshape", text: nil) { chrome.settingsOpen = true }
                .help(tr("Ajustes"))
        }
    }

    @ViewBuilder var direita: some View {
        @Bindable var chrome = chrome
        if let path = ws.active, ws.naoEhTexto.contains(path) {
            // Imagem, PDF, banco: linha do cursor, indentação e codificação descrevem
            // um editor que não está na tela. Um PNG anunciava "Ln 1, Col 1 · UTF-8 ·
            // LF · Texto". Sobra o que é do arquivo mesmo.
            if nivel.roomy, let m = medida(path) {
                RotuloDeStatus(text: m)
            }
            HStack(spacing: 5) {
                FileGlyph(path: path, size: 10)
                Text(extensao(path)).foregroundStyle(theme.fgMuted)
            }
            .padding(.horizontal, 8).frame(height: 22)
            .fixedSize()
        } else if let path = ws.active {
            if medindo {
                // A posição mais larga que a barra aceita mostrar sem apertar o resto.
                RotuloDeStatus(text: tr("Ln %1$@, Col %2$@", "000000", "0000"))
            } else {
                PosicaoDoCursorNaBarra(path: path)
            }
            if nivel != .minimo {
                Menu {
                    ForEach([2, 4, 8], id: \.self) { w in
                        Button { chrome.snapshot.editor.tabWidth = w } label: {
                            Label(
                                tr("%1$@ espaços", "\(w)"),
                                systemImage: w == chrome.snapshot.editor.tabWidth ? "checkmark" : ""
                            )
                        }
                    }
                    Divider()
                    Toggle(tr("Mostrar espaços"), isOn: $chrome.snapshot.editor.showWhitespace)
                    Toggle(tr("Guias de indentação"), isOn: $chrome.snapshot.editor.indentGuides)
                } label: {
                    RotuloDeStatus(text: nivel.roomy ? tr("Espaços: %1$@", "\(chrome.snapshot.editor.tabWidth)")
                        : "⇥\(chrome.snapshot.editor.tabWidth)")
                }
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
            }
            if nivel.roomy {
                BotaoDeStatus(text: "UTF-8") {}
                if medindo {
                    BotaoDeStatus(text: "CRLF") {}
                } else {
                    FimDeLinha(path: path)
                }
            }
            Button {
                ws.paletteOpen = true
                ws.paletteQuery = "@"
            } label: {
                HStack(spacing: 5) {
                    FileGlyph(path: path, size: 10)
                    Text(Language.detect(path: path).label).foregroundStyle(theme.fgMuted)
                }
                .padding(.horizontal, 8).frame(height: 22).contentShape(Capsule())
                .fixedSize()
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        }
    }

    /// "PNG", "PDF", "SQLITE" — o que o visualizador está mostrando.
    func extensao(_ path: String) -> String {
        let e = (path as NSString).pathExtension
        return e.isEmpty ? tr("binário") : e.uppercased()
    }

    func medida(_ path: String) -> String? {
        guard let u = try? ws.ops.url(path),
              let n = (try? FileManager.default.attributesOfItem(atPath: u.path)[.size]) as? Int
        else { return nil }
        return Tamanho.arquivo(n)
    }
}

/// O branch, com o asterisco de sujo e o quanto está à frente e atrás.
private struct Ramo: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme

    var body: some View {
        BotaoDeStatus(symbol: "arrow.triangle.branch", text: texto, tint: theme.accent) {
            chrome.snapshot.side = .git
            chrome.snapshot.sideOpen = true
        }
        .help(tr("Git · abrir painel"))
    }

    var texto: String {
        var s = ws.git.current?.name ?? ws.git.headName ?? tr("sem branch")
        if !ws.git.isClean {
            s += "*"
        }
        if let ab = ws.git.aheadBehind, ab.ahead > 0 || ab.behind > 0 {
            s += "  \(ab.ahead)↑ \(ab.behind)↓"
        }
        return s
    }
}

/// Erros e avisos de todas as fontes. Lê a contagem guardada, que só muda quando o número
/// muda — ver `WorkspaceModel.contagemDeProblemas`.
private struct Problemas: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    let roomy: Bool

    var body: some View {
        let c = ws.contagemDeProblemas
        BotaoDeStatus(
            symbol: c.erros > 0 ? "xmark.octagon" : c.avisos > 0 ? "exclamationmark.triangle" : "checkmark.circle",
            text: c.erros == 0 && c.avisos == 0 ? (roomy ? tr("sem problemas") : nil) : "\(c.erros) ⊗ \(c.avisos) △",
            tint: c.erros > 0 ? theme.danger : c.avisos > 0 ? theme.accent : theme.ok
        ) {
            abrirProblemas(chrome)
        }
        .help(tr("Problemas"))
    }
}

/// Abre o painel de Problemas na coluna lateral — o mesmo caminho do rail.
@MainActor
func abrirProblemas(_ chrome: ChromeState) {
    chrome.snapshot.side = .problems
    chrome.snapshot.sideOpen = true
}

/// "Ln 12, Col 5". Folha que muda a cada tecla e a cada movimento do cursor.
private struct PosicaoDoCursorNaBarra: View {
    @Environment(WorkspaceModel.self) private var ws
    let path: String

    var body: some View {
        let p = ws.posicaoDoCursor(em: path)
        BotaoDeStatus(text: tr("Ln %1$@, Col %2$@", "\(p.linha)", "\(p.coluna)")) {
            ws.paletteOpen = true
            ws.paletteQuery = "@"
        }
        .help(tr("Ir para símbolo"))
    }
}

/// LF ou CRLF, do mesmo mapa de linhas da posição do cursor.
private struct FimDeLinha: View {
    @Environment(WorkspaceModel.self) private var ws
    let path: String

    var body: some View {
        BotaoDeStatus(text: ws.usaCRLF(path) ? "CRLF" : "LF") {}
    }
}

/// O problema da linha do cursor, por extenso.
///
/// A contagem diz que há um erro; isto diz qual, sem tirar o olho do código nem abrir
/// painel. O primeiro erro da linha, ou o primeiro aviso quando não há erro. Tocar abre o
/// painel de Problemas, onde estão todos.
private struct ProblemaDaLinha: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    let path: String

    var body: some View {
        if let p = ws.problemaNaLinhaDoCursor(em: path) {
            let erro = p.severity == .error
            Button {
                abrirProblemas(chrome)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: erro ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(erro ? theme.danger : theme.accent)
                    Text(p.message)
                        .foregroundStyle(theme.fgMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            .frame(maxWidth: 420, alignment: .leading)
            .help(tr("Problema nesta linha · abrir Problemas"))
            .accessibilityLabel(tr("Problema nesta linha: %1$@", p.message))
        }
    }
}

/// Ícone e texto de um item da barra, sem ação. Nunca encolhe até virar reticências: a
/// barra escolhe uma versão com menos itens antes disso.
struct RotuloDeStatus: View {
    @Environment(\.theme) private var theme
    var symbol: String?
    var text: String?
    var tint: Color?

    init(symbol: String? = nil, text: String?, tint: Color? = nil) {
        self.symbol = symbol
        self.text = text
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint ?? theme.fgMuted)
            }
            if let text {
                Text(text).foregroundStyle(theme.fgMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Capsule())
        .fixedSize()
    }
}

/// Item da barra que responde ao toque.
struct BotaoDeStatus: View {
    var symbol: String?
    var text: String?
    var tint: Color?
    var action: () -> Void

    init(symbol: String? = nil, text: String?, tint: Color? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.text = text
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) { RotuloDeStatus(symbol: symbol, text: text, tint: tint) }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
    }
}
