import Foundation
import OdeteI18n
import OdeteNpm

/// `npm install|i|add|uninstall|remove|ls|run|start|dev|build|test|init|exec` (+ `npx`, `pnpm`, `yarn` como aliases).
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
    let help = "install, uninstall, ls, run <script>, start, dev, build, init"

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        guard let sub = args.first else { io.out(tr("npm <install|uninstall|ls|run|init>")); return 0 }
        let rest = Array(args.dropFirst())
        let pkg = PackageJSON(url: ctx.root.appending(path: "package.json"))
        let installer = Installer(project: ctx.root, registry: ctx.shell.services.registry) { line in io.out(line) }
        do {
            switch sub {
            case "install", "i", "add":
                let dev = rest.contains("-D") || rest.contains("--save-dev")
                let specs = rest.filter { !$0.hasPrefix("-") }.map(Installer.Spec.init)
                if !FileManager.default.fileExists(atPath: ctx.root.appending(path: "package.json").path) {
                    try #"{"name":"\#(ctx.root.lastPathComponent)","private":true,"version":"0.0.0","type":"module","scripts":{},"dependencies":{}}"#
                        .write(
                            to: ctx.root.appending(path: "package.json"),
                            atomically: true,
                            encoding: .utf8
                        )
                    io.out(tr("package.json criado"))
                }
                Self.ensureGitignore(installer, io: io)
                let rep = try await installer.install(add: specs, dev: dev)
                for a in rep.added {
                    io.out("+ \(a)")
                }
                io
                    .out("\(rep.installed.count) pacote(s) instalado(s)" +
                        (rep.installed.isEmpty ? tr(" (já estava tudo lá)") : ""))
                if !rep.nativosCobertos.isEmpty {
                    io.out(tr(
                        "%1$@ ferramenta(s) nativa(s) com equivalente embutido na Odete",
                        "\(rep.nativosCobertos.count)"
                    ))
                }
                for n in rep.native {
                    io.err(tr("aviso: %1$@ tem código nativo e não roda no iPad", "\(n)"))
                }
                // `npm i -D typescript` hoje traz o 7, que é só um lançador do binário em Go.
                if rep.installed.contains(where: { $0.name == "typescript" }),
                   let v = BinCommand.typescriptNativo(root: ctx.root)
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
                // Estes são de verdade: a dependência não vai estar lá.
                for s in rep.skipped {
                    io.err("ignorado: \(s)")
                }
                for a in rep.avisos {
                    io.err("aviso: \(a)")
                }
                for (n, e) in rep.failed {
                    io.err(tr("falhou: %1$@: %2$@", "\(n)", "\(e)"))
                }
                return rep.failed.isEmpty ? 0 : 1
            case "uninstall", "remove", "rm", "un":
                _ = try await installer.uninstall(rest.filter { !$0.hasPrefix("-") })
                io.out(tr("removido: %1$@", "\(rest.joined(separator: " "))"))
            case "ls", "list":
                let list = installer.list()
                if list.isEmpty {
                    io.out(tr("nenhum pacote instalado (rode npm install)"))
                }
                for p in list {
                    io.out("\(p.name)@\(p.version)\(p.dev ? " (dev)" : "")\(p.native ? "  [nativo, não roda]" : "")")
                }
            case "init":
                if FileManager.default
                    .fileExists(atPath: ctx.root.appending(path: "package.json").path)
                {
                    io.out(tr("package.json já existe"))
                } else {
                    try #"{"name":"\#(ctx.root.lastPathComponent)","private":true,"version":"0.0.0","type":"module","scripts":{"dev":"vite","build":"vite build"},"dependencies":{}}"#
                        .write(
                            to: ctx.root.appending(path: "package.json"),
                            atomically: true,
                            encoding: .utf8
                        )
                    io.out(tr("package.json criado"))
                }
            case "run", "run-script":
                guard let script = rest.first
                else {
                    for (k, v) in pkg.scripts.sorted(by: { $0.key < $1.key }) {
                        io.out("  \(k): \(v)")
                    }; return 0
                }
                guard let cmd = pkg.scripts[script]
                else { io.err(tr("npm: script \"%1$@\" não existe em package.json", "\(script)")); return 1 }
                io.out("> \(cmd)")
                return await ctx.shell
                    .run(cmd + (rest.count > 1 ? " " + rest.dropFirst().joined(separator: " ") : "")) { kind, text in
                        kind == .out ? io.out(text) : io.err(text)
                    }
            case "start", "dev", "build", "test", "preview", "lint":
                if let cmd = pkg
                    .scripts[sub]
                {
                    io.out("> \(cmd)"); return await ctx.shell.run(cmd) { kind, text in
                        kind == .out ? io.out(text) : io.err(text)
                    }
                }
                if sub == "start",
                   FileManager.default
                   .fileExists(atPath: ctx.root.appending(path: "index.js").path)
                {
                    return await ctx.shell.run("node index.js") { k, t in k == .out ? io.out(t) : io.err(t) }
                }
                io.err(tr("npm: script \"%1$@\" não existe em package.json", "\(sub)")); return 1
            case "exec", "x", "dlx":
                return await BinCommand().run(rest, ctx)
            case "-v", "--version", "version": io.out(tr("odete-npm 0.1 (registro real, sem Node)"))
            case "cache": io.out(tr("cache em Library/Caches/odete-npm"))
            default: io.err(tr("npm: comando não suportado: %1$@", "\(sub)")); return 1
            }
            return 0
        } catch { io.err("npm: \(error.localizedDescription)"); return 1 }
    }
}
