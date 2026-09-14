import Foundation
import SwiftUI

struct RuntimeError: Error { let line: Int; let message: String }

/// Programa: as structs de todos os arquivos, e a raiz a renderizar.
@MainActor
public final class Program {
    public let structs: [String: StructDecl]
    public var diagnostics: [SwiftDiagnostic]
    public let rootName: String?

    public init(files: [SwiftFile]) {
        var map: [String: StructDecl] = [:]
        var diags: [SwiftDiagnostic] = []
        for f in files {
            for s in f.structs {
                map[s.name] = s
            }; diags += f.diagnostics
        }
        structs = map
        diagnostics = diags
        // raiz: a view dentro de WindowGroup do @main, senão ContentView, senão a primeira View
        var root: String?
        if let app = map.values.first(where: { $0.isMain && $0.isApp }), let body = app.body {
            for st in body {
                if case let .expr(e, _) = st {
                    root = Self.firstViewName(e, in: map) ?? root
                }
            }
        }
        if root == nil, map["ContentView"]?.isView == true {
            root = "ContentView"
        }
        if root == nil {
            root = map.values.filter(\.isView).sorted { $0.line < $1.line }.first?.name
        }
        rootName = root
    }

    static func firstViewName(_ e: Expr, in map: [String: StructDecl]) -> String? {
        switch e {
        case let .call(.ident(n, _), _, tr, _):
            if map[n]?.isView == true {
                return n
            }
            for (_, c) in tr {
                for st in c.body {
                    if case let .expr(x, _) = st, let f = firstViewName(x, in: map) {
                        return f
                    }
                }
            }
            return nil
        case let .call(base, _, tr, _):
            if let f = firstViewName(base, in: map) {
                return f
            }
            for (_, c) in tr {
                for st in c.body {
                    if case let .expr(x, _) = st, let f = firstViewName(x, in: map) {
                        return f
                    }
                }
            }
            return nil
        case let .member(base?, _, _): return firstViewName(base, in: map)
        default: return nil
        }
    }

    public var viewNames: [String] {
        structs.values.filter(\.isView).map(\.name).sorted()
    }

    public func instance(of name: String) -> ViewInstance? {
        guard let s = structs[name] else { return nil }
        return ViewInstance(decl: s, program: self, args: [])
    }
}

/// Uma instância de View: estado próprio, filhos estáveis e avaliação do body.
@MainActor
@Observable
public final class ViewInstance {
    public let decl: StructDecl
    let program: Program
    public var state: [String: Value] = [:]
    public private(set) var diagnostics: [SwiftDiagnostic] = []
    private var children: [String: ViewInstance] = [:]
    private var childSeq = 0
    private var appeared = false

    init(decl: StructDecl, program: Program, args: [(String?, Value)]) {
        self.decl = decl
        self.program = program
        for v in decl.vars {
            if let a = args.first(where: { $0.0 == v.name }) {
                state[v.name] = a.1; continue
            }
            if v.attr == .binding {
                state[v.name] = .none; continue
            }
            if let e = v.initial {
                if case let .closure(c) = e, v.typeName != nil, !isViewType(v.typeName) {
                    state[v.name] = .closure(
                        c,
                        self
                    )
                } // computada
                else {
                    state[v.name] = (try? eval(e, [:])) ?? .none
                }
            } else {
                state[v.name] = defaultValue(v.typeName)
            }
        }
    }

    func isViewType(_ t: String?) -> Bool {
        t?.contains("View") == true
    }

    func defaultValue(_ t: String?) -> Value {
        switch t ?? "" {
        case "Int": .int(0); case "Double", "CGFloat": .double(0); case "Bool": .bool(false); case "String": .string("")
        default: t?.hasPrefix("[") == true ? .array([]) : .none
        }
    }

    public func get(_ name: String) -> Value {
        let v = state[name] ?? .none
        if case let .binding(inst, n) = v {
            return inst.get(n)
        }
        if case let .closure(c, inst) = v, c.params.isEmpty, decl.vars.first(where: { $0.name == name })?.isLet == true,
           decl.vars.first(where: { $0.name == name })?.typeName != nil
        {
            return (try? inst.run(c.body, [:], builder: false)) ?? .none // propriedade computada
        }
        return v
    }

    public func set(_ name: String, _ value: Value) {
        if case let .binding(inst, n) = state[name] ?? .none {
            inst.set(n, value); return
        }
        state[name] = value
    }

