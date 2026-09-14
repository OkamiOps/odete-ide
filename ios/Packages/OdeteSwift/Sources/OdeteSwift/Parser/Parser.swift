import Foundation

struct ParseError: Error { let line: Int; let message: String }

/// Parser recursivo do subconjunto de Swift usado nos playgrounds.
public struct Parser {
    var toks: [Token]
    var p = 0
    let file: String
    var diags: [SwiftDiagnostic] = []

    public static func parse(file: String, source: String) -> SwiftFile {
        var lx = Lexer(source)
        var parser = Parser(toks: lx.run(), file: file)
        let structs = parser.parseFile()
        return SwiftFile(path: file, structs: structs, diagnostics: parser.diags)
    }

    // MARK: utilidades

    var cur: Token {
        toks[p]
    }

    var line: Int {
        cur.line
    }

    func at(_ s: String) -> Bool {
        if case let .punct(x) = cur.kind {
            return x == s
        }; if case let .ident(x) = cur
            .kind
        {
            return x == s
        }; return false
    }

    func peekIs(
        _ s: String,
        _ n: Int = 1
    ) -> Bool {
        let t = toks[min(p + n, toks.count - 1)]; if case let .punct(x) = t
            .kind
        {
            return x == s
        }; if case let .ident(x) = t.kind {
            return x == s
        }; return false
    }

    var isEOF: Bool {
        cur.kind == .eof
    }

    var isNewline: Bool {
        cur.kind == .newline
    }

    mutating func skipNewlines() {
        while isNewline {
            p += 1
        }
    }

    mutating func advance() {
        if !isEOF {
            p += 1
        }
    }

    mutating func expect(_ s: String) throws {
        skipNewlines(); guard at(s)
        else { throw ParseError(
            line: line,
            message: "esperava '\(s)'"
        ) }; advance()
    }

    mutating func ident() throws -> String {
        skipNewlines(); guard case let .ident(s) = cur.kind
        else { throw ParseError(
            line: line,
            message: "esperava um nome"
        ) }; advance(); return s
    }

    mutating func warn(_ msg: String, _ l: Int) {
        diags.append(SwiftDiagnostic(
            .warning,
            file: file,
            line: l,
            message: msg
        ))
    }

    mutating func fail(_ msg: String, _ l: Int) {
        diags.append(SwiftDiagnostic(
            .error,
            file: file,
            line: l,
            message: msg
        ))
    }

    /// Pula um bloco `{ … }` balanceado (a partir do `{`).
    mutating func skipBlock() {
        skipNewlines()
        guard at("{") else { return }
        var depth = 0
        repeat {
            if at("{") {
                depth += 1
            } else if at("}") {
                depth -= 1
            }
            advance()
        } while depth > 0 && !isEOF
    }

    mutating func skipToLineEnd() {
        while !isNewline, !isEOF, !at("}") {
            advance()
        }
    }

    // MARK: arquivo

