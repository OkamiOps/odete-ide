import Foundation
import OdeteCore
import OdeteI18n
import OdeteRuntime
import Synchronization

public struct Diagnostic: Sendable, Hashable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable { case error, warning, info }
    public var kind: Kind
    public var text: String
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var lineText: String?
    public var source: String
    public var id: String {
        "\(source):\(file ?? ""):\(line ?? 0):\(column ?? 0):\(text)"
    }

    public init(
        kind: Kind,
        text: String,
        file: String? = nil,
        line: Int? = nil,
        column: Int? = nil,
        lineText: String? = nil,
        source: String
    ) {
        self.kind = kind; self.text = text; self.file = file; self.line = line; self.column = column; self
            .lineText = lineText; self.source = source
    }
}

public struct BuildResult: Sendable {
    /// Um arquivo que o build produziu. Em bytes: a imagem que sai como arquivo não é texto.
    public struct Arquivo: Sendable {
        public var path: String
        public var data: Data
        public var text: String {
            String(decoding: data, as: UTF8.self)
        }
    }

    public var ok: Bool
    public var files: [Arquivo]
    public var diagnostics: [Diagnostic]
    /// O `import.meta.env` do build (MODE, BASE_URL, as `VITE_*`…), em texto.
    public var env: [String: String] = [:]
}

/// Um JSEngine com o esbuild-wasm carregado.
///
/// **Um por projeto**, via `doProjeto(_:)`: o dev server, o `vite build`, o `node x.ts` de
/// qualquer aba e o lint do editor falam com o mesmo. Cada instância compila o módulo de
/// 14 MB e segura a própria memória linear do Go, que só cresce — antes eram uma por aba
/// de terminal, mais uma por `npm run dev`, mais a do lint, criada já na abertura do app.
/// No iPad isso é memória e bateria gastas em cópias do mesmo compilador.
///
/// A fila do JSEngine é serial: um lint pode esperar atrás de um rebuild. Tudo aqui é
/// `async` e nada bloqueia quem chama esperando pela própria fila, então esperar é tudo o
/// que acontece — sem trava e sem engasgo na interface.
public final class Esbuild: @unchecked Sendable {
    public let engine: JSEngine
    public let root: URL
    private let inicializacao = Mutex<Task<String, Error>?>(nil)
    /// A carga já terminou bem: `transformCJSSync` não precisa mais esperar por ela.
    private let carregado = Mutex(false)
    private let saida: SaidaDoMotor
    private let paradas = Mutex<[Task<Void, Never>]>([])
    private let ultimoLint = Mutex<[String: (texto: String, diagnosticos: [Diagnostic])]>([:])
    /// Quantos lints chegaram de fato ao esbuild (os repetidos não contam). Para teste.
    let lintsExecutados = Mutex(0)

