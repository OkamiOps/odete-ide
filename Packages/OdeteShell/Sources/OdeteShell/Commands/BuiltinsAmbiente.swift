import Foundation
import OdeteI18n

/// A outra metade dos embutidos: ambiente, jobs, tempo e utilidades.
extension Builtins {
    static let ambiente: [ShellCommand] = [
        Simple(name: "env", help: "variáveis") { _, ctx in
            for (k, v) in ctx.env.sorted(by: { $0.key < $1.key }) {
                ctx.io.out("\(k)=\(v)")
            }; return 0
        },
        Simple(name: "export", help: "define variável") { args, ctx in
            for a in args {
                if let i = a.firstIndex(of: "=") {
                    ctx.shell.env[String(a[..<i])] = String(a[a.index(after: i)...])
                }
            }
            return 0
        },
        Simple(name: "which", help: "onde está o comando") { args, ctx in
            for a in args {
                if ctx.shell.command(named: a) != nil {
                    ctx.io.out("odete: \(a)")
                } else if let p = BinCommand.binPath(
                    a,
                    root: ctx.root
                ) {
                    ctx.io.out(ctx.display(p))
                } else {
                    ctx.io.err(tr("%1$@ não encontrado", "\(a)")); return 1
                }
            }
            return 0
        },
        Simple(name: "clear", help: "limpa a tela") { _, ctx in ctx.io.out("\u{1B}[clear]"); return 0 },
        Simple(name: "history", help: "histórico") { _, ctx in
            for (i, h) in ctx.shell.history.enumerated() {
                ctx.io.out(tr("%1$@  %2$@", "\(String(i + 1).leftPad(4))", "\(h)"))
            }; return 0
        },
        Simple(name: "swift", help: "explica como rodar Swift no iPad") { _, ctx in
            ctx.io.out(tr("Não há compilador Swift no iPad. O Preview mostra o subconjunto de SwiftUI na hora;"))
            ctx.io
                .out(
                    tr(
                        "para compilar e rodar de verdade, abra o pacote .swiftpm no Swift Playgrounds (botão no Preview)."
                    )
                )
            return 1
        },
        Simple(name: "date", help: "data e hora") { _, ctx in ctx.io.out(Date().noIdioma(
            date: .complete,
            time: .standard
        )); return 0 },
        Simple(name: "sleep", help: "espera N segundos") { args, _ in
            try? await Task.sleep(for: .seconds(Double(args.first ?? "1") ?? 1)); return 0
        },
        Simple(name: "true", help: "sai com 0") { _, _ in 0 },
        Simple(name: "false", help: "sai com 1") { _, _ in 1 },
        Simple(name: "jobs", help: "jobs em execução") { _, ctx in
            let js = ctx.shell.jobs
            if js.isEmpty {
                ctx.io.out(tr("nenhum job"))
            }
            for j in js {
                ctx.io
                    .out("[\(j.id)] \(j.command)" +
                        (j.ports
                            .isEmpty ? "" : "  http://127.0.0.1:\(j.ports.map(String.init).joined(separator: ","))"))
            }
            return 0
        },
        Simple(name: "kill", help: "para um job (kill %1 ou kill all)") { args, ctx in
            if args.first == "all" || args.isEmpty {
                // O servidor costuma subir numa aba e ser morto de outra.
                if let todos = ctx.shell.services.onKillAll {
                    todos()
                } else {
                    ctx.shell.killAll()
                }
                ctx.io.out(tr("jobs encerrados")); return 0
            }
            // `kill -9 %1`, `kill -TERM %1`: o sinal não muda nada aqui, o job para igual.
            for a in args where !a.hasPrefix("-") {
                let id = Int(a.replacingOccurrences(of: "%", with: "")); if let j = ctx.shell.jobs
                    .first(where: { $0.id == id })
                {
                    j.kill(); ctx.io.out(tr("[%1$@] parado", "\(j.id)"))
                } else {
                    ctx.io.err(tr("kill: job %1$@ não existe nesta aba (kill all para o projeto inteiro)", "\(a)"))
                }
            }
            return 0
        },
        Simple(name: "open", help: "abre o preview numa URL") { args, ctx in
            if let a = args.first,
               let port = Int(a.replacingOccurrences(of: "http://127.0.0.1:", with: "").replacingOccurrences(
                   of: "http://localhost:",
                   with: ""
               ).split(separator: "/").first ?? "")
            {
                ctx.shell.services.onServer(port, "open")
            }
            return 0
        },
    ]
}