    func report(_ msg: String, _ line: Int, warning: Bool = true) {
        let d = SwiftDiagnostic(warning ? .warning : .error, file: decl.file, line: line, message: msg)
        if !diagnostics.contains(d) {
            diagnostics.append(d)
        }
    }

    /// Avalia o body e devolve os nós.
    public func evalBody() -> [ViewNode] {
        childSeq = 0
        diagnostics.removeAll()
        guard let body = decl.body else { report("\(decl.name) não tem body", decl.line, warning: false); return [] }
        let nodes = builder(body, [:])
        if !appeared {
            appeared = true; for n in nodes {
                runOnAppear(n)
            }
        }
        return nodes
    }

    func runOnAppear(_ n: ViewNode) {
        for m in n.modifiers where m.name == "onAppear" {
            if case let .closure(c, inst)? = m.first {
                _ = try? inst.run(
                    c.body,
                    [:],
                    builder: false
                )
            }
        }
        for c in n.children {
            runOnAppear(c)
        }
    }

    /// Executa statements num contexto de ViewBuilder: expressões que viram views entram na lista.
    func builder(_ stmts: [Stmt], _ env: [String: Value]) -> [ViewNode] {
        var out: [ViewNode] = []
        var env = env
        for st in stmts {
            do {
                switch st {
                case let .expr(e, line):
                    let v = try eval(e, env)
                    switch v {
                    case let .view(n): out.append(n)
                    case let .views(ns): out += ns
                    case .none: break
                    default: report("isto não é uma view", line)
                    }
                case let .varDecl(v): env[v.name] = try v.initial.map { try eval($0, env) } ?? .none
                case let .ifStmt(c, a, b, _):
                    if try eval(c, env).asBool {
                        out += builder(a, env)
                    } else if let b {
                        out += builder(b, env)
                    }
                case let .forIn(name, seq, body, _):
                    for item in try iterate(eval(seq, env)) {
                        var e2 = env; e2[name] = item; out += builder(body, e2)
                    }
                case let .assign(t, op, v, line): try assign(t, op, eval(v, env), &env, line)
                case .funcDecl: break
                case let .returnStmt(e, _): if let e, case let .view(n) = try eval(e, env) {
                        out.append(n)
                    }
                }
            } catch let e as RuntimeError { report(e.message, e.line, warning: false); out.append(placeholder(
                e.message,
                e.line
            )) } catch { report("\(error)", st.line, warning: false) }
        }
        return out
    }

    func placeholder(_ msg: String, _ line: Int) -> ViewNode {
        ViewNode(
            kind: "__placeholder",
            args: [(nil, .string(msg))],
            line: line
        )
    }

    /// Executa statements como código (ações, funções). Devolve o valor de `return`.
    @discardableResult
    func run(_ stmts: [Stmt], _ env: [String: Value], builder isBuilder: Bool) throws -> Value {
        var env = env
        for st in stmts {
            switch st {
            case let .expr(e, _): let v = try eval(e, env); if stmts.count == 1 {
                    return v
                }
            case let .varDecl(v): env[v.name] = try v.initial.map { try eval($0, env) } ?? .none
            case let .assign(t, op, v, line): try assign(t, op, eval(v, env), &env, line)
            case let .ifStmt(c, a, b, _):
                if try eval(c, env).asBool {
                    let r = try run(a, env, builder: false); if !r.isNone {
                        return r
                    }
                } else if let b {
                    let r = try run(
                        b,
                        env,
                        builder: false
                    ); if !r.isNone {
                        return r
                    }
                }
            case let .forIn(name, seq, body, _):
                for item in try iterate(eval(seq, env)) {
                    var e2 = env; e2[name] = item; _ = try run(
                        body,
                        e2,
                        builder: false
                    )
                }
            case let .returnStmt(e, _): return try e.map { try eval($0, env) } ?? .none
            case .funcDecl: break
            }
        }
        return .none
    }

    func iterate(_ v: Value) throws -> [Value] {
        switch v.deref {
        case let .array(a): return a
        case let .int(n): return (0 ..< max(0, n)).map { .int($0) }
        default: throw RuntimeError(line: 0, message: "não dá para iterar \(v.asString)")
        }
    }

