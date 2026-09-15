import Foundation
import OdeteI18n
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
    /// `internal(set)`: quem escreve é a avaliação, que vive numa extensão noutro
    /// arquivo; de fora do módulo continua só de leitura.
    public internal(set) var diagnostics: [SwiftDiagnostic] = []
    /// `internal` e não `private`: a avaliação vive numa extensão, noutro arquivo.
    var children: [String: ViewInstance] = [:]
    var childSeq = 0
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
        guard let body = decl.body else { report(
            tr("%1$@ não tem body", "\(decl.name)"),
            decl.line,
            warning: false
        ); return [] }
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
                    default: report(tr("isto não é uma view"), line)
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
        default: throw RuntimeError(line: 0, message: tr("não dá para iterar %1$@", "\(v.asString)"))
        }
    }

    func assign(_ target: Expr, _ op: String, _ value: Value, _ env: inout [String: Value], _ line: Int) throws {
        guard case let .ident(name, _) = target else { throw RuntimeError(
            line: line,
            message: tr("só dá para atribuir a variáveis")
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
        default: throw RuntimeError(line: line, message: tr("operador %1$@", "\(op)"))
        }
        if env[name] != nil, state[name] == nil {
            env[name] = new
        } else {
            set(name, new)
        }
    }
}
