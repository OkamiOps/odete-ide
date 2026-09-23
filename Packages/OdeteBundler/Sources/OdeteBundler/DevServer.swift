import Foundation
import OdeteCore
import OdeteRuntime

/// Servidor de desenvolvimento em `127.0.0.1:porta`, com esbuild e reload.
///
/// Roda no esbuild do projeto (`Esbuild.doProjeto`), o mesmo do lint e do terminal. Parar
/// o servidor fecha a porta e descarta os contextos de build dele; o motor fica para os
/// outros.
///
/// O que o faz refazer o build é `VigiaDeDependencias`: ele olha só os arquivos que o
/// build leu (e as pastas deles) e compara conteúdo, não data. O salvamento automático do
/// editor regrava o arquivo com o mesmo texto a cada pausa na digitação — antes cada
/// regravação derrubava o cache e mandava o Preview recarregar, e o recarregar refazia o
/// build do zero: seis segundos de CPU num iPad sem JIT, para nada.
///
/// Os pacotes de node_modules não entram no bundle do app: vêm de um pacote de
/// dependências à parte (`dependencias.js`, o `optimizeDeps` do Vite), feito uma vez e
/// guardado em `node_modules/.odete-deps/`. Sem isso, cada letra mudada no App.tsx
/// religava e reimprimia o react-dom inteiro — 1,6 s de CPU sem JIT num projeto pequeno.
public final class DevServer: @unchecked Sendable {
    public enum Preset: String, Sendable { case plain, vite, astro, next }

    /// O que um lote de mudanças fez com o Preview.
    public enum Reacao: String, Sendable { case nada, css, reload }

    public let esbuild: Esbuild
    public let root: URL
    public private(set) var port = 0
    public var onDiagnostics: (@Sendable ([Diagnostic]) -> Void)?
    private let output: @Sendable (OutputKind, String) -> Void
    private var id: Int?
    private var tokenDaSaida: Int?
    private var vigia: VigiaDeDependencias?
    private var acompanhamento: Task<Void, Never>?
    private let trava = NSLock()
    private var ultimosDiagnosticos: [Diagnostic]?

    /// Servidor no esbuild do projeto em `root`.
    public convenience init(root: URL, output: @escaping @Sendable (OutputKind, String) -> Void = { _, _ in }) {
        self.init(esbuild: Esbuild.doProjeto(root), root: root, output: output)
    }

    /// Servidor num esbuild dado — o do projeto, que o shell já tem. `root` é o que se
    /// serve (o `vite preview` serve `dist/` no motor do projeto).
    public init(
        esbuild: Esbuild,
        root: URL? = nil,
        output: @escaping @Sendable (OutputKind, String) -> Void = { _, _ in }
    ) {
        self.esbuild = esbuild
        self.root = root ?? esbuild.root
        self.output = output
    }

    public var url: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    public func start(port: Int = 5173, preset: Preset = .vite) async throws {
        // Um servidor que acabou de parar neste motor ainda pode estar soltando a porta.
        await esbuild.esperarParadas()
        _ = try await esbuild.ready()
        let js = Bundle.module.url(forResource: "js", withExtension: nil)!
        // O compilador de .astro vem antes: o servidor chama `__astroCompila` ao servir
        // uma rota de `src/pages`.
        // O runtime das ilhas não roda aqui: ele é o texto que vai ser empacotado para o
        // navegador quando uma rota tiver componente de cliente.
        let ilhas = try String(contentsOf: js.appending(path: "ilhas-cliente.js"), encoding: .utf8)
        try await esbuild.engine.evaluate(
            "globalThis.__ilhasClienteJS = \(Self.comoLiteralJS(ilhas));",
            name: "ilhas-cliente-fonte.js"
        )
        // O pacote de dependências vem antes do servidor, que cria um por servidor.
        for arquivo in ["astro.js", "next.js", "dependencias.js", "devserver.js"] {
            try await esbuild.engine.evaluate(
                String(contentsOf: js.appending(path: arquivo), encoding: .utf8),
                name: arquivo
            )
        }
        let json = try await esbuild.engine.call("__devStart", [root.path, port, preset.rawValue])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let novoId = (obj?["id"] as? Int) ?? 0
        self.port = (obj?["port"] as? Int) ?? port
        let token = esbuild.definirSaida(output)
        let vigia = VigiaDeDependencias(raiz: root) { [weak self] alterados, criados in
            guard let self else { return }
            Task { await self.arquivosMudaram(alterados, criados: criados) }
        }
        trava.withLock {
            id = novoId
            tokenDaSaida = token
            self.vigia = vigia
        }
        acompanhar(novoId)
    }

    /// Texto virando literal de JS, sem depender de escape à mão.
    static func comoLiteralJS(_ s: String) -> String {
        let dados = try? JSONSerialization.data(withJSONObject: [s], options: [])
        let json = dados.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }

    // MARK: - Dependências

