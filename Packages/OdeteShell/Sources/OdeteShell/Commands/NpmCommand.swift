import Foundation
import OdeteBundler
import OdeteI18n
import OdeteNpm

/// `npm install|i|add|ci|uninstall|remove|ls|run|start|dev|build|test|init|exec` (+ `npx`,
/// `pnpm`, `yarn` e `bun` como aliases).
struct NpmCommand: ShellCommand {
    /// Sem .gitignore, node_modules viraria 500 arquivos no painel do git.
    ///
    /// No iCloud são duas linhas em vez de uma: `node_modules` (sem barra, porque ali é
    /// um link, e para o git link não é pasta) e `node_modules.nosync/`, onde os pacotes
    /// estão de verdade. Quem decide é o `Installer`.
    static func ensureGitignore(_ installer: Installer, io: CommandIO) {
        let novas = installer.garantirGitignore()
        guard !novas.isEmpty else { return }
        if novas == ["node_modules/"] {
            io.out(tr(".gitignore: node_modules/ adicionado"))
        } else {
            io.out(tr(".gitignore: %1$@ adicionado(s)", novas.joined(separator: ", ")))
        }
    }

    let name = "npm"
    let help = "install, ci, uninstall, ls, run <script>, start, dev, build, init"
    /// Por qual nome foi chamado: `yarn` e `pnpm` sem argumento instalam, e `yarn dev`
    /// roda o script — o `npm` sem argumento só mostra o uso, como o de verdade.
    var chamadoComo = "npm"

