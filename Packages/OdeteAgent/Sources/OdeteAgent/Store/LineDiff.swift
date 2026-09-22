import Foundation

/// Diff por linhas (LCS) e hunks, para mostrar patches e aceitar por hunk.
public struct Hunk: Sendable, Hashable, Identifiable {
    public enum Line: Sendable, Hashable { case context(String), removed(String), added(String) }
    public var id: Int
    public var beforeStart: Int
    public var afterStart: Int
    public var lines: [Line]
}

public enum LineDiff {
    enum Op: Equatable { case keep(String), del(String), ins(String) }

    /// Até quantas células o caminho exato ainda cabe.
    ///
    /// É o mesmo teto da tabela antiga, e não por acaso: abaixo dele o diff sai idêntico
    /// ao de antes, linha por linha — os hunks que a pessoa já via não mudam de forma.
    /// A diferença é o que se guarda. A tabela antiga eram `Int`s, uma matriz inteira
    /// de antes × depois (até 32 MB por chamada, refeita a cada redesenho do cartão); aqui
    /// sobra um bit por célula — no máximo 512 kB — e duas linhas de `Int`.
    static let tetoExato = 4_000_000

    /// Quanto trabalho o Myers pode fazer antes de desistir e trocar o arquivo inteiro.
    ///
    /// Reescrever um arquivo enorme de cima a baixo é um diff sem nada em comum: não há
    /// hunk que valha a espera. A tabela antiga fazia o mesmo, só que para qualquer
    /// arquivo grande — inclusive o de uma linha mudada.
    static let orcamentoMyers = 10_000_000

    static func ops(_ a: [String], _ b: [String]) -> [Op] {
        // Cada linha vira um número: comparar dois `Int` é uma instrução, comparar duas
        // `String` é andar pelas duas.
        var ids: [String: Int] = [:]
        ids.reserveCapacity(a.count + b.count)
        func id(_ s: String) -> Int {
            if let n = ids[s] {
                return n
            }
            let n = ids.count
            ids[s] = n
            return n
        }
        let ia = a.map(id), ib = b.map(id)
        var out: [Op] = []
        out.reserveCapacity(max(a.count, b.count))
        // O começo em comum sai de graça, e sai igual ao de sempre: quem compara linha a
        // linha do topo sempre mantém a linha quando ela é igual.
        var p = 0
        while p < ia.count, p < ib.count, ia[p] == ib[p] {
            out.append(.keep(a[p]))
            p += 1
        }
        let (celulas, estourou) = (ia.count - p).multipliedReportingOverflow(by: ib.count - p)
        if !estourou, celulas <= tetoExato {
            out += exato(ia, ib, de: p, a: a, b: b)
        } else {
            var myers = Myers(a: ia, b: ib, orcamento: orcamentoMyers)
            for passo in myers.caminho(p ..< ia.count, p ..< ib.count) {
                switch passo {
                case let .keep(i, _): out.append(.keep(a[i]))
                case let .del(i): out.append(.del(a[i]))
                case let .ins(j): out.append(.ins(b[j]))
                }
            }
        }
        return out
    }

