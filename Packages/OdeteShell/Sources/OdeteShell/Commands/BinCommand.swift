import Foundation
import OdeteBundler
import OdeteI18n
import OdeteNpm
import OdeteRuntime

/// Binários de `node_modules/.bin` e os que a Odete substitui (vite, next, astro, nest).
struct BinCommand: ShellCommand {
    let name = "npx"
    let help = tr("roda um binário de node_modules/.bin (vite, tsc, …)")

    /// Ferramentas que a Odete substitui por conta própria. Valem mesmo sem
    /// `node_modules`, e precisam responder pelo nome puro: `npm run dev` com
    /// `"dev": "vite"` executa `vite`, não `npx vite`.
    static let substituidos: Set<String> = [
        "vite", "astro", "next", "nest", "serve", "http-server", "tsx", "ts-node", "vitest",
    ]

    static func binPath(_ name: String, root: URL) -> URL? {
        let link = root.appending(path: "node_modules/.bin/\(name)")
        guard FileManager.default.fileExists(atPath: link.path) else { return nil }
        if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) {
            return link.deletingLastPathComponent().appending(path: dest).standardizedFileURL
        }
        return link
    }

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        guard let bin = args.first else { io.err(tr("npx <binário>")); return 1 }
        let rest = Array(args.dropFirst())
        switch bin {
        case "vite":
            if rest.first == "build" {
                return await build(ctx, Array(rest.dropFirst()))
            }
            if rest.first == "preview" {
                // Serve o que o build gravou, onde o build gravou, sob o mesmo `base`.
                let config = ViteBuild.configDoVite(ctx.root)
                let args = Array(rest.dropFirst())
                let base = ViteBuild.normalizaBase(opcao("--base", args) ?? config.base ?? "/")
                return await serveStatic(
                    ctx,
                    dir: opcao("--outDir", args) ?? config.saida ?? "dist",
                    port: portArg(args) ?? 4173,
                    base: base.hasPrefix("/") ? base : "/"
                )
            }
            return await devServer(ctx, preset: .vite, port: portArg(rest) ?? 5173, label: "vite")
        case "astro":
            if rest.first == "build" {
                io.err(tr("astro build ainda não roda no iPad; use astro dev")); return 1
            }
            return await devServer(ctx, preset: .astro, port: portArg(rest) ?? 4321, label: "astro dev")
        case "next":
            if rest.first == "build" {
                io.err(tr("next build ainda não roda no iPad; use next dev")); return 1
            }
            return await devServer(ctx, preset: .next, port: portArg(rest) ?? 3000, label: "next dev")
        case "nest":
            if rest
                .first ==
                "start"
            {
                return await ctx.shell.run("node dist/main.js") { k, t in
                    k == .out ? io.out(t) : io.err(t)
                }
            }
            io.err(tr("nest: use npm run start:dev com tsx, ou node src/main.ts")); return 1
        case "serve", "http-server": return await serveStatic(ctx, dir: rest.first { !$0.hasPrefix("-") } ?? ".")
        case "tsx", "ts-node":
            return await NodeCommand().run(rest, ctx)
        case "vitest":
            return await vitest(rest, ctx)
        case "tsc" where Self.typescriptNativo(root: ctx.root) != nil, "tsgo":
            let versao = Self.typescriptNativo(root: ctx.root) ?? "7"
            io.err(tr(
                "%1$@: o TypeScript %2$@ é o compilador nativo (Go) e não roda no iPad. Para checar tipos aqui, instale o compilador em JavaScript: npm i -D typescript@6",
                bin,
                versao
            ))
            return 1
        default:
            guard let file = Self.binPath(bin, root: ctx.root)
            else { io.err(tr("npx: %1$@ não está em node_modules/.bin (rode npm install)", "\(bin)")); return 127 }
            if file.pathExtension == "node" || (try? Data(contentsOf: file))?.prefix(4) == Data([
                0xCF,
                0xFA,
                0xED,
                0xFE,
            ]) {
                io.err(tr("%1$@ é um binário nativo e não roda no iPad", "\(bin)")); return 126
            }
            return await NodeCommand.runProcess(
                NodeCommand.Alvo(code: nil, file: file, argv: rest, label: ([bin] + rest).joined(separator: " ")),
                ctx: ctx,
                esbuild: ctx.shell.esbuildEngine()
            )
        }
    }

    /// A versão do `typescript` instalado quando ele é o 7 ou mais novo: o compilador nativo
    /// (Go). O pacote traz só um lançador que executa o binário da plataforma — que o
    /// instalador nem baixa, porque não roda no iPad. O último `tsc` em JavaScript é o 6.
    static func typescriptNativo(root: URL) -> String? {
        guard let v = versaoInstalada("typescript", root: root),
              let maior = Int(v.prefix { $0.isNumber }), maior >= 7 else { return nil }
        return v
    }

    /// `vitest`, `vitest run [filtros]`: o executor embutido (`ExecutorDeTestes`).
    ///
    /// O vitest de verdade não sobe aqui em nenhuma configuração — o vite 8 dele precisa do
    /// binário nativo do rolldown, e todo pool (forks, threads, vmThreads) roda os arquivos
    /// em worker_threads ou processos filhos. Antes ele morria calado e o comando saía com
    /// 0, como se tudo tivesse passado. Sem modo watch: roda uma vez e sai.
    func vitest(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        let versao = Self.versaoInstalada("vitest", root: ctx.root) ?? "5"
        var filtros: [String] = []
        var padrao: String?
        var tempoLimite: Int?
        var detalhado = false
        var semTestesOk = false
        var raiz = ctx.root
        // Opções que levam valor separado (`--pool threads`): o valor não é filtro.
        let comValor: Set = [
            "--pool", "--reporter", "--maxWorkers", "--minWorkers", "--config", "-c", "--environment",
            "--project", "--outputFile", "--shard", "--mode", "--retry", "--bail", "--hookTimeout", "--exclude",
        ]
        var i = 0
        let valor = { (j: Int) -> String? in j + 1 < args.count ? args[j + 1] : nil }
        while i < args.count {
            let a = args[i]
            switch a {
            case "-v", "--version":
                io.out("vitest/\(versao) (Odete)"); return 0
            case "run", "watch", "dev":
                break
            case "bench", "init", "list", "related", "typecheck":
                io.err(tr("vitest %1$@ não existe no executor embutido da Odete; use vitest run", a)); return 1
            case "-t", "--testNamePattern":
                padrao = valor(i); i += 1
            case "--testTimeout":
                tempoLimite = valor(i).flatMap { Int($0) }; i += 1
            case "--dir", "--root", "-r":
                if let d = valor(i) {
                    raiz = ctx.resolve(d)
                }
                i += 1
            case "--passWithNoTests":
                semTestesOk = true
            case "--reporter=verbose":
                detalhado = true
            default:
                if a.hasPrefix("--testNamePattern=") {
                    padrao = String(a.dropFirst("--testNamePattern=".count))
                } else if a.hasPrefix("--testTimeout=") {
                    tempoLimite = Int(a.dropFirst("--testTimeout=".count))
                } else if a == "--reporter", valor(i) == "verbose" {
                    detalhado = true; i += 1
                } else if comValor.contains(a) {
                    i += 1
                } else if !a.hasPrefix("-") {
                    filtros.append(a)
                }
            }
            i += 1
        }
        io.out(tr(
            "vitest: o vitest de verdade não roda no iPad (precisa de worker_threads e do binário nativo do vite); usando o executor embutido da Odete"
        ))
        if let ignorado = Self.configDoVitestIgnorada(raiz) {
            io.err(tr("aviso: %1$@ usa %2$@, que o executor embutido não aplica", ignorado.arquivo, ignorado.opcao))
        }
        let arquivos = ExecutorDeTestes.arquivos(em: raiz, filtros: filtros)
        guard !arquivos.isEmpty else {
            io.err(tr(
                "Nenhum arquivo de teste encontrado (*.test.ts, *.spec.js, …)%1$@",
                filtros.isEmpty ? "" : ": " + filtros.joined(separator: " ")
            ))
            return semTestesOk ? 0 : 1
        }
        let opcoes = ExecutorDeTestes.Opcoes(
            raiz: raiz.path,
            versao: versao,
            arquivos: arquivos.map(\.path),
            padrao: padrao,
            tempoLimite: tempoLimite,
            detalhado: detalhado
        )
        return await NodeCommand.runProcess(
            NodeCommand.Alvo(code: nil, file: ExecutorDeTestes.script, argv: [opcoes.json], label: "vitest run"),
            ctx: ctx,
            esbuild: ctx.shell.esbuildEngine()
        )
    }

    /// O que a config do vitest pede e o executor embutido não faz: `setupFiles` e ambiente
    /// de navegador (jsdom, happy-dom). Sem executar a config — ela importa o vite —, só
    /// lendo o texto. Melhor avisar do que ver o teste falhar sem saber por quê.
    static func configDoVitestIgnorada(_ raiz: URL) -> (arquivo: String, opcao: String)? {
        let nomes = ["vitest.config", "vite.config"].flatMap { base in
            ["ts", "mts", "js", "mjs", "cts", "cjs"].map { "\(base).\($0)" }
        }
        for nome in nomes {
            guard let texto = try? String(contentsOf: raiz.appending(path: nome), encoding: .utf8) else { continue }
            if texto.contains("setupFiles") {
                return (nome, "setupFiles")
            }
            if let m = texto.firstMatch(of: /environment\s*:\s*["'](jsdom|happy-dom|edge-runtime)["']/) {
                return (nome, "environment: \(m.1)")
            }
        }
        return nil
    }

    /// `version` do package.json de um pacote instalado no projeto.
    static func versaoInstalada(_ pacote: String, root: URL) -> String? {
        let pkg = root.appending(path: "node_modules/\(pacote)/package.json")
        guard let d = try? Data(contentsOf: pkg),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["version"] as? String
    }

    func portArg(_ args: [String]) -> Int? {
        if let i = args.firstIndex(where: { $0 == "--port" || $0 == "-p" }),
           i + 1 < args.count
        {
            return Int(args[i + 1])
        }
        return args.first { $0.hasPrefix("--port=") }.flatMap { Int($0.dropFirst(7)) }
    }

    func devServer(_ ctx: CommandContext, preset: DevServer.Preset, port: Int, label: String) async -> Int32 {
        let io = ctx.io
        if let existing = ctx.shell.devServer {
            io.out(tr("dev server já está em http://127.0.0.1:%1$@", "\(existing.port)"))
            ctx.shell.services.onServer(existing.port, label)
            return 0
        }
        // Outra aba pode ter subido o servidor. Antes cada aba só enxergava o seu, e o
        // segundo `npm run dev` subia um servidor inteiro numa porta vizinha — dois
        // esbuild na memória e um preview apontando para o que não recarrega.
        if let jaTem = ctx.shell.services.servidorAtivo?() {
            io.out(tr("dev server já está em http://127.0.0.1:%1$@ (%2$@)", "\(jaTem.porta)", "\(jaTem.comando)"))
            io.out(tr("  kill all para derrubar antes de subir outro"))
            ctx.shell.services.onServer(jaTem.porta, jaTem.comando)
            return 0
        }
        // No esbuild do projeto, o mesmo que o lint e o `node x.ts` usam: subir o servidor
        // não compila um segundo motor, e parar o servidor não derruba o dos outros.
        let dev = DevServer(esbuild: ctx.shell.esbuildEngine(), root: ctx.root) { kind, text in
            kind == .out ? io.out(text) : io.err(text)
        }
        dev.onDiagnostics = ctx.shell.services.onDiagnostics
        do {
            io.out(tr("  %1$@: carregando esbuild…", "\(label)"))
            try await dev.start(port: port, preset: preset)
        } catch { io.err("\(label): \(error.localizedDescription)"); return 1 }
        ctx.shell.devServer = dev
        let missing = EsmFallback.missing(project: ctx.root)
        if !missing
            .isEmpty
        {
            io
                .err(
                    tr(
                        "aviso: %1$@ não instalados; o preview vai buscar no esm.sh",
                        "\(missing.keys.sorted().joined(separator: ", "))"
                    )
                )
        }
        let job = ctx.shell.registerJob(label, ports: [dev.port]) { dev.stop(); ctx.shell.devServer = nil }
        io.out(tr("  ➜  Local:   http://127.0.0.1:%1$@/   (job %2$@)", "\(dev.port)", "\(job.id)"))
        return 0
    }

    /// `vite build [--mode m] [--base b] [--outDir d]`: `ViteBuild`, no esbuild do projeto.
    func build(_ ctx: CommandContext, _ args: [String]) async -> Int32 {
        let io = ctx.io
        let opcoes = ViteBuild.Opcoes(
            modo: opcao("--mode", args) ?? opcao("-m", args) ?? "production",
            base: opcao("--base", args),
            saida: opcao("--outDir", args)
        )
        do {
            let r = try await ViteBuild.rodar(raiz: ctx.root, esbuild: ctx.shell.esbuildEngine(), opcoes: opcoes)
            for d in r.diagnosticos {
                (d.kind == .error ? io.err : io.out)("\(d.file ?? ""):\(d.line ?? 0): \(d.text)")
            }
            guard r.ok else { return 1 }
            for g in r.gravados {
                io.out("  \(g.caminho)  \(Tamanho.arquivo(g.bytes))")
            }
            io.out(r.saida == "dist" ? tr("✓ build em dist/") : tr("✓ build em %1$@/", r.saida))
            return 0
        } catch { io.err(tr("vite build: %1$@", "\(error.localizedDescription)")); return 1 }
    }

    /// O valor de `--nome valor` ou `--nome=valor`.
    func opcao(_ nome: String, _ args: [String]) -> String? {
        if let i = args.firstIndex(of: nome), i + 1 < args.count {
            return args[i + 1]
        }
        return args.first { $0.hasPrefix(nome + "=") }.map { String($0.dropFirst(nome.count + 1)) }
    }

    func serveStatic(_ ctx: CommandContext, dir: String, port: Int = 4173, base: String = "/") async -> Int32 {
        let io = ctx.io
        let pasta = ctx.resolve(dir)
        // `vite preview` serve dist/, mas no motor do projeto: servir estático não justifica
        // compilar outro esbuild só porque a raiz servida é outra.
        let dev = DevServer(esbuild: ctx.shell.esbuildEngine(), root: pasta) { k, t in
            k == .out ? io.out(t) : io.err(t)
        }
        do { try await dev.start(port: port, preset: .plain, base: base) } catch {
            io.err(error.localizedDescription); return 1
        }
        let job = ctx.shell.registerJob("serve \(dir)", ports: [dev.port]) { dev.stop() }
        io.out(tr("  ➜  http://127.0.0.1:%1$@/   (job %2$@)", "\(dev.port)", "\(job.id)"))
        return 0
    }
}
