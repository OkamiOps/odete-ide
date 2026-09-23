import Foundation
import OdeteCore
import OdeteI18n
import OdeteRuntime

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
        var acabaram = false
        for a in args {
            if !acabaram, a == "--" {
                acabaram = true; continue
            }
            if !acabaram, a.hasPrefix("-"), a.count > 1, !a.hasPrefix("--") {
                a.dropFirst().forEach { f.insert($0) }
            } else {
                r.append(a)
            }
        }
        return (f, r)
    }

    /// As opções de um comando, recusando as que ele não conhece. Antes `grep -v` e `find
    /// -type f` eram aceitos e ignorados: saía o contrário do pedido, sem aviso.
    static func opcoes(
        _ comando: String,
        _ args: [String],
        aceitas: String,
        _ ctx: CommandContext
    ) -> (flags: Set<Character>, rest: [String])? {
        let (f, rest) = flags(args)
        if let x = f.first(where: { !aceitas.contains($0) }) {
            ctx.io.err(tr("%1$@: opção desconhecida: -%2$@", comando, String(x)))
            return nil
        }
        if let longa = args.first(where: { $0.hasPrefix("--") && $0 != "--" }) {
            ctx.io.err(tr("%1$@: opção desconhecida: %2$@", comando, longa))
            return nil
        }
        return (f, rest)
    }

    /// Lista recursiva (síncrona, para usar dentro de comandos async).
    static func walk(_ base: URL, skipNoise: Bool) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return out }
        while let item = e.nextObject() as? URL {
            let n = item.lastPathComponent
            if skipNoise,
               n == "node_modules" || n == Ignore.modulosForaDaNuvem || n == ".git" || n == ".odete"
               || n == "dist"
            {
                e.skipDescendants(); continue
            }
            out.append(item)
        }
        return out
    }

    static func readInput(_ args: [String], _ ctx: CommandContext, comando: String = "cat") -> [(String, String)]? {
        if args.isEmpty {
            return [("", ctx.io.stdin ?? "")]
        }
        var out: [(String, String)] = []
        for a in args {
            if a == "-" {
                out.append(("", ctx.io.stdin ?? "")); continue
            }
            guard let u = ctx.noProjeto(a) else { ctx.avisarFora(comando, a); return nil }
            guard let s = try? String(contentsOf: u, encoding: .utf8)
            else { ctx.io.err(tr("%1$@: não existe", "\(a)")); return nil }
            out.append((a, s))
        }
        return out
    }

    /// As linhas de um texto como o `grep`/`wc` as veem: o `\n` final não abre uma linha
    /// a mais, mas linha vazia no meio conta.
    static func linhas(_ s: String) -> [Substring] {
        var l = s.split(separator: "\n", omittingEmptySubsequences: false)
        if s.hasSuffix("\n") {
            l.removeLast()
        }
        return s.isEmpty ? [] : l
    }

    /// Arquivos e texto. O resto — ambiente, jobs, utilidades — está em
    /// `BuiltinsAmbiente.swift`: juntos não cabiam num arquivo que se lê de uma vez.
    static let all: [ShellCommand] = arquivos + texto + ambiente

    static let arquivos: [ShellCommand] = [
        Simple(name: "help", help: "lista os comandos") { _, ctx in
            ctx.io.out(tr("Comandos da Odete:"))
            for c in ctx.shell.commands
                .sorted(by: { $0.name < $1.name })
            {
                ctx.io.out("  \(c.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(tr(c.help))")
            }
            ctx.io.out(tr("Também: | > >> < && || ; & e $VAR. Ctrl+C para o job atual."))
            return 0
        },
        Simple(name: "pwd", help: "pasta atual") { _, ctx in ctx.io.out(ctx.display(ctx.cwd)); return 0 },
        Simple(name: "cd", help: "muda de pasta") { args, ctx in
            // `cd -` volta para a pasta de antes, e mostra qual é, como no sh.
            if args.first == "-" {
                guard let antes = ctx.shell.cwdAnterior else { ctx.io.err(tr("cd: não há pasta anterior")); return 1 }
                guard ctx.shell.setCwd(antes) else { ctx.io.err(tr(
                    "cd: %1$@: não é uma pasta do projeto",
                    "-"
                )); return 1 }
                ctx.io.out(ctx.display(antes))
                return 0
            }
            let alvo = args.first.map { ctx.caminhoCru($0) } ?? ctx.root
            if ctx.shell.setCwd(alvo) {
                return 0
            }
            ctx.io.err(tr("cd: %1$@: não é uma pasta do projeto", "\(args.first ?? "")")); return 1
        },
        Simple(name: "ls", help: "lista arquivos") { args, ctx in
            guard let (f, rest) = opcoes("ls", args, aceitas: "laA1hF", ctx) else { return 2 }
            let targets = rest.isEmpty ? ["."] : rest
            for t in targets {
                guard let u = ctx.noProjeto(t) else { ctx.avisarFora("ls", t); return 1 }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                else { ctx.io.err(tr("ls: %1$@: não existe", "\(t)")); return 1 }
                if !isDir.boolValue {
                    ctx.io.out(t); continue
                }
                guard var items = try? FileManager.default.contentsOfDirectory(atPath: u.path) else { continue }
                items = items.filter { f.contains("a") || f.contains("A") || !$0.hasPrefix(".") }
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
                        let date = ((attrs[.modificationDate] as? Date) ?? .now).noIdioma(
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
                        ctx.io.out(line.joined(separator: f.contains("1") ? "\n" : "  "))
                    }
                }
            }
            return 0
        },
        Simple(name: "mkdir", help: "cria pasta (-p)") { args, ctx in
            guard let (f, rest) = opcoes("mkdir", args, aceitas: "pv", ctx) else { return 2 }
            for r in rest {
                guard let u = ctx.noProjeto(r) else { ctx.avisarFora("mkdir", r); return 1 }
                do
                { try FileManager.default.createDirectory(
                    at: u,
                    withIntermediateDirectories: f.contains("p")
                ) } catch { ctx.io.err(tr("mkdir: %1$@: %2$@", "\(r)", "\(error.localizedDescription)")); return 1 }
            }
            return 0
        },
        Simple(name: "touch", help: "cria arquivo vazio") { args, ctx in
            for a in args {
                guard let u = ctx.noProjeto(a) else { ctx.avisarFora("touch", a); return 1 }
                if !FileManager.default.fileExists(atPath: u.path) {
                    FileManager.default.createFile(atPath: u.path, contents: Data())
                } else {
                    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: u.path)
                }
            }
            return 0
        },
        Simple(name: "rm", help: "apaga (-r, -f)") { args, ctx in
            guard let (f, rest) = opcoes("rm", args, aceitas: "rRfdiv", ctx) else { return 2 }
            let recursivo = f.contains("r") || f.contains("R")
            for r in rest {
                // O link é apagado, não seguido; e nada fora do projeto — `rm -rf ../Outro`
                // apagava outro projeto inteiro.
                // `rm link/` (com a barra) é a pasta do outro lado do link, como no sh.
                guard let u = ctx.noProjeto(r, seguirUltimo: r.hasSuffix("/"))
                else { ctx.avisarFora("rm", r); return 1 }
                let conf = Confinamento(raiz: ctx.root)
                if conf.raizes.contains(Confinamento.real(u.path, seguirUltimo: false)) {
                    ctx.io.err(tr("rm: não vou apagar a raiz do projeto")); return 1
                }
                var st = stat()
                guard lstat(u.path, &st) == 0 else {
                    if !f.contains("f") {
                        ctx.io.err(tr("rm: %1$@: não existe", "\(r)")); return 1
                    }; continue
                }
                if (st.st_mode & S_IFMT) == S_IFDIR, !recursivo {
                    ctx.io.err(tr("rm: %1$@: é uma pasta (use -r)", "\(r)")); return 1
                }
                if (st.st_mode & S_IFMT) != S_IFLNK {
                    HistoricoDeArquivos.guardar(u, raiz: ctx.root, origem: .terminal)
                }
                do { try FileManager.default.removeItem(at: u) } catch {
                    ctx.io.err(tr("rm: %1$@: %2$@", "\(r)", "\(error.localizedDescription)")); return 1
                }
            }
            return 0
        },
        Simple(name: "cp", help: "copia (-r)") { args, ctx in
            guard let (f, rest) = opcoes("cp", args, aceitas: "rRfpaiv", ctx) else { return 2 }
            guard rest.count >= 2 else { ctx.io.err(tr("cp: origem destino")); return 1 }
            guard let dest = ctx.noProjeto(rest.last!) else { ctx.avisarFora("cp", rest.last!); return 1 }
            let destIsDir = Shell.ehPasta(dest)
            let recursivo = f.contains("r") || f.contains("R") || f.contains("a")
            for src in rest.dropLast() {
                guard let s = ctx.noProjeto(src) else { ctx.avisarFora("cp", src); return 1 }
                let d = destIsDir ? dest.appending(path: s.lastPathComponent) : dest
                if Shell.ehPasta(s), !recursivo {
                    ctx.io.err(tr("cp: %1$@: é uma pasta (use -r)", src)); return 1
                }
                // Pasta sobre pasta mescla, como o cp; antes o destino era apagado inteiro.
                if let e = Self.copiar(s, para: d) {
                    ctx.io.err(tr("cp: %1$@: %2$@", "\(src)", e)); return 1
                }
            }
            return 0
        },
        Simple(name: "mv", help: "move ou renomeia") { args, ctx in
            guard let (_, rest) = opcoes("mv", args, aceitas: "fiv", ctx) else { return 2 }
            guard rest.count >= 2 else { ctx.io.err(tr("mv: origem destino")); return 1 }
            guard let dest = ctx.noProjeto(rest.last!, seguirUltimo: false) else { ctx.avisarFora(
                "mv",
                rest.last!
            ); return 1 }
            let destIsDir = Shell.ehPasta(dest)
            for src in rest.dropLast() {
                guard let s = ctx.noProjeto(src, seguirUltimo: false) else { ctx.avisarFora("mv", src); return 1 }
                let d = destIsDir ? dest.appending(path: s.lastPathComponent) : dest
                // `rename(2)`: arquivo sobre arquivo substitui; pasta sobre pasta cheia é
                // recusado. Antes o destino era apagado antes — pasta inteira inclusive.
                HistoricoDeArquivos.guardar(d, raiz: ctx.root, origem: .terminal)
                if Darwin.rename(s.path, d.path) != 0 {
                    let e = errno
                    if e == EXDEV, (try? FileManager.default.moveItem(at: s, to: d)) != nil {
                        continue
                    }
                    ctx.io.err(tr("mv: %1$@: %2$@", "\(src)", String(cString: strerror(e)))); return 1
                }
            }
            return 0
        },
        Simple(name: "find", help: "lista arquivos recursivamente (-name, -type)") { args, ctx in
            var start = "."; var name: String?; var iname: String?; var tipo: Character?
            var i = 0
            while i < args.count {
                let a = args[i]
                if a == "-name" || a == "-iname", i + 1 < args.count {
                    if a == "-name" {
                        name = args[i + 1]
                    } else {
                        iname = args[i + 1]
                    }
                    i += 2
                } else if a == "-type", i + 1 < args.count, let t = args[i + 1].first, "fd".contains(t),
                          args[i + 1].count == 1
                {
                    tipo = t; i += 2
                } else if !a.hasPrefix("-") {
                    start = a; i += 1
                } else {
                    ctx.io.err(tr("find: opção desconhecida: %1$@", a)); return 2
                }
            }
            guard let base = ctx.noProjeto(start) else { ctx.avisarFora("find", start); return 1 }
            guard FileManager.default.fileExists(atPath: base.path)
            else { ctx.io.err(tr("find: %1$@: não existe", "\(start)")); return 1 }
            for item in [base] + walk(base, skipNoise: true) {
                if let name, fnmatch(name, item.lastPathComponent, 0) != 0 {
                    continue
                }
                if let iname, fnmatch(iname.lowercased(), item.lastPathComponent.lowercased(), 0) != 0 {
                    continue
                }
                if let tipo, Shell.ehPasta(item) != (tipo == "d") {
                    continue
                }
                ctx.io.out(start == "." && item == base ? "." : ctx.display(item))
            }
            return 0
        },
    ]

    /// Copia arquivo ou pasta (mesclando com o que já existe). Devolve a mensagem de erro.
    static func copiar(_ s: URL, para d: URL) -> String? {
        let fm = FileManager.default
        if Shell.ehPasta(s) {
            if !fm.fileExists(atPath: d.path) {
                do { try fm.createDirectory(at: d, withIntermediateDirectories: false) } catch {
                    return error.localizedDescription
                }
            } else if !Shell.ehPasta(d) {
                return tr("%1$@ não é uma pasta", d.lastPathComponent)
            }
            for nome in (try? fm.contentsOfDirectory(atPath: s.path)) ?? [] {
                if let e = copiar(s.appending(path: nome), para: d.appending(path: nome)) {
                    return e
                }
            }
            return nil
        }
        if Shell.ehPasta(d) {
            return tr("%1$@ é uma pasta", d.lastPathComponent)
        }
        if fm.fileExists(atPath: d.path) {
            HistoricoDeArquivos.guardar(d, origem: .terminal)
            try? fm.removeItem(at: d)
        }
        do { try fm.copyItem(at: s, to: d) } catch { return error.localizedDescription }
        return nil
    }
}

extension String {
    func leftPad(_ n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}