    /// O LCS de sempre, com a mesma escolha nos empates, sem a matriz de inteiros.
    ///
    /// A tabela antiga guardava o tamanho do LCS de cada sufixo, mas o caminho só lia
    /// uma coisa dela: nas linhas diferentes, se apagar ainda deixava o LCS do mesmo
    /// tamanho (`dp[i+1][j] >= dp[i][j+1]`). É um bit. As linhas da tabela são calculadas
    /// de baixo para cima com duas fileiras que se revezam, e só esse bit fica.
    static func exato(_ ia: [Int], _ ib: [Int], de p: Int, a: [String], b: [String]) -> [Op] {
        let n = ia.count - p, m = ib.count - p
        var out: [Op] = []
        out.reserveCapacity(max(n, m))
        guard n > 0, m > 0 else {
            for i in 0 ..< n {
                out.append(.del(a[p + i]))
            }
            for j in 0 ..< m {
                out.append(.ins(b[p + j]))
            }
            return out
        }
        var apaga = [UInt64](repeating: 0, count: (n * m + 63) / 64)
        var abaixo = [Int](repeating: 0, count: m + 1)
        var atual = [Int](repeating: 0, count: m + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            atual[m] = 0
            let ai = ia[p + i]
            let base = i * m
            for j in stride(from: m - 1, through: 0, by: -1) {
                if ai == ib[p + j] {
                    atual[j] = abaixo[j + 1] + 1
                } else if abaixo[j] >= atual[j + 1] {
                    atual[j] = abaixo[j]
                    let bit = base + j
                    apaga[bit >> 6] |= 1 << UInt64(bit & 63)
                } else {
                    atual[j] = atual[j + 1]
                }
            }
            swap(&atual, &abaixo)
        }
        var i = 0, j = 0
        while i < n, j < m {
            if ia[p + i] == ib[p + j] {
                out.append(.keep(a[p + i])); i += 1; j += 1
            } else if apaga[(i * m + j) >> 6] & (1 << UInt64((i * m + j) & 63)) != 0 {
                out.append(.del(a[p + i])); i += 1
            } else {
                out.append(.ins(b[p + j])); j += 1
            }
        }
        while i < n {
            out.append(.del(a[p + i])); i += 1
        }
        while j < m {
            out.append(.ins(b[p + j])); j += 1
        }
        return out
    }

    static func lines(_ s: String) -> [String] {
        s.isEmpty ? [] : s.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
    }

    /// Hunks com `context` linhas de contexto em volta.
    public static func hunks(_ before: String, _ after: String, context: Int = 3) -> [Hunk] {
        let ops = ops(lines(before), lines(after))
        var changed: [Int] = []
        for (i, op) in ops.enumerated() {
            if case .keep = op {} else {
                changed.append(i)
            }
        }
        guard !changed.isEmpty else { return [] }
        // agrupa mudanças cuja distância ≤ 2*context
        var groups: [(Int, Int)] = []
        var start = changed[0], end = changed[0]
        for c in changed.dropFirst() {
            if c - end <= context * 2 {
                end = c
            } else {
                groups.append((start, end)); start = c; end = c
            }
        }
        groups.append((start, end))
        var out: [Hunk] = []
        var bLine = 1, aLine = 1
        var pos = 0
        for (gi, g) in groups.enumerated() {
            let from = max(0, g.0 - context), to = min(ops.count - 1, g.1 + context)
            // avança contadores até `from`
            while pos <
                from
            {
                if case .del = ops[pos] {
                    bLine += 1
                } else if case .ins = ops[pos] {
                    aLine += 1
                } else {
                    bLine += 1; aLine += 1
                }; pos += 1
            }
            var lines: [Hunk.Line] = []
            let hunkBefore = bLine, hunkAfter = aLine
            while pos <= to {
                switch ops[pos] {
                case let .keep(s): lines.append(.context(s)); bLine += 1; aLine += 1
                case let .del(s): lines.append(.removed(s)); bLine += 1
                case let .ins(s): lines.append(.added(s)); aLine += 1
                }
                pos += 1
            }
            out.append(Hunk(id: gi, beforeStart: hunkBefore, afterStart: hunkAfter, lines: lines))
        }
        return out
    }

    /// Texto com só o hunk `index` aplicado sobre `before`.
    public static func applyOnly(hunk index: Int, before: String, after: String, context: Int = 3) -> String {
        let ops = ops(lines(before), lines(after))
        var changed: [Int] = []
        for (i, op) in ops.enumerated() {
            if case .keep = op {} else {
                changed.append(i)
            }
        }
        guard !changed.isEmpty else { return before }
        var groups: [(Int, Int)] = []
        var start = changed[0], end = changed[0]
        for c in changed
            .dropFirst()
        {
            if c - end <= context * 2 {
                end = c
            } else {
                groups.append((start, end)); start = c; end = c
            }
        }
        groups.append((start, end))
        guard index < groups.count else { return before }
        let g = groups[index]
        var out: [String] = []
        for (i, op) in ops.enumerated() {
            let inHunk = i >= g.0 && i <= g.1
            switch op {
            case let .keep(s): out.append(s)
            case let .del(s): if !inHunk {
                    out.append(s)
                }
            case let .ins(s): if inHunk {
                    out.append(s)
                }
            }
        }
        return out.joined(separator: "\n")
    }
}

