import Foundation

struct ParseError: Error { let line: Int; let message: String }

/// Parser recursivo do subconjunto de Swift usado nos playgrounds.
public struct Parser {
    var toks: [Token]
    var p = 0
    let file: String
    var diags: [SwiftDiagnostic] = []
    /// Enquanto vale, `parsePostfix` não engole o bloco `{ … }` que vier depois.
    var noTrailing = false

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
}
