import Foundation
import OdeteI18n

/// A parte do parser que lê expressões, da precedência ao literal. Mora aqui para o
/// corpo do `Parser` caber numa leitura.
extension Parser {
    mutating func parseExprNoTrailing() throws -> Expr {
        let saved = noTrailing; noTrailing = true; defer { noTrailing = saved }
        return try parseExpr()
    }

    mutating func parseExpr() throws -> Expr {
        try parseTernary()
    }

    mutating func parseTernary() throws -> Expr {
        let c = try parseBinary(0)
        if at("?") {
            advance(); skipNewlines(); let a = try parseExpr(); try expect(":"); skipNewlines(); let b =
                try parseExpr(); return .ternary(
                    c,
                    a,
                    b
                )
        }
        if at("??") {
            advance(); skipNewlines(); let b = try parseExpr(); return .binary("??", c, b)
        }
        return c
    }

    static let levels: [[String]] = [
        ["||"],
        ["&&"],
        ["==", "!=", "<", ">", "<=", ">="],
        ["..<", "..."],
        ["+", "-"],
        ["*", "/", "%"],
    ]

    mutating func parseBinary(_ level: Int) throws -> Expr {
        if level >= Self.levels.count {
            return try parseUnary()
        }
        var left = try parseBinary(level + 1)
        while case let .punct(op) = cur.kind, Self.levels[level].contains(op) {
            // `-` sem espaço antes e sem espaço depois vira binário do mesmo jeito; `a -1` idem
            advance(); skipNewlines()
            let right = try parseBinary(level + 1)
            if op == "..<" || op == "..." {
                left = .range(left, right, closed: op == "...")
            } else {
                left = .binary(
                    op,
                    left,
                    right
                )
            }
        }
        return left
    }

    mutating func parseUnary() throws -> Expr {
        if at("!") {
            advance(); return try .unary("!", parseUnary())
        }
        if at("-"), !cur.spaceBefore || true {
            if case .punct("-") = cur.kind {
                advance(); return try .unary(
                    "-",
                    parseUnary()
                )
            }
        }
        return try parsePostfix(parsePrimary())
    }

    mutating func parsePostfix(_ base: Expr) throws -> Expr {
        var e = base
        while true {
            // `.membro` na mesma linha ou na próxima
            if at(".") {
                advance(); skipNewlines(); let n = try ident(); e = .member(e, n, line: line); continue
            }
            if isNewline, peekAfterNewlinesIs(".") {
                skipNewlines(); continue
            }
            if at("("),
               !cur
               .spaceBefore
            {
                let (args, l) = try parseArgs(); var tr: [(String?, Closure)] = []; if !noTrailing {
                    tr = try parseTrailing()
                }; e = .call(
                    e,
                    args,
                    tr,
                    line: l
                ); continue
            }
            if at("["), !cur.spaceBefore {
                advance(); let idx = try parseExpr(); try expect("]"); e = .subscriptExpr(
                    e,
                    idx
                ); continue
            }
            if at("{"), !noTrailing,
               isCallable(e)
            {
                let tr = try parseTrailing(); e = .call(e, [], tr, line: line); continue
            }
            if at("!"), !cur.spaceBefore {
                advance(); continue
            } // force unwrap
            if at("?"), !cur.spaceBefore, peekIs(".") {
                advance(); continue
            } // optional chaining
            return e
        }
    }

    func peekAfterNewlinesIs(_ s: String) -> Bool {
        var k = p
        while k < toks.count, toks[k].kind == .newline {
            k += 1
        }
        if case let .punct(x) = toks[k].kind {
            return x == s
        }
        return false
    }

    /// Só identificadores/membros com inicial maiúscula (Text, VStack, Button…) ou `ForEach` aceitam trailing closure
    /// sem parênteses.
    func isCallable(_ e: Expr) -> Bool {
        switch e {
        case let .ident(n, _), let .member(_, n, _): n.first?.isUppercase == true || ["withAnimation"].contains(n)
        default: false
        }
    }

    mutating func parseArgs() throws -> ([Arg], Int) {
        let l = line
        try expect("(")
        var args: [Arg] = []
        skipNewlines()
        while !at(")") {
            var label: String?
            if case let .ident(s) = cur.kind, peekIs(":"),
               !peekIs(":", 2)
            {
                label = s; advance(); advance(); skipNewlines()
            }
            try args.append(Arg(label, parseExpr()))
            skipNewlines()
            if at(",") {
                advance(); skipNewlines()
            }
        }
        try expect(")")
        return (args, l)
    }