    func assign(_ target: Expr, _ op: String, _ value: Value, _ env: inout [String: Value], _ line: Int) throws {
        guard case let .ident(name, _) = target else { throw RuntimeError(
            line: line,
            message: "só dá para atribuir a variáveis"
        ) }
        let cur: Value = env[name] ?? get(name)
        let new: Value
        switch op {
        case "=": new = value
        case "+=":
            if case let .string(s) = cur.deref {
                new = .string(s + value.asString)
            } else if case .double = cur.deref {
                new = .double((cur.asDouble ?? 0) + (value.asDouble ?? 0))
            } else if case let .array(a) = cur.deref {
                new = .array(a + [value])
            } else {
                new = .int((cur.asInt ?? 0) + (value.asInt ?? 0))
            }
        case "-=": if case .double = cur.deref {
                new = .double((cur.asDouble ?? 0) - (value.asDouble ?? 0))
            } else {
                new = .int((cur.asInt ?? 0) - (value.asInt ?? 0))
            }
        case "*=": if case .double = cur.deref {
                new = .double((cur.asDouble ?? 0) * (value.asDouble ?? 1))
            } else {
                new = .int((cur.asInt ?? 0) * (value.asInt ?? 1))
            }
        case "/=": new = .double((cur.asDouble ?? 0) / max(value.asDouble ?? 1, 0.000001))
        default: throw RuntimeError(line: line, message: "operador \(op)")
        }
        if env[name] != nil, state[name] == nil {
            env[name] = new
        } else {
            set(name, new)
        }
    }

    // MARK: avaliação

    public func eval(_ e: Expr, _ env: [String: Value]) throws -> Value {
        switch e {
        case let .int(i): return .int(i)
        case let .double(d): return .double(d)
        case let .bool(b): return .bool(b)
        case let .string(segs):
            var s = ""
            for seg in segs {
                switch seg { case let .text(t): s += t; case let .expr(x): s += try eval(x, env).asString }
            }
            return .string(s)
        case let .array(items): return try .array(items.map { try eval($0, env) })
        case let .range(a, b, closed):
            let lo = try eval(a, env).asInt ?? 0, hi = try eval(b, env).asInt ?? 0
            return .array((lo ..< (closed ? hi + 1 : hi)).map { .int($0) })
        case let .closure(c): return .closure(c, self)
        case let .ident(name, line):
            if name.hasPrefix("$") {
                return bindingFor(String(name.dropFirst()), env)
            }
            if let v = env[name] {
                return v
            }
            if state[name] != nil {
                return get(name)
            }
            if let f = decl.funcs.first(where: { $0.name == name }) {
                return .closure(
                    Closure(params: f.params.map(\.name), body: f.body, line: f.line),
                    self
                )
            }
            switch name {
            case "nil": return .none
            case "Color": return .token("Color")
            default:
                if program.structs[name] != nil || name.first?.isUppercase == true {
                    return .token(name)
                }
                throw RuntimeError(line: line, message: "não conheço '\(name)'")
            }
        case let .member(base, name, line):
            guard let base else { return .token(name) }
            let b = try eval(base, env)
            return try member(b, name, line)
        case let .call(callee, args, trailing, line):
            return try call(callee, args, trailing, env, line)
        case let .subscriptExpr(a, i):
            let arr = try eval(a, env).deref, idx = try eval(i, env).asInt ?? 0
            if case let .array(items) = arr {
                guard idx >= 0, idx < items.count
                else { throw RuntimeError(
                    line: a.line,
                    message: "índice \(idx) fora do array"
                ) }; return items[idx]
            }
            throw RuntimeError(line: a.line, message: "subscript em algo que não é array")
        case let .unary(op, x):
            let v = try eval(x, env).deref
            if op == "!" {
                return .bool(!v.asBool)
            }
            if case let .int(i) = v {
                return .int(-i)
            }
            return .double(-(v.asDouble ?? 0))
        case let .binary(op, a, b): return try binary(op, eval(a, env).deref, eval(b, env).deref, a.line)
        case let .ternary(c, a, b): return try eval(c, env).asBool ? try eval(a, env) : try eval(b, env)
        case let .ifExpr(c, a, b, _):
            let nodes = try eval(c, env).asBool ? builder(a, env) : (b.map { builder($0, env) } ?? [])
            return .views(nodes)
        }
    }

