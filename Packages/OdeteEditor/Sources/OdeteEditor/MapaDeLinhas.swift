import Foundation

/// Onde cada linha do texto começa, calculado uma vez.
///
/// Parece detalhe e era o maior custo do editor. Toda decoração — marca do git na margem,
/// onda embaixo do erro, guia de recuo, realce da busca — precisa saber em que posição
/// cada linha começa, e isso era recalculado do zero em cada passada: ao digitar, ao
/// mover o cursor, ao rolar e ao mudar a largura da margem. Medido no simulador, uma
/// tecla num arquivo de 2000 linhas custava 84 ms de CPU; num de 18 linhas, 16 ms.
/// Digitando a cinco caracteres por segundo, o arquivo grande queimava 42% de um núcleo
/// só para receber o que a pessoa escrevia — que é bateria e calor no iPad.
///
/// Guardar o mapa num valor, em vez de recalcular, é o que troca isso por uma conta só
/// quando o texto realmente muda.
struct MapaDeLinhas {
    /// O texto como `NSString`, que é a forma que as APIs de faixa de texto pedem.
    ///
    /// Também vale guardar: a ponte de `String` para `NSString` copia o documento.
    let ns: NSString
    /// Deslocamento, em unidades UTF-16, do começo de cada linha.
    let starts: [Int]

    init(_ texto: String) {
        let ns = texto as NSString
        self.ns = ns
        var out = [0]
        var i = 0
        let n = ns.length
        while i < n {
            let r = ns.lineRange(for: NSRange(location: i, length: 0))
            i = r.location + r.length
            if i < n || (i == n && ns.character(at: n - 1) == 10) {
                out.append(i)
            }
            if r.length == 0 {
                break
            }
        }
        starts = out
    }

    var quantidade: Int {
        starts.count
    }

    /// Em que linha (base zero) cai este deslocamento.
    ///
    /// Busca binária, e não varredura: isto é chamado a cada movimento do cursor, e
    /// percorrer o mapa inteiro ali devolveria por outra porta o custo que o mapa
    /// existe para evitar.
    func linha(de offset: Int) -> Int {
        var baixo = 0
        var alto = starts.count - 1
        while baixo < alto {
            let meio = (baixo + alto + 1) / 2
            if starts[meio] <= offset {
                baixo = meio
            } else {
                alto = meio - 1
            }
        }
        return baixo
    }
}
