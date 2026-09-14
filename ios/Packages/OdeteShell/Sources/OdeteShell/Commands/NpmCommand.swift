import Foundation
import OdeteNpm

/// `npm install|i|add|uninstall|remove|ls|run|start|dev|build|test|init|exec` (+ `npx`, `pnpm`, `yarn` como aliases).
struct NpmCommand: ShellCommand {
    let name = "npm"
    let help = "install, uninstall, ls, run <script>, start, dev, build, init"

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        guard let sub = args.first else { io.out("npm <install|uninstall|ls|run|init>"); return 0 }
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
                    io.out("package.json criado")
                }
                let rep = try await installer.install(add: specs, dev: dev)
                for a in rep.added {
                    io.out("+ \(a)")
                }
                io
                    .out("\(rep.installed.count) pacote(s) instalado(s)" +
                        (rep.installed.isEmpty ? " (já estava tudo lá)" : ""))
                for n in rep
                    .native
                {
                    io
                        .err(
                            "aviso: \(n) tem código nativo e não roda no iPad (o esbuild e o swc têm equivalentes embutidos)"
                        )
                }
                for s in rep.skipped {
                    io.err("ignorado: \(s)")
                }
                for (n, e) in rep.failed {
                    io.err("falhou: \(n): \(e)")
                }
                return rep.failed.isEmpty ? 0 : 1
            case "uninstall", "remove", "rm", "un":
                _ = try await installer.uninstall(rest.filter { !$0.hasPrefix("-") })
                io.out("removido: \(rest.joined(separator: " "))")
            case "ls", "list":
                let list = installer.list()
                if list.isEmpty {
                    io.out("nenhum pacote instalado (rode npm install)")
                }
                for p in list {
                    io.out("\(p.name)@\(p.version)\(p.dev ? " (dev)" : "")\(p.native ? "  [nativo, não roda]" : "")")
                }
            case "init":
                if FileManager.default
                    .fileExists(atPath: ctx.root.appending(path: "package.json").path)
                {
                    io.out("package.json já existe")
                } else {
                    try #"{"name":"\#(ctx.root.lastPathComponent)","private":true,"version":"0.0.0","type":"module","scripts":{"dev":"vite","build":"vite build"},"dependencies":{}}"#
                        .write(
                            to: ctx.root.appending(path: "package.json"),
                            atomically: true,
                            encoding: .utf8
                        )
                    io.out("package.json criado")
                }
            case "run", "run-script":
                guard let script = rest.first
                else {
                    for (k, v) in pkg.scripts.sorted(by: { $0.key < $1.key }) {
                        io.out("  \(k): \(v)")
                    }; return 0
                }
                guard let cmd = pkg.scripts[script]
                else { io.err("npm: script \"\(script)\" não existe em package.json"); return 1 }
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
                io.err("npm: script \"\(sub)\" não existe em package.json"); return 1
            case "exec", "x", "dlx":
                return await BinCommand().run(rest, ctx)
            case "-v", "--version", "version": io.out("odete-npm 0.1 (registro real, sem Node)")
            case "cache": io.out("cache em Library/Caches/odete-npm")
            default: io.err("npm: comando não suportado: \(sub)"); return 1
            }
            return 0
        } catch { io.err("npm: \(error.localizedDescription)"); return 1 }
    }
}