    func bindingFor(_ name: String, _ env: [String: Value]) -> Value {
        if case let .binding(inst, n)? = state[name] {
            return .binding(inst, n)
        }
        return .binding(self, name)
    }

    func binary(_ op: String, _ a: Value, _ b: Value, _ line: Int) throws -> Value {
        switch op {
        case "&&": return .bool(a.asBool && b.asBool)
        case "||": return .bool(a.asBool || b.asBool)
        case "??": return a.isNone ? b : a
        case "==", "!=":
            let eq: Bool = switch (a, b) {
            case (.none, .none): true
            case (.none, _), (_, .none): false
            case let (.int(x), .int(y)): x == y
            case let (.bool(x), .bool(y)): x == y
            default: if let x = a.asDouble, let y = b.asDouble {
                    x == y
                } else {
                    a.asString == b.asString
                }
            }
            return .bool(op == "==" ? eq : !eq)
        case "<", ">", "<=", ">=":
            guard let x = a.asDouble,
                  let y = b.asDouble
            else { return .bool(op.contains("<") ? a.asString < b.asString : a.asString > b.asString) }
            switch op {
            case "<": return .bool(x < y); case ">": return .bool(x > y); case "<=": return .bool(x <=
                    y); default: return .bool(x >= y)
            }
        case "+":
            if case let .string(s) = a {
                return .string(s + b.asString)
            }
            if case let .array(x) = a, case let .array(y) = b {
                return .array(x + y)
            }
            if case let .int(x) = a, case let .int(y) = b {
                return .int(x + y)
            }
            return .double((a.asDouble ?? 0) + (b.asDouble ?? 0))
        case "-", "*", "/", "%":
            if case let .int(x) = a, case let .int(y) = b {
                switch op {
                case "-": return .int(x - y); case "*": return .int(x * y); case "/": guard y != 0
                    else { throw RuntimeError(
                        line: line,
                        message: "divisão por zero"
                    ) }; return .int(x / y); default: guard y != 0 else { throw RuntimeError(
                        line: line,
                        message: "divisão por zero"
                    ) }; return .int(x % y)
                }
            }
            let x = a.asDouble ?? 0, y = b.asDouble ?? 0
            switch op {
            case "-": return .double(x - y); case "*": return .double(x * y); case "/": return .double(x /
                    y); default: return .double(x.truncatingRemainder(dividingBy: y))
            }
        default: throw RuntimeError(line: line, message: "operador \(op)")
        }
    }

    /// Membros de valores: `.count`, `.uppercased()`, `.toggle()`, cores, fontes.
    func member(_ base: Value, _ name: String, _ line: Int) throws -> Value {
        switch base {
        case let .view(n): return .view(n) // modificador sem parênteses (.bold) tratado em call; aqui só devolve
        case let .token(t):
            if t == "Color" {
                return Builtins.color(name).map { .color($0) } ?? .token(name)
            }
            if t == "Font" {
                return Builtins.font(name).map { .font($0) } ?? .token(name)
            }
            return .token(name)
        case let .binding(inst, n):
            if name == "wrappedValue" {
                return inst.get(n)
            }
            return try member(inst.get(n), name, line)
        case let .string(s):
            switch name { case "count": return .int(s.count); case "isEmpty": return .bool(
                    s.isEmpty
                ); case "uppercased",
                 "lowercased", "capitalized", "trimmed": return .closure(
                    Closure(params: [], body: [], line: line),
                    self
                ).stringOp(s, name)
            default: throw RuntimeError(line: line, message: "String não tem .\(name)") }
        case let .array(a):
            switch name {
            case "count": return .int(a.count); case "isEmpty": return .bool(a.isEmpty); case "first": return a
                .first ?? .none; case "last": return a.last ?? .none
            default: throw RuntimeError(line: line, message: "Array não tem .\(name) (fora do subconjunto)")
            }
        case let .int(i): if name == "description" {
                return .string(String(i))
            }; throw RuntimeError(
                line: line,
                message: "Int não tem .\(name)"
            )
        case let .double(d): if name == "rounded" {
                return .double(d.rounded())
            }; throw RuntimeError(
                line: line,
                message: "Double não tem .\(name)"
            )
        default: throw RuntimeError(line: line, message: ".\(name) em \(base.asString)")
        }
    }