/// Myers com a cobra do meio: O((N+M)·D) de tempo e O(N+M) de memória.
///
/// Entra só onde a tabela exata não cabe — arquivo grande com o miolo mexido. Ali a
/// tabela antiga desistia e mostrava o arquivo inteiro apagado e reescrito, mesmo com uma
/// linha mudada. O caminho que sai daqui é mínimo (o mesmo número de linhas tiradas e
/// postas que o LCS daria), mas nos empates pode escolher outro alinhamento.
///
/// É o "bisect" do diff-match-patch: as duas buscas, do começo e do fim, andam uma
/// contra a outra até se cruzarem; o ponto de cruzamento divide o problema em dois
/// menores, e cada metade recomeça com o prefixo e o sufixo em comum já tirados.
struct Myers {
    enum Passo: Equatable { case keep(Int, Int), del(Int), ins(Int) }

    let a: [Int]
    let b: [Int]
    /// Passos de cobra que ainda podem ser dados. Acabou, o resto é troca inteira.
    var orcamento: Int
    private var saida: [Passo] = []

    init(a: [Int], b: [Int], orcamento: Int) {
        self.a = a
        self.b = b
        self.orcamento = orcamento
    }

    mutating func caminho(_ ra: Range<Int>, _ rb: Range<Int>) -> [Passo] {
        saida = []
        saida.reserveCapacity(max(ra.count, rb.count))
        resolver(ra, rb)
        return saida
    }

