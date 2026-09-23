import Foundation
import Runestone

/// A quebra de linha de um arquivo, do jeito que o `.editorconfig` escreve (`end_of_line`).
public enum FimDeLinha: String, Sendable, Equatable {
    case lf
    case crlf
    case cr

    public var simbolo: String {
        switch self {
        case .lf: "\n"
        case .crlf: "\r\n"
        case .cr: "\r"
        }
    }

    var runestone: LineEnding {
        switch self {
        case .lf: .lf
        case .crlf: .crlf
        case .cr: .cr
        }
    }
}

/// Contas de quebra de linha feitas em UTF-16, que é como o editor conta.
///
/// Em Swift, `"\r\n"` é um `Character` só: `split(separator: "\n")` não parte linha
/// CRLF nenhuma e `hasSuffix("\n")` diz que `"a\r\n"` não termina em quebra. Era por aí
/// que o aparar e a quebra no fim estragavam arquivo do Windows em silêncio.
public enum QuebrasDeLinha {
    /// A primeira quebra do texto (`\r\n`, `\n` ou `\r`), ou `nil` se ele tem uma linha só.
    public static func primeira(_ ns: NSString) -> String? {
        var i = 0
        while i < ns.length {
            switch ns.character(at: i) {
            case 10: return "\n"
            case 13: return i + 1 < ns.length && ns.character(at: i + 1) == 10 ? "\r\n" : "\r"
            default: i += 1
            }
        }
        return nil
    }

    /// Todas as quebras viram `\n`.
    public static func soLF(_ s: String) -> String {
        guard s.utf16.contains(13) else { return s }
        let ns = NSMutableString(string: s)
        ns.replaceOccurrences(of: "\r\n", with: "\n", options: .literal, range: NSRange(location: 0, length: ns.length))
        ns.replaceOccurrences(of: "\r", with: "\n", options: .literal, range: NSRange(location: 0, length: ns.length))
        return ns as String
    }

    /// O texto que o Runestone estragou ao inserir num arquivo CRLF, de volta a só `\n`.
    ///
    /// Antes de inserir, o Runestone troca `\r` por `\r\n` e depois `\n` por `\r\n`. Com
    /// texto que já tem `\r\n` isso vira `\r\r\n\r\n` — e colar faz a troca duas vezes, então
    /// até texto só com `\n` sai estragado. A troca é reversível (`\r` virou `\r\r\n`, `\n`
    /// virou `\r\n`); desfeita quantas vezes der, sobra o texto original com `\n`, que numa
    /// inserção só vira CRLF certo.
    static func desfazerPreparoCRLF(_ s: String) -> String {
        var atual = s
        while atual.utf16.contains(13), let anterior = desfazerUmPreparo(atual) {
            atual = anterior
        }
        return soLF(atual)
    }

    private static func desfazerUmPreparo(_ s: String) -> String? {
        let u = Array(s.utf16)
        var out: [UInt16] = []
        out.reserveCapacity(u.count)
        var i = 0
        while i < u.count {
            if u[i] == 13 {
                if i + 2 < u.count, u[i + 1] == 13, u[i + 2] == 10 {
                    out.append(13)
                    i += 3
                } else if i + 1 < u.count, u[i + 1] == 10 {
                    out.append(10)
                    i += 2
                } else {
                    return nil
                }
            } else if u[i] == 10 {
                return nil
            } else {
                out.append(u[i])
                i += 1
            }
        }
        return String(utf16CodeUnits: out, count: out.count)
    }

    /// Inserir `texto` num editor com esta quebra muda o texto? O Runestone troca toda
    /// quebra do texto inserido pela do editor; só vale inserir por ele o que já está
    /// todo na quebra do editor.
    static func inalterado(_ texto: String, por quebra: LineEnding) -> Bool {
        let u = Array(texto.utf16)
        switch quebra {
        case .lf:
            return !u.contains(13)
        case .cr:
            return !u.contains(10)
        case .crlf:
            for (i, c) in u.enumerated() {
                if c == 13, !(i + 1 < u.count && u[i + 1] == 10) {
                    return false
                }
                if c == 10, !(i > 0 && u[i - 1] == 13) {
                    return false
                }
            }
            return true
        }
    }

    /// Onde cada linha começa e onde o conteúdo dela acaba (antes da quebra), em UTF-16.
    static func linhas(_ ns: NSString) -> [(inicio: Int, fimDoConteudo: Int, fim: Int)] {
        var out: [(Int, Int, Int)] = []
        var inicio = 0
        var i = 0
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 10 || c == 13 {
                let fimConteudo = i
                if c == 13, i + 1 < ns.length, ns.character(at: i + 1) == 10 {
                    i += 1
                }
                out.append((inicio, fimConteudo, i + 1))
                inicio = i + 1
            }
            i += 1
        }
        out.append((inicio, ns.length, ns.length))
        return out
    }
}

