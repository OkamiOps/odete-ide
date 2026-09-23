import Foundation
import OdeteI18n
import SwiftUI

/// A avaliação de expressões do interpretador. Mora aqui para o corpo da classe
/// caber numa leitura.
@MainActor
extension ViewInstance {
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
            return try intervalo(eval(a, env), eval(b, env), fechado: closed, linha: a.line)
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
                throw RuntimeError(line: line, message: tr("não conheço '%1$@'", "\(name)"))
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
                    message: tr("índice %1$@ fora do array", "\(idx)")
                ) }; return items[idx]
            }
            throw RuntimeError(line: a.line, message: tr("subscript em algo que não é array"))
        case let .unary(op, x):
            let v = try eval(x, env).deref
            if op == "!" {
                return .bool(!v.asBool)
            }
            if case let .int(i) = v {
                return try .int(Self.conferido(0.subtractingReportingOverflow(i), x.line))
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
                return try .int(Self.conferido(x.addingReportingOverflow(y), line))
            }
            return .double((a.asDouble ?? 0) + (b.asDouble ?? 0))
        case "-", "*", "/", "%":
            // Conta de inteiro que passa do limite derrubava o app inteiro: no Swift de
            // verdade é uma parada do programa, aqui é um erro na linha.
            if case let .int(x) = a, case let .int(y) = b {
                if op == "/" || op == "%", y == 0 {
                    throw RuntimeError(line: line, message: tr("divisão por zero"))
                }
                switch op {
                case "-": return try .int(Self.conferido(x.subtractingReportingOverflow(y), line))
                case "*": return try .int(Self.conferido(x.multipliedReportingOverflow(by: y), line))
                case "/": return try .int(Self.conferido(x.dividedReportingOverflow(by: y), line))
                default: return try .int(Self.conferido(x.remainderReportingOverflow(dividingBy: y), line))
                }
            }
            let x = a.asDouble ?? 0, y = b.asDouble ?? 0
            switch op {
            case "-": return .double(x - y); case "*": return .double(x * y); case "/": return .double(x /
                    y); default: return .double(x.truncatingRemainder(dividingBy: y))
            }
        default: throw RuntimeError(line: line, message: tr("operador %1$@", "\(op)"))
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
            default: throw RuntimeError(line: line, message: tr("String não tem .%1$@", "\(name)")) }
        case let .array(a):
            switch name {
            case "count": return .int(a.count); case "isEmpty": return .bool(a.isEmpty); case "first": return a
                .first ?? .none; case "last": return a.last ?? .none
            default: throw RuntimeError(line: line, message: tr("Array não tem .%1$@ (fora do subconjunto)", "\(name)"))
            }
        case let .int(i): if name == "description" {
                return .string(String(i))
            }; throw RuntimeError(
                line: line,
                message: tr("Int não tem .%1$@", "\(name)")
            )
        case let .double(d): if name == "rounded" {
                return .double(d.rounded())
            }; throw RuntimeError(
                line: line,
                message: tr("Double não tem .%1$@", "\(name)")
            )
        default: throw RuntimeError(line: line, message: tr(".%1$@ em %2$@", "\(name)", "\(base.asString)"))
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
                default: throw RuntimeError(line: line, message: tr("String.%1$@ (fora do subconjunto)", "\(name)"))
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
                throw RuntimeError(line: line, message: tr(".%1$@ (fora do subconjunto)", "\(name)"))
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
            default: throw RuntimeError(line: line, message: tr(".%1$@(…) em %2$@", "\(name)", "\(base.asString)"))
            }
        }
        // chamada por nome
        guard case let .ident(name, _) = callee else {
            if case let .member(nil, n, _) = callee {
                return try call(.ident(n, line: line), args, trailing, env, line)
            }
            throw RuntimeError(line: line, message: tr("chamada fora do subconjunto"))
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
        let evArgs = try args.map { try ($0.label, argumento($0, env, de: name)) }
        switch name {
        case "String": return .string(evArgs.first?.1.asString ?? "")
        case "Int":
            // `Int(1e21)` para o programa no Swift; aqui é erro, não queda do app.
            if case let .double(d)? = evArgs.first?.1.deref, Int(exactly: d.rounded(.towardZero)) == nil {
                throw RuntimeError(line: line, message: tr("%1$@ não cabe num Int", "\(d)"))
            }
            return .int(evArgs.first?.1.asInt ?? 0)
        case "Double", "CGFloat": return .double(evArgs.first?.1.asDouble ?? 0)
        case "Bool": return .bool(evArgs.first?.1.asBool ?? false)
        case "min", "max":
            // Só inteiros: a conta é em inteiros. Passar por `Double` e voltar com `Int(_:)`
            // derrubava o app com o maior inteiro, que em `Double` arredonda para fora.
            let ints = evArgs.compactMap { a -> Int? in
                if case let .int(i) = a.1.deref {
                    return i
                }
                return nil
            }
            if ints.count == evArgs.count, !ints.isEmpty {
                return .int((name == "min" ? ints.min() : ints.max()) ?? 0)
            }
            let ds = evArgs.compactMap(\.1.asDouble)
            return .double((name == "min" ? ds.min() : ds.max()) ?? 0)
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
                report(tr("fora do subconjunto: %1$@", "\(name)"), line); return .view(placeholder(
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
        throw RuntimeError(line: line, message: tr("não conheço '%1$@'", "\(name)"))
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

    var absValue: Value {
        // `abs(Int.min)` não cabe num Int e para o programa; vira Double.
        if case let .int(i) = self {
            return i == .min ? .double(-Double(i)) : .int(abs(i))
        }; return .double(abs(asDouble ?? 0))
    }
}
