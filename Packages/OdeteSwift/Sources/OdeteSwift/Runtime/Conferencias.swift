import Foundation
import OdeteI18n

/// As conferências que o Swift de verdade faz e que, sem elas, derrubavam o app inteiro:
/// conta de inteiro que passa do limite, intervalo ao contrário, intervalo que vira uma
/// lista de bilhões de itens no ator principal. No Swift de verdade são paradas do
/// programa; no playground viram um erro na linha, e o resto da tela continua.
@MainActor
extension ViewInstance {
    /// Um argumento de chamada. O `in:` de `Slider` e `Stepper` só precisa das pontas:
    /// um intervalo ali vira `[começo, fim]` em vez da lista inteira, e
    /// `Slider(value: $x, in: 0...1_000_000)` continua valendo apesar do teto de
    /// `maiorIntervalo`.
    func argumento(_ a: Arg, _ env: [String: Value], de chamada: String) throws -> Value {
        guard chamada == "Slider" || chamada == "Stepper", a.label == "in",
              case let .range(x, y, fechado) = a.value else { return try eval(a.value, env) }
        let lo = try eval(x, env).asInt ?? 0, hi = try eval(y, env).asInt ?? 0
        // `lo < hi` garante que `hi - 1` não estoura.
        guard fechado ? lo <= hi : lo < hi else {
            let texto = "\(lo)\(fechado ? "..." : "..<")\(hi)"
            throw RuntimeError(line: x.line, message: tr("intervalo inválido: %1$@ (o começo passa do fim)", texto))
        }
        return .array([.int(lo), .int(fechado ? hi : hi - 1)])
    }

    /// Resultado de uma conta de inteiro, ou erro se ela passou do limite do `Int`.
    static func conferido(_ r: (partialValue: Int, overflow: Bool), _ line: Int) throws -> Int {
        guard !r.overflow else {
            throw RuntimeError(line: line, message: tr("a conta passa do limite do Int"))
        }
        return r.partialValue
    }

    /// O maior intervalo que vira lista. Cada item é um valor no ator principal: um
    /// `0..<1_000_000_000` montava um array de um bilhão de itens antes de desenhar a tela.
    static let maiorIntervalo = 100_000

    /// `a...b` e `a..<b` como lista de inteiros, com as conferências que o Swift faz.
    ///
    /// `3...1` montava `3 ..< 2`, e o próprio Swift parava o app. `x...Int.max` somava
    /// um ao fim e estourava.
    func intervalo(_ a: Value, _ b: Value, fechado: Bool, linha: Int) throws -> Value {
        let lo = a.asInt ?? 0, hi = b.asInt ?? 0
        let texto = "\(lo)\(fechado ? "..." : "..<")\(hi)"
        guard lo <= hi else {
            throw RuntimeError(line: linha, message: tr("intervalo inválido: %1$@ (o começo passa do fim)", texto))
        }
        let (dif, estourou) = hi.subtractingReportingOverflow(lo)
        let n = estourou ? Int.max : (fechado ? (dif == .max ? .max : dif + 1) : dif)
        guard n <= Self.maiorIntervalo else {
            throw RuntimeError(
                line: linha,
                message: tr("intervalo grande demais: %1$@ (o máximo são %2$@ itens)", texto, "\(Self.maiorIntervalo)")
            )
        }
        return .array((0 ..< n).map { .int(lo + $0) })
    }
}
