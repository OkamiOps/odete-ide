import Foundation
import OdeteI18n
import OdeteRuntime

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
        if let i = argv.firstIndex(where: { $0 == "-e" || $0 == "--eval" }),
           i + 1 < argv.count
        {
            code = argv[i + 1]; argv.removeSubrange(i ... i + 1)
        } else if let i = argv.firstIndex(where: { $0 == "-p" || $0 == "--print" }),
                  i + 1 < argv.count
        {
            code = "console.log(" + argv[i + 1] + ")"; argv.removeSubrange(i ... i + 1)
        } else {
            let f = argv.removeFirst()
            file = ctx.resolve(f)
            guard let file,
                  FileManager.default.fileExists(atPath: file.path) || FileManager.default
                  .fileExists(atPath: file.path + ".js") else { io.err(tr("node: não achei %1$@", "\(f)")); return 1 }
        }
        return await Self.runProcess(
            Alvo(code: code, file: file, argv: argv, label: "node " + args.joined(separator: " ")),
            ctx: ctx,
            esbuild: esbuild
        )
    }

    /// O que rodar: código solto ou arquivo, com os argumentos dele.
    struct Alvo {
        var code: String?
        var file: URL?
        var argv: [String]
        var label: String
    }

    /// Roda um processo JS; se abrir servidor, vira job e o prompt volta.
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
            argv: (file.map { [$0.path] } ?? ["[eval]"]) + argv
        ) { kind, text in
            kind == .out ? io.out(text) : io.err(text)
        }
        p.setTransform(esbuild.cjsTransform)
        let task = Task { () -> Int32 in
            if let code {
                return await p.run(code: code)
            }
            return await p.run(file: file!)
        }
        // espera até 1,5 s: se o processo abriu porta, vira job
        for _ in 0 ..< 15 {
            try? await Task.sleep(for: .milliseconds(100))
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
            if task.isCancelled {
                break
            }
        }
        // ainda rodando sem porta: espera terminar, checando cancelamento
        while true {
            if ctx.isCancelled() {
                p.kill(); break
            }
            if let v = await withTimeout(task, ms: 200) {
                return v
            }
        }
        return await task.value
    }

    static func withTimeout(_ task: Task<Int32, Never>, ms: Int) async -> Int32? {
        await withTaskGroup(of: Int32?.self) { g in
            g.addTask { await task.value }
            g.addTask { try? await Task.sleep(for: .milliseconds(ms)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }
}

public typealias OdeteBundlerEsbuild = OdeteBundler.Esbuild
import OdeteBundler
