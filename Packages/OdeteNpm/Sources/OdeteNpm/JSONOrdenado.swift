import Foundation

/// JSON que lembra a ordem das chaves — o que o `JSONSerialization` não faz.
///
/// O npm lê o package.json, mexe nas dependências e grava de volta com a mesma ordem de
/// campos, a mesma indentação e a mesma quebra de linha do arquivo. O install daqui
/// gravava pelo `JSONSerialization`: chaves em ordem alfabética, `" : "` no lugar de
/// `": "`, `\/` nas URLs e dois espaços sempre — um package.json de quatro espaços virava
/// um diff inteiro no git a cada `npm install x`. Com a ordem guardada, a gravação sai
/// como a do npm (que é a do `JSON.stringify`), e o diff fica só no que mudou.
public indirect enum JSONOrdenado: Sendable, Hashable {
    case objeto([(String, JSONOrdenado)])
    case lista([JSONOrdenado])
    case texto(String)
    /// O número como estava escrito; a gravação normaliza como o `JSON.stringify`.
    case numero(String)
    case booleano(Bool)
    case nulo

    public func hash(into h: inout Hasher) {
        switch self {
        case let .objeto(pares):
            h.combine(0)
            for (k, v) in pares {
                h.combine(k); h.combine(v)
            }
        case let .lista(l): h.combine(1); h.combine(l)
        case let .texto(s): h.combine(2); h.combine(s)
        case let .numero(n): h.combine(3); h.combine(Double(n) ?? 0)
        case let .booleano(b): h.combine(4); h.combine(b)
        case .nulo: h.combine(5)
        }
    }

    public static func == (a: JSONOrdenado, b: JSONOrdenado) -> Bool {
        switch (a, b) {
        case let (.objeto(x), .objeto(y)):
            x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.lista(x), .lista(y)): x == y
        case let (.texto(x), .texto(y)): x == y
        case let (.numero(x), .numero(y)): Double(x) == Double(y)
        case let (.booleano(x), .booleano(y)): x == y
        case (.nulo, .nulo): true
        default: false
        }
    }

    // MARK: - Acesso

    public subscript(chave: String) -> JSONOrdenado? {
        get {
            guard case let .objeto(pares) = self else { return nil }
            return pares.first { $0.0 == chave }?.1
        }
        set {
            guard case var .objeto(pares) = self else { return }
            if let i = pares.firstIndex(where: { $0.0 == chave }) {
                if let newValue {
                    pares[i].1 = newValue
                } else {
                    pares.remove(at: i)
                }
            } else if let newValue {
                pares.append((chave, newValue))
            }
            self = .objeto(pares)
        }
    }

    public var comoTexto: String? {
        if case let .texto(s) = self {
            return s
        }
        return nil
    }

    public var comoBool: Bool? {
        if case let .booleano(b) = self {
            return b
        }
        return nil
    }

    public var comoLista: [JSONOrdenado]? {
        if case let .lista(l) = self {
            return l
        }
        return nil
    }

    public var chaves: [String] {
        if case let .objeto(pares) = self {
            return pares.map(\.0)
        }
        return []
    }

    public var pares: [(String, JSONOrdenado)] {
        if case let .objeto(p) = self {
            return p
        }
        return []
    }

    /// Um objeto de texto em texto (`dependencies`, `bin`, `engines`…). O que não for
    /// texto fica de fora, como o `as? [String: String]` de antes fazia com o objeto todo.
    public var comoMapaDeTexto: [String: String] {
        var out: [String: String] = [:]
        for (k, v) in pares {
            if let s = v.comoTexto {
                out[k] = s
            }
        }
        return out
    }

    public var comoListaDeTexto: [String] {
        (comoLista ?? []).compactMap(\.comoTexto)
    }

    public static func mapa(_ m: [String: String], ordenado: Bool = true) -> JSONOrdenado {
        let chaves = ordenado ? m.keys.sorted(by: menorComoONpm) : Array(m.keys)
        return .objeto(chaves.map { ($0, .texto(m[$0] ?? "")) })
    }

    public static func listaDeTexto(_ l: [String]) -> JSONOrdenado {
        .lista(l.map { .texto($0) })
    }

    /// A comparação do `localeCompare(b, "en")` que o npm usa para ordenar dependências e
    /// o lock: pontuação antes de letra (`@types/x` antes de `ansi`), `-` antes de `/`
    /// (`strip-ansi-cjs` antes de `strip-ansi/node_modules/…`).
    public static func menorComoONpm(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [], range: nil, locale: Locale(identifier: "en")) == .orderedAscending
    }
}

