import Foundation
import OdeteI18n
import OdeteRuntime
import Synchronization

/// Saída de um comando: linhas que a sessão mostra.
public enum StreamKind: Sendable { case out, err }

/// Contexto de execução de um comando dentro de um pipeline.
///
/// O stdout capturado (pipe ou `>`) é guardado em bytes: o `node` escreve binário por
/// `escreverBruto`, e um PNG redirecionado para arquivo chegava corrompido quando tudo
/// passava por String. Na tela, `escreverBruto` junta os pedaços até o `\n` — antes cada
/// `process.stdout.write` virava uma linha.
public final class CommandIO: @unchecked Sendable {
    public let stdin: String?
    /// O stdin em bytes, como chegou (o do `node` vai inteiro, sem passar por String).
    public let stdinBytes: Data?
    private let outSink: @Sendable (StreamKind, String) -> Void
    private let capture = Mutex<Data>(Data())
    private let capturaErro = Mutex<Data>(Data())
    /// Onde os pedaços sem `\n` esperam. O shell passa o mesmo para todos os comandos de
    /// uma linha: `echo -n x; echo y` é "xy", como no terminal.
    let montador: MontadorDeLinhas
    public let capturing: Bool
    /// `2>&1`: o stderr vai para onde o stdout for.
    public var stderrToStdout = false
    /// `>&2`: o stdout vai para o stderr.
    public var stdoutToStderr = false
    /// `2> arquivo`: o stderr é guardado para o shell escrever no arquivo.
    public var capturandoErro = false

    public init(stdin: String?, capturing: Bool, sink: @escaping @Sendable (StreamKind, String) -> Void) {
        self.stdin = stdin; self.capturing = capturing; outSink = sink
        stdinBytes = stdin.map { Data($0.utf8) }
        montador = MontadorDeLinhas(sink)
    }

    init(
        stdinBytes: Data?,
        capturing: Bool,
        sink: @escaping @Sendable (StreamKind, String) -> Void,
        montador: MontadorDeLinhas? = nil
    ) {
        self.stdinBytes = stdinBytes
        stdin = stdinBytes.map { String(decoding: $0, as: UTF8.self) }
        self.capturing = capturing
        outSink = sink
        self.montador = montador ?? MontadorDeLinhas(sink)
    }

    /// Escreve uma linha em stdout (vai para o próximo comando do pipe ou para a tela).
    public func out(_ text: String) {
        escreverBruto(.out, Data((text + "\n").utf8))
    }

    /// Uma linha em stderr.
    public func err(_ text: String) {
        escreverBruto(.err, Data((text + "\n").utf8))
    }

    /// Bytes sem linha implícita (`process.stdout.write`). Para onde vão depende dos
    /// redirecionamentos; na tela, só linhas inteiras saem — o resto espera o `\n` ou o fim
    /// do comando (`fecharLinhas`).
    public func escreverBruto(_ kind: StreamKind, _ dados: Data) {
        var destino = kind
        if kind == .out, stdoutToStderr {
            destino = .err
        } else if kind == .err, stderrToStdout {
            destino = .out
        }
        if destino == .out, capturing {
            capture.withLock { $0.append(dados) }
            return
        }
        if destino == .err, capturandoErro {
            capturaErro.withLock { $0.append(dados) }
            return
        }
        montador.escrever(destino, dados)
    }

    /// O que ficou sem `\n` no fim vai para a tela como última linha.
    public func fecharLinhas() {
        montador.fechar()
    }

    public var captured: String {
        String(decoding: capturedData, as: UTF8.self)
    }

    /// O stdout capturado, byte a byte.
    public var capturedData: Data {
        capture.withLock { $0 }
    }

    /// O stderr capturado para `2> arquivo`.
    public var stderrCapturado: Data {
        capturaErro.withLock { $0 }
    }
}

/// Junta os pedaços de saída em linhas para a tela: só linha inteira sai, e o `\r` de barra
/// de progresso reescreve o começo dela (ver `LinhaDeTerminal`).
final class MontadorDeLinhas: @unchecked Sendable {
    private let sink: @Sendable (StreamKind, String) -> Void
    private let parciais = Mutex<[StreamKind: Data]>([:])

    init(_ sink: @escaping @Sendable (StreamKind, String) -> Void) {
        self.sink = sink
    }

    func escrever(_ kind: StreamKind, _ dados: Data) {
        let linhas = parciais.withLock { tabela -> [String] in
            var acumulado = tabela[kind] ?? Data()
            acumulado.append(dados)
            var prontas: [String] = []
            var inicio = acumulado.startIndex
            while let fim = acumulado[inicio...].firstIndex(of: 0x0A) {
                prontas.append(LinhaDeTerminal.texto(acumulado[inicio ..< fim]))
                inicio = acumulado.index(after: fim)
            }
            tabela[kind] = Data(acumulado[inicio...])
            return prontas
        }
        for l in linhas {
            sink(kind, l)
        }
    }

