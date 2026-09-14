import Foundation
import OdeteCore

struct Simple: ShellCommand {
    let name: String
    let help: String
    let body: @Sendable ([String], CommandContext) async -> Int32
    func run(_ args: [String], _ ctx: CommandContext) async -> Int32 {
        await body(args, ctx)
    }
}

enum Builtins {
    static func flags(_ args: [String]) -> (flags: Set<Character>, rest: [String]) {
        var f: Set<Character> = [], r: [String] = []
        for a in args {
            if a.hasPrefix("-"), a.count > 1,
               !a.hasPrefix("--")
            {
                a.dropFirst().forEach { f.insert($0) }
            } else {
                r.append(a)
            }
        }
        return (f, r)
    }

    /// Lista recursiva (síncrona, para usar dentro de comandos async).
    static func walk(_ base: URL, skipNoise: Bool) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return out }
        while let item = e.nextObject() as? URL {
            let n = item.lastPathComponent
            if skipNoise,
               n == "node_modules" || n == ".git" || n == ".odete" || n == "dist"
            {
                e.skipDescendants(); continue
            }
            out.append(item)
        }
        return out
    }

    static func readInput(_ args: [String], _ ctx: CommandContext) -> [(String, String)]? {
        if args.isEmpty {
            return [("", ctx.io.stdin ?? "")]
        }
        var out: [(String, String)] = []
        for a in args {
            guard let s = try? String(contentsOf: ctx.resolve(a), encoding: .utf8)
            else { ctx.io.err("\(a): não existe"); return nil }
            out.append((a, s))
        }
        return out
    }

    static let all: [ShellCommand] = [
        Simple(name: "help", help: "lista os comandos") { _, ctx in
            ctx.io.out("Comandos da Odete:")
            for c in ctx.shell.commands
                .sorted(by: { $0.name < $1.name })
            {
                ctx.io.out("  \(c.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.help)")
            }
            ctx.io.out("Também: | > >> < && || ; & e $VAR. Ctrl+C para o job atual.")
            return 0
        },
        Simple(name: "pwd", help: "pasta atual") { _, ctx in ctx.io.out(ctx.display(ctx.cwd)); return 0 },
        Simple(name: "cd", help: "muda de pasta") { args, ctx in
            let target = args.first.map { ctx.resolve($0) } ?? ctx.root
            if ctx.shell.setCwd(target) {
                return 0
            }
            ctx.io.err("cd: \(args.first ?? ""): não é uma pasta do projeto"); return 1
        },
        Simple(name: "ls", help: "lista arquivos") { args, ctx in
            let (f, rest) = flags(args)
            let targets = rest.isEmpty ? ["."] : rest
            for t in targets {
                let u = ctx.resolve(t)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                else { ctx.io.err("ls: \(t): não existe"); return 1 }
                if !isDir.boolValue {
                    ctx.io.out(t); continue
                }
                guard var items = try? FileManager.default.contentsOfDirectory(atPath: u.path) else { continue }
                items = items.filter { f.contains("a") || !$0.hasPrefix(".") }
                    .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                if targets.count > 1 {
                    ctx.io.out("\(t):")
                }
                if f.contains("l") {
                    for i in items {
                        let p = u.appending(path: i)
                        let attrs = (try? FileManager.default.attributesOfItem(atPath: p.path)) ?? [:]
                        var d: ObjCBool = false; FileManager.default.fileExists(atPath: p.path, isDirectory: &d)
                        let size = (attrs[.size] as? Int) ?? 0
                        let date = ((attrs[.modificationDate] as? Date) ?? .now).formatted(
                            date: .abbreviated,
                            time: .shortened
                        )
                        ctx.io
                            .out(
                                "\(d.boolValue ? "d" : "-")  \(String(size).padding(toLength: 8, withPad: " ", startingAt: 0)) \(date)  \(i)\(d.boolValue ? "/" : "")"
                            )
                    }
                } else {
                    let line = items.map { i in var d: ObjCBool = false; FileManager.default.fileExists(
                        atPath: u.appending(path: i).path,
                        isDirectory: &d
                    ); return i + (d.boolValue ? "/" : "") }
                    if !line.isEmpty {
                        ctx.io.out(line.joined(separator: "  "))
                    }
                }
            }
            return 0
        },
        Simple(name: "cat", help: "mostra arquivos") { args, ctx in
            guard let inputs = readInput(args, ctx) else { return 1 }
            for (_, s) in inputs {
                ctx.io.out(s.hasSuffix("\n") ? String(s.dropLast()) : s)
            }
            return 0
        },
        Simple(name: "head", help: "primeiras linhas (-n)") { args, ctx in
            var n = 10; var rest: [String] = []
            var i = 0
            while i < args
                .count
            {
                if args[i] == "-n",
                   i + 1 < args.count
                {
                    n = Int(args[i + 1]) ?? 10; i += 2
                } else if args[i].hasPrefix("-"),
                          let v = Int(args[i].dropFirst())
                {
                    n = v; i += 1
                } else {
                    rest.append(args[i]); i += 1
                }
            }
            guard let inputs = readInput(rest, ctx) else { return 1 }
            for (_, s) in inputs {
                ctx.io
                    .out(s.split(separator: "\n", omittingEmptySubsequences: false).prefix(n).joined(separator: "\n"))
            }
            return 0
        },
        Simple(name: "tail", help: "últimas linhas (-n)") { args, ctx in
            var n = 10; var rest: [String] = []
            var i = 0
            while i < args
                .count
            {
                if args[i] == "-n",
                   i + 1 < args.count
                {
                    n = Int(args[i + 1]) ?? 10; i += 2
                } else if args[i].hasPrefix("-"),
                          let v = Int(args[i].dropFirst())
                {
                    n = v; i += 1
                } else {
                    rest.append(args[i]); i += 1
                }
            }
            guard let inputs = readInput(rest, ctx) else { return 1 }
            for (_, s) in inputs {
                let lines = s.split(separator: "\n", omittingEmptySubsequences: false); ctx.io
                    .out(lines.suffix(n).joined(separator: "\n"))
            }
            return 0
        },
        Simple(name: "echo", help: "imprime") { args, ctx in
            let (f, rest) = flags(args.prefix(1).map(\.self) + [])
            let text = (f.contains("n") ? Array(args.dropFirst()) : args).joined(separator: " ")
            _ = rest
            ctx.io.out(text); return 0
        },
        Simple(name: "mkdir", help: "cria pasta (-p)") { args, ctx in
            let (f, rest) = flags(args)
            for r in rest {
                do
                { try FileManager.default.createDirectory(
                    at: ctx.resolve(r),
                    withIntermediateDirectories: f.contains("p")
                ) } catch { ctx.io.err("mkdir: \(r): \(error.localizedDescription)"); return 1 }
            }
            return 0
        },
        Simple(name: "touch", help: "cria arquivo vazio") { args, ctx in
            for a in args {
                let u = ctx.resolve(a); if !FileManager.default
                    .fileExists(atPath: u.path)
                {
                    FileManager.default.createFile(
                        atPath: u.path,
                        contents: Data()
                    )
                } else {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
                }
            }
            return 0
        },
        Simple(name: "rm", help: "apaga (-r, -f)") { args, ctx in
            let (f, rest) = flags(args)
            for r in rest {
                let u = ctx.resolve(r)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                else {
                    if !f.contains("f") {
                        ctx.io.err("rm: \(r): não existe"); return 1
                    }; continue
                }
                if isDir.boolValue, !f.contains("r") {
                    ctx.io.err("rm: \(r): é uma pasta (use -r)"); return 1
                }
                if u.standardizedFileURL.path == ctx.root.standardizedFileURL
                    .path
                {
                    ctx.io.err("rm: não vou apagar a raiz do projeto"); return 1
                }
                do { try FileManager.default.removeItem(at: u) } catch {
                    ctx.io.err("rm: \(r): \(error.localizedDescription)"); return 1
                }
            }
            return 0
        },
        Simple(name: "cp", help: "copia (-r)") { args, ctx in
            let (_, rest) = flags(args)
            guard rest.count >= 2 else { ctx.io.err("cp: origem destino"); return 1 }
            var dest = ctx.resolve(rest.last!)
            var isDir: ObjCBool = false
            let destIsDir = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) && isDir.boolValue
            for src in rest.dropLast() {
                let s = ctx.resolve(src)
                let d = destIsDir ? dest.appending(path: s.lastPathComponent) : dest
                do {
                    if FileManager.default
                        .fileExists(atPath: d.path)
                    {
                        try FileManager.default.removeItem(at: d)
                    }; try FileManager.default
                        .copyItem(
                            at: s,
                            to: d
                        )
                } catch { ctx.io.err("cp: \(src): \(error.localizedDescription)"); return 1 }
            }
            dest = dest.standardizedFileURL
            return 0
        },
        Simple(name: "mv", help: "move ou renomeia") { args, ctx in
            guard args.count >= 2 else { ctx.io.err("mv: origem destino"); return 1 }
            let dest = ctx.resolve(args.last!)
            var isDir: ObjCBool = false
            let destIsDir = FileManager.default.fileExists(atPath: dest.path, isDirectory: &isDir) && isDir.boolValue
            for src in args.dropLast() {
                let s = ctx.resolve(src)
                let d = destIsDir ? dest.appending(path: s.lastPathComponent) : dest
                do {
                    if FileManager.default
                        .fileExists(atPath: d.path)
                    {
                        try FileManager.default.removeItem(at: d)
                    }; try FileManager.default
                        .moveItem(
                            at: s,
                            to: d
                        )
                } catch { ctx.io.err("mv: \(src): \(error.localizedDescription)"); return 1 }
            }
            return 0
        },
        Simple(name: "grep", help: "busca texto (-i, -n, -r)") { args, ctx in
            let (f, rest) = flags(args)
            guard let pattern = rest.first else { ctx.io.err("grep: padrão"); return 2 }
            let opts: String.CompareOptions = f.contains("i") ? [.caseInsensitive] : []
            var found = false
            func scan(_ label: String, _ text: String) {
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    where line.range(
                        of: pattern,
                        options: opts
                    ) != nil
                {
                    found = true
                    ctx.io.out((label.isEmpty ? "" : label + ":") + (f.contains("n") ? "\(i + 1):" : "") + line)
                }
            }
            let files = Array(rest.dropFirst())
            if files.isEmpty {
                scan("", ctx.io.stdin ?? ""); return found ? 0 : 1
            }
            for file in files {
                let u = ctx.resolve(file)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    guard f.contains("r") else { ctx.io.err("grep: \(file): é uma pasta (use -r)"); continue }
                    for item in walk(u, skipNoise: true) {
                        if let s = try? String(contentsOf: item, encoding: .utf8) {
                            scan(ctx.display(item), s)
                        }
                    }
                } else if let s = try? String(contentsOf: u, encoding: .utf8) {
                    scan(files.count > 1 ? file : "", s)
                } else {
                    ctx.io.err("grep: \(file): não existe")
                }
            }
            return found ? 0 : 1
        },
        Simple(name: "wc", help: "conta linhas, palavras e bytes") { args, ctx in
            let (f, rest) = flags(args)
            guard let inputs = readInput(rest, ctx) else { return 1 }
            for (label, s) in inputs {
                let l = s.split(separator: "\n").count, w = s.split(whereSeparator: { $0.isWhitespace }).count,
                    b = s.utf8.count
                let parts = f.isEmpty ? [l, w, b] : [
                    f.contains("l") ? l : nil,
                    f.contains("w") ? w : nil,
                    f.contains("c") ? b : nil,
                ].compactMap(\.self)
                ctx.io.out(parts.map { String($0).leftPad(7) }.joined() + (label.isEmpty ? "" : " " + label))
            }
            return 0
        },
        Simple(name: "find", help: "lista arquivos recursivamente (-name)") { args, ctx in
            var start = "."; var name: String?
            var i = 0
            while i < args
                .count
            {
                if args[i] == "-name",
                   i + 1 < args.count
                {
                    name = args[i + 1]; i += 2
                } else if !args[i].hasPrefix("-") {
                    start = args[i]; i += 1
                } else {
                    i += 1
                }
            }
            let base = ctx.resolve(start)
            guard FileManager.default.fileExists(atPath: base.path)
            else { ctx.io.err("find: \(start): não existe"); return 1 }
            let re = name
                .map {
                    NSRegularExpression.escapedPattern(for: $0).replacingOccurrences(of: "\\*", with: ".*")
                        .replacingOccurrences(
                            of: "\\?",
                            with: "."
                        )
                }
            for item in walk(base, skipNoise: true) {
                if let re,
                   item.lastPathComponent.range(of: "^" + re + "$", options: .regularExpression) == nil
                {
                    continue
                }
                ctx.io.out(ctx.display(item))
            }
            return 0
        },
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
                    ctx.io.err("\(a) não encontrado"); return 1
                }
            }
            return 0
        },
        Simple(name: "clear", help: "limpa a tela") { _, ctx in ctx.io.out("\u{1B}[clear]"); return 0 },
        Simple(name: "history", help: "histórico") { _, ctx in
            for (i, h) in ctx.shell.history.enumerated() {
                ctx.io.out("\(String(i + 1).leftPad(4))  \(h)")
            }; return 0
        },
        Simple(name: "date", help: "data e hora") { _, ctx in ctx.io.out(Date().formatted(
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
                ctx.io.out("nenhum job")
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
                ctx.shell.killAll(); ctx.io.out("jobs encerrados"); return 0
            }
            for a in args {
                let id = Int(a.replacingOccurrences(of: "%", with: "")); if let j = ctx.shell.jobs
                    .first(where: { $0.id == id })
                {
                    j.kill(); ctx.io.out("[\(j.id)] parado")
                } else {
                    ctx.io.err("kill: job \(a) não existe")
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

extension String {
    func leftPad(_ n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}
