import Foundation
import OdeteCore

/// Um pedido ao GitHub do projeto. Campos separados, e não um dicionário, para o
/// contrato ser o mesmo dos dois lados e atravessar ator sem cerimônia.
public struct GitHubPedido: Sendable {
    public enum Acao: String, Sendable, CaseIterable {
        case listPulls = "list_pulls", createPull = "create_pull", comment, mergePull = "merge_pull",
             closePull = "close_pull"

        /// Só listar não muda nada lá fora.
        public var escreve: Bool {
            self != .listPulls
        }
    }

    public var acao: Acao
    public var numero: Int?
    public var titulo: String?
    public var corpo: String?
    public var base: String?
    public var head: String?
    public var metodo: String?

    public init(
        acao: Acao,
        numero: Int? = nil,
        titulo: String? = nil,
        corpo: String? = nil,
        base: String? = nil,
        head: String? = nil,
        metodo: String? = nil
    ) {
        self.acao = acao
        self.numero = numero
        self.titulo = titulo
        self.corpo = corpo
        self.base = base
        self.head = head
        self.metodo = metodo
    }
}

/// O que as ferramentas precisam do app: arquivos, terminal e shell.
public protocol ToolHost: Sendable {
    var root: URL { get }
    func read(_ path: String) -> String?
    func write(_ path: String, _ text: String) throws
    func exists(_ path: String) -> Bool
    func list(_ path: String) -> [String]
    /// Todos os caminhos relativos (sem ruído), para a lista do sistema e o checkpoint.
    func allPaths() -> [String]
    func grep(_ pattern: String, in path: String?) -> String
    func terminalTail(_ n: Int) -> String
    func runShell(_ command: String) async -> String
    /// Abre o arquivo no editor (após patch); pode ser no-op.
    func reveal(_ path: String)
    /// Pull requests do repositório. Quem não tem GitHub responde o porquê.
    func github(_ pedido: GitHubPedido) async -> String
    /// Os problemas que o app já mostra na tela: lint e sintaxe dos arquivos abertos,
    /// erros do build, do Swift e do preview. Quem não tem nada disso devolve vazio.
    func problemas() -> [Problema]
    /// As últimas `n` linhas do console do preview.
    func consolePreview(_ n: Int) -> [LinhaDoConsole]
    /// Pasta em que o shell do agente está, relativa à raiz ("" é a raiz). Serve para
    /// saber em que arquivo um `rm x` vai mexer antes de ele rodar.
    func pastaDoShell() -> String
}

/// Implementação direta sobre FileManager. Serve para testes e como base para o app.
open class FileToolHost: ToolHost, @unchecked Sendable {
    public let root: URL
    public init(root: URL) {
        self.root = root
    }

    public func url(_ path: String) -> URL {
        root.appending(path: path).standardizedFileURL
    }

    public func inside(_ path: String) -> Bool {
        url(path).path.hasPrefix(root.standardizedFileURL.path)
    }

    /// Padrão como método da classe, e não como extensão do protocolo: em extensão a
    /// escolha é estática e a subclasse do app nunca era chamada.
    open func github(_: GitHubPedido) async -> String {
        "este host não fala com o GitHub"
    }

    public func read(_ path: String) -> String? {
        inside(path) ? try? String(contentsOf: url(path), encoding: .utf8) :
            nil
    }

    open func write(_ path: String, _ text: String) throws {
        guard inside(path) else { throw AgentError.transport("fora do projeto") }
        try FileManager.default.createDirectory(
            at: url(path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        HistoricoDeArquivos.guardar(url(path), raiz: root, origem: .agente)
        try text.write(to: url(path), atomically: true, encoding: .utf8)
    }

    public func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(path).path)
    }

    public func list(_ path: String) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: url(path).path) else { return [] }
        return items.filter { !Ignore.isNoisePath($0) }.sorted().map { n in
            var d: ObjCBool = false
            FileManager.default.fileExists(atPath: url(path).appending(path: n).path, isDirectory: &d)
            return n + (d.boolValue ? "/" : "")
        }
    }

    public func allPaths() -> [String] {
        var out: [String] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        else { return out }
        let base = root.standardizedFileURL.path + "/"
        while let u = e.nextObject() as? URL {
            let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
            if Ignore.isNoisePath(rel) || rel == ".odete" || rel.hasPrefix(".odete/") || rel == ".git" || rel
                .hasPrefix(".git/")
            {
                e.skipDescendants(); continue
            }
            if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                out.append(rel)
            }
        }
        return out.sorted()
    }

    public func grep(_ pattern: String, in path: String?) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return "regex inválida" }
        var lines: [String] = []
        let paths = (path?.isEmpty == false ? allPaths().filter { $0.hasPrefix(path!) } : allPaths())
        for p in paths {
            guard let text = read(p) else { continue }
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let s = String(line)
                if re
                    .firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) !=
                    nil
                {
                    lines.append("\(p):\(i + 1):\(s.prefix(200))")
                }
                if lines.count >= 200 {
                    return lines.joined(separator: "\n") + "\n… (limite de 200)"
                }
            }
        }
        return lines.isEmpty ? "(nada encontrado)" : lines.joined(separator: "\n")
    }

    open func terminalTail(_ n: Int) -> String {
        "(terminal vazio)"
    }

    open func runShell(_ command: String) async -> String {
        "shell indisponível"
    }

    open func reveal(_ path: String) {}

    open func problemas() -> [Problema] {
        []
    }

    open func consolePreview(_: Int) -> [LinhaDoConsole] {
        []
    }

    open func pastaDoShell() -> String {
        ""
    }
}
