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
        let fim = Termino()
        let task = Task { () -> Int32 in
            let c = if let code {
                await p.run(code: code)
            } else {
                await p.run(file: file!)
            }
            fim.marcar(c)
            return c
        }
        // Olha o processo a cada 20 ms: acabou, devolve na hora; nos primeiros 1,5 s, se
        // abriu porta, vira job. Antes o laço dormia os 1,5 s inteiros mesmo com o processo
        // já terminado — todo `node`/`npx` levava no mínimo 1,5 s — e depois esperava num
        // grupo de tasks que só volta quando o processo acaba, então Ctrl+C não chegava.
        // Passada a janela do job, 200 ms: um processo longo sem porta (watcher, script
        // demorado) não acorda o iPad 50 vezes por segundo, e o Ctrl+C responde como antes.
        let inicio = ContinuousClock.now
        while true {
            if let c = fim.codigo {
                return c
            }
            if ctx.isCancelled() {
                p.kill(); return await task.value
            }
            let naJanela = ContinuousClock.now - inicio < .milliseconds(1500)
            if naJanela {
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
            }
            try? await Task.sleep(for: .milliseconds(naJanela ? 20 : 200))
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
