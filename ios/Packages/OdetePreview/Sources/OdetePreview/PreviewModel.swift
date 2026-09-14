import Foundation
import Observation
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
        case .fill: "Livre"
        case .phone: "iPhone"
        case .tablet: "iPad"
        case .desktop: "Desktop 16:9"
        case .wide: "Full HD 16:9"
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
    }

    public func reload() {
        reloadTick += 1
    }

    public func back() {
        backTick += 1
    }

    public func log(_ level: ConsoleLine.Level, _ text: String, file: String? = nil, line: Int? = nil) {
        seq += 1
        console.append(ConsoleLine(id: seq, level: level, text: text, file: file, line: line))
        if console.count > 1000 {
            console.removeFirst(console.count - 1000)
        }
    }

    public var errorCount: Int {
        console.filter { $0.level == .error }.count
    }

    public func clearConsole() {
        console.removeAll()
    }
}
