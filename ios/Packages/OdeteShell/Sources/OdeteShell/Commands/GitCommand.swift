import Foundation
import OdeteGit
import OdeteI18n

/// `git` sobre o OdeteGit.
struct GitCommand: ShellCommand {
    let name = "git"
    let help = "status, add, commit, log, diff, branch, checkout, merge, stash, remote, fetch, pull, push, clone, init"

    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        let io = ctx.io
        guard let sub = args.first else { io.out(help); return 0 }
        let rest = Array(args.dropFirst())
        if sub == "init" {
            do {
                _ = try Repository.initialize(at: ctx.root); io
                    .out(tr("Repositório iniciado em %1$@", "\(ctx.display(ctx.root))")); return 0
            } catch {
                io.err(error.localizedDescription); return 1
            }
        }
        if sub == "clone" {
            guard let url = rest.first else { io.err(tr("git clone <url> [pasta]")); return 1 }
            let name = rest.count > 1 ? rest[1] : (url.split(separator: "/").last.map { String($0).replacingOccurrences(
                of: ".git",
                with: ""
            ) } ?? "repo")
            let dest = ctx.resolve(name)
            do {
                _ = try await Repository
                    .clone(url, to: dest, credentials: ctx.shell.services.credentials(url)) { p in
                        if p.total > 0, p.received % 50 == 0 {
                            io.out("  \(p.received)/\(p.total)")
                        }
                    }
                io.out(tr("Clonado em %1$@", "\(ctx.display(dest))")); return 0
            } catch { io.err(error.localizedDescription); return 1 }
        }
        guard Repository.isRepository(ctx.root),
              let repo = try? Repository.open(ctx.root)
        else { io.err(tr("fatal: não é um repositório git (rode git init)")); return 128 }
        let author = ctx.shell.services.author()
        do {
            switch sub {
            case "status":
                let st = try await repo.status()
                let head = await repo.headBranchName()
                let branch = try await repo.currentBranch()?.name ?? head ?? "?"
                io.out(tr("Na branch %1$@", "\(branch)"))
                if let ab = try await repo
                    .aheadBehind()
                {
                    io.out(tr("  ↑%1$@ ↓%2$@ em relação ao upstream", "\(ab.ahead)", "\(ab.behind)"))
                }
                if st.isEmpty {
                    io.out(tr("nada a commitar, working tree limpa")); return 0
                }
                let staged = st.filter { $0.staged != nil }, unstaged = st.filter { $0.unstaged != nil }
                if !staged.isEmpty {
                    io.out("Staged:"); for e in staged {
                        io.out("  \(e.staged!.symbol)  \(e.path)")
                    }
                }
                if !unstaged
                    .isEmpty
                {
                    io.out(tr("Não staged:")); for e in unstaged {
                        io.out("  \(e.unstaged!.symbol)  \(e.path)")
                    }
                }
            case "add":
                if rest.contains(".") || rest.contains("-A") || rest.contains("--all") {
                    try await repo.stageAll()
                } else {
                    try await repo.stage(rest)
                }
            case "reset", "restore":
                // `git reset --soft HEAD~1` é como se desfaz o último commit mantendo o
                // que ele tinha no índice; sem isso o comando não fazia nada.
                if sub == "reset", rest.first == "--soft" {
                    try await repo.undoLastCommit()
                    io.out(tr("desfeito o último commit; o conteúdo ficou no stage"))
                } else if rest.first == "--staged" {
                    try await repo.unstage(Array(rest.dropFirst()))
                } else if sub == "restore" {
                    try await repo.discard(rest)
                } else if rest.isEmpty {
                    try await repo.unstageAll()
                } else {
                    try await repo.unstage(rest)
                }
            case "commit":
                // Um `-m` por parágrafo, como no git de verdade: era só o primeiro que
                // valia, e o agente não tinha como escrever mensagem com corpo.
                var partes: [String] = []
                for (i, a) in rest.enumerated() where a == "-m" || a == "-am" {
                    if i + 1 < rest.count {
                        partes.append(rest[i + 1])
                    }
                }
                // `-F arquivo` é o outro jeito de mandar mensagem comprida, e o agente
                // tenta os dois.
                if let i = rest.firstIndex(of: "-F"), i + 1 < rest.count {
                    let u = ctx.resolve(rest[i + 1])
                    guard let texto = try? String(contentsOf: u, encoding: .utf8) else {
                        io.err(tr("git: não achei o arquivo %1$@", "\(rest[i + 1])"))
                        return 1
                    }
                    partes.append(texto.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                if rest.contains("-a") || rest.contains("-am") {
                    try await repo.stageAll()
                }
                let msg = partes.joined(separator: "\n\n")
                if rest.contains("--amend") {
                    let c = try await repo.amendLastCommit(message: msg.isEmpty ? nil : msg, author: author)
                    try await io.out(tr(
                        "[%1$@ %2$@] %3$@",
                        "\(repo.currentBranch()?.name ?? "main")",
                        "\(c.short)",
                        "\(c.summary)"
                    ))
                    return 0
                }
                guard !msg.isEmpty else { io.err(tr("use git commit -m \"mensagem\"")); return 1 }
                let c = try await repo.commit(message: msg, author: author)
                try await io.out(tr(
                    "[%1$@ %2$@] %3$@",
                    "\(repo.currentBranch()?.name ?? "main")",
                    "\(c.short)",
                    "\(c.summary)"
                ))
            case "log":
                let n = rest.firstIndex(of: "-n")
                    .flatMap { $0 + 1 < rest.count ? Int(rest[$0 + 1]) : nil } ??
                    (rest.first { $0.hasPrefix("-") && Int($0.dropFirst()) != nil }.flatMap { Int($0.dropFirst()) }) ??
                    20
                let oneline = rest.contains("--oneline")
                for c in try await repo.log(limit: n) {
                    if oneline {
                        io.out("\(c.short) \(c.summary)")
                    } else {
                        io.out(cabecalho(c))
                    }
                }
            case "diff":
                let src: Repository.DiffSource = rest.contains("--staged") || rest
                    .contains("--cached") ? .index : .workdir
                let path = rest.first { !$0.hasPrefix("-") }
                try await imprimir(repo.diff(src, path: path), io)
            // `git show` é como o agente confere o que acabou de commitar; sem ele,
            // tentava `cat-file`, não entendia a resposta e ia escrever arquivo de
            // recado em `.odete/` para contornar.
            case "show":
                let ref = rest.first { !$0.hasPrefix("-") }
                let head = try await repo.headSha() ?? ""
                let sha = (ref == nil || ref == "HEAD") ? head : ref!
                let c = try await repo.lookupCommit(sha)
                io.out(cabecalho(c))
                try await imprimir(repo.diff(.commit(sha), path: nil), io)
            case "branch":
                if rest.contains("-d") || rest.contains("-D"),
                   let n = rest.last
                {
                    try await repo.deleteBranch(n); io.out(tr("branch %1$@ apagada", "\(n)"))
                } else if let n = rest.first,
                          !n
                          .hasPrefix("-")
                {
                    try await repo.createBranch(n, checkout: false); io.out(tr("branch %1$@ criada", "\(n)"))
                } else {
                    for b in try await repo
                        .branches(includeRemote: rest.contains("-a"))
                    {
                        io.out((b.isHead ? "* " : "  ") + b.name)
                    }
                }
            case "checkout", "switch":
                if rest.first == "-b" || rest.first == "-c", rest.count > 1 {
                    try await repo.createBranch(
                        rest[1],
                        checkout: true
                    ); io.out(tr("Nova branch %1$@", "\(rest[1])"))
                } else if let n = rest.first {
                    try await repo.checkout(n); io.out(tr("Agora em %1$@", "\(n)"))
                }
            case "merge":
                guard let n = rest.first else { io.err(tr("git merge <branch>")); return 1 }
                switch try await repo.merge(n, author: author) {
                case .upToDate: io.out(tr("Já atualizado."))
                case let .fastForward(s): io.out(tr("Fast-forward para %1$@", "\(s.prefix(7))"))
                case let .merged(s): io.out(tr("Merge feito: %1$@", "\(s.prefix(7))"))
                case let .conflicts(p): io
                    .err(tr(
                        "CONFLITO em: %1$@. Resolva no editor e faça o commit.",
                        "\(p.joined(separator: ", "))"
                    )); return 1
                }
            case "stash":
                switch rest.first {
                case nil, "push", "save": try await repo.stashPush(
                        message: rest.dropFirst().joined(separator: " "),
                        author: author
                    ); io.out(tr("stash guardado"))
                case "pop": try await repo.stashPop(0); io.out(tr("stash aplicado"))
                case "drop": try await repo.stashDrop(0); io.out(tr("stash apagado"))
                case "list": for s in try await repo.stashes() {
                        io.out(tr("stash@{%1$@}: %2$@", "\(s.index)", "\(s.message)"))
                    }
                default: io.err(tr("git stash [push|pop|drop|list]")); return 1
                }
            case "remote":
                if rest.first == "add", rest.count >= 3 {
                    try await repo.addRemote(name: rest[1], url: rest[2])
                } else if rest.first == "remove", rest.count >= 2 {
                    try await repo.removeRemote(name: rest[1])
                } else if rest.first == "set-url", rest.count >= 3 {
                    try await repo.setRemoteURL(
                        name: rest[1],
                        url: rest[2]
                    )
                } else {
                    for r in try await repo.remotes() {
                        io.out(rest.contains("-v") ? "\(r.name)\t\(r.url)" : r.name)
                    }
                }
            case "fetch":
                let remote = posicionais(rest).first ?? "origin"
                let url = try await repo.remotes().first { $0.name == remote }?.url ?? ""
                try await repo.fetch(remote: remote, credentials: ctx.shell.services.credentials(url)); io
                    .out("fetch ok")
            case "pull":
                let remote = posicionais(rest).first ?? "origin"
                let url = try await repo.remotes().first { $0.name == remote }?.url ?? ""
                switch try await repo.pull(
                    remote: remote,
                    credentials: ctx.shell.services.credentials(url),
                    author: author
                ) {
                case .upToDate: io.out(tr("Já atualizado."))
                case .fastForward: io.out("Fast-forward.")
                case .merged: io.out(tr("Merge feito."))
                case let .conflicts(p): io.err(tr("CONFLITO em: %1$@", "\(p.joined(separator: ", "))")); return 1
                }
            case "push":
                // `git push -u origin minha-branch`: contando pela posição crua, o `-u`
                // empurrava tudo e a branch virava "origin". Só o que não é opção conta.
                let args = posicionais(rest)
                let remote = args.first ?? "origin"
                let url = try await repo.remotes().first { $0.name == remote }?.url ?? ""
                let branch = args.count > 1 ? args[1] : nil
                try await repo
                    .push(remote: remote, branch: branch, credentials: ctx.shell.services.credentials(url)); io
                    .out("push ok")
            case "rev-parse":
                try await io
                    .out(rest
                        .contains("--abbrev-ref") ? (repo.currentBranch()?.name ?? "HEAD") : (repo.headSha() ?? ""))
            default:
                io.err(tr("git: subcomando não suportado: %1$@", "\(sub)"))
                io.err("tenho: " + Self.suportados.joined(separator: ", "))
                return 1
            }
            return 0
        } catch { io.err("git: \(error.localizedDescription)"); return 1 }
    }

    /// Os argumentos que não são opção, na ordem: remoto e branch.
    func posicionais(_ rest: [String]) -> [String] {
        rest.filter { !$0.hasPrefix("-") }
    }

    static let suportados = [
        "status", "add", "reset", "restore", "commit", "log", "show", "diff", "branch",
        "checkout", "switch", "merge", "stash", "remote", "fetch", "pull", "push", "rev-parse",
    ]

    /// Cabeçalho de commit no formato do `git log`, com o corpo — que faltava, e sem ele
    /// o agente não conseguia confirmar a mensagem que tinha acabado de escrever.
    func cabecalho(_ c: Commit) -> String {
        var s = "commit \(c.id)\nAutor: \(c.author.name) <\(c.author.email)>\n"
        s += "Data:  \(c.date.formatted())\n\n    \(c.summary)\n"
        if !c.body.isEmpty {
            s += c.body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "    " + $0 }.joined(separator: "\n") + "\n"
        }
        return s
    }

    func imprimir(_ d: Diff, _ io: CommandIO) {
        if d.files.isEmpty {
            io.out(tr("sem diferenças"))
        }
        for f in d.files {
            io.out(tr("--- a/%1$@\n+++ b/%2$@", "\(f.oldPath ?? f.path)", "\(f.path)"))
            if f.isBinary {
                io.out(tr("arquivo binário"))
                continue
            }
            for h in f.hunks {
                io.out(h.header)
                for l in h.lines {
                    io.out((l.kind == .addition ? "+" : l.kind == .deletion ? "-" : " ") + l.text)
                }
            }
        }
    }
}