    /// Chamadas: views, modificadores, funções, métodos.
    func call(
        _ callee: Expr,
        _ args: [Arg],
        _ trailing: [(String?, Closure)],
        _ env: [String: Value],
        _ line: Int
    ) throws -> Value {
        // modificador: base.nome(args) { trailing }
        if case let .member(baseExpr?, name, _) = callee {
            let base = try eval(baseExpr, env)
            switch base.deref {
            case var .view(n):
                let evArgs = try args.map { try ($0.label, eval($0.value, env)) }
                var tr: [ViewNode] = []
                for (_, c) in trailing {
                    tr += builder(c.body, env)
                }
                n.modifiers.append(Modifier(name: name, args: evArgs, trailing: tr, line: line))
                if name == "onAppear", let c = trailing.first?.1 {
                    n.modifiers[n.modifiers.count - 1].args = [(
                        nil,
                        .closure(c, self)
                    )]
                }
                return .view(n)
            case let .views(ns):
                // modificador em `if` de views: aplica em cada um
                let evArgs = try args.map { try ($0.label, eval($0.value, env)) }
                return .views(ns.map { var m = $0; m.modifiers.append(Modifier(
                    name: name,
                    args: evArgs,
                    trailing: [],
                    line: line
                )); return m })
            case let .string(s):
                switch name {
                case "uppercased": return .string(s.uppercased())
                case "lowercased": return .string(s.lowercased())
                case "capitalized": return .string(s.capitalized)
                case "contains": return try .bool(s.contains(eval(args[0].value, env).asString))
                case "hasPrefix": return try .bool(s.hasPrefix(eval(args[0].value, env).asString))
                case "trimmingCharacters": return .string(s.trimmingCharacters(in: .whitespacesAndNewlines))
                case "replacingOccurrences": return try .string(s.replacingOccurrences(
                        of: eval(args[0].value, env).asString,
                        with: eval(args[1].value, env).asString
                    ))
                default: throw RuntimeError(line: line, message: "String.\(name) (fora do subconjunto)")
                }
            case .array, .binding, .int, .double, .bool:
                if case let .binding(inst, n) = base {
                    let cur = inst.get(n)
                    switch name {
                    case "toggle": inst.set(n, .bool(!cur.asBool)); return .none
                    case "append": if case let .array(a) = cur {
                            try inst.set(n, .array(a + [eval(args[0].value, env)]))
                        }; return .none
                    case "removeAll": inst.set(n, .array([])); return .none
                    case "remove":
                        if case let .array(a) = cur, let at = args.first(where: { $0.label == "at" }), let i = try eval(
                            at.value,
                            env
                        ).asInt, i < a.count {
                            var b = a; b.remove(at: i); inst.set(n, .array(b))
                        }
                        return .none
                    default: break
                    }
                }
                if case let .ident(varName, _) = baseExpr, state[varName] != nil || env[varName] == nil {
                    let cur = get(varName)
                    switch name {
                    case "toggle": set(varName, .bool(!cur.asBool)); return .none
                    case "append": if case let .array(a) = cur {
                            try set(varName, .array(a + [eval(args[0].value, env)]))
                        }; return .none
                    case "removeAll": set(varName, .array([])); return .none
                    case "remove":
                        if case let .array(a) = cur, let at = args.first(where: { $0.label == "at" }), let i = try eval(
                            at.value,
                            env
                        ).asInt, i < a.count {
                            var b = a; b.remove(at: i); set(varName, .array(b))
                        }
                        return .none
                    case "shuffled": if case let .array(a) = cur {
                            return .array(a.shuffled())
                        }
                    case "contains": if case let .array(a) = cur {
                            let v = try eval(args[0].value, env); return .bool(a.contains { $0.asString == v.asString })
                        }
                    case "randomElement": if case let .array(a) = cur {
                            return a.randomElement() ?? .none
                        }
                    default: break
                    }
                }
                if case let .array(a) = base.deref {
                    switch name {
                    case "map": if let c = trailing.first?
                        .1 {
                            return try .array(a.map { try callClosure(c, [$0], env) })
                        }
                    case "filter": if let c = trailing.first?.1 {
                            return try .array(a.filter { try callClosure(
                                c,
                                [$0],
                                env
                            ).asBool })
                        }
                    case "contains": let v = try eval(
                            args[0].value,
                            env
                        ); return .bool(a.contains { $0.asString == v.asString })
                    case "joined": return try .string(a.map(\.asString).joined(separator: args.first.map { try eval(
                            $0.value,
                            env
                        ).asString } ?? ""))
                    case "reversed": return .array(a.reversed())
                    case "sorted": return .array(a.sorted { ($0.asDouble ?? 0, $0.asString) < (
                            $1.asDouble ?? 0,
                            $1.asString
                        ) })
                    default: break
                    }
                }
                if case let .double(d) = base.deref, name == "rounded" {
                    return .double(d.rounded())
                }
                if case let .int(i) = base.deref, name == "formatted" {
                    return .string(i.formatted())
                }
                if case let .double(d) = base.deref,
                   name == "formatted"
                {
                    return .string(d.formatted(.number.precision(.fractionLength(0 ... 2))))
                }
                throw RuntimeError(line: line, message: ".\(name) (fora do subconjunto)")
            case let .token(t):
                if t == "Color", name == "init" {
                    break
                }
                // Color.red.opacity(0.5), Font.system(size:)
                if t == "Font", name == "system" {
                    return try .font(Builtins.systemFont(args.map { try (
                        $0.label,
                        eval($0.value, env)
                    ) }))
                }
                return .token(name)
            case let .color(c):
                if name == "opacity" {
                    return try .color(c.opacity(eval(args[0].value, env).asDouble ?? 1))
                }
                return .color(c)
            case let .font(f):
                switch name {
                case "bold": return .font(f.bold()); case "weight": return try .font(f.weight(Builtins.weight(eval(
                        args[0].value,
                        env
                    )))); case "italic": return .font(f.italic()); case "monospaced": return .font(f
                        .monospaced()); default: return .font(f)
                }
            default: throw RuntimeError(line: line, message: ".\(name)(…) em \(base.asString)")
            }
        }
        // chamada por nome
        guard case let .ident(name, _) = callee else {
            if case let .member(nil, n, _) = callee {
                return try call(.ident(n, line: line), args, trailing, env, line)
            }
            throw RuntimeError(line: line, message: "chamada fora do subconjunto")
        }
        // closure em variável / função da struct / parâmetro
        if let v = env[name] ?? state[name], case let .closure(c, inst) = v {
            return try inst.callClosure(
                c,
                args.map { try eval($0.value, env) },
                env
            )
        }
        if let f = decl.funcs.first(where: { $0.name == name }) {
            return try run(
                f.body,
                Dictionary(uniqueKeysWithValues: zip(f.params.map(\.name), args.map { try eval($0.value, env) })),
                builder: false
            )
        }
        let evArgs = try args.map { try ($0.label, eval($0.value, env)) }
        switch name {
        case "String": return .string(evArgs.first?.1.asString ?? "")
        case "Int": return .int(evArgs.first?.1.asInt ?? 0)
        case "Double", "CGFloat": return .double(evArgs.first?.1.asDouble ?? 0)
        case "Bool": return .bool(evArgs.first?.1.asBool ?? false)
        case "min": return .double(evArgs.compactMap(\.1.asDouble).min() ?? 0).intIfWhole(evArgs)
        case "max": return .double(evArgs.compactMap(\.1.asDouble).max() ?? 0).intIfWhole(evArgs)
        case "abs": return evArgs[0].1.deref.absValue
        case "print": return .none
        case "withAnimation": if let c = trailing.first?.1 {
                return try run(c.body, env, builder: false)
            }; return .none
        case "Array": return try .array(iterate(evArgs.first?.1 ?? .array([])))
        case "Color": return .color(Builtins.colorInit(evArgs))
        default: break
        }
        // struct do usuário
        if let s = program.structs[name], s.isView {
            childSeq += 1
            let key = "\(name)#\(childSeq)"
            let inst = children[key] ?? ViewInstance(decl: s, program: program, args: evArgs)
            if children[key] == nil {
                children[key] = inst
            } else {
                for (l, v) in evArgs {
                    if let l, case .binding = v {
                        inst.state[l] = v
                    } else if let l,
                              s.vars
                              .first(where: {
                                  $0.name == l
                              })?
                              .attr != .state
                    {
                        inst.state[l] = v
                    }
                }
            }
            var node = ViewNode(kind: "__struct", args: evArgs, line: line)
            node.owner = inst
            node.children = inst.evalBody()
            diagnostics += inst.diagnostics
            return .view(node)
        }
        // views embutidas
        if Builtins.views.contains(name) || name.first?.isUppercase == true {
            if !Builtins.views.contains(name) {
                report("fora do subconjunto: \(name)", line); return .view(placeholder(
                    name,
                    line
                ))
            }
            var node = ViewNode(kind: name, args: evArgs, line: line)
            node.owner = self
            switch name {
            case "Button":
                if let c = trailing.first?.1, trailing.count == 1,
                   args.contains(where: { $0.label == nil }) || args.isEmpty && false
                {
                    node.action = (
                        c,
                        self
                    )
                }
                if let a = args.first(where: { $0.label == "action" }), case let .closure(c) = a.value {
                    node.action = (
                        c,
                        self
                    )
                }
                if trailing.count == 1, node.action == nil, !args.isEmpty {
                    node.action = (trailing[0].1, self)
                } else if trailing.count == 1, node.action == nil {
                    node.action = (trailing[0].1, self)
                }
                if trailing.count == 2 {
                    node.action = (trailing[0].1, self); node.children = builder(
                        trailing[1].1.body,
                        env
                    )
                } else if node.action.map(\.0.line) != trailing.first?.1.line,
                          let c = trailing.first?.1
                {
                    node.children = builder(
                        c.body,
                        env
                    )
                } else if args.isEmpty, let c = trailing.first?.1 {
                    _ = c
                }
                if trailing.count == 1, args.contains(where: { $0.label == "action" }) {
                    node.children = builder(
                        trailing[0].1.body,
                        env
                    )
                }
            case "ForEach":
                guard let c = trailing.first?.1 else { break }
                let items = try iterate(evArgs.first?.1 ?? .array([]))
                var kids: [ViewNode] = []
                for (i, item) in items.enumerated() {
                    var e2 = env
                    if let p = c.params.first {
                        e2[p] = item
                    }
                    if c.params.count > 1 {
                        e2[c.params[1]] = .int(i)
                    }
                    kids += builder(c.body, e2)
                }
                return .views(kids)
            case "NavigationLink":
                if let dest = args.first(where: { $0.label == "destination" }) {
                    let d = dest.value
                    node
                        .lazyChildren = { [weak self] _ in
                            guard let self, case let .view(n)? = try? eval(d, env) else { return [] }; return [n]
                        }
                    if let c = trailing.first?.1 {
                        node.children = builder(c.body, env)
                    }
                } else if trailing.count >= 1 {
                    let destC = trailing.count == 2 ? trailing[1].1 : trailing[0].1
                    node.lazyChildren = { [weak self] _ in self?.builder(destC.body, env) ?? [] }
                    if trailing.count == 2 {
                        node.children = builder(trailing[0].1.body, env)
                    }
                }
            default:
                for (_, c) in trailing {
                    node.children += builder(c.body, env)
                }
            }
            return .view(node)
        }
        throw RuntimeError(line: line, message: "não conheço '\(name)'")
    }

