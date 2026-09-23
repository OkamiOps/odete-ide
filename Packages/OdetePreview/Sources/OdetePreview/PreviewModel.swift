import Foundation
import Observation
import OdeteI18n
import UIKit

/// Uma linha do console do app do usuário (ou erro de página).
public struct ConsoleLine: Identifiable, Sendable, Hashable {
    public enum Level: String, Sendable { case log, info, warn, error }
    public var id: Int
    public var level: Level
    public var text: String
    public var file: String?
    public var line: Int?
}

/// Viewports que o preview simula.
public enum Viewport: String, CaseIterable, Sendable, Identifiable {
    case fill, phone, tablet, desktop, wide
    public var id: String {
        rawValue
    }

    public var width: CGFloat? {
        switch self {
        case .fill: nil
        case .phone: 390
        case .tablet: 820
        case .desktop: 1280
        case .wide: 1920
        }
    }

    /// Altura fixa, para os formatos que precisam de proporção e não só de largura.
    /// Nos de aparelho a altura segue o painel, que é o que se quer ao testar rolagem.
    public var height: CGFloat? {
        switch self {
        case .desktop: 720
        case .wide: 1080
        default: nil
        }
    }

    public var label: String {
        switch self {
        case .fill: tr("Livre")
        case .phone: tr("iPhone")
        case .tablet: tr("iPad")
        case .desktop: tr("Desktop 16:9")
        case .wide: tr("Full HD 16:9")
        }
    }

    public var symbol: String {
        switch self {
        case .fill: "rectangle"
        case .phone: "iphone"
        case .tablet: "ipad"
        case .desktop: "display"
        case .wide: "macwindow"
        }
    }

    /// Texto curto para a barra: "1280 × 720".
    public var medida: String? {
        guard let w = width else { return nil }
        guard let h = height else { return "\(Int(w)) pt" }
        return "\(Int(w)) × \(Int(h))"
    }
}

/// Estado do preview: URL, navegação, console e viewport.
@MainActor
@Observable
public final class PreviewModel {
    public let root: URL
    public var url: URL?
    public var title = ""
    public var loading = false
    public var canGoBack = false
    public var console: [ConsoleLine] = []
    public var consoleOpen = false
    public var viewport: Viewport = .fill
    /// Incrementa para pedir reload à view.
    public var reloadTick = 0
    public var navTick = 0
    public var backTick = 0
    /// Ligado pela PreviewView: tira um print da página.
    public var snapshotter: (@MainActor (@escaping @MainActor (UIImage?) -> Void) -> Void)?
    /// Um link que aponta para fora do projeto. O painel é o preview do que a pessoa
    /// está escrevendo, não um navegador: sair dali é sair para o Safari.
    public var pedidoExterno: URL?
    private var seq = 0

    public init(root: URL) {
        self.root = root
    }

    /// URL estática (sem servidor) para um arquivo do projeto.
    public func staticURL(_ path: String = "index.html") -> URL {
        URL(string: "\(StaticScheme.scheme)://\(StaticScheme.host)/\(path)")!
    }

    public var hasIndex: Bool {
        FileManager.default.fileExists(atPath: root.appending(path: "index.html").path)
    }

    public func go(_ u: URL?) {
        url = u; navTick += 1
        // Sem URL o painel mostra a tela de "nada rodando": não há página, e o erro da
        // página que estava ali (o servidor morreu) deixa de ser problema de agora.
        if u == nil {
            inicioDaPagina = seq
        }
    }

    public func reload() {
        reloadTick += 1
    }

    public func back() {
        backTick += 1
    }

    /// Sobe a cada linha que entra no console.
    ///
    /// Quem rola o console até o fim deve olhar isto, e não `console.count`: no teto de
    /// mil linhas cada linha nova tira uma velha, a contagem para de mudar e a rolagem
    /// parava junto — em silêncio, justo quando o app está falando muito.
    public private(set) var versaoDoConsole = 0

    public func log(_ level: ConsoleLine.Level, _ text: String, file: String? = nil, line: Int? = nil) {
        seq += 1
        console.append(ConsoleLine(id: seq, level: level, text: text, file: file, line: line))
        if console.count > 1000 {
            console.removeFirst(console.count - 1000)
        }
        versaoDoConsole &+= 1
    }

    /// O `id` da última linha do console antes da página que está carregada agora.
    ///
    /// O console é histórico, como no Safari ou no Chrome com "preserve log": sobrevive a
    /// recargas, e é bom que sobreviva — o erro de um segundo atrás continua lá para ser
    /// lido. Os problemas não. Contando o console inteiro, um erro de build que o dev
    /// server mostrou num overlay ficava no painel Problemas e na barra de status depois
    /// do conserto, com a página já recarregada e limpa, até alguém tocar em "Limpar
    /// console". Esta marca separa o que é da página de agora do que é história.
    public private(set) var inicioDaPagina = 0

    /// Os erros da página que está no painel agora — o que conta como problema.
    ///
    /// Todo lugar que conta erro de runtime (painel Problemas, barra de status, selo do
    /// console, as ferramentas do agente) lê daqui, para mostrar o mesmo número.
    public var errosDaPagina: [ConsoleLine] {
        console.filter { $0.id > inicioDaPagina && $0.level == .error }
    }

    public var errorCount: Int {
        errosDaPagina.count
    }

    /// Uma página nova entrou no painel: navegação, o botão de recarregar ou o
    /// `location.reload()` que o dev server manda depois de um build.
    ///
    /// Quem chama é a `PreviewView`, quando o WebKit confirma a navegação (`didCommit`) —
    /// e não o `reload()` daqui, porque a recarga do dev server acontece dentro da página
    /// e o modelo nunca fica sabendo dela por outro caminho. Se a página anterior escreveu
    /// algo no console, uma linha marca a troca, para o erro que ficou lá em cima não
    /// parecer da página de agora.
    public func paginaNova(_ u: URL?) {
        if let ultima = console.last, ultima.id > inicioDaPagina {
            log(.info, tr("navegou para %1$@", u?.absoluteString ?? "about:blank"))
        }
        inicioDaPagina = seq
    }

    public func clearConsole() {
        console.removeAll()
    }
}
