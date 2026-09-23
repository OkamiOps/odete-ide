import Foundation

/// Versão semântica com pré-release. Ordena como o semver.org.
public struct Version: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int
    public var prerelease: [String]

    public init(_ major: Int, _ minor: Int, _ patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    public init?(_ s: String) {
        var str = s.trimmingCharacters(in: .whitespaces)
        if str.hasPrefix("v") || str.hasPrefix("=") {
            str.removeFirst()
        }
        let core = str.split(separator: "+", maxSplits: 1)[0]
        let parts = core.split(separator: "-", maxSplits: 1)
        let nums = parts[0].split(separator: ".").map(String.init)
        guard nums.count == 3, let a = Int(nums[0]), let b = Int(nums[1]), let c = Int(nums[2]) else { return nil }
        self.init(a, b, c, prerelease: parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : [])
    }

    public var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    public static func < (a: Version, b: Version) -> Bool {
        if a.major != b.major {
            return a.major < b.major
        }
        if a.minor != b.minor {
            return a.minor < b.minor
        }
        if a.patch != b.patch {
            return a.patch < b.patch
        }
        if a.prerelease.isEmpty != b.prerelease.isEmpty {
            return !a.prerelease.isEmpty
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (i?, j?): return i < j
            case (nil, _?): return false
            case (_?, nil): return true
            default: return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

/// Faixa semver do npm: `^1.2`, `~0.3.1`, `>=1 <2`, `1.x`, `*`, `1.2.3 - 2.0.0`, `a || b`, `latest`.
public struct SemverRange: Sendable, Hashable {
    struct Comparator: Hashable { var op: String; var v: Version }
    var sets: [[Comparator]]
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw.trimmingCharacters(in: .whitespaces)
        if self.raw.isEmpty || self.raw == "*" || self.raw == "latest" || self.raw == "x" {
            sets = [[]]; return
        }
        sets = self.raw.components(separatedBy: "||").map { Self.parseSet($0.trimmingCharacters(in: .whitespaces)) }
    }

    public var isAny: Bool {
        sets == [[]]
    }

    static func parseSet(_ s: String) -> [Comparator] {
        // hyphen range
        if let r = s.range(of: " - ") {
            let lo = String(s[..<r.lowerBound]), hi = String(s[r.upperBound...])
            var out: [Comparator] = []
            if let (v, _) = parsePartial(lo) {
                out.append(Comparator(op: ">=", v: v))
            }
            // O fim parcial conta inteiro: `1.2 - 2.3` vai até antes de 2.4.0, e `1 - 2`
            // até antes de 3.0.0. `wild` é quantos campos faltam: 1 é o patch, 2 é o minor.
            // Os dois casos estavam trocados, e `1.2 - 2.3` aceitava 2.9.
            if let (v, wild) = parsePartial(hi), wild < 3 {
                if wild == 0 {
                    out.append(Comparator(op: "<=", v: v))
                } else if wild == 1 {
                    out.append(Comparator(op: "<", v: Version(v.major, v.minor + 1, 0, prerelease: ["0"])))
                } else {
                    out.append(Comparator(op: "<", v: Version(v.major + 1, 0, 0, prerelease: ["0"])))
                }
            }
            return out
        }
        var out: [Comparator] = []
        for tok in juntarOperadores(s).split(separator: " ").map(String.init) where !tok.isEmpty {
            out += parseComparator(tok)
        }
        return out
    }

    /// `>= 1.2.3` e `^ 1.2` têm espaço entre o operador e a versão, e o npm aceita. Sem
    /// juntar, o `>=` sozinho virava "qualquer uma" e o `1.2.3` virava versão exata.
    static func juntarOperadores(_ s: String) -> String {
        var out = ""
        var pendente = false
        for parte in s.split(separator: " ", omittingEmptySubsequences: true) {
            let p = String(parte)
            if pendente {
                out += p
            } else {
                out += (out.isEmpty ? "" : " ") + p
            }
            pendente = [">=", "<=", ">", "<", "=", "^", "~", "~>"].contains(p)
        }
        return out
    }

    /// Versão parcial "1", "1.2", "1.x"; devolve versão completada e quantos campos são wildcard.
    static func parsePartial(_ s: String) -> (Version, Int)? {
        var t = s
        if t.hasPrefix("v") || t.hasPrefix("=") {
            t.removeFirst()
        }
        if t.isEmpty || t == "*" || t == "x" || t == "X" {
            return (Version(0, 0, 0), 3)
        }
        let core = t.split(separator: "-", maxSplits: 1)
        let nums = core[0].split(separator: ".").map(String.init)
        var vals: [Int] = []
        var wild = 0
        for i in 0 ..< 3 {
            if i < nums.count, let n = Int(nums[i]) {
                vals.append(n)
            } else {
                vals.append(0); wild += 1
            }
        }
        let pre = core.count > 1 ? core[1].split(separator: ".").map(String.init) : []
        return (Version(vals[0], vals[1], vals[2], prerelease: pre), wild)
    }

    static func parseComparator(_ tok: String) -> [Comparator] {
        var t = tok
        var op = ""
        for candidate in ["~>", ">=", "<=", ">", "<", "=", "^", "~"]
            where t.hasPrefix(candidate)
        {
            op = candidate == "~>" ? "~" : candidate; t = String(t.dropFirst(candidate.count)); break
        }
        guard let (v, wild) = parsePartial(t) else { return [] }
        switch op {
        case "^":
            if wild == 3 {
                return []
            }
            let upper = if v.major > 0 || wild >= 2 {
                Version(v.major + 1, 0, 0, prerelease: ["0"])
            } else if v.minor > 0 || wild == 1 {
                Version(0, v.minor + 1, 0, prerelease: ["0"])
            } else {
                Version(0, 0, v.patch + 1, prerelease: ["0"])
            }
            return [Comparator(op: ">=", v: v), Comparator(op: "<", v: upper)]
        case "~":
            if wild == 3 {
                return []
            }
            let upper = wild >= 2 ? Version(v.major + 1, 0, 0, prerelease: ["0"]) : Version(
                v.major,
                v.minor + 1,
                0,
                prerelease: ["0"]
            )
            return [Comparator(op: ">=", v: v), Comparator(op: "<", v: upper)]
        case "", "=":
            if wild == 3 {
                return []
            }
            if wild == 2 {
                return [
                    Comparator(op: ">=", v: v),
                    Comparator(op: "<", v: Version(v.major + 1, 0, 0, prerelease: ["0"])),
                ]
            }
            if wild == 1 {
                return [
                    Comparator(op: ">=", v: v),
                    Comparator(op: "<", v: Version(v.major, v.minor + 1, 0, prerelease: ["0"])),
                ]
            }
            return [Comparator(op: "=", v: v)]
        case ">", ">=", "<", "<=":
            if wild == 3 {
                // `<*` não aceita nada; `>=*` e `>*`… tudo (o npm faz igual para `>=*`).
                return op == "<" ? [Comparator(op: "<", v: Version(0, 0, 0, prerelease: ["0"]))] : []
            }
            guard wild > 0 else { return [Comparator(op: op, v: v)] }
            // Versão parcial com comparador: `>1.2` é `>=1.3.0`, `<=1.2` é `<1.3.0-0`,
            // `<1.2` é `<1.2.0-0`. Tratar o que falta como zero errava a borda.
            let seguinte = wild == 1 ? Version(v.major, v.minor + 1, 0) : Version(v.major + 1, 0, 0)
            switch op {
            case ">": return [Comparator(op: ">=", v: seguinte)]
            case "<=": return [Comparator(op: "<", v: Version(
                    seguinte.major,
                    seguinte.minor,
                    0,
                    prerelease: ["0"]
                ))]
            case "<": return [Comparator(op: "<", v: Version(v.major, v.minor, 0, prerelease: ["0"]))]
            default: return [Comparator(op: ">=", v: v)]
            }
        default: return []
        }
    }

    public func satisfies(_ v: Version) -> Bool {
        for set in sets {
            var ok = true
            for c in set {
                let r: Bool = switch c.op {
                case "=": v == c.v
                case ">": v > c.v
                case ">=": v >= c.v
                case "<": v < c.v
                case "<=": v <= c.v
                default: true
                }
                if !r {
                    ok = false; break
                }
            }
            if ok {
                // pré-release só entra se algum comparador do set citar pré-release do mesmo [major.minor.patch]
                if !v.prerelease.isEmpty,
                   !set
                   .contains(where: {
                       !$0.v.prerelease.isEmpty && $0.v.major == v.major && $0.v.minor == v.minor && $0.v.patch == v
                           .patch
                   })
                {
                    continue
                }
                return true
            }
        }
        return false
    }

    public func maxSatisfying(_ versions: [Version]) -> Version? {
        versions.filter(satisfies).max()
    }
}

extension SemverRange {
    /// Um conjunto de comparadores visto como intervalo: `[de, ate)`, com as bordas.
    private struct Intervalo {
        var de: Version?
        var deInclui = true
        var ate: Version?
        var ateInclui = false
    }

    private static func intervalo(_ set: [Comparator]) -> Intervalo {
        var i = Intervalo()
        func subir(_ v: Version, _ inclui: Bool) {
            if let de = i.de, de > v || (de == v && !inclui) {
                return
            }
            i.de = v; i.deInclui = inclui
        }
        func descer(_ v: Version, _ inclui: Bool) {
            if let ate = i.ate, ate < v || (ate == v && inclui) {
                return
            }
            i.ate = v; i.ateInclui = inclui
        }
        for c in set {
            switch c.op {
            case ">=": subir(c.v, true)
            case ">": subir(c.v, false)
            case "<": descer(c.v, false)
            case "<=": descer(c.v, true)
            case "=": subir(c.v, true); descer(c.v, true)
            default: break
            }
        }
        return i
    }

    /// Toda versão de `^v` também serve para esta faixa?
    ///
    /// É a conta que o npm faz ao gravar `npm install x@<faixa>` no package.json: se o
    /// `^<versão escolhida>` cabe na faixa pedida, grava o `^`; senão grava a faixa como
    /// veio. `npm i dotenv@16` grava `^16.6.1`, e `npm i x@"1.x <1.2.3"` grava a faixa.
    public func contemCircunflexo(_ v: Version) -> Bool {
        guard let a = SemverRange("^\(v.description)").sets.first else { return false }
        let ia = Self.intervalo(a)
        for set in sets {
            let i = Self.intervalo(set)
            let embaixo: Bool = if let de = i.de, let ade = ia.de {
                de < ade || (de == ade && (i.deInclui || !ia.deInclui))
            } else {
                i.de == nil
            }
            let emcima: Bool = if let ate = i.ate, let aate = ia.ate {
                ate > aate || (ate == aate && (i.ateInclui || !ia.ateInclui))
            } else {
                i.ate == nil
            }
            if embaixo, emcima {
                return true
            }
        }
        return false
    }

    /// A menor versão que a faixa aceita, quando dá para dizer (para casar seletor de
    /// `overrides` como `pacote@^1`).
    var menorVersao: Version? {
        guard let set = sets.first else { return nil }
        return Self.intervalo(set).de ?? Version(0, 0, 0)
    }
}
