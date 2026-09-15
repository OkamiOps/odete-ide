import Foundation

/// Erro ou aviso do parser/interpretador, sempre com arquivo e linha.
public struct SwiftDiagnostic: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable { case error, warning }
    public var kind: Kind
    public var file: String
    public var line: Int
    public var message: String
    public var id: String {
        "\(file):\(line):\(message)"
    }

    public init(_ kind: Kind, file: String, line: Int, message: String) {
        self.kind = kind; self.file = file; self.line = line; self.message = message
    }
}

/// Pedaço de uma string com interpolação.
public enum Segment: Sendable, Hashable { case text(String), expr(Expr) }

public struct Arg: Sendable, Hashable {
    public var label: String?
    public var value: Expr
    public init(_ label: String?, _ value: Expr) {
        self.label = label; self.value = value
    }
}

public struct Closure: Sendable, Hashable {
    public var params: [String]
    public var body: [Stmt]
    public var line: Int
    public init(params: [String], body: [Stmt], line: Int) {
        self.params = params; self.body = body; self.line = line
    }
}

public indirect enum Expr: Sendable, Hashable {
    case int(Int), double(Double), bool(Bool), string([Segment])
    case ident(String, line: Int)
    /// `.title` (base nil) ou `x.y`.
    case member(Expr?, String, line: Int)
    /// chamada: base, argumentos e trailing closures (o primeiro sem rótulo).
    case call(Expr, [Arg], [(String?, Closure)], line: Int)
    case subscriptExpr(Expr, Expr)
    case binary(String, Expr, Expr)
    case unary(String, Expr)
    case ternary(Expr, Expr, Expr)
    case closure(Closure)
    case array([Expr])
    case range(Expr, Expr, closed: Bool)
    /// `if` dentro de um builder de views (também usado como expressão de valor).
    case ifExpr(Expr, [Stmt], [Stmt]?, line: Int)

    public static func == (a: Expr, b: Expr) -> Bool {
        "\(a)" == "\(b)"
    }

    public func hash(into h: inout Hasher) {
        h.combine("\(self)")
    }

    public var line: Int {
        switch self {
        case let .ident(_, l), let .member(_, _, l), let .call(_, _, _, l), let .ifExpr(_, _, _, l): l
        case let .binary(_, a, _), let .unary(_, a), let .ternary(a, _, _), let .subscriptExpr(a, _), let .range(
            a,
            _,
            _
        ): a.line
        case let .closure(c): c.line
        default: 0
        }
    }
}

public enum VarAttr: String, Sendable { case none, state, binding, environment, observed }

public struct VarDecl: Sendable, Hashable {
    public var name: String
    public var attr: VarAttr
    public var isLet: Bool
    public var typeName: String?
    public var initial: Expr?
    public var line: Int
}

public struct FuncDecl: Sendable, Hashable {
    public var name: String
    public var params: [(label: String?, name: String)]
    public var body: [Stmt]
    public var line: Int
    public static func == (a: FuncDecl, b: FuncDecl) -> Bool {
        a.name == b.name && a.line == b.line
    }

    public func hash(into h: inout Hasher) {
        h.combine(name); h.combine(line)
    }
}

public indirect enum Stmt: Sendable, Hashable {
    case expr(Expr, line: Int)
    case varDecl(VarDecl)
    case assign(Expr, String, Expr, line: Int)
    case funcDecl(FuncDecl)
    case ifStmt(Expr, [Stmt], [Stmt]?, line: Int)
    case forIn(String, Expr, [Stmt], line: Int)
    case returnStmt(Expr?, line: Int)

    public var line: Int {
        switch self {
        case let .expr(_, l), let .assign(_, _, _, l), let .ifStmt(_, _, _, l), let .forIn(_, _, _, l), let .returnStmt(
            _,
            l
        ): l
        case let .varDecl(v): v.line
        case let .funcDecl(f): f.line
        }
    }
}

public struct StructDecl: Sendable, Hashable {
    public var name: String
    public var conforms: [String]
    public var vars: [VarDecl]
    public var funcs: [FuncDecl]
    /// Corpo de `var body: some View { … }` (ou `some Scene`).
    public var body: [Stmt]?
    public var isMain: Bool
    public var file: String
    public var line: Int
    public var isView: Bool {
        conforms.contains("View")
    }

    public var isApp: Bool {
        conforms.contains("App")
    }
}

public struct SwiftFile: Sendable {
    public var path: String
    public var structs: [StructDecl]
    public var diagnostics: [SwiftDiagnostic]
}