public extension JSONOrdenado {
    // MARK: - Leitura

    enum Erro: Error { case invalido(Int) }

    static func ler(_ dados: Data) throws -> JSONOrdenado {
        var leitor = Leitor(bytes: Array(dados))
        leitor.pularEspacos()
        let v = try leitor.valor()
        leitor.pularEspacos()
        guard leitor.i == leitor.bytes.count else { throw Erro.invalido(leitor.i) }
        return v
    }

    private struct Leitor {
        let bytes: [UInt8]
        var i = 0

        init(bytes: [UInt8]) {
            // BOM do UTF-8: o npm também ignora.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
                self.bytes = Array(bytes.dropFirst(3))
            } else {
                self.bytes = bytes
            }
        }

        mutating func pularEspacos() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) {
                i += 1
            }
        }

        mutating func valor() throws -> JSONOrdenado {
            guard i < bytes.count else { throw Erro.invalido(i) }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var pares: [(String, JSONOrdenado)] = []
                pularEspacos()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
                    i += 1
                    return .objeto([])
                }
                while true {
                    pularEspacos()
                    let k = try texto()
                    pularEspacos()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw Erro.invalido(i) }
                    i += 1
                    pularEspacos()
                    let v = try valor()
                    // Chave repetida: vale a última, como no `JSON.parse`.
                    if let j = pares.firstIndex(where: { $0.0 == k }) {
                        pares[j].1 = v
                    } else {
                        pares.append((k, v))
                    }
                    pularEspacos()
                    guard i < bytes.count else { throw Erro.invalido(i) }
                    if bytes[i] == UInt8(ascii: ",") {
                        i += 1; continue
                    }
                    guard bytes[i] == UInt8(ascii: "}") else { throw Erro.invalido(i) }
                    i += 1
                    return .objeto(pares)
                }
            case UInt8(ascii: "["):
                i += 1
                var itens: [JSONOrdenado] = []
                pularEspacos()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
                    i += 1
                    return .lista([])
                }
                while true {
                    pularEspacos()
                    try itens.append(valor())
                    pularEspacos()
                    guard i < bytes.count else { throw Erro.invalido(i) }
                    if bytes[i] == UInt8(ascii: ",") {
                        i += 1; continue
                    }
                    guard bytes[i] == UInt8(ascii: "]") else { throw Erro.invalido(i) }
                    i += 1
                    return .lista(itens)
                }
            case UInt8(ascii: "\""):
                return try .texto(texto())
            case UInt8(ascii: "t"):
                try palavra("true"); return .booleano(true)
            case UInt8(ascii: "f"):
                try palavra("false"); return .booleano(false)
            case UInt8(ascii: "n"):
                try palavra("null"); return .nulo
            default:
                let inicio = i
                while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) {
                    i += 1
                }
                let s = String(decoding: bytes[inicio ..< i], as: UTF8.self)
                guard !s.isEmpty, Double(s) != nil else { throw Erro.invalido(inicio) }
                return .numero(s)
            }
        }

        mutating func palavra(_ p: String) throws {
            let b = Array(p.utf8)
            guard i + b.count <= bytes.count, Array(bytes[i ..< i + b.count]) == b else { throw Erro.invalido(i) }
            i += b.count
        }

        mutating func texto() throws -> String {
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw Erro.invalido(i) }
            i += 1
            var out: [UInt8] = []
            while i < bytes.count {
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    i += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if c == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { throw Erro.invalido(i) }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var u = try hex4()
                        // Par substituto: os dois `\u` viram um caractere só.
                        if (0xD800 ..< 0xDC00).contains(u), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"),
                           bytes[i + 1] == UInt8(ascii: "u")
                        {
                            i += 2
                            let baixo = try hex4()
                            u = 0x10000 + ((u - 0xD800) << 10) + (baixo - 0xDC00)
                        }
                        out.append(contentsOf: Array(String(Character(Unicode.Scalar(u) ?? "\u{FFFD}")).utf8))
                    default: out.append(e)
                    }
                    continue
                }
                out.append(c)
                i += 1
            }
            throw Erro.invalido(i)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i ..< i + 4], as: UTF8.self), radix: 16)
            else { throw Erro.invalido(i) }
            i += 4
            return v
        }
    }

    // MARK: - Gravação

    /// Como gravar: a indentação e a quebra de linha que o arquivo já usava.
    struct Estilo: Sendable, Equatable {
        public var indentacao: String
        public var quebra: String

        public init(indentacao: String = "  ", quebra: String = "\n") {
            self.indentacao = indentacao
            self.quebra = quebra
        }

        /// O estilo de um arquivo que já existe, pela regra do `json-parse-even-better-errors`
        /// que o npm usa: a quebra é a que vem logo depois do `{` de abertura, e a
        /// indentação é o que vem depois dela. Arquivo numa linha só não tem nenhuma das
        /// duas — e o npm grava de volta numa linha só, sem quebra no fim.
        public static func de(_ dados: Data?) -> Estilo {
            guard let dados, let texto = String(data: dados, encoding: .utf8) else { return Estilo() }
            let t = texto.hasPrefix("\u{FEFF}") ? String(texto.dropFirst()) : texto
            let u = Array(t.unicodeScalars)
            // `{}` ou `[]` sozinhos, com ou sem quebra depois: o padrão, com a quebra dele.
            if u.count >= 2, (u[0] == "{" && u[1] == "}") || (u[0] == "[" && u[1] == "]") {
                let resto = String(String.UnicodeScalarView(u.dropFirst(2)))
                if resto.isEmpty || resto.allSatisfy({ $0 == "\n" || $0 == "\r" }) {
                    return Estilo(quebra: resto.isEmpty ? "\n" : resto)
                }
            }
            var i = 0
            while i < u.count, u[i].properties.isWhitespace {
                i += 1
            }
            guard i < u.count, u[i] == "{" || u[i] == "[" else { return Estilo(indentacao: "", quebra: "") }
            i += 1
            var quebra = ""
            while i < u.count {
                if u[i] == "\n" {
                    quebra += "\n"; i += 1
                } else if u[i] == "\r", i + 1 < u.count, u[i + 1] == "\n" {
                    quebra += "\r\n"; i += 2
                } else {
                    break
                }
            }
            guard !quebra.isEmpty else { return Estilo(indentacao: "", quebra: "") }
            var recuo = ""
            while i < u.count, u[i] == " " || u[i] == "\t" {
                recuo.unicodeScalars.append(u[i]); i += 1
            }
            return Estilo(indentacao: recuo, quebra: quebra)
        }

        /// O que o npm usa no lock quando a referência não tem formato (arquivo numa
        /// linha só): dois espaços e `\n`.
        public var paraOLock: Estilo {
            Estilo(indentacao: indentacao.isEmpty ? "  " : indentacao, quebra: quebra.isEmpty ? "\n" : quebra)
        }
    }

    /// Texto como o `JSON.stringify(valor, null, indentacao)` escreveria, mais uma quebra
    /// no fim, com toda quebra trocada pela do estilo — é assim que o npm grava.
    func gravado(_ estilo: Estilo = Estilo()) -> String {
        var out = ""
        escrever(&out, estilo, nivel: 0)
        out += "\n"
        return estilo.quebra == "\n" ? out : out.replacingOccurrences(of: "\n", with: estilo.quebra)
    }

    private func escrever(_ out: inout String, _ e: Estilo, nivel: Int) {
        // Sem indentação o `JSON.stringify` escreve tudo junto, sem espaço depois do `:`.
        let junto = e.indentacao.isEmpty
        switch self {
        case let .objeto(pares):
            guard !pares.isEmpty else { out += "{}"; return }
            out += junto ? "{" : "{\n"
            for (n, (k, v)) in pares.enumerated() {
                out += String(repeating: e.indentacao, count: nivel + 1)
                Self.escreverTexto(k, &out)
                out += junto ? ":" : ": "
                v.escrever(&out, e, nivel: nivel + 1)
                if n < pares.count - 1 {
                    out += ","
                }
                out += junto ? "" : "\n"
            }
            out += String(repeating: e.indentacao, count: nivel) + "}"
        case let .lista(itens):
            guard !itens.isEmpty else { out += "[]"; return }
            out += junto ? "[" : "[\n"
            for (n, v) in itens.enumerated() {
                out += String(repeating: e.indentacao, count: nivel + 1)
                v.escrever(&out, e, nivel: nivel + 1)
                if n < itens.count - 1 {
                    out += ","
                }
                out += junto ? "" : "\n"
            }
            out += String(repeating: e.indentacao, count: nivel) + "]"
        case let .texto(s):
            Self.escreverTexto(s, &out)
        case let .numero(n):
            out += Self.numeroComoNoJS(n)
        case let .booleano(b):
            out += b ? "true" : "false"
        case .nulo:
            out += "null"
        }
    }

    /// O escape do `JSON.stringify`: aspas, barra invertida e controle. Barra normal e
    /// acento ficam como estão.
    static func escreverTexto(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }

    /// `1.50` vira `1.5` e `1e2` vira `100`, como no JS, que lê o número e escreve de novo.
    static func numeroComoNoJS(_ raw: String) -> String {
        guard let d = Double(raw), d.isFinite else { return raw }
        if d == d.rounded(), abs(d) < 1e21 {
            return String(format: "%.0f", d)
        }
        return "\(d)"
    }

    /// O `funding` como o npm grava no lock: texto vira `{ "url": texto }`, numa lista
    /// também.
    var fundingComoONpm: JSONOrdenado {
        switch self {
        case let .texto(u): .objeto([("url", .texto(u))])
        case let .lista(l): .lista(l.map(\.fundingComoONpm))
        default: self
        }
    }

    // MARK: - Ordem do lock

    /// A ordem do `json-stringify-nice` que o npm usa no package-lock.json: em cada objeto,
    /// primeiro os valores simples (texto, número, lista), depois os objetos; em cada grupo,
    /// as chaves preferidas na ordem delas e o resto em ordem alfabética.
    func ordenadoComoOLock() -> JSONOrdenado {
        switch self {
        case let .objeto(pares):
            let preferidas = ["name", "version", "lockfileVersion", "resolved", "integrity", "requires", "packages",
                              "dependencies"]
            func ehObjeto(_ v: JSONOrdenado) -> Bool {
                if case .objeto = v {
                    return true
                }
                return false
            }
            let ordenados = pares.map { ($0.0, $0.1.ordenadoComoOLock()) }.sorted { a, b in
                if ehObjeto(a.1) != ehObjeto(b.1) {
                    return !ehObjeto(a.1)
                }
                let ia = preferidas.firstIndex(of: a.0), ib = preferidas.firstIndex(of: b.0)
                switch (ia, ib) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return Self.menorComoONpm(a.0, b.0)
                }
            }
            return .objeto(ordenados)
        case let .lista(itens):
            return .lista(itens.map { $0.ordenadoComoOLock() })
        default:
            return self
        }
    }
}
