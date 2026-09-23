import Foundation

/// As trocas pequenas que levam um texto a outro, em posições UTF-16 do texto antigo.
///
/// Texto que muda por fora do editor — salvar aparando espaços, o disco, o agente — era
/// posto no editor inteiro de novo. Isso refaz a análise do arquivo todo e leva o cursor
/// para onde a troca inteira acabou: com salvamento automático e "remover espaços no fim"
/// ligados, o cursor pulava a cada pausa na digitação. Aplicando só o que mudou, o resto
/// do documento — cursor, rolagem, desfazer — fica onde estava.
enum DiferencaDeTexto {
    struct Troca: Equatable {
        /// Faixa no texto antigo.
        var faixa: NSRange
        var texto: String
    }

    /// As trocas, em ordem e sem sobreposição. Linhas que mudaram viram uma troca cada
    /// quando o número de linhas é o mesmo dos dois lados; senão, uma troca só com o miolo
    /// que difere.
    static func trocas(de antigo: String, para novo: String) -> [Troca] {
        let a = antigo as NSString, b = novo as NSString
        guard a != b else { return [] }
        let d = diferenca(a, b)
        let meioA = a.substring(with: NSRange(location: d.inicio, length: d.fimA - d.inicio)) as NSString
        let meioB = b.substring(with: NSRange(location: d.inicio, length: d.fimB - d.inicio)) as NSString
        let linhasA = QuebrasDeLinha.linhas(meioA)
        let linhasB = QuebrasDeLinha.linhas(meioB)
        guard linhasA.count == linhasB.count, linhasA.count > 1 else {
            return [Troca(faixa: NSRange(location: d.inicio, length: d.fimA - d.inicio), texto: meioB as String)]
        }
        var out: [Troca] = []
        for (la, lb) in zip(linhasA, linhasB) {
            let sa = meioA.substring(with: NSRange(location: la.inicio, length: la.fim - la.inicio)) as NSString
            let sb = meioB.substring(with: NSRange(location: lb.inicio, length: lb.fim - lb.inicio)) as NSString
            let l = diferenca(sa, sb)
            guard l.fimA > l.inicio || l.fimB > l.inicio else { continue }
            out.append(Troca(
                faixa: NSRange(location: d.inicio + la.inicio + l.inicio, length: l.fimA - l.inicio),
                texto: sb.substring(with: NSRange(location: l.inicio, length: l.fimB - l.inicio))
            ))
        }
        return out
    }

    /// Tira o começo e o fim comuns: o que difere é `a[inicio..<fimA]` e `b[inicio..<fimB]`.
    /// Nunca corta no meio de um par substituto nem de um `\r\n`.
    static func diferenca(_ a: NSString, _ b: NSString) -> (inicio: Int, fimA: Int, fimB: Int) {
        var p = 0
        let menor = min(a.length, b.length)
        while p < menor, a.character(at: p) == b.character(at: p) {
            p += 1
        }
        while p > 0, partiria(a, p) || partiria(b, p) {
            p -= 1
        }
        var s = 0
        while s < menor - p, a.character(at: a.length - 1 - s) == b.character(at: b.length - 1 - s) {
            s += 1
        }
        while s > 0, partiria(a, a.length - s) || partiria(b, b.length - s) {
            s -= 1
        }
        return (p, a.length - s, b.length - s)
    }

    /// Cortar em `i` separaria um par substituto ou um `\r\n`?
    private static func partiria(_ s: NSString, _ i: Int) -> Bool {
        guard i > 0, i < s.length else { return false }
        let antes = s.character(at: i - 1), depois = s.character(at: i)
        return UTF16.isLeadSurrogate(antes) || (antes == 13 && depois == 10)
    }

    /// Junta trocas vizinhas até sobrarem no máximo `maximo`, cada uma cobrindo o trecho
    /// entre a primeira e a última do grupo.
    ///
    /// Cada troca no Runestone refaz a análise e o layout do trecho; mil ocorrências num
    /// "substituir todos" eram mil passadas. Juntando, o texto fora das ocorrências continua
    /// intocado — só o que fica entre duas delas de um mesmo grupo é reescrito igual.
    static func agrupar(_ trocas: [Troca], em ns: NSString, maximo: Int) -> [Troca] {
        guard trocas.count > maximo, maximo > 0 else { return trocas }
        let porGrupo = (trocas.count + maximo - 1) / maximo
        var out: [Troca] = []
        var i = 0
        while i < trocas.count {
            let grupo = trocas[i ..< min(i + porGrupo, trocas.count)]
            let inicio = grupo.first!.faixa.location
            var texto = ""
            var cursor = inicio
            for t in grupo {
                texto += ns.substring(with: NSRange(location: cursor, length: t.faixa.location - cursor))
                texto += t.texto
                cursor = NSMaxRange(t.faixa)
            }
            out.append(Troca(faixa: NSRange(location: inicio, length: cursor - inicio), texto: texto))
            i += porGrupo
        }
        return out
    }

    /// Onde uma seleção do texto antigo fica depois das trocas.
    static func mapear(_ selecao: NSRange, _ trocas: [Troca]) -> NSRange {
        let de = mapear(selecao.location, trocas)
        let ate = mapear(NSMaxRange(selecao), trocas)
        return NSRange(location: de, length: max(ate - de, 0))
    }

    static func mapear(_ pos: Int, _ trocas: [Troca]) -> Int {
        var delta = 0
        for t in trocas {
            let novo = (t.texto as NSString).length
            if NSMaxRange(t.faixa) <= pos {
                delta += novo - t.faixa.length
            } else if t.faixa.location < pos {
                // Dentro de um trecho trocado: fica no mesmo deslocamento, preso ao novo.
                return t.faixa.location + delta + min(pos - t.faixa.location, novo)
            }
        }
        return pos + delta
    }
}
