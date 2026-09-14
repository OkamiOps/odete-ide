import Foundation
import OdeteGit

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
                    .out("Repositório iniciado em \(ctx.display(ctx.root))"); return 0
            } catch {
                io.err(error.localizedDescription); return 1
            }
        }
        if sub == "clone" {
            guard let url = rest.first else { io.err("git clone <url> [pasta]"); return 1 }
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
                io.out("Clonado em \(ctx.display(dest))"); return 0
            } catch { io.err(error.localizedDescription); return 1 }
        }
        guard Repository.isRepository(ctx.root),
              let repo = try? Repository.open(ctx.root)
        else { io.err("fatal: não é um repositório git (rode git init)"); return 128 }
        let author = ctx.shell.services.author()
        do {
            switch sub {
            case "status":
                let st = try await repo.status()
                let head = await repo.headBranchName()
                let branch = try await repo.currentBranch()?.name ?? head ?? "?"
                io.out("Na branch \(branch)")
                if let ab = try await repo
                    .aheadBehind()
                {
                    io.out("  ↑\(ab.ahead) ↓\(ab.behind) em relação ao upstream")
                }
                if st.isEmpty {
                    io.out("nada a commitar, working tree limpa"); return 0
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
                    io.out("Não staged:"); for e in unstaged {
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
                if rest.first == "--staged" {
                    try await repo.unstage(Array(rest.dropFirst()))
                } else if sub == "restore" {
                    try await repo.discard(rest)
                } else if rest.isEmpty {
                    try await repo.unstageAll()
                } else {
                    try await repo.unstage(rest)
                }
            case "commit":
                var msg = ""
                if let i = rest.firstIndex(of: "-m"), i + 1 < rest.count {
                    msg = rest[i + 1]
                }
                if rest.contains("-a") || rest.contains("-am") {
                    try await repo.stageAll()
                }
                if rest.contains("-am"), let i = rest.firstIndex(of: "-am"), i + 1 < rest.count {
                    msg = rest[i + 1]
                }
                guard !msg.isEmpty else { io.err("use git commit -m \"mensagem\""); return 1 }
                let c = try await repo.commit(message: msg, author: author)
                try await io.out("[\(repo.currentBranch()?.name ?? "main") \(c.short)] \(c.summary)")
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
                        io
                            .out(
                                "commit \(c.id)\nAutor: \(c.author.name) <\(c.author.email)>\nData:  \(c.date.formatted())\n\n    \(c.summary)\n"
                            )
                    }
                }
            case "diff":
                let src: Repository.DiffSource = rest.contains("--staged") || rest
                    .contains("--cached") ? .index : .workdir
                let path = rest.first { !$0.hasPrefix("-") }
                let d = try await repo.diff(src, path: path)
                if d.files.isEmpty {
                    io.out("sem diferenças")
                }
                for f in d.files {
                    io.out("--- a/\(f.oldPath ?? f.path)\n+++ b/\(f.path)")
                    for h in f
                        .hunks
                    {
                        io.out(h.header); for l in h
                            .lines
                        {
                            io.out((l.kind == .addition ? "+" : l.kind == .deletion ? "-" : " ") + l.text)
                        }
                    }
                }
            case "branch":
                if rest.contains("-d") || rest.contains("-D"),
                   let n = rest.last
                {
                    try await repo.deleteBranch(n); io.out("branch \(n) apagada")
                } else if let n = rest.first,
                          !n
                          .hasPrefix("-")
                {
                    try await repo.createBranch(n, checkout: false); io.out("branch \(n) criada")
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
                    ); io.out("Nova branch \(rest[1])")
                } else if let n = rest.first {
                    try await repo.checkout(n); io.out("Agora em \(n)")
                }
            case "merge":
                guard let n = rest.first else { io.err("git merge <branch>"); return 1 }
                switch try await repo.merge(n, author: author) {
                case .upToDate: io.out("Já atualizado.")
                case let .fastForward(s): io.out("Fast-forward para \(s.prefix(7))")
                case let .merged(s): io.out("Merge feito: \(s.prefix(7))")
                case let .conflicts(p): io
                    .err("CONFLITO em: \(p.joined(separator: ", ")). Resolva no editor e faça o commit."); return 1
                }
            case "stash":
                switch rest.first {
                case nil, "push", "save": try await repo.stashPush(
                        message: rest.dropFirst().joined(separator: " "),
                        author: author
                    ); io.out("stash guardado")
                case "pop": try await repo.stashPop(0); io.out("stash aplicado")
                case "drop": try await repo.stashDrop(0); io.out("stash apagado")
                case "list": for s in try await repo.stashes() {
                        io.out("stash@{\(s.index)}: \(s.message)")
                    }
                default: io.err("git stash [push|pop|drop|list]"); return 1
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
                let remote = rest.first ?? "origin"
                let url = try await repo.remotes().first { $0.name == remote }?.url ?? ""
                try await repo.fetch(remote: remote, credentials: ctx.shell.services.credentials(url)); io
                    .out("fetch ok")
            case "pull":
                let remote = rest.first ?? "origin"
                let url = try await repo.remotes().first { $0.name == remote }?.url ?? ""
                switch try await repo.pull(
                    remote: remote,
                    credentials: ctx.shell.services.credentials(url),
                    author: author
                ) {
                case .upToDate: io.out("Já atualizado.")
                case .fastForward: io.out("Fast-forward.")
                case .merged: io.out("Merge feito.")
                case let .conflicts(p): io.err("CONFLITO em: \(p.joined(separator: ", "))"); return 1
                }
            case "push":
                let remote = rest.first { !$0.hasPrefix("-") } ?? "origin"
                let url = try await repo.remotes().first { $0.name == remote }?.url ?? ""
                let branch = rest.count > 1 && !rest[1].hasPrefix("-") ? rest[1] : nil
                try await repo
                    .push(remote: remote, branch: branch, credentials: ctx.shell.services.credentials(url)); io
                    .out("push ok")
            case "rev-parse":
                try await io
                    .out(rest
                        .contains("--abbrev-ref") ? (repo.currentBranch()?.name ?? "HEAD") : (repo.headSha() ?? ""))
            default: io.err("git: subcomando não suportado: \(sub)"); return 1
            }
            return 0
        } catch { io.err("git: \(error.localizedDescription)"); return 1 }
    }
}