    public static let version: String = {
        let u = Bundle.module.url(forResource: "esbuild", withExtension: nil)!.appending(path: "VERSION")
        return (try? String(contentsOf: u, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
    }()

    /// Um esbuild avulso, fora do registro. Quem quer o do projeto usa `doProjeto(_:)`.
    public init(root: URL, output: @escaping @Sendable (OutputKind, String) -> Void = { _, _ in }) {
        self.root = root
        let caixa = SaidaDoMotor()
        saida = caixa
        engine = JSEngine(cwd: root) { tipo, texto in
            (caixa.destino ?? output)(tipo, texto)
        }
    }

    deinit {
        // Ninguém mais usa: timers e servidores do motor param junto, senão o Go dentro
        // dele seguiria agendando despertares para um compilador que ninguém chama.
        engine.stop()
    }

    // MARK: - Um por projeto

    /// Referência fraca: fechar o projeto (e com ele as abas, o servidor e o editor) solta
    /// o motor e a memória dele. Enquanto alguém segura, todo mundo recebe o mesmo.
    private final class Fraca: @unchecked Sendable {
        weak var valor: Esbuild?
        init(_ valor: Esbuild) {
            self.valor = valor
        }
    }

    private static let registro = Mutex<[String: Fraca]>([:])

    static func chave(_ root: URL) -> String {
        root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// O esbuild do projeto em `root`, criado na primeira vez que alguém pede.
    public static func doProjeto(_ root: URL) -> Esbuild {
        let k = chave(root)
        return registro.withLock { tabela in
            tabela = tabela.filter { $0.value.valor != nil }
            if let vivo = tabela[k]?.valor {
                return vivo
            }
            let novo = Esbuild(root: root)
            tabela[k] = Fraca(novo)
            return novo
        }
    }

    /// O do projeto se alguém já criou — sem criar. O lint usa isto para não subir um
    /// motor inteiro só porque o app abriu com um `.tsx` na aba.
    public static func existente(_ root: URL) -> Esbuild? {
        let k = chave(root)
        return registro.withLock { $0[k]?.valor }
    }

    // MARK: - Saída

    /// A saída do JS (console do dev server, erro de página do Next) vai para quem pediu por
    /// último — o terminal que subiu o servidor. O token deixa quem saiu soltar só a sua.
    func definirSaida(_ destino: @escaping @Sendable (OutputKind, String) -> Void) -> Int {
        saida.definir(destino)
    }

    func soltarSaida(_ token: Int) {
        saida.soltar(token)
    }

    public var onOutput: (@Sendable (OutputKind, String) -> Void)? {
        get { saida.destino }
        set {
            if let newValue {
                _ = saida.definir(newValue)
            } else {
                saida.soltar(nil)
            }
        }
    }

    // MARK: - Paradas pendentes

    /// Um servidor que para manda o JS fechar a porta e descartar os contextos; o próximo a
    /// subir no mesmo motor espera isso terminar, senão pegaria a porta ainda ocupada.
    func enfileirarParada(_ corpo: @escaping @Sendable () async -> Void) {
        let t = Task { await corpo() }
        paradas.withLock { $0.append(t) }
    }

    func esperarParadas() async {
        let pendentes = paradas.withLock { lista in
            defer { lista.removeAll() }
            return lista
        }
        for t in pendentes {
            await t.value
        }
    }

    // MARK: - Carga

    /// Carrega o esbuild (uma vez; ~1-2 s). Chamadas simultâneas esperam a mesma carga:
    /// carregar duas vezes faria o esbuild recusar o segundo `initialize`.
    public func ready() async throws -> String {
        let t = inicializacao.withLock { atual -> Task<String, Error> in
            if let atual {
                return atual
            }
            let nova = Task<String, Error> { [engine] in
                let res = Bundle.module.url(forResource: "esbuild", withExtension: nil)!
                let js = Bundle.module.url(forResource: "js", withExtension: nil)!
                try await engine.evaluate(
                    String(contentsOf: js.appending(path: "bundler.js"), encoding: .utf8),
                    name: "bundler.js"
                )
                let v = try await engine.call(
                    "__esbuildInit",
                    [res.appending(path: "browser.js").path, res.appending(path: "esbuild.wasm").path]
                )
                return v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
            atual = nova
            return nova
        }
        return try await t.value
    }

    public func transform(_ code: String, loader: String, options: [String: Any] = [:]) async throws -> String {
        _ = try await ready()
        var o = options
        o["loader"] = loader
        let json = try await engine.call("__transform", [code, o])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (obj?["code"] as? String) ?? ""
    }

    // MARK: - Lint

    /// Só sintaxe: diagnósticos do esbuild para um arquivo.
    ///
    /// O mesmo texto do mesmo arquivo não volta ao esbuild: salvar, recarregar do disco e
    /// reabrir a aba pedem lint de novo com o texto que já foi conferido, e cada ida custa
    /// uma análise inteira em wasm interpretado. A resposta guardada é a mesma que viria.
    public func lint(_ code: String, file: String) async throws -> [Diagnostic] {
        if let guardado = ultimoLint.withLock({ $0[file] }), guardado.texto == code {
            return guardado.diagnosticos
        }
        _ = try await ready()
        let ext = (file as NSString).pathExtension.lowercased()
        let loader = ["ts": "ts", "mts": "ts", "cts": "ts", "tsx": "tsx", "jsx": "jsx", "css": "css",
                      "json": "json"][ext] ?? "js"
        lintsExecutados.withLock { $0 += 1 }
        let json = try await engine.call("__lint", [code, loader, file])
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return [] }
        func parse(_ key: String, _ kind: Diagnostic.Kind) -> [Diagnostic] {
            ((obj[key] as? [[String: Any]]) ?? []).map { m in
                Diagnostic(
                    kind: kind,
                    text: m["text"] as? String ?? "",
                    file: file,
                    line: m["line"] as? Int,
                    column: (m["column"] as? Int).map { $0 + 1 },
                    lineText: m["lineText"] as? String,
                    source: "esbuild"
                )
            }
        }
        let diagnosticos = parse("errors", .error) + parse("warnings", .warning)
        ultimoLint.withLock { tabela in
            // Poucos arquivos ficam abertos; o teto só impede a tabela de crescer sem fim
            // numa sessão longa que abre e fecha centenas deles.
            if tabela.count >= 64, tabela[file] == nil {
                tabela.removeAll()
            }
            tabela[file] = (code, diagnosticos)
        }
        return diagnosticos
    }

    /// TS/ESM → CJS, bloqueante (para o `require` de outro runtime).
    ///
    /// Bloqueia a fila de quem chama, nunca a deste motor: quem chama é o runtime de um
    /// `node x.ts`, que tem fila própria. Chamar daqui de dentro travaria para sempre.
    public func transformCJSSync(_ code: String, file: String) throws -> String {
        try carregarSync()
        let json = try engine.callSync("__transformCJS", [code, file])
        return try (JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) as? String) ?? ""
    }

    /// `ready()` bloqueante, para o `require` de outro runtime.
    ///
    /// `__transformCJS` só existe depois que o bundler.js foi avaliado. Desde que o app abre
    /// sem carregar o esbuild, o primeiro `node x.ts` (ou `npx vitest`) do terminal podia
    /// chegar antes de qualquer lint e morria com "função não encontrada: __transformCJS".
    /// Bloquear aqui é seguro pelo mesmo motivo de `transformCJSSync`: quem espera é a fila
    /// do outro runtime, e a carga roda na fila deste motor. Depois da primeira vez não
    /// custa nada além de ler a trava.
    private func carregarSync() throws {
        if carregado.withLock({ $0 }) {
            return
        }
        let caixa = CaixaDeCarga()
        Task.detached { [self] in
            do {
                _ = try await ready()
            } catch {
                caixa.erro = error
            }
            caixa.pronto.signal()
        }
        caixa.pronto.wait()
        if let e = caixa.erro {
            throw e
        }
        carregado.withLock { $0 = true }
    }

    /// Build avulso (o `vite build`, por exemplo).
    ///
    /// Sem sourcemap por padrão: o bundler.js caía em `inline` quando ninguém dizia nada, e
    /// o `vite build` saía com o mapa inteiro embutido no JS de produção — o dobro do
    /// tamanho para quem abre o site.
    ///
    /// O resto é o que o `vite build` pede (`ViteBuild`): `mode` e `base` para o
    /// `import.meta.env`, nomes com hash (`entryNames`, `assetNames`, com `publicPath`),
    /// o tamanho até onde um arquivo importado vai embutido no JS (`limiteDeInline`), módulos
    /// que só existem em memória (`virtuais`) e a fachada do interop CJS/ESM (`fachadas`).
    public func build(
        entries: [String],
        platform: String = "browser",
        format: String = "esm",
        dev: Bool = true,
        minify: Bool = false,
        define: [String: String] = [:],
        sourcemap: Bool = false,
        mode: String? = nil,
        base: String = "/",
        entryNames: String? = nil,
        assetNames: String? = nil,
        publicPath: String? = nil,
        limiteDeInline: Int? = nil,
        virtuais: [String: String] = [:],
        fachadas: Bool = true
    ) async throws -> BuildResult {
        _ = try await ready()
        var opts: [String: Any] = [
            "root": root.path,
            "entries": entries,
            "platform": platform,
            "format": format,
            "dev": dev,
            "minify": minify,
            "define": define,
            "outdir": "dist",
            "sourcemap": sourcemap ? "inline" : false,
            "base": base,
            "fachadas": fachadas,
        ]
        if let mode {
            opts["mode"] = mode
        }
        if let entryNames {
            opts["entryNames"] = entryNames
        }
        if let assetNames {
            opts["assetNames"] = assetNames
        }
        if let publicPath {
            opts["publicPath"] = publicPath
        }
        if let limiteDeInline {
            opts["limiteDeInline"] = limiteDeInline
        }
        if !virtuais.isEmpty {
            opts["virtuais"] = virtuais
        }
        let json = try await engine.call("__build", [opts])
        return try Self.parseBuild(json)
    }

    static func parseBuild(_ json: String) throws -> BuildResult {
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw RuntimeError(message: tr("build: resposta inválida")) }
        let files = ((obj["files"] as? [[String: Any]]) ?? []).map { f in
            let data = if let t = f["text"] as? String {
                Data(t.utf8)
            } else {
                Data(base64Encoded: (f["base64"] as? String) ?? "") ?? Data()
            }
            return BuildResult.Arquivo(path: (f["path"] as? String) ?? "", data: data)
        }
        // Valores do `import.meta.env` são texto ou booleano (DEV, PROD, SSR).
        var env: [String: String] = [:]
        for (k, v) in (obj["env"] as? [String: Any]) ?? [:] {
            if let b = v as? Bool {
                env[k] = b ? "true" : "false"
            } else {
                env[k] = "\(v)"
            }
        }
        func diags(_ key: String, _ kind: Diagnostic.Kind) -> [Diagnostic] {
            ((obj[key] as? [[String: Any]]) ?? []).map { Diagnostic(
                kind: kind,
                text: ($0["text"] as? String) ?? "",
                file: $0["file"] as? String,
                line: $0["line"] as? Int,
                column: $0["column"] as? Int,
                lineText: $0["lineText"] as? String,
                source: "esbuild"
            ) }
        }
        return BuildResult(
            ok: (obj["ok"] as? Bool) ?? false,
            files: files,
            diagnostics: diags("errors", .error) + diags("warnings", .warning),
            env: env
        )
    }

    /// Transformador para injetar num `JSProcess`.
    public var cjsTransform: @Sendable (String, String) throws -> String {
        { [self] code, file in try transformCJSSync(code, file: file) }
    }
}

/// O resultado da carga esperada por `carregarSync`. O semáforo ordena a escrita do erro
/// (na task) antes da leitura (em quem espera).
private final class CaixaDeCarga: @unchecked Sendable {
    let pronto = DispatchSemaphore(value: 0)
    var erro: Error?
}

/// Para onde vai o que o JS do motor escreve. Classe à parte porque o motor é criado
/// antes de o `Esbuild` existir, e a saída precisa ser trocada depois.
final class SaidaDoMotor: @unchecked Sendable {
    private let trava = NSLock()
    private var token = 0
    private var atual: (@Sendable (OutputKind, String) -> Void)?

    var destino: (@Sendable (OutputKind, String) -> Void)? {
        trava.lock(); defer { trava.unlock() }
        return atual
    }

    func definir(_ destino: @escaping @Sendable (OutputKind, String) -> Void) -> Int {
        trava.lock(); defer { trava.unlock() }
        token += 1
        atual = destino
        return token
    }

    /// Solta só se ninguém tiver definido outra depois (`nil` solta de qualquer jeito).
    func soltar(_ dono: Int?) {
        trava.lock(); defer { trava.unlock() }
        if dono == nil || dono == token {
            atual = nil
        }
    }
}