    init(chamadoComo: String = "npm") {
        self.chamadoComo = chamadoComo
    }

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        let gerenciador = chamadoComo != "npm"
        guard let primeiro = args.first else {
            if gerenciador {
                return await instalar([], ctx)
            }
            io.out(tr("npm <install|uninstall|ls|run|init>")); return 0
        }
        let sub = primeiro
        let rest = Array(args.dropFirst())
        // O package.json mais próximo, subindo da pasta atual — como o npm faz. Num
        // monorepo, `cd packages/web && npm run dev` é o dev do web, não o da raiz.
        let pasta = BinCommand.pastaDoPacote(ctx)
        let pkg = PackageJSON(url: pasta.appending(path: "package.json"))
        do {
            switch sub {
            case "install", "i", "add", "in", "isntall":
                return await instalar(rest, ctx)
            case "ci", "clean-install":
                return await ci(ctx)
            case "uninstall", "remove", "rm", "un", "r":
                let installer = Installer(project: pasta, registry: ctx.shell.services.registry) { io.out($0) }
                _ = try await installer.uninstall(rest.filter { !$0.hasPrefix("-") })
                io.out(tr("removido: %1$@", "\(rest.joined(separator: " "))"))
            case "ls", "list":
                let installer = Installer(project: pasta, registry: ctx.shell.services.registry)
                let list = installer.list()
                if list.isEmpty {
                    io.out(tr("nenhum pacote instalado (rode npm install)"))
                }
                for p in list {
                    let nativo = p.native ? tr("  [nativo, não roda]") : ""
                    io.out("\(p.name)@\(p.version)\(p.dev ? " (dev)" : "")\(nativo)")
                }
            case "init":
                if FileManager.default.fileExists(atPath: pasta.appending(path: "package.json").path) {
                    io.out(tr("package.json já existe"))
                } else {
                    try #"{"name":"\#(pasta.lastPathComponent)","private":true,"version":"0.0.0","type":"module","scripts":{"dev":"vite","build":"vite build"},"dependencies":{}}"#
                        .write(to: pasta.appending(path: "package.json"), atomically: true, encoding: .utf8)
                    io.out(tr("package.json criado"))
                }
            case "run", "run-script", "rum", "urn":
                guard let script = rest.first else {
                    for (k, v) in pkg.scripts.sorted(by: { $0.key < $1.key }) {
                        io.out("  \(k): \(v)")
                    }
                    return 0
                }
                guard pkg.scripts[script] != nil else {
                    io.err(tr("npm: script \"%1$@\" não existe em package.json", "\(script)")); return 1
                }
                return await rodarScript(script, extras: Array(rest.dropFirst()), pkg, ctx)
            case "start", "dev", "build", "test", "t", "preview", "lint", "stop", "restart":
                let script = sub == "t" ? "test" : sub
                if pkg.scripts[script] != nil {
                    return await rodarScript(script, extras: rest, pkg, ctx)
                }
                if script == "start", FileManager.default.fileExists(atPath: pasta.appending(path: "index.js").path) {
                    return await ctx.shell.run("node index.js") { k, t in k == .out ? io.out(t) : io.err(t) }
                }
                io.err(tr("npm: script \"%1$@\" não existe em package.json", "\(script)")); return 1
            case "exec", "x", "dlx":
                return await BinCommand().run(rest, ctx)
            case "-v", "--version", "version": io.out(tr("odete-npm 0.1 (registro real, sem Node)"))
            case "cache": io.out(tr("cache em Library/Caches/odete-npm"))
            default:
                // `yarn dev`, `pnpm build`: no yarn e no pnpm, script é subcomando.
                if gerenciador, pkg.scripts[sub] != nil {
                    return await rodarScript(sub, extras: rest, pkg, ctx)
                }
                io.err(tr("npm: comando não suportado: %1$@", "\(sub)")); return 1
            }
            return 0
        } catch { io.err("npm: \(error.localizedDescription)"); return 1 }
    }

    /// `npm run x`: `prex`, `x` e `postx`, parando no primeiro que falhar — como o npm.
    /// Os argumentos a mais vão só para o `x`.
    func rodarScript(_ script: String, extras: [String], _ pkg: PackageJSON, _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        let argumentos = extras.first == "--" ? Array(extras.dropFirst()) : extras
        for (nome, comArgs) in [("pre" + script, false), (script, true), ("post" + script, false)] {
            guard let cmd = pkg.scripts[nome] else { continue }
            let linha = cmd + (comArgs && !argumentos.isEmpty ? " " + argumentos.joined(separator: " ") : "")
            io.out("> \(linha)")
            let codigo = await ctx.shell.run(linha) { kind, text in
                kind == .out ? io.out(text) : io.err(text)
            }
            if codigo != 0 {
                return codigo
            }
        }
        return 0
    }

    /// `npm install [pacotes]`, `yarn add`, `pnpm i`: instala e, no fim, aquece o dev
    /// server em segundo plano para o primeiro `npm run dev` já achar tudo pronto.
    func instalar(_ rest: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        let pasta = BinCommand.pastaDoPacote(ctx)
        let dev = rest.contains { ["-D", "--save-dev", "--dev", "-d"].contains($0) }
        let exato = rest.contains { ["-E", "--save-exact", "--exact"].contains($0) }
        let forcar = rest.contains { ["-f", "--force"].contains($0) }
        let specs = rest.filter { !$0.hasPrefix("-") }.map(Installer.Spec.init)
        do {
            if !FileManager.default.fileExists(atPath: pasta.appending(path: "package.json").path) {
                try #"{"name":"\#(pasta.lastPathComponent)","private":true,"version":"0.0.0","type":"module","scripts":{},"dependencies":{}}"#
                    .write(to: pasta.appending(path: "package.json"), atomically: true, encoding: .utf8)
                io.out(tr("package.json criado"))
            }
            let installer = Installer(project: pasta, registry: ctx.shell.services.registry) { line in io.out(line) }
            Self.ensureGitignore(installer, io: io)
            let rep = try await installer.install(add: specs, dev: dev, force: forcar, exato: exato)
            let codigo = Self.relatar(rep, ctx: ctx, raiz: pasta)
            if codigo == 0 {
                Self.aquecerDepoisDoInstall(ctx, pasta)
            }
            return codigo
        } catch {
            io.err("npm: \(error.localizedDescription)")
            if Installer.ehErroDeRede(error) {
                io.err(tr("sem conexão com o registro do npm: confira a internet e rode de novo"))
            }
            return 1
        }
    }

    func ci(_ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        let pasta = BinCommand.pastaDoPacote(ctx)
        let installer = Installer(project: pasta, registry: ctx.shell.services.registry) { line in io.out(line) }
        do {
            Self.ensureGitignore(installer, io: io)
            let rep = try await installer.ci()
            let codigo = Self.relatar(rep, ctx: ctx, raiz: pasta)
            if codigo == 0 {
                Self.aquecerDepoisDoInstall(ctx, pasta)
            }
            return codigo
        } catch {
            io.err("npm ci: \(error.localizedDescription)")
            return 1
        }
    }

    /// O pacote de dependências do dev server, feito agora e não no primeiro
    /// `npm run dev` (ver `Aquecimento`). Não segura o terminal: quem subir o servidor
    /// antes de terminar espera por ele em vez de fazer o mesmo trabalho de novo.
    static func aquecerDepoisDoInstall(_ ctx: CommandContext, _ pasta: URL) {
        guard FileManager.default.fileExists(atPath: pasta.appending(path: "index.html").path) else { return }
        ctx.io.out(tr("preparando o dev server em segundo plano (esbuild e pacote de dependências)"))
        Aquecimento.aquecer(esbuild: ctx.shell.esbuildEngine(), raiz: pasta)
    }

    /// O resumo da instalação, na saída do terminal. Devolve o código de saída: falta de
    /// dependência obrigatória é erro.
    @discardableResult
    static func relatar(_ rep: Installer.Report, ctx: CommandContext, raiz: URL) -> Int32 {
        let io = ctx.io
        for a in rep.added {
            io.out("+ \(a)")
        }
        io.out(
            tr("%1$@ pacote(s) instalado(s)", "\(rep.installed.count)")
                + (rep.installed.isEmpty ? tr(" (já estava tudo lá)") : "")
        )
        if !rep.nativosCobertos.isEmpty {
            io.out(tr(
                "%1$@ ferramenta(s) nativa(s) com equivalente embutido na Odete",
                "\(rep.nativosCobertos.count)"
            ))
        }
        for n in rep.native {
            io.err(tr("aviso: %1$@ tem código nativo e não roda no iPad", "\(n)"))
        }
        // Script de instalação que não rodou (o npm 12 também não roda sem aprovação):
        // uma linha, não um alarme por pacote.
        if !rep.scripts.isEmpty {
            io.out(tr(
                "%1$@ pacote(s) com script de instalação não executado: %2$@",
                "\(rep.scripts.count)",
                rep.scripts.joined(separator: ", ")
            ))
        }
        // `npm i -D typescript` hoje traz o 7, que é só um lançador do binário em Go.
        if rep.installed.contains(where: { $0.name == "typescript" }),
           let v = BinCommand.typescriptNativo(root: raiz)
        {
            io.err(tr(
                "aviso: typescript@%1$@ é o compilador nativo (Go); o tsc dele não roda no iPad. Para checar tipos aqui: npm i -D typescript@6",
                v
            ))
        }
        // Pacote de outra plataforma não é problema: é o rollup e o esbuild
        // trazendo um binário por sistema. Uma linha vermelha para cada um fazia
        // uma instalação certa parecer que tinha dado errado dez vezes.
        if !rep.plataforma.isEmpty {
            let nomes = rep.plataforma.prefix(2)
                .map { $0.split(separator: " ").first.map(String.init) ?? $0 }
                .joined(separator: ", ")
            let resto = rep.plataforma.count - min(2, rep.plataforma.count)
            io.out(
                tr("%1$@ pacote(s) de outros sistemas ignorado(s): ", "\(rep.plataforma.count)")
                    + nomes + (resto > 0 ? tr(" e mais %1$@", "\(resto)") : "")
            )
        }
        // Opcional que não deu: o pacote segue sem ele, como no npm.
        for s in rep.skipped {
            io.err(tr("ignorado: %1$@", "\(s)"))
        }
        for a in rep.avisos {
            io.err(tr("aviso: %1$@", "\(a)"))
        }
        for (n, e) in rep.failed.sorted(by: { $0.key < $1.key }) {
            io.err(tr("falhou: %1$@: %2$@", "\(n)", "\(e)"))
        }
        if rep.semRede {
            io.err(tr("sem conexão com o registro do npm: confira a internet e rode de novo"))
        }
        return rep.failed.isEmpty ? 0 : 1
    }
}
