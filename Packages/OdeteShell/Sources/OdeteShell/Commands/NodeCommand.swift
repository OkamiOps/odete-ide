import Foundation
import OdeteI18n
import OdeteRuntime
import Synchronization

/// `node arquivo.js [args]`, `node -e "código"`, `node -v`.
struct NodeCommand: ShellCommand {
    let name = "node"
    let help = tr("roda JavaScript/TypeScript no JavaScriptCore")

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        if args.isEmpty || args.first == "-v" || args
            .first == "--version"
        {
            io.out(tr("v22.0.0-odete (JavaScriptCore)")); return 0
        }
        let esbuild = ctx.shell.esbuildEngine()
        var argv = args
        var code: String?
        var file: URL?
        var ctx = ctx
        // Opções do próprio node antes do script: `--env-file` vale; as de depuração e de
        // aviso não mudam nada aqui e saem da frente (antes `node --no-warnings x.js`
        // procurava um arquivo "--no-warnings").
        while let a = argv.first, a.hasPrefix("--"), a != "--eval", a != "--print" {
            argv.removeFirst()
            if a.hasPrefix("--env-file") {
                let caminho = a.hasPrefix("--env-file=") ? String(a.dropFirst(11)) : argv.isEmpty ? "" : argv
                    .removeFirst()
                guard let u = ctx.noProjeto(caminho), let texto = try? String(contentsOf: u, encoding: .utf8) else {
                    io.err(tr("node: %1$@: não existe", caminho)); return 9
                }
                for (k, v) in Self.lerEnv(texto) where ctx.env[k] == nil {
                    ctx.env[k] = v
                }
            }
        }
        if let i = argv.firstIndex(where: { $0 == "-e" || $0 == "--eval" }),
           i + 1 < argv.count
        {
            code = argv[i + 1]; argv.removeSubrange(i ... i + 1)
        } else if let i = argv.firstIndex(where: { $0 == "-p" || $0 == "--print" }),
                  i + 1 < argv.count
        {
            code = "console.log(" + argv[i + 1] + ")"; argv.removeSubrange(i ... i + 1)
        } else if !argv.isEmpty {
            let f = argv.removeFirst()
            guard let u = ctx.noProjeto(f) else { ctx.avisarFora("node", f); return 1 }
            file = u
            guard FileManager.default.fileExists(atPath: u.path) || FileManager.default
                .fileExists(atPath: u.path + ".js") else { io.err(tr("node: não achei %1$@", "\(f)")); return 1 }
        } else {
            io.out(tr("v22.0.0-odete (JavaScriptCore)")); return 0
        }
        return await Self.runProcess(
            Alvo(code: code, file: file, argv: argv, label: "node " + args.joined(separator: " ")),
            ctx: ctx,
            esbuild: esbuild
        )
    }

    /// O `.env` do `--env-file`: KEY=valor, aspas, `export` e comentários.
    static func lerEnv(_ texto: String) -> [String: String] {
        var out: [String: String] = [:]
        for linha in texto.split(whereSeparator: \.isNewline) {
            var l = linha.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") {
                continue
            }
            if l.hasPrefix("export ") {
                l = String(l.dropFirst(7))
            }
            guard let i = l.firstIndex(of: "=") else { continue }
            let k = l[..<i].trimmingCharacters(in: .whitespaces)
            var v = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            if let q = v.first, q == "\"" || q == "'", v.count > 1, v.last == q {
                v = String(v.dropFirst().dropLast())
                if q == "\"" {
                    v = v.replacingOccurrences(of: "\\n", with: "\n")
                }
            } else if let h = v.range(of: " #") {
                v = String(v[..<h.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            out[k] = v
        }
        return out
    }

    /// O que rodar: código solto ou arquivo, com os argumentos dele.
    struct Alvo {
        var code: String?
        var file: URL?
        var argv: [String]
        var label: String
    }

    /// Identifica o transformador para o cache em disco das transformações (ver
    /// `CacheDeTransformacao`): muda com o esbuild e com cada build do código que o chama —
    /// a data do executável que contém este código (o app, ou o pacote de testes). O número
    /// de build do app não serve: durante o desenvolvimento ele não muda, e uma opção nova no
    /// transformador ficaria escondida atrás de saídas velhas.
    static let versaoDoTransformador: String = {
        var st = stat()
        let exe = Bundle(for: Shell.self).executableURL?.path ?? ""
        let data = stat(exe, &st) == 0 ? "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)" : "?"
        return "esbuild \(OdeteBundlerEsbuild.version); build \(data); entrada 1"
    }()

    /// Espera o esbuild carregar, bloqueando a fila de quem chama (a do runtime), como o
    /// `transformCJSSync` faz: a carga roda na fila do motor, então não há impasse.
    static func esperarEsbuild(_ e: OdeteBundlerEsbuild) throws {
        final class Caixa: @unchecked Sendable {
            var erro: Error?
            let pronto = DispatchSemaphore(value: 0)
        }
        let c = Caixa()
        Task.detached {
            do { _ = try await e.ready() } catch { c.erro = error }
            c.pronto.signal()
        }
        c.pronto.wait()
        if let erro = c.erro {
            throw erro
        }
    }

    /// Chama o `transform` do esbuild de forma síncrona e devolve o código.
    static func transformar(_ e: OdeteBundlerEsbuild, _ codigo: String, _ opcoes: [String: Any]) throws -> String {
        try esperarEsbuild(e)
        let json = try e.engine.callSync("__transform", [codigo, opcoes])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (obj?["code"] as? String) ?? ""
    }

    /// A string como literal JS (para o `define` do esbuild).
    static func json(_ s: String) -> String {
        (try? String(decoding: JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed]), as: UTF8.self))
            ?? "\"\""
    }

    static func loader(_ arquivo: String) -> String {
        let ext = (arquivo as NSString).pathExtension.lowercased()
        return ["ts": "ts", "mts": "ts", "cts": "ts", "tsx": "tsx", "jsx": "jsx"][ext] ?? "js"
    }

    /// O transformador do módulo de entrada: CJS com `async`/`await` rebaixados (a Promise
    /// do runtime passa a ver a rejeição de um `main()` sem `catch`) e ESM só sem tipos,
    /// para o top-level await. Ver `TransformadorDeEntrada`.
    static func transformadorDeEntrada(_ e: OdeteBundlerEsbuild) -> TransformadorDeEntrada {
        TransformadorDeEntrada(
            paraCJS: { codigo, arquivo in
                try transformar(e, codigo, [
                    "loader": loader(arquivo), "format": "cjs", "target": "es2022", "sourcefile": arquivo,
                    "platform": "node", "supported": ["dynamic-import": false, "async-await": false],
                    "define": [
                        "import.meta.url": json("file://" + arquivo),
                        "import.meta.dirname": json((arquivo as NSString).deletingLastPathComponent),
                        "import.meta.filename": json(arquivo),
                    ],
                ])
            },
            paraESM: { codigo, arquivo in
                try transformar(e, codigo, [
                    "loader": loader(arquivo), "format": "esm", "target": "es2022", "sourcefile": arquivo,
                    "platform": "node",
                ])
            }
        )
    }

    /// Roda um processo JS; se abrir servidor, vira job e o prompt volta.
    ///
    /// O Ctrl+C (ou o `kill %N` do job em que isto roda) chega pelo `Cancelamento` do
    /// contexto e mata o processo na hora — mesmo preso num laço síncrono, o terminal é
    /// solto (ver `JSProcess.kill`). Antes a espera era um laço de `Task.sleep` que, com a
    /// Task cancelada, voltava na hora e girava a CPU.
    static func runProcess(
        _ alvo: Alvo,
        ctx: CommandContext,
        esbuild: OdeteBundlerEsbuild
    ) async -> Int32 {
        let (code, file, argv, label) = (alvo.code, alvo.file, alvo.argv, alvo.label)
        let io = ctx.io
        let p = JSProcess(
            cwd: ctx.cwd,
            env: ctx.env,
            argv: (file.map { [$0.path] } ?? ["[eval]"]) + argv,
            raiz: ctx.root,
            stdin: io.stdinBytes
        ) { kind, text in
            kind == .out ? io.out(text) : io.err(text)
        }
        p.setSaidaBruta { kind, dados in
            io.escreverBruto(kind == .out ? .out : .err, dados)
        }
        p.setTransform(esbuild.cjsTransform, versao: versaoDoTransformador)
        p.setTransformDaEntrada(transformadorDeEntrada(esbuild))
        let fim = Termino()
        let desfazer = ctx.cancelamento.aoCancelar { p.kill() }
        defer { desfazer() }
        let task = Task { () -> Int32 in
            let c = if let code {
                await p.run(code: code)
            } else {
                await p.run(file: file!)
            }
            fim.marcar(c)
            return c
        }
        // Nos primeiros 1,5 s olha o processo a cada 20 ms: acabou, devolve na hora; se
        // abriu porta, vira job e o prompt volta. Depois só espera o fim.
        let inicio = ContinuousClock.now
        while ContinuousClock.now - inicio < .milliseconds(1500) {
            if let c = fim.codigo {
                return c
            }
            if ctx.isCancelled() {
                p.kill(); return await task.value
            }
            let ports = p.ports
            if !ports.isEmpty {
                let job = ctx.shell.registerJob(label, ports: ports) { p.kill() }
                io.out(tr(
                    "servidor em http://127.0.0.1:%1$@ (job %2$@; kill %%%3$@ para parar)",
                    "\(ports[0])",
                    "\(job.id)",
                    "\(job.id)"
                ))
                Task { _ = await task.value; ctx.shell.removeJob(job) }
                return 0
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            p.kill()
        }
    }

    /// O código de saída, visível sem esperar pela task do processo.
    final class Termino: Sendable {
        private let valor = Mutex<Int32?>(nil)

        func marcar(_ c: Int32) {
            valor.withLock { $0 = c }
        }

        var codigo: Int32? {
            valor.withLock { $0 }
        }
    }
}

public typealias OdeteBundlerEsbuild = OdeteBundler.Esbuild
import OdeteBundler
