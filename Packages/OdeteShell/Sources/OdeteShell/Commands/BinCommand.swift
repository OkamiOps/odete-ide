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

    /// O binário no `node_modules/.bin` mais próximo, subindo de `desde` até a raiz — é o
    /// PATH que o npm monta para scripts e para o npx.
    static func binPath(_ name: String, desde: URL, raiz: URL) -> URL? {
        for pasta in pastasAcima(desde, raiz: raiz) {
            if let achado = binPath(name, root: pasta) {
                return achado
            }
        }
        return nil
    }

    /// `desde` e cada pasta acima dela, até a raiz do projeto (inclusive).
    static func pastasAcima(_ desde: URL, raiz: URL) -> [URL] {
        let base = raiz.standardizedFileURL.path
        var atual = desde.standardizedFileURL
        var out: [URL] = []
        while atual.path.hasPrefix(base) {
            out.append(atual)
            if atual.path == base {
                break
            }
            atual = atual.deletingLastPathComponent().standardizedFileURL
        }
        return out.isEmpty ? [raiz] : out
    }

    /// A pasta do package.json mais próximo, subindo da pasta atual até a raiz — como o
    /// npm acha o projeto. Sem nenhum, a raiz.
    static func pastaDoPacote(_ ctx: CommandContext) -> URL {
        pastasAcima(ctx.cwd, raiz: ctx.root).first {
            FileManager.default.fileExists(atPath: $0.appending(path: "package.json").path)
        } ?? ctx.root
    }

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        // `npx -y create-vite app`, `npx --package=x y`: as opções do npx vêm antes do
        // binário e não são o binário. Sem terminal interativo não há o que perguntar, então
        // o `-y` e a falta dele dão no mesmo: o que não está no projeto é baixado.
        var args = args
        var pacote: String?
        while let a = args.first, a.hasPrefix("-") {
            args.removeFirst()
            switch a {
            case "-y", "--yes", "--no", "--no-install", "-q", "--quiet": break
            case "-p", "--package":
                if !args.isEmpty {
                    pacote = args.removeFirst()
                }
            default:
                if a.hasPrefix("--package=") {
                    pacote = String(a.dropFirst("--package=".count))
                }
            }
        }
        guard let pedido = args.first else { io.err(tr("npx <binário>")); return 1 }
        // `npx create-vite@latest`: o binário é o nome sem a versão (e sem o escopo).
        let spec = Installer.Spec(pedido)
        let bin = pacote == nil ? (spec.name.split(separator: "/").last.map(String.init) ?? spec.name) : pedido
        let rest = Array(args.dropFirst())
        switch bin {
        case "vite":
            if rest.first == "build" {
                return await build(ctx, Array(rest.dropFirst()))
            }
            if rest.first == "preview" {
                // Serve o que o build gravou, onde o build gravou, sob o mesmo `base`.
                let config = ViteBuild.configDoVite(Self.pastaDoPacote(ctx))
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
        case "tsc" where Self.typescriptNativo(root: Self.pastaDoPacote(ctx)) != nil, "tsgo":
            let versao = Self.typescriptNativo(root: Self.pastaDoPacote(ctx)) ?? "7"
            io.err(tr(
                "%1$@: o TypeScript %2$@ é o compilador nativo (Go) e não roda no iPad. Para checar tipos aqui, instale o compilador em JavaScript: npm i -D typescript@6",
                bin,
                versao
            ))
            return 1
        default:
            var achado = Self.binPath(bin, desde: ctx.cwd, raiz: ctx.root)
            if achado == nil {
                // Como o npx: o que não está no projeto é baixado para um cache e roda de lá.
                achado = await baixarParaONpx(pacote ?? pedido, bin: bin, ctx)
            }
            guard let file = achado
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
        let versao = Self.versaoInstalada("vitest", root: Self.pastaDoPacote(ctx)) ?? "5"
        var filtros: [String] = []
        var padrao: String?
        var tempoLimite: Int?
        var detalhado = false
        var semTestesOk = false
        var raiz = Self.pastaDoPacote(ctx)
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

    /// Instala `spec` num cache só do npx (um projeto por pacote pedido) e devolve o
    /// binário. É o `npx -y create-vite@latest app`: nada disso entra no projeto.
    func baixarParaONpx(_ spec: String, bin: String, _ ctx: CommandContext) async -> URL? {
        let io = ctx.io
        let chave = spec.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "odete-npx/\(chave)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let pj = cache.appending(path: "package.json")
            if !FileManager.default.fileExists(atPath: pj.path) {
                try #"{"name":"odete-npx","private":true}"#.write(to: pj, atomically: true, encoding: .utf8)
            }
            io.out(tr("npx: instalando %1$@…", spec))
            let installer = Installer(project: cache, registry: ctx.shell.services.registry) { _ in }
            let rep = try await installer.install(add: [Installer.Spec(spec)])
            for (n, e) in rep.failed.sorted(by: { $0.key < $1.key }) {
                io.err(tr("falhou: %1$@: %2$@", "\(n)", "\(e)"))
            }
            if let achado = Self.binPath(bin, root: cache) {
                return achado
            }
            // Pacote com um binário só, de nome diferente do pacote.
            let nome = PackageJSON(url: pj).dependencies.keys.first ?? ""
            let bins = PackageJSON(url: cache.appending(path: "node_modules/\(nome)/package.json")).bin
            if bins.count == 1, let unico = bins.keys.first {
                return Self.binPath(unico, root: cache)
            }
            return nil
        } catch {
            io.err("npx: \(error.localizedDescription)")
            return nil
        }
    }

    /// Roda o `npm install` quando falta dependência do package.json em node_modules, com
    /// a saída no terminal. Devolve `false` se ainda faltar alguma depois — aí o servidor
    /// não sobe: a página sairia preta. Sem rede, o erro diz isso.
    static func instalarOQueFalta(_ ctx: CommandContext, raiz: URL, label: String) async -> Bool {
        let io = ctx.io
        let faltam = Faltando.dependencias(projeto: raiz)
        guard !faltam.isEmpty else { return true }
        let nomes = faltam.prefix(4).joined(separator: ", ")
            + (faltam.count > 4 ? tr(" e mais %1$@", "\(faltam.count - 4)") : "")
        io.out(tr("  %1$@: faltam pacotes em node_modules (%2$@); rodando npm install", label, nomes))
        let installer = Installer(project: raiz, registry: ctx.shell.services.registry) { io.out($0) }
        NpmCommand.ensureGitignore(installer, io: io)
        let semRede = tr(
            "%1$@: sem conexão, não deu para instalar as dependências, e sem elas o Preview não abre. Conecte-se à internet e rode npm run dev de novo.",
            label
        )
        let rep: Installer.Report
        do {
            rep = try await installer.install()
        } catch {
            io.err("npm: \(error.localizedDescription)")
            if Installer.ehErroDeRede(error) {
                io.err(semRede)
            }
            return false
        }
        NpmCommand.relatar(rep, ctx: ctx, raiz: raiz)
        // Pacote só de outro sistema (`"os": ["linux"]`) nunca vai estar lá, e não é por
        // ele que o servidor deixa de subir.
        let aindaFaltam = Faltando.dependencias(projeto: raiz).filter { nome in
            !rep.plataforma.contains { $0.hasPrefix(nome + " ") }
        }
        guard aindaFaltam.isEmpty else {
            if rep.semRede {
                io.err(semRede)
            } else {
                io.err(tr(
                    "%1$@: o servidor não sobe sem %2$@ em node_modules; confira os erros acima e rode npm install",
                    label,
                    aindaFaltam.joined(separator: ", ")
                ))
            }
            return false
        }
        return true
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
        let raiz = Self.pastaDoPacote(ctx)
        // Projeto recém-criado (ou recém-clonado) sem node_modules: instala antes. Antes o
        // servidor subia assim mesmo e mandava os pacotes para o esm.sh — misturado com o
        // que houvesse em node_modules, eram duas cópias do React e o Preview preto.
        if await !Self.instalarOQueFalta(ctx, raiz: raiz, label: label) {
            return 1
        }
        // Um `npm install` recém-terminado pode estar aquecendo o pacote de dependências
        // neste motor: esperar sai mais barato que fazer o mesmo pacote duas vezes.
        if Aquecimento.emAndamento(raiz: raiz) {
            io.out(tr("  %1$@: terminando de preparar o pacote de dependências…", label))
            _ = await Aquecimento.esperar(raiz: raiz)
        }
        // No esbuild do projeto, o mesmo que o lint e o `node x.ts` usam: subir o servidor
        // não compila um segundo motor, e parar o servidor não derruba o dos outros.
        let dev = DevServer(esbuild: ctx.shell.esbuildEngine(), root: raiz) { kind, text in
            kind == .out ? io.out(text) : io.err(text)
        }
        dev.onDiagnostics = ctx.shell.services.onDiagnostics
        do {
            io.out(tr("  %1$@: carregando esbuild…", "\(label)"))
            try await dev.start(port: port, preset: preset)
        } catch { io.err("\(label): \(error.localizedDescription)"); return 1 }
        ctx.shell.devServer = dev
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
            let r = try await ViteBuild.rodar(
                raiz: Self.pastaDoPacote(ctx),
                esbuild: ctx.shell.esbuildEngine(),
                opcoes: opcoes
            )
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
