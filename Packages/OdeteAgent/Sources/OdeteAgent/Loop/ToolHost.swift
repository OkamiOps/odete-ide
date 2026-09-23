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
    /// Tamanho em bytes, sem ler o conteúdo; `nil` se não existe ou está fora do projeto.
    func tamanho(_ path: String) -> Int?
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

    /// O caminho está dentro do projeto — de verdade, com os links seguidos.
    ///
    /// Comparava o prefixo do texto, sem a barra: com o projeto em `…/meu-app`,
    /// `../meu-app-2/.env` virava `…/meu-app-2/.env`, que começa com `…/meu-app` e
    /// passava. E um link simbólico dentro do projeto apontando para fora também passava,
    /// porque o texto do caminho não sai do lugar. Agora os dois lados são resolvidos
    /// (links inclusive) e a comparação é com `raiz + "/"`.
    public func inside(_ path: String) -> Bool {
        guard let raiz = Self.caminhoReal(root.standardizedFileURL.path),
              let alvo = Self.caminhoReal(url(path).path) else { return false }
        return alvo == raiz || alvo.hasPrefix(raiz + "/")
    }

    /// O caminho com os links resolvidos, mesmo que o fim dele ainda não exista (um
    /// arquivo que o agente vai criar): resolve o maior pedaço que existe e cola o resto.
    ///
    /// Link quebrado dá `nil`: não há como saber para onde a escrita iria.
    static func caminhoReal(_ caminho: String) -> String? {
        var atual = caminho
        var sobra: [String] = []
        while true {
            if let r = realpath(atual, nil) {
                defer { free(r) }
                var base = String(cString: r)
                for parte in sobra.reversed() {
                    base = (base as NSString).appendingPathComponent(parte)
                }
                return base
            }
            // Existe (como link) e mesmo assim não resolve: link quebrado ou sem acesso.
            var st = stat()
            if lstat(atual, &st) == 0 {
                return nil
            }
            let pai = (atual as NSString).deletingLastPathComponent
            guard !pai.isEmpty, pai != atual else { return nil }
            sobra.append((atual as NSString).lastPathComponent)
            atual = pai
        }
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
        inside(path) && FileManager.default.fileExists(atPath: url(path).path)
    }

    public func tamanho(_ path: String) -> Int? {
        guard inside(path) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url(path).path)[.size]) as? Int
    }

    /// `list_dir("..")` listava a pasta de cima do projeto.
    public func list(_ path: String) -> [String] {
        guard inside(path),
              let items = try? FileManager.default.contentsOfDirectory(atPath: url(path).path) else { return [] }
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
            guard let text = textoParaBusca(p) else { continue }
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

    /// Acima disto o grep pula o arquivo: um bundle de 30 MB ou um vídeo não têm linha
    /// que valha a pena, e lê-los inteiros para a memória a cada busca travava o turno.
    public static let tetoDoGrep = 2_000_000

    /// O texto de `p` para o grep, ou `nil` se é grande demais ou binário.
    ///
    /// Binário é quem tem byte zero no começo — a mesma leitura do `grep` de verdade.
    func textoParaBusca(_ p: String) -> String? {
        guard let n = tamanho(p), n <= Self.tetoDoGrep,
              let dados = try? Data(contentsOf: url(p)) else { return nil }
        if dados.prefix(8192).contains(0) {
            return nil
        }
        return String(data: dados, encoding: .utf8)
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