    mutating func parseTrailing() throws -> [(String?, Closure)] {
        var out: [(String?, Closure)] = []
        if at("{") {
            try out.append((nil, parseClosure()))
        }
        // trailing closures rotuladas: `label: { … }`
        while case let .ident(lbl) = cur.kind, peekIs(":"), peekIs("{", 2) {
            advance(); advance(); try out.append((
                lbl,
                parseClosure()
            ))
        }
        return out
    }

    mutating func parseClosure() throws -> Closure {
        let l = line
        try expect("{")
        var params: [String] = []
        // `{ a, b in` ou `{ (a, b) in`
        var k = p
        var names: [String] = []
        var ok = false
        if case .punct("(") = toks[k].kind {
            k += 1
        }
        while k < toks.count {
            if case let .ident(s) = toks[k].kind,
               s !=
               "in"
            {
                names.append(s); k += 1; if case .punct(",") = toks[k]
                    .kind
                {
                    k += 1; continue
                }; if case .punct(")") = toks[k].kind {
                    k += 1
                }; if case .ident("in") = toks[k]
                    .kind
                {
                    ok = true
                }; break
            }
            break
        }
        if ok {
            params = names; p = k + 1
        }
        var body: [Stmt] = []
        while true {
            skipNewlines()
            if at("}") {
                advance(); break
            }
            if isEOF {
                throw ParseError(line: l, message: tr("closure sem fechar"))
            }
            try body.append(parseStmt())
            if at(";") {
                advance()
            }
        }
        return Closure(params: params, body: body, line: l)
    }

    mutating func parsePrimary() throws -> Expr {
        skipNewlines()
        let l = line
        switch cur.kind {
        case let .int(v): advance(); return .int(v)
        case let .double(v): advance(); return .double(v)
        case let .string(s): advance(); return try .string(segments(s, line: l))
        case let .ident(s):
            advance()
            switch s {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "if": p -= 1; return try parseIf()
            case "self": return try parsePrimary()
            default: return .ident(s, line: l)
            }
        case .punct("("):
            advance(); skipNewlines()
            let e = try parseExpr(); skipNewlines()
            if at(",") { // tupla: guardamos como array
                var items = [e]; while at(",") {
                    advance(); skipNewlines(); try items.append(parseExpr()); skipNewlines()
                }
                try expect(")"); return .array(items)
            }
            try expect(")"); return e
        case .punct("["):
            advance(); skipNewlines()
            var items: [Expr] = []
            while !at("]") {
                try items.append(parseExpr()); skipNewlines(); if at(",") {
                    advance(); skipNewlines()
                }
            }
            try expect("]"); return .array(items)
        case .punct("."):
            advance(); let n = try ident(); return .member(nil, n, line: l)
        case .punct("{"):
            return try .closure(parseClosure())
        case .punct("\\"):
            advance(); if at(".") {
                advance()
            }; let n = try ident(); return .member(nil, n, line: l) // key path
        case .punct("&"):
            advance(); return try parsePrimary()
        default:
            throw ParseError(line: l, message: tr("não entendi '%1$@'", "\(describe(cur))"))
        }
    }

    func describe(_ t: Token) -> String {
        switch t
            .kind
        { case let .punct(s), let .ident(s),
             let .string(s): s; case let .int(v): String(
                v
            ); case let .double(v): String(v); case .newline: "fim de linha"; case .eof: "fim do arquivo"
        }
    }

    /// Divide `"a \(x + 1) b"` em segmentos, parseando cada interpolação.
    mutating func segments(_ raw: String, line l: Int) throws -> [Segment] {
        var out: [Segment] = []
        var text = ""
        let chars = Array(raw)
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                let n = chars[i + 1]
                if n == "(" {
                    var depth = 1; var j = i + 2; var inner = ""
                    while j < chars.count, depth > 0 {
                        if chars[j] == "(" {
                            depth += 1
                        } else if chars[j] == ")" {
                            depth -= 1
                        }; if depth > 0 {
                            inner.append(chars[j])
                        }; j += 1
                    }
                    if !text.isEmpty {
                        out.append(.text(text)); text = ""
                    }
                    var lx = Lexer(inner)
                    var sub = Parser(toks: lx.run(), file: file)
                    let e = try sub.parseExpr()
                    diags += sub.diags
                    out.append(.expr(e))
                    i = j; continue
                }
                switch n {
                case "n": text.append("\n"); case "t": text.append("\t"); case "\"": text
                    .append("\""); case "\\": text.append("\\"); default: text.append(n)
                }
                i += 2; continue
            }
            text.append(chars[i]); i += 1
        }
        if !text.isEmpty || out.isEmpty {
            out.append(.text(text))
        }
        return out
    }
}