    /// Espera longa no JS: cada volta traz o que vigiar e os diagnósticos, e só volta
    /// quando algo mudou. Termina quando o servidor para (o JS responde `null`).
    private func acompanhar(_ id: Int) {
        let esbuild = esbuild
        acompanhamento = Task { [weak self] in
            var versao = -1
            while !Task.isCancelled {
                guard let json = try? await esbuild.engine.call("__devEspera", [id, versao]),
                      let r = Retrato(json: json)
                else { return }
                versao = r.versao
                guard let self else { return }
                vigiaAtual?.vigiar(arquivos: r.arquivos, pastas: r.pastas)
                publicar(r.diagnosticos)
            }
        }
    }

    private var vigiaAtual: VigiaDeDependencias? {
        trava.withLock { vigia }
    }

    private var idAtual: Int? {
        trava.withLock { id }
    }

    /// Diagnósticos para o painel Problemas, só quando mudam — e nunca depois de parar: um
    /// rebuild que termina com o servidor já derrubado deixaria erro de um build morto.
    private func publicar(_ diagnosticos: [Diagnostic]) {
        let mudou = trava.withLock {
            guard id != nil, ultimosDiagnosticos != diagnosticos else { return false }
            ultimosDiagnosticos = diagnosticos
            return true
        }
        if mudou {
            onDiagnostics?(diagnosticos)
        }
    }

    /// Arquivos cujo conteúdo mudou (`alterados`) e que nasceram (`criados`), em caminho
    /// absoluto. O JS decide o que refazer, refaz só o que é afetado e só avisa o Preview
    /// se a saída mudou. É o que o observador chama; teste pode chamar direto.
    @discardableResult
    public func arquivosMudaram(_ alterados: [String], criados: [String] = []) async -> Reacao {
        guard let id = idAtual else { return .nada }
        let json = try? await esbuild.engine.call("__devMudou", [id, alterados, criados])
        let obj = json.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        if let d = try? await esbuild.engine.call("__devDiagnostics", [id]),
           let list = try? Self.parseDiagnostics(d)
        {
            publicar(list)
        }
        return (obj?["acao"] as? String).flatMap(Reacao.init(rawValue:)) ?? .nada
    }

    /// Joga tudo fora e recarrega: é o botão Rebuild. Contextos, caches e o grafo vão
    /// embora, e o próximo pedido refaz do zero.
    public func invalidate() {
        Task { await invalidateNow() }
    }

    public func invalidateNow() async {
        _ = try? await esbuild.engine.call("__devInvalidate", idAtual.map { [$0] } ?? [])
        if let d = try? await esbuild.engine.call("__devDiagnostics", idAtual.map { [$0] } ?? []),
           let list = try? Self.parseDiagnostics(d)
        {
            publicar(list)
        }
    }

    public func diagnostics() async -> [Diagnostic] {
        await (try? esbuild.engine.call("__devDiagnostics", idAtual.map { [$0] } ?? []))
            .flatMap { try? Self.parseDiagnostics($0) } ?? []
    }

    /// O que o observador vigia agora. Para teste.
    var arquivosVigiados: Set<String> {
        vigiaAtual?.vigiados ?? []
    }

    /// Quantos builds, recargas e trocas de CSS este servidor fez. Para teste.
    func estatisticas() async -> [String: Int] {
        guard let id = idAtual,
              let json = try? await esbuild.engine.call("__devEstatisticas", [id]),
              let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Int]
        else { return [:] }
        return obj
    }

    static func parseDiagnostics(_ json: String) throws -> [Diagnostic] {
        let arr = try (JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]) ?? []
        return arr.map { Diagnostic(
            kind: ($0["kind"] as? String) == "warning" ? .warning : .error,
            text: ($0["text"] as? String) ?? "",
            file: $0["file"] as? String,
            line: $0["line"] as? Int,
            column: $0["column"] as? Int,
            lineText: $0["lineText"] as? String,
            source: "esbuild"
        ) }
    }

    public func stop() {
        let (id, token, vigia) = trava.withLock {
            defer { self.id = nil; tokenDaSaida = nil; self.vigia = nil }
            return (self.id, tokenDaSaida, self.vigia)
        }
        vigia?.parar()
        acompanhamento?.cancel()
        if let token {
            esbuild.soltarSaida(token)
        }
        guard let id else { return }
        let engine = esbuild.engine
        esbuild.enfileirarParada { _ = try? await engine.call("__devStop", [id]) }
    }
}

/// O que o JS manda a cada volta da espera longa.
struct Retrato {
    var versao: Int
    var arquivos: [(caminho: String, mtime: Double?)]
    var pastas: [String]
    var diagnosticos: [Diagnostic]

    init?(json: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let versao = obj["versao"] as? Int
        else { return nil }
        self.versao = versao
        arquivos = ((obj["arquivos"] as? [[Any]]) ?? []).compactMap { par in
            guard let caminho = par.first as? String else { return nil }
            return (caminho, par.count > 1 ? par[1] as? Double : nil)
        }
        pastas = (obj["pastas"] as? [String]) ?? []
        let dados = (try? JSONSerialization.data(withJSONObject: obj["diagnostics"] ?? []))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        diagnosticos = (try? DevServer.parseDiagnostics(dados)) ?? []
    }
}
