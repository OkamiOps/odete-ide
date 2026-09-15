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
        "vite", "astro", "next", "nest", "serve", "http-server", "tsx", "ts-node",
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
                return await build(ctx, entryHTML: true)
            }
            if rest.first == "preview" {
                return await serveStatic(ctx, dir: "dist")
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
        let dev = DevServer(root: ctx.root) { kind, text in kind == .out ? io.out(text) : io.err(text) }
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

    func build(_ ctx: CommandContext, entryHTML: Bool) async -> Int32 {
        let io = ctx.io
        let es = ctx.shell.esbuildEngine()
        let index = ctx.root.appending(path: "index.html")
        guard let html = try? String(contentsOf: index, encoding: .utf8)
        else { io.err(tr("vite build: sem index.html")); return 1 }
        let entries = html.matches(of: /<script\s+type="module"\s+src="([^"]+)"/)
            .map { String($0.1).replacingOccurrences(
                of: "^/",
                with: "",
                options: .regularExpression
            ) }
        guard !entries.isEmpty
        else { io.err(tr("vite build: nenhum <script type=module src> no index.html")); return 1 }
        do {
            let r = try await es.build(entries: entries, dev: false, minify: true)
            for d in r.diagnostics {
                (d.kind == .error ? io.err : io.out)("\(d.file ?? ""):\(d.line ?? 0): \(d.text)")
            }
            guard r.ok else { return 1 }
            let dist = ctx.root.appending(path: "dist")
            try? FileManager.default.removeItem(at: dist)
            try FileManager.default.createDirectory(
                at: dist.appending(path: "assets"),
                withIntermediateDirectories: true
            )
            var out = html
            for f in r.files {
                let name = "assets/" + (f.path as NSString).lastPathComponent
                try f.text.write(to: dist.appending(path: name), atomically: true, encoding: .utf8)
                io
                    .out(
                        "  dist/\(name)  \(Tamanho.arquivo(f.text.utf8.count))"
                    )
            }
            for e in entries {
                let js = "assets/" + ((e as NSString).deletingPathExtension as NSString).lastPathComponent + ".js"
                let css = "assets/" + ((e as NSString).deletingPathExtension as NSString).lastPathComponent + ".css"
                let hasCSS = r.files.contains { $0.path.hasSuffix(".css") }
                out = out.replacingOccurrences(of: "src=\"/\(e)\"", with: "src=\"/\(js)\"").replacingOccurrences(
                    of: "src=\"\(e)\"",
                    with: "src=\"/\(js)\""
                )
                if hasCSS {
                    out = out.replacingOccurrences(
                        of: "</head>",
                        with: "<link rel=\"stylesheet\" href=\"/\(css)\"></head>"
                    )
                }
            }
            try out.write(to: dist.appending(path: "index.html"), atomically: true, encoding: .utf8)
            if let pub = try? FileManager.default.contentsOfDirectory(
                at: ctx.root.appending(path: "public"),
                includingPropertiesForKeys: nil
            ) {
                for item in pub {
                    try? FileManager.default.copyItem(
                        at: item,
                        to: dist.appending(path: item.lastPathComponent)
                    )
                }
            }
            io.out(tr("✓ build em dist/"))
            return 0
        } catch { io.err(tr("vite build: %1$@", "\(error.localizedDescription)")); return 1 }
    }

    func serveStatic(_ ctx: CommandContext, dir: String) async -> Int32 {
        let io = ctx.io
        let base = ctx.resolve(dir)
        let dev = DevServer(root: base) { k, t in k == .out ? io.out(t) : io.err(t) }
        do { try await dev.start(port: 4173, preset: .plain) } catch { io.err(error.localizedDescription); return 1 }
        let job = ctx.shell.registerJob("serve \(dir)", ports: [dev.port]) { dev.stop() }
        io.out(tr("  ➜  http://127.0.0.1:%1$@/   (job %2$@)", "\(dev.port)", "\(job.id)"))
        return 0
    }
}