    /// Solta o que sobrou sem `\n` (stdout antes de stderr).
    func fechar() {
        let restos = parciais.withLock { tabela -> [(StreamKind, Data)] in
            defer { tabela = [:] }
            return [StreamKind.out, .err].compactMap { k in tabela[k].flatMap { $0.isEmpty ? nil : (k, $0) } }
        }
        for (k, d) in restos {
            sink(k, LinhaDeTerminal.texto(d))
        }
    }
}

/// O sinal de Ctrl+C (ou `kill %N`) de uma execução.
///
/// Antes havia uma marca só no shell: o Ctrl+C numa linha em primeiro plano parava também os
/// jobs em segundo plano, e o `kill %1` cancelava a Task do job sem que o `node` percebesse —
/// o processo seguia vivo e o laço de espera girava a 81% de CPU. Agora cada linha e cada job
/// têm o seu; o de uma linha de dentro (o script do `npm run`) é filho do de quem a chamou.
public final class Cancelamento: @unchecked Sendable {
    private struct Estado {
        var cancelado = false
        var aoCancelar: [Int: @Sendable () -> Void] = [:]
        var proximo = 0
    }

    private let estado = Mutex(Estado())

    public init(pai: Cancelamento? = nil) {
        if let pai {
            let filho = self
            _ = pai.aoCancelar { [weak filho] in filho?.cancelar() }
        }
    }

    public var cancelado: Bool {
        estado.withLock { $0.cancelado }
    }

    public func cancelar() {
        let acoes = estado.withLock { e -> [@Sendable () -> Void] in
            guard !e.cancelado else { return [] }
            e.cancelado = true
            defer { e.aoCancelar = [:] }
            return Array(e.aoCancelar.values)
        }
        acoes.forEach { $0() }
    }

    /// Roda `acao` no cancelamento (na hora, se já foi). Devolve o que desfaz o registro.
    @discardableResult
    public func aoCancelar(_ acao: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let id: Int? = estado.withLock { e in
            if e.cancelado {
                return nil
            }
            e.proximo += 1
            e.aoCancelar[e.proximo] = acao
            return e.proximo
        }
        guard let id else {
            acao()
            return {}
        }
        return { [weak self] in self?.estado.withLock { _ = $0.aoCancelar.removeValue(forKey: id) } }
    }
}

public struct CommandContext: Sendable {
    public var cwd: URL
    public var root: URL
    public var env: [String: String]
    public var io: CommandIO
    public var shell: Shell
    public var isCancelled: @Sendable () -> Bool
    /// O cancelamento desta execução: quem roda algo longo registra aqui como parar.
    public var cancelamento = Cancelamento()

    /// O caminho do jeito do shell (`/` e `~` são a raiz do projeto), sem conferir nada.
    public func caminhoCru(_ path: String) -> URL {
        if path.hasPrefix("/") {
            return root.appending(path: String(path.dropFirst())).standardizedFileURL
        }
        if path == "~" || path.hasPrefix("~/") {
            return root.appending(path: String(path.dropFirst(path == "~" ? 1 : 2))).standardizedFileURL
        }
        return cwd.appending(path: path).standardizedFileURL
    }

    /// O caminho dentro do projeto, ou nil se ele sai de lá (por `..` ou por link).
    /// `seguirUltimo: false` é para quem mexe na entrada em si (apagar, mover): um link do
    /// projeto que aponta para fora pode ser apagado, só não seguido.
    public func noProjeto(_ path: String, seguirUltimo: Bool = true) -> URL? {
        let u = caminhoCru(path)
        return Confinamento(raiz: root).permite(u.path, seguirUltimo: seguirUltimo) ? u : nil
    }

    /// Onde fica um caminho que saiu do projeto: debaixo de /dev/null nada existe e nada pode
    /// ser criado, então quem ainda usa `resolve` sem conferir falha em vez de mexer fora.
    public static let foraDoProjeto = URL(fileURLWithPath: "/dev/null/odete-fora-do-projeto")

    /// O caminho resolvido; se ele sair do projeto, `foraDoProjeto`. Os embutidos usam
    /// `noProjeto` para dizer o motivo; este é a rede para quem não confere.
    public func resolve(_ path: String) -> URL {
        noProjeto(path) ?? Self.foraDoProjeto
    }

    /// O erro que o comando mostra para um caminho fora do projeto.
    public func avisarFora(_ comando: String, _ path: String) {
        io.err(tr("%1$@: %2$@: fora da pasta do projeto", comando, path))
    }

    /// Caminho relativo à raiz do projeto, para exibir.
    public func display(_ url: URL) -> String {
        let r = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        if r == base {
            return "~"
        }
        return r.hasPrefix(base + "/") ? "~/" + String(r.dropFirst(base.count + 1)) : r
    }
}

public protocol ShellCommand: Sendable {
    var name: String { get }
    var help: String { get }
    func run(_ args: [String], _ ctx: CommandContext) async -> Int32
}
