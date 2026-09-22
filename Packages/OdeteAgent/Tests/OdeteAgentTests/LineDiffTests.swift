import Foundation
@testable import OdeteAgent
import Testing

/// A implementação de antes, copiada como estava: a tabela inteira de `Int`, antes × depois.
///
/// Fica aqui como régua. O diff novo tem que sair idêntico a ela, operação por operação,
/// em tudo que ela conseguia calcular — os hunks que a pessoa via não podem mudar de forma
/// só porque a conta ficou mais barata.
enum LineDiffAntigo {
    static func ops(_ a: [String], _ b: [String]) -> [LineDiff.Op] {
        let n = a.count, m = b.count
        if n * m > 4_000_000 { // arquivos enormes: sem LCS
            return a.map { .del($0) } + b.map { .ins($0) }
        }
        var dp = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        var out: [LineDiff.Op] = []
        var i = 0, j = 0
        while i < n, j < m {
            if a[i] == b[j] {
                out.append(.keep(a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(.del(a[i])); i += 1
            } else {
                out.append(.ins(b[j])); j += 1
            }
        }
        while i < n {
            out.append(.del(a[i])); i += 1
        }
        while j < m {
            out.append(.ins(b[j])); j += 1
        }
        return out
    }
}

/// Gerador com semente: um teste que falha tem que falhar igual na próxima vez.
struct Sorteio {
    var estado: UInt64
    mutating func proximo() -> UInt64 {
        estado = estado &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return estado >> 33
    }

    mutating func ate(_ n: Int) -> Int {
        Int(proximo() % UInt64(max(1, n)))
    }

    /// Linhas de um alfabeto pequeno: com poucas linhas diferentes aparecem os empates, que
    /// é onde dois algoritmos de diff costumam discordar.
    mutating func linhas(_ n: Int, alfabeto: Int) -> [String] {
        (0 ..< n).map { _ in "l\(ate(alfabeto))" }
    }

    /// Uma versão editada de `base`: troca, apaga e insere aqui e ali.
    mutating func editar(_ base: [String], alfabeto: Int) -> [String] {
        var out: [String] = []
        for l in base {
            switch ate(10) {
            case 0: continue
            case 1: out.append("l\(ate(alfabeto))")
            case 2: out.append(l); out.append("l\(ate(alfabeto))")
            default: out.append(l)
            }
        }
        return out
    }
}

/// O que o roteiro diz que era e o que diz que ficou: tem que dar `a` e `b`.
func aplicar(_ ops: [LineDiff.Op]) -> (antes: [String], depois: [String]) {
    var antes: [String] = [], depois: [String] = []
    for op in ops {
        switch op {
        case let .keep(s): antes.append(s); depois.append(s)
        case let .del(s): antes.append(s)
        case let .ins(s): depois.append(s)
        }
    }
    return (antes, depois)
}

struct LineDiffTests {
    @Test func igualAoAntigoEmEntradasSorteadas() {
        var s = Sorteio(estado: 42)
        for rodada in 0 ..< 600 {
            let alfabeto = [2, 3, 5, 12, 40][rodada % 5]
            let a = s.linhas(s.ate(45), alfabeto: alfabeto)
            let b = rodada % 3 == 0 ? s.linhas(s.ate(45), alfabeto: alfabeto) : s.editar(a, alfabeto: alfabeto)
            let novo = LineDiff.ops(a, b), antigo = LineDiffAntigo.ops(a, b)
            #expect(novo == antigo, "rodada \(rodada): \(a) → \(b)")
            if novo != antigo {
                return
            }
        }
    }

    /// Arquivos de verdade, maiores, com o começo em comum que o caminho novo pula.
    @Test func igualAoAntigoEmArquivosMaiores() {
        var s = Sorteio(estado: 7)
        for _ in 0 ..< 12 {
            let a = s.linhas(200 + s.ate(400), alfabeto: 150)
            let b = s.editar(a, alfabeto: 150)
            #expect(LineDiff.ops(a, b) == LineDiffAntigo.ops(a, b))
            let antes = a.joined(separator: "\n"), depois = b.joined(separator: "\n")
            #expect(aplicar(LineDiff.ops(a, b)).depois == b)
            #expect(!LineDiff.hunks(antes, depois).isEmpty || a == b)
        }
    }

    /// Onde a tabela exata não cabe entra o Myers. Ele pode alinhar diferente nos empates,
    /// mas não pode tirar nem pôr uma linha a mais que o LCS.
    @Test func myersEhMinimoEReconstroi() {
        var s = Sorteio(estado: 99)
        for rodada in 0 ..< 400 {
            let alfabeto = [2, 4, 9, 30][rodada % 4]
            let a = s.linhas(s.ate(70), alfabeto: alfabeto)
            let b = rodada % 4 == 0 ? s.linhas(s.ate(70), alfabeto: alfabeto) : s.editar(a, alfabeto: alfabeto)
            var ids: [String: Int] = [:]
            func id(_ l: String) -> Int {
                if let n = ids[l] {
                    return n
                }
                ids[l] = ids.count
                return ids.count - 1
            }
            let ia = a.map(id), ib = b.map(id)
            var myers = Myers(a: ia, b: ib, orcamento: .max)
            let passos = myers.caminho(0 ..< ia.count, 0 ..< ib.count)
            var antes: [String] = [], depois: [String] = []
            var mantidas = 0
            for p in passos {
                switch p {
                case let .keep(i, j):
                    #expect(a[i] == b[j]); antes.append(a[i]); depois.append(b[j]); mantidas += 1
                case let .del(i): antes.append(a[i])
                case let .ins(j): depois.append(b[j])
                }
            }
            #expect(antes == a && depois == b, "rodada \(rodada) não reconstrói")
            let lcs = LineDiffAntigo.ops(a, b).count {
                if case .keep = $0 {
                    return true
                }
                return false
            }
            #expect(mantidas == lcs, "rodada \(rodada): Myers manteve \(mantidas), o LCS é \(lcs)")
        }
    }

    /// Arquivo grande com duas linhas mudadas no miolo.
    ///
    /// A tabela antiga não cabia (vinte mil por vinte mil são 400 milhões de células) e
    /// mostrava o arquivo inteiro apagado e reescrito. Uma matriz dessas nem caberia na
    /// memória do iPad; o caminho novo usa memória proporcional ao tamanho do arquivo.
    @Test func arquivoGrandeComPoucaMudancaViraDoisHunks() {
        let base = (0 ..< 30000).map { "linha \($0)" }
        var editado = base
        editado[10000] = "mudou 1"
        editado[20000] = "mudou 2"
        let inicio = ContinuousClock.now
        let hunks = LineDiff.hunks(base.joined(separator: "\n"), editado.joined(separator: "\n"))
        #expect(ContinuousClock.now - inicio < .seconds(5))
        #expect(hunks.count == 2)
        #expect(hunks.first?.beforeStart == 9998)
        let linhas = hunks.flatMap(\.lines)
        let removidas = linhas.count { $0 == .removed("linha 10000") || $0 == .removed("linha 20000") }
        let postas = linhas.count { $0 == .added("mudou 1") || $0 == .added("mudou 2") }
        #expect(removidas == 2 && postas == 2 && linhas.count == 2 * (3 + 1 + 1 + 3))
        #expect(LineDiffAntigo.ops(base, editado).count == 60000, "a régua antiga desistia aqui")
    }

    /// Reescrever um arquivo grande de cima a baixo: nada em comum, troca inteira, e rápido.
    @Test func arquivoGrandeSemNadaEmComumNaoTrava() {
        let a = (0 ..< 5000).map { "a\($0)" }, b = (0 ..< 5000).map { "b\($0)" }
        let inicio = ContinuousClock.now
        let ops = LineDiff.ops(a, b)
        #expect(ContinuousClock.now - inicio < .seconds(5))
        #expect(aplicar(ops).antes == a && aplicar(ops).depois == b)
    }
}

/// O diff mora no patch: calculado quando o texto muda, lido de graça depois.
struct PatchDiffTests {
    @Test func oDiffAcompanhaOTexto() throws {
        var p = Patch(
            id: "1",
            path: "a.txt",
            before: "a\nb\nc",
            after: "a\nB\nc",
            orig: "a\nb\nc",
            status: .pending,
            at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        #expect(p.hunks.count == 1 && p.additions == 1 && p.deletions == 1)
        p.after = "a\nB\nC\nD"
        #expect(p.additions == 3 && p.deletions == 2)
        p.trocar(before: "x", after: "x")
        #expect(p.hunks.isEmpty && p.additions == 0 && p.deletions == 0)

        // Guardado e lido de volta, o diff renasce do texto.
        let enc = JSONEncoder(), dec = JSONDecoder()
        enc.dateEncodingStrategy = .iso8601
        dec.dateDecodingStrategy = .iso8601
        p.after = "y"
        let volta = try dec.decode(Patch.self, from: enc.encode(p))
        #expect(volta.before == "x" && volta.after == "y" && volta.additions == 1 && volta.deletions == 1)
        #expect(volta == p)
        let json = try #require(String(data: enc.encode(p), encoding: .utf8))
        #expect(!json.contains("hunks") && !json.contains("antes"), "o formato do patches.json mudou")
    }
}