    private mutating func resolver(_ ra: Range<Int>, _ rb: Range<Int>) {
        var aLo = ra.lowerBound, aHi = ra.upperBound, bLo = rb.lowerBound, bHi = rb.upperBound
        while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
            saida.append(.keep(aLo, bLo)); aLo += 1; bLo += 1
        }
        var fim = 0
        while aLo < aHi - fim, bLo < bHi - fim, a[aHi - fim - 1] == b[bHi - fim - 1] {
            fim += 1
        }
        aHi -= fim
        bHi -= fim
        meio(aLo ..< aHi, bLo ..< bHi)
        for k in 0 ..< fim {
            saida.append(.keep(aHi + k, bHi + k))
        }
    }

    private mutating func trocaInteira(_ ra: Range<Int>, _ rb: Range<Int>) {
        for i in ra {
            saida.append(.del(i))
        }
        for j in rb {
            saida.append(.ins(j))
        }
    }

    /// O miolo, já sem começo nem fim em comum.
    private mutating func meio(_ ra: Range<Int>, _ rb: Range<Int>) {
        if ra.isEmpty || rb.isEmpty {
            trocaInteira(ra, rb)
            return
        }
        // Uma linha só de um lado: ou ela aparece do outro lado e fica, ou não há nada em
        // comum. A busca dupla com uma linha só não tem onde se cruzar.
        if ra.count == 1 || rb.count == 1 {
            if ra.count == 1, let j = rb.first(where: { b[$0] == a[ra.lowerBound] }) {
                for k in rb.lowerBound ..< j {
                    saida.append(.ins(k))
                }
                saida.append(.keep(ra.lowerBound, j))
                for k in (j + 1) ..< rb.upperBound {
                    saida.append(.ins(k))
                }
                return
            }
            if rb.count == 1, let i = ra.first(where: { a[$0] == b[rb.lowerBound] }) {
                for k in ra.lowerBound ..< i {
                    saida.append(.del(k))
                }
                saida.append(.keep(i, rb.lowerBound))
                for k in (i + 1) ..< ra.upperBound {
                    saida.append(.del(k))
                }
                return
            }
            trocaInteira(ra, rb)
            return
        }
        // Nenhuma linha em comum: a busca andaria o quadrado do tamanho para descobrir
        // que a resposta é trocar tudo. Uma passada pelos dois lados já sabe.
        guard temAlgoEmComum(ra, rb), let (x, y) = cruzamento(ra, rb) else {
            trocaInteira(ra, rb)
            return
        }
        resolver(ra.lowerBound ..< x, rb.lowerBound ..< y)
        resolver(x ..< ra.upperBound, y ..< rb.upperBound)
    }

    private func temAlgoEmComum(_ ra: Range<Int>, _ rb: Range<Int>) -> Bool {
        let menor = ra.count <= rb.count ? ra.map { a[$0] } : rb.map { b[$0] }
        let vistos = Set(menor)
        return ra.count <= rb.count ? rb.contains { vistos.contains(b[$0]) } : ra.contains { vistos.contains(a[$0]) }
    }

    /// Onde a busca do começo encontra a busca do fim. `nil` quando não há nada em comum
    /// ou o orçamento acabou.
    private mutating func cruzamento(_ ra: Range<Int>, _ rb: Range<Int>) -> (Int, Int)? {
        let n = ra.count, m = rb.count
        let a0 = ra.lowerBound, b0 = rb.lowerBound
        let maxD = (n + m + 1) / 2
        let deslocamento = maxD
        let tamanho = 2 * maxD + 2
        var v1 = [Int](repeating: -1, count: tamanho)
        var v2 = [Int](repeating: -1, count: tamanho)
        v1[deslocamento + 1] = 0
        v2[deslocamento + 1] = 0
        let delta = n - m
        // Com delta ímpar quem encontra a outra é a busca da frente; com delta par, a de trás.
        let frente = delta % 2 != 0
        var k1Inicio = 0, k1Fim = 0, k2Inicio = 0, k2Fim = 0
        for d in 0 ..< maxD {
            for k1 in stride(from: -d + k1Inicio, through: d - k1Fim, by: 2) {
                let o1 = deslocamento + k1
                var x1 = if k1 == -d || (k1 != d && v1[o1 - 1] < v1[o1 + 1]) {
                    v1[o1 + 1]
                } else {
                    v1[o1 - 1] + 1
                }
                var y1 = x1 - k1
                let partida = x1
                while x1 < n, y1 < m, a[a0 + x1] == b[b0 + y1] {
                    x1 += 1; y1 += 1
                }
                orcamento -= 1 + x1 - partida
                v1[o1] = x1
                if x1 > n {
                    k1Fim += 2
                } else if y1 > m {
                    k1Inicio += 2
                } else if frente {
                    let o2 = deslocamento + delta - k1
                    if o2 >= 0, o2 < tamanho, v2[o2] != -1, x1 >= n - v2[o2] {
                        return (a0 + x1, b0 + y1)
                    }
                }
            }
            for k2 in stride(from: -d + k2Inicio, through: d - k2Fim, by: 2) {
                let o2 = deslocamento + k2
                var x2 = if k2 == -d || (k2 != d && v2[o2 - 1] < v2[o2 + 1]) {
                    v2[o2 + 1]
                } else {
                    v2[o2 - 1] + 1
                }
                var y2 = x2 - k2
                let partida = x2
                while x2 < n, y2 < m, a[a0 + n - x2 - 1] == b[b0 + m - y2 - 1] {
                    x2 += 1; y2 += 1
                }
                orcamento -= 1 + x2 - partida
                v2[o2] = x2
                if x2 > n {
                    k2Fim += 2
                } else if y2 > m {
                    k2Inicio += 2
                } else if !frente {
                    let o1 = deslocamento + delta - k2
                    if o1 >= 0, o1 < tamanho, v1[o1] != -1 {
                        let x1 = v1[o1]
                        let y1 = deslocamento + x1 - o1
                        if x1 >= n - x2 {
                            return (a0 + x1, b0 + y1)
                        }
                    }
                }
            }
            if orcamento <= 0 {
                return nil
            }
        }
        return nil
    }
}
