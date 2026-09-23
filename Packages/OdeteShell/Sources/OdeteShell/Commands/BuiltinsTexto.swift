import Foundation
import OdeteI18n

/// Os embutidos de texto: cat, head, tail, echo, grep e wc.
extension Builtins {
    /// `-n N`, `-N` e `-nN` de head/tail.
    static func quantasLinhas(_ comando: String, _ args: [String], _ ctx: CommandContext) -> (Int, [String])? {
        var n = 10; var rest: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "-n", i + 1 < args.count, let v = Int(args[i + 1]) {
                n = v; i += 2
            } else if a.hasPrefix("-n"), let v = Int(a.dropFirst(2)) {
                n = v; i += 1
            } else if a.hasPrefix("-"), a.count > 1, let v = Int(a.dropFirst()) {
                n = v; i += 1
            } else if a.hasPrefix("-"), a.count > 1 {
                ctx.io.err(tr("%1$@: opção desconhecida: %2$@", comando, a)); return nil
            } else {
                rest.append(a); i += 1
            }
        }
        return (n, rest)
    }

    /// O `echo -e`: `\n`, `\t`, `\\`, `\e`, `\0NNN` e `\c` (para tudo).
    static func escapesDoEcho(_ s: String) -> (String, parar: Bool) {
        var r = ""
        let it = Array(s)
        var i = 0
        while i < it.count {
            let c = it[i]
            guard c == "\\", i + 1 < it.count else { r.append(c); i += 1; continue }
            let e = it[i + 1]
            i += 2
            switch e {
            case "n": r.append("\n")
            case "t": r.append("\t")
            case "r": r.append("\r")
            case "\\": r.append("\\")
            case "a": r.append("\u{07}")
            case "b": r.append("\u{08}")
            case "e", "E": r.append("\u{1B}")
            case "f": r.append("\u{0C}")
            case "v": r.append("\u{0B}")
            case "c": return (r, true)
            case "0":
                var oct = ""
                while oct.count < 3, i < it.count, ("0" ... "7").contains(it[i]) {
                    oct.append(it[i]); i += 1
                }
                r.append(Character(UnicodeScalar(UInt8(oct.isEmpty ? "0" : oct, radix: 8) ?? 0)))
            default: r.append("\\"); r.append(e)
            }
        }
        return (r, false)
    }

    static let texto: [ShellCommand] = [
        Simple(name: "cat", help: "mostra arquivos") { args, ctx in
            guard let (_, rest) = opcoes("cat", args, aceitas: "", ctx) else { return 2 }
            guard let inputs = readInput(rest, ctx) else { return 1 }
            for (_, s) in inputs {
                ctx.io.escreverBruto(.out, Data(s.utf8))
            }
            return 0
        },
        Simple(name: "head", help: "primeiras linhas (-n)") { args, ctx in
            guard let (n, rest) = quantasLinhas("head", args, ctx) else { return 2 }
            guard let inputs = readInput(rest, ctx, comando: "head") else { return 1 }
            for (_, s) in inputs {
                for l in linhas(s).prefix(max(n, 0)) {
                    ctx.io.out(String(l))
                }
            }
            return 0
        },
        Simple(name: "tail", help: "últimas linhas (-n)") { args, ctx in
            guard let (n, rest) = quantasLinhas("tail", args, ctx) else { return 2 }
            guard let inputs = readInput(rest, ctx, comando: "tail") else { return 1 }
            for (_, s) in inputs {
                for l in linhas(s).suffix(max(n, 0)) {
                    ctx.io.out(String(l))
                }
            }
            return 0
        },
        Simple(name: "echo", help: "imprime (-n, -e)") { args, ctx in
            // Só `-n`, `-e` e `-E` no começo são opções; o resto é texto, como no sh.
            var semQuebra = false, escapes = false
            var i = 0
            while i < args.count, args[i].count > 1, args[i].hasPrefix("-"),
                  args[i].dropFirst().allSatisfy({ "neE".contains($0) })
            {
                for c in args[i].dropFirst() {
                    if c == "n" {
                        semQuebra = true
                    } else {
                        escapes = c == "e"
                    }
                }
                i += 1
            }
            var texto = args[i...].joined(separator: " ")
            if escapes {
                let (t, parar) = escapesDoEcho(texto)
                texto = t
                if parar {
                    semQuebra = true
                }
            }
            ctx.io.escreverBruto(.out, Data((texto + (semQuebra ? "" : "\n")).utf8))
            return 0
        },
        Simple(name: "grep", help: "busca texto (-i, -n, -r, -v, -E, -F, -c, -l, -w, -o, -q)") { args, ctx in
            guard let (f, rest) = opcoes("grep", args, aceitas: "inrRvEFclwoqsHe", ctx) else { return 2 }
            guard let pattern = rest.first else { ctx.io.err(tr("grep: padrão")); return 2 }
            // Expressão estendida por padrão do NSRegularExpression é a ERE com mais coisa; a
            // básica (sem -E) trata `|`, `+`, `?`, `(`, `)` e `{}` como texto, como no grep.
            var fonte: String = if f.contains("F") {
                NSRegularExpression.escapedPattern(for: pattern)
            } else if f.contains("E") {
                pattern
            } else {
                Self.basicaParaEstendida(pattern)
            }
            if f.contains("w") {
                fonte = "\\b(?:" + fonte + ")\\b"
            }
            guard let re = try? NSRegularExpression(pattern: fonte, options: f.contains("i") ? [.caseInsensitive] : [])
            else { ctx.io.err(tr("grep: padrão inválido: %1$@", pattern)); return 2 }
            let inverter = f.contains("v"), silencioso = f.contains("q")
            var found = false
            func casa(_ l: Substring) -> [NSRange] {
                let s = String(l)
                return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map(\.range)
            }
            func scan(_ label: String, _ text: String) {
                var contagem = 0
                for (i, line) in linhas(text).enumerated() {
                    let achados = casa(line)
                    guard achados.isEmpty == inverter else { continue }
                    found = true
                    contagem += 1
                    if silencioso || f.contains("c") || f.contains("l") {
                        continue
                    }
                    let pre = (label.isEmpty ? "" : label + ":") + (f.contains("n") ? "\(i + 1):" : "")
                    if f.contains("o"), !inverter {
                        let s = String(line)
                        for r in achados {
                            if let rr = Range(r, in: s) {
                                ctx.io.out(pre + s[rr])
                            }
                        }
                    } else {
                        ctx.io.out(pre + line)
                    }
                }
                if silencioso {
                    return
                }
                if f.contains("c") {
                    ctx.io.out((label.isEmpty ? "" : label + ":") + "\(contagem)")
                } else if f.contains("l"), contagem > 0 {
                    ctx.io.out(label.isEmpty ? "(standard input)" : label)
                }
            }
            var files = Array(rest.dropFirst())
            if files.isEmpty, f.contains("r") || f.contains("R") {
                files = ["."]
            }
            if files.isEmpty {
                scan("", ctx.io.stdin ?? ""); return found ? 0 : 1
            }
            var erro = false
            for file in files {
                guard let u = ctx.noProjeto(file) else { ctx.avisarFora("grep", file); erro = true; continue }
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                    guard f.contains("r") || f.contains("R")
                    else { ctx.io.err(tr("grep: %1$@: é uma pasta (use -r)", "\(file)")); continue }
                    for item in walk(u, skipNoise: true) {
                        if let s = try? String(contentsOf: item, encoding: .utf8) {
                            scan(ctx.display(item), s)
                        }
                    }
                } else if let s = try? String(contentsOf: u, encoding: .utf8) {
                    scan(files.count > 1 || f.contains("H") ? file : "", s)
                } else if !f.contains("s") {
                    ctx.io.err(tr("grep: %1$@: não existe", "\(file)")); erro = true
                }
            }
            return found ? 0 : erro ? 2 : 1
        },
        Simple(name: "wc", help: "conta linhas, palavras e bytes") { args, ctx in
            guard let (f, rest) = opcoes("wc", args, aceitas: "lwcm", ctx) else { return 2 }
            guard let inputs = readInput(rest, ctx, comando: "wc") else { return 1 }
            var totais = [0, 0, 0]
            for (label, s) in inputs {
                // Linhas são os `\n`, como no wc: linha vazia conta, e a última sem `\n` não.
                let l = s.utf8.count(where: { $0 == 0x0A })
                let w = s.split(whereSeparator: { $0.isWhitespace }).count
                let b = f.contains("m") ? s.count : s.utf8.count
                totais[0] += l; totais[1] += w; totais[2] += b
                let parts = f.isEmpty ? [l, w, b] : [
                    f.contains("l") ? l : nil,
                    f.contains("w") ? w : nil,
                    f.contains("c") || f.contains("m") ? b : nil,
                ].compactMap(\.self)
                ctx.io.out(parts.map { String($0).leftPad(8) }.joined() + (label.isEmpty ? "" : " " + label))
            }
            if inputs.count > 1 {
                let parts = f.isEmpty ? totais : [
                    f.contains("l") ? totais[0] : nil,
                    f.contains("w") ? totais[1] : nil,
                    f.contains("c") || f.contains("m") ? totais[2] : nil,
                ].compactMap(\.self)
                ctx.io.out(parts.map { String($0).leftPad(8) }.joined() + " total")
            }
            return 0
        },
    ]

    /// Expressão básica (BRE) do grep em estendida: `\|`, `\+`, `\?`, `\(`, `\)`, `\{`, `\}`
    /// são os operadores; sem a barra, esses caracteres são texto.
    static func basicaParaEstendida(_ p: String) -> String {
        var r = ""
        var it = p.makeIterator()
        while let c = it.next() {
            if c == "\\", let n = it.next() {
                if "|+?(){}".contains(n) {
                    r.append(n)
                } else {
                    r.append("\\"); r.append(n)
                }
            } else if "|+?(){}".contains(c) {
                r.append("\\"); r.append(c)
            } else {
                r.append(c)
            }
        }
        return r
    }
}
