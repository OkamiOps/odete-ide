import Foundation
import SwiftUI

/// Valor em tempo de execução do subconjunto.
@MainActor
public indirect enum Value {
    case string(String), int(Int), double(Double), bool(Bool)
    case array([Value])
    case color(Color)
    case font(Font)
    /// `.leading`, `.largeTitle`, `.bordered`… (membro implícito sem tipo conhecido)
    case token(String)
    case closure(Closure, ViewInstance)
    case view(ViewNode)
    case views([ViewNode])
    /// Referência a um estado (`$x` ou parâmetro de @Binding).
    case binding(ViewInstance, String)
    case none

    public var asString: String {
        switch self {
        case let .string(s): s
        case let .int(i): String(i)
        // `if` e não ternário: o SwiftLint lê `String(format:)` dentro de um ternário
        // como chamada de função Void, e aqui a forma longa é igualmente clara.
        case let .double(d):
            if d == d.rounded(), abs(d) < 1e15 {
                String(format: "%.1f", d)
            } else {
                String(d)
            }
        case let .bool(b): b ? "true" : "false"
        case let .array(a): "[" + a.map(\.asString).joined(separator: ", ") + "]"
        case let .token(t): "." + t
        case .none: "nil"
        case let .binding(inst, n): inst.get(n).asString
        default: ""
        }
    }

    public var asDouble: Double? {
        switch self {
        case let .int(i): Double(i)
        case let .double(d): d
        case let .string(s): Double(s)
        case let .binding(inst, n): inst.get(n).asDouble
        default: nil
        }
    }

    public var asInt: Int? {
        switch self {
        case let .int(i): i
        // `Int(d)` para o programa com NaN, infinito ou número fora do Int.
        case let .double(d): Int(exactly: d.rounded(.towardZero))
        case let .string(s): Int(s)
        case let .binding(inst, n): inst.get(n).asInt
        default: nil
        }
    }

    public var asBool: Bool {
        switch self {
        case let .bool(b): b
        case let .int(i): i != 0
        case let .binding(inst, n): inst.get(n).asBool
        case .none: false
        default: true
        }
    }

    public var isNone: Bool {
        if case .none = self {
            return true
        }; return false
    }

    public var deref: Value {
        if case let .binding(inst, n) = self {
            return inst.get(n)
        }; return self
    }
}

/// Nó de view avaliado: o que o render desenha.
@MainActor
public struct ViewNode {
    public var kind: String
    public var args: [(label: String?, value: Value)]
    public var children: [ViewNode]
    public var modifiers: [Modifier]
    public var line: Int
    /// Botão: ação; NavigationLink: destino preguiçoso.
    public var action: (Closure, ViewInstance)?
    public var lazyChildren: ((ViewInstance) -> [ViewNode])?
    public var owner: ViewInstance?

    public init(kind: String, args: [(label: String?, value: Value)] = [], children: [ViewNode] = [], line: Int = 0) {
        self.kind = kind; self.args = args; self.children = children; modifiers = []; self.line = line
    }

    public func arg(_ label: String?) -> Value? {
        args.first { $0.label == label }?.value
    }

    public func arg(at i: Int) -> Value? {
        i < args.count ? args[i].value : nil
    }

    public var firstUnlabeled: Value? {
        args.first { $0.label == nil }?.value
    }
}

@MainActor
public struct Modifier {
    public var name: String
    public var args: [(label: String?, value: Value)]
    public var trailing: [ViewNode]
    public var line: Int
    public func arg(_ label: String?) -> Value? {
        args.first { $0.label == label }?.value
    }

    public var first: Value? {
        args.first?.value
    }
}