/// O recuo que um texto já usa: tabs, ou espaços de quantos em quantos.
///
/// O detector do Runestone não serve: em arquivo pequeno ele quase sempre diz "não sei"
/// (só decide depois de 20 linhas com conteúdo, ou quando a última linha lida tem texto —
/// e a última linha de um arquivo costuma ser a vazia depois da quebra final), e no modo de
/// texto puro nem tenta. Aqui a conta é a do VS Code: a diferença de recuo entre linhas
/// seguidas com conteúdo; a diferença que mais aparece é o passo do arquivo.
enum RecuoDoTexto {
    static func detectar(_ texto: String, limite: Int = 2000) -> DetectedIndentStrategy {
        let ns = texto as NSString
        let n = ns.length
        var comTab = 0, comEspacos = 0
        var passos: [Int: Int] = [:]
        var anterior = 0
        var lidas = 0
        var i = 0
        while i < n, lidas < limite {
            var espacos = 0, tabs = 0
            var j = i
            while j < n {
                let c = ns.character(at: j)
                if c == 32 {
                    espacos += 1
                } else if c == 9 {
                    tabs += 1
                } else {
                    break
                }
                j += 1
            }
            var k = j
            while k < n, ns.character(at: k) != 10, ns.character(at: k) != 13 {
                k += 1
            }
            if k > j {
                lidas += 1
                if tabs > 0, espacos == 0 {
                    comTab += 1
                } else if tabs == 0 {
                    if espacos >= 2 {
                        comEspacos += 1
                    }
                    let passo = abs(espacos - anterior)
                    if passo >= 2, passo <= 8 {
                        passos[passo, default: 0] += 1
                    }
                    anterior = espacos
                }
            }
            if k < n, ns.character(at: k) == 13, k + 1 < n, ns.character(at: k + 1) == 10 {
                k += 1
            }
            i = k + 1
        }
        if comTab == 0, comEspacos == 0 {
            return .unknown
        }
        if comTab > comEspacos {
            return .tab
        }
        // Empate entre passos: o menor, que é o que o maior costuma ser múltiplo.
        guard let passo = passos.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) })
        else { return .unknown }
        return .space(length: passo.key)
    }
}

/// O que os ajustes de salvamento fazem com o texto — tirar espaço no fim das linhas e
/// garantir a quebra no fim do arquivo —, contado em UTF-16 para não errar em CRLF.
public enum Arrumacao {
    /// Tira espaços e tabs do fim de cada linha, mantendo a quebra de cada uma como está.
    ///
    /// `preservando` é uma posição (UTF-16) do texto: a linha dela fica como está. É a
    /// linha do cursor no salvamento automático — aparar ali comia o espaço que a pessoa
    /// tinha acabado de digitar, um segundo depois de ela parar.
    public static func aparar(_ texto: String, preservando: Int? = nil) -> String {
        let ns = texto as NSString
        var partes: [String] = []
        var mudou = false
        for l in QuebrasDeLinha.linhas(ns) {
            let conteudo = NSRange(location: l.inicio, length: l.fimDoConteudo - l.inicio)
            var fim = l.fimDoConteudo
            let protegida = preservando.map { $0 >= l.inicio && $0 <= l.fimDoConteudo } ?? false
            if !protegida {
                while fim > l.inicio, [32, 9].contains(ns.character(at: fim - 1)) {
                    fim -= 1
                }
            }
            if fim != l.fimDoConteudo {
                mudou = true
            }
            partes.append(ns.substring(with: NSRange(location: conteudo.location, length: fim - conteudo.location)))
            partes.append(ns.substring(with: NSRange(location: l.fimDoConteudo, length: l.fim - l.fimDoConteudo)))
        }
        return mudou ? partes.joined() : texto
    }

    /// Acrescenta uma quebra no fim se falta — a mesma quebra que o arquivo já usa.
    public static func quebraNoFim(_ texto: String, padrao: FimDeLinha? = nil) -> String {
        let ns = texto as NSString
        guard ns.length > 0 else { return texto }
        let ultimo = ns.character(at: ns.length - 1)
        if ultimo == 10 || ultimo == 13 {
            return texto
        }
        return texto + (QuebrasDeLinha.primeira(ns) ?? padrao?.simbolo ?? "\n")
    }
}