    mutating func parseFile() -> [StructDecl] {
        var out: [StructDecl] = []
        var pendingMain = false
        while !isEOF {
            skipNewlines()
            if isEOF {
                break
            }
            let l = line
            do {
                if at("import") {
                    skipToLineEnd(); continue
                }
                if at("@main") {
                    pendingMain = true; advance(); continue
                }
                if at("@") {
                    advance(); skipToLineEnd(); continue
                }
                if at("struct") || at("class") || at("final") {
                    if at("final") {
                        advance()
                    }
                    var s = try parseStruct()
                    s.isMain = pendingMain
                    pendingMain = false
                    out.append(s)
                    continue
                }
                if at("#Preview") || at("extension") || at("enum") || at("protocol") || at("func") || at("let") ||
                    at("var")
                {
                    let what = "\(cur.kind)"
                    warn(
                        "fora do subconjunto: \(what.replacingOccurrences(of: "ident(\"", with: "").replacingOccurrences(of: "\")", with: "")) no nível do arquivo (ignorado)",
                        l
                    )
                    while !at("{"), !isNewline, !isEOF {
                        advance()
                    }
                    if at("{") {
                        skipBlock()
                    } else {
                        skipToLineEnd()
                    }
                    continue
                }
                throw ParseError(line: l, message: "não entendi o começo da linha")
            } catch let e as ParseError {
                fail(e.message, e.line)
                // recupera: até a próxima linha em branco de nível zero
                while !isEOF, !isNewline {
                    if at("{") {
                        skipBlock()
                    } else {
                        advance()
                    }
                }
            } catch { fail("erro interno: \(error)", l) }
        }
        return out
    }

    mutating func parseStruct() throws -> StructDecl {
        let l = line
        try expect("struct").self ?? (try expect("class"))
        let name = try ident()
        var conforms: [String] = []
        if at(":") {
            advance(); repeat {
                skipNewlines(); try conforms.append(ident()); skipNewlines()
            } while at(",") &&
                { advance(); return true }()
        }
        try expect("{")
        var vars: [VarDecl] = [], funcs: [FuncDecl] = []
        var body: [Stmt]?
        while true {
            skipNewlines()
            if at("}") {
                advance(); break
            }
            if isEOF {
                throw ParseError(line: l, message: "struct \(name) sem fechar")
            }
            let ml = line
            do {
                if at("var"), peekIs("body") {
                    advance(); advance()
                    if at(":") {
                        advance(); while !at("{"), !isEOF {
                            advance()
                        }
                    }
                    body = try parseBlock()
                    continue
                }
                if at("@State") || at("@Binding") || at("@Environment") || at("@ObservedObject") || at(
                    "@StateObject"
                ) ||
                    at("@Bindable") || at("@FocusState") || at("@AppStorage")
                {
                    let attrName = ident0()
                    advance()
                    if at("(") {
                        skipParens()
                    }
                    let attr: VarAttr = attrName == "@State" || attrName == "@FocusState" || attrName == "@AppStorage" ?
                        .state : attrName == "@Binding" ? .binding : attrName == "@Environment" ? .environment :
                        .observed
                    if attr ==
                        .environment
                    {
                        warn("fora do subconjunto: \(attrName) (ignorado)", ml); skipToLineEnd(); continue
                    }
                    while at("private") || at("public") || at("internal") || at("fileprivate") {
                        advance()
                    }
                    var v = try parseVarDecl()
                    v.attr = attr
                    vars.append(v)
                    continue
                }
                while at("private") || at("public") || at("internal") || at("fileprivate") || at("static") {
                    advance()
                }
                if at("var") || at("let") {
                    try vars.append(parseVarDecl()); continue
                }
                if at("func") {
                    try funcs.append(parseFunc()); continue
                }
                if at("init") {
                    warn("init personalizado ignorado", ml); while !at("{"),
                                                                   !isEOF
                    {
                        advance()
                    }; skipBlock(); continue
                }
                if at("@") {
                    advance(); skipToLineEnd(); continue
                }
                throw ParseError(line: ml, message: "não entendi este membro de \(name)")
            } catch let e as ParseError {
                fail(e.message, e.line)
                while !isEOF, !isNewline {
                    if at("{") {
                        skipBlock()
                    } else {
                        advance()
                    }
                }
            }
        }
        return StructDecl(
            name: name,
            conforms: conforms,
            vars: vars,
            funcs: funcs,
            body: body,
            isMain: false,
            file: file,
            line: l
        )
    }

    func ident0() -> String {
        if case let .ident(s) = cur.kind {
            return s
        }; return ""
    }

    mutating func skipParens() {
        var depth = 0
        repeat {
            if at("(") {
                depth += 1
            } else if at(")") {
                depth -= 1
            }; advance()
        } while depth > 0 && !isEOF
    }

    mutating func parseVarDecl() throws -> VarDecl {
        let l = line
        let isLet = at("let")
        advance()
        let name = try ident()
        var typeName: String?
        if at(":") {
            advance(); skipNewlines()
            var t = ""
            while !at("="), !isNewline, !at("{"),
                  !isEOF
            {
                if case let .ident(s) = cur.kind {
                    t += s
                } else if case let .punct(s) = cur.kind {
                    t += s
                }; advance()
            }
            typeName = t
        }
        var initial: Expr?
        if at("=") {
            advance(); skipNewlines(); initial = try parseExpr()
        } else if at("{") {
            // propriedade computada: tratamos como closure sem parâmetros avaliada na leitura
            let body = try parseBlock()
            initial = .closure(Closure(params: [], body: body, line: l))
            return VarDecl(name: name, attr: .none, isLet: true, typeName: typeName, initial: initial, line: l)
        }
        return VarDecl(name: name, attr: .none, isLet: isLet, typeName: typeName, initial: initial, line: l)
    }

    mutating func parseFunc() throws -> FuncDecl {
        let l = line
        try expect("func")
        let name = try ident()
        try expect("(")
        var params: [(label: String?, name: String)] = []
        skipNewlines()
        while !at(")") {
            let a = try ident()
            var label: String? = a
            var pname = a
            if case .ident = cur.kind, !at(":") {
                pname = try ident(); label = a == "_" ? nil : a
            }
            try expect(":")
            while !at(","), !at(")"), !isEOF {
                advance()
            }
            params.append((label, pname))
            if at(",") {
                advance()
            }
            skipNewlines()
        }
        try expect(")")
        skipNewlines()
        if at("->") {
            advance(); while !at("{"), !isEOF {
                advance()
            }
        }
        let body = try parseBlock()
        return FuncDecl(name: name, params: params, body: body, line: l)
    }

    // MARK: blocos e statements

    mutating func parseBlock() throws -> [Stmt] {
        try expect("{")
        var out: [Stmt] = []
        while true {
            skipNewlines()
            if at("}") {
                advance(); return out
            }
            if isEOF {
                throw ParseError(line: line, message: "bloco sem fechar")
            }
            try out.append(parseStmt())
            if at(";") {
                advance()
            }
        }
    }

    mutating func parseStmt() throws -> Stmt {
        let l = line
        if at("let") || at("var") {
            return try .varDecl(parseVarDecl())
        }
        if at("func") {
            return try .funcDecl(parseFunc())
        }
        if at("return") {
            advance(); if isNewline || at("}") {
                return .returnStmt(nil, line: l)
            }; return try .returnStmt(
                parseExpr(),
                line: l
            )
        }
        if at("if") {
            let e = try parseIf(); if case let .ifExpr(c, a, b, _) = e {
                return .ifStmt(c, a, b, line: l)
            }; return .expr(
                e,
                line: l
            )
        }
        if at("for") {
            advance()
            let name = try ident()
            try expect("in")
            let seq = try parseExpr()
            let body = try parseBlock()
            return .forIn(name, seq, body, line: l)
        }
        let e = try parseExpr()
        if case let .punct(op) = cur.kind, ["=", "+=", "-=", "*=", "/="].contains(op) {
            advance(); skipNewlines()
            let v = try parseExpr()
            return .assign(e, op, v, line: l)
        }
        return .expr(e, line: l)
    }

    mutating func parseIf() throws -> Expr {
        let l = line
        try expect("if")
        var cond: Expr
        if at("let") { // if let x = y  → tratamos como `y != nil`
            advance(); let n = try ident(); try expect("="); let v = try parseExprNoTrailing()
            cond = .binary("!=", v, .ident("nil", line: l))
            _ = n
        } else {
            cond = try parseExprNoTrailing()
        }
        let then = try parseBlock()
        var els: [Stmt]?
        skipNewlines()
        if at("else") {
            advance(); skipNewlines()
            if at("if") {
                let e = try parseIf(); els = [.expr(e, line: e.line)]
            } else {
                els = try parseBlock()
            }
        }
        return .ifExpr(cond, then, els, line: l)
    }

    // MARK: expressões (precedência)

    var noTrailing = false

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
                throw ParseError(line: l, message: "closure sem fechar")
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
            throw ParseError(line: l, message: "não entendi '\(describe(cur))'")
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
                    while j < chars.count,
                          depth >
                          0
                    {
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