    func callClosure(_ c: Closure, _ args: [Value], _ env: [String: Value]) throws -> Value {
        var e2 = env
        for (i, p) in c.params.enumerated() {
            e2[p] = i < args.count ? args[i] : .none
        }
        if c.params.isEmpty, !args.isEmpty {
            e2["$0"] = args[0]
        }
        return try run(c.body, e2, builder: false)
    }

    /// Ação de um botão.
    public func perform(_ action: (Closure, ViewInstance)) {
        do { _ = try action.1.run(action.0.body, [:], builder: false) } catch let e as RuntimeError { report(
            e.message,
            e.line,
            warning: false
        ) } catch {}
    }
}

extension Value {
    func stringOp(_ s: String, _ name: String) -> Value {
        switch name {
        case "uppercased": .string(s.uppercased()); case "lowercased": .string(s
                .lowercased()); case "capitalized": .string(s.capitalized); default: .string(s
                .trimmingCharacters(in: .whitespaces))
        }
    }

    func intIfWhole(_ args: [(String?, Value)]) -> Value {
        if args.allSatisfy({
            if case .int = $0.1.deref {
                true
            } else {
                false
            }
        }),
            let d = asDouble
        {
            return .int(Int(d))
        }
        return self
    }

    var absValue: Value {
        if case let .int(i) = self {
            return .int(abs(i))
        }; return .double(abs(asDouble ?? 0))
    }
}
