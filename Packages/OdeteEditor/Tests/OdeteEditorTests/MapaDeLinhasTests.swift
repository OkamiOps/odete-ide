import Foundation
@testable import OdeteEditor
import Testing

/// O mapa de linhas é a conta que o editor fazia a cada tecla e agora faz uma vez.
///
/// Se ele errar, erra tudo que se apoia nele — marca do git na margem, onda de erro, guia
/// de recuo, realce da busca —, e erra em silêncio: a decoração aparece na linha errada
/// sem nada quebrar. Por isso as fronteiras estão todas aqui.
struct MapaDeLinhasTests {
    @Test func contaAsLinhasDeUmTextoComum() {
        let m = MapaDeLinhas("um\ndois\ntrês")
        #expect(m.quantidade == 3)
        #expect(m.starts == [0, 3, 8])
    }

    /// Arquivo que termina em quebra de linha tem uma linha vazia no fim — é onde o
    /// cursor fica depois de dar Enter no último caractere.
    @Test func quebraNoFimAbreUmaLinhaVazia() {
        let m = MapaDeLinhas("um\ndois\n")
        #expect(m.quantidade == 3)
        #expect(m.starts.last == 8)
    }

    @Test func textoVazioTemUmaLinha() {
        let m = MapaDeLinhas("")
        #expect(m.quantidade == 1)
        #expect(m.starts == [0])
        #expect(m.linha(de: 0) == 0)
    }

    @Test func umaLinhaSozinhaNaoVirouDuas() {
        let m = MapaDeLinhas("sem quebra")
        #expect(m.quantidade == 1)
    }

    /// As fronteiras são o que erra numa busca binária escrita com pressa: o primeiro
    /// caractere de cada linha pertence àquela linha, não à anterior.
    @Test func aFronteiraDaLinhaPertenceALinhaNova() {
        let m = MapaDeLinhas("um\ndois\ntrês")
        #expect(m.linha(de: 0) == 0)
        #expect(m.linha(de: 2) == 0, "a própria quebra ainda é da linha de cima")
        #expect(m.linha(de: 3) == 1, "o primeiro caractere depois da quebra já é da linha nova")
        #expect(m.linha(de: 7) == 1)
        #expect(m.linha(de: 8) == 2)
        #expect(m.linha(de: 11) == 2)
    }

    /// Cursor no fim do documento é caso de todo dia — e é o que estoura índice quando a
    /// busca binária tem o limite errado.
    @Test func oFimDoDocumentoNaoEstoura() {
        let texto = "um\ndois\ntrês"
        let m = MapaDeLinhas(texto)
        #expect(m.linha(de: (texto as NSString).length) == 2)
        #expect(m.linha(de: 9999) == 2)
    }

    /// Emoji e acento ocupam mais de uma unidade UTF-16. O mapa fala em UTF-16 porque é
    /// o que as APIs de faixa de texto pedem; contar em caracteres deslocaria tudo.
    @Test func acentoEEmojiNaoDeslocamAsLinhas() {
        let texto = "ação 🇧🇷\nsegunda"
        let m = MapaDeLinhas(texto)
        #expect(m.quantidade == 2)
        let inicioDaSegunda = m.starts[1]
        #expect((texto as NSString).substring(from: inicioDaSegunda) == "segunda")
    }

    /// Linha vazia no meio não some: quem calcula por `split` costuma perdê-la, e aí
    /// toda decoração abaixo dela desce uma linha.
    @Test func linhaVaziaNoMeioContinuaSendoUmaLinha() {
        let m = MapaDeLinhas("um\n\ntrês")
        #expect(m.quantidade == 3)
        #expect(m.linha(de: 3) == 1)
        #expect(m.linha(de: 4) == 2)
    }

    @Test func linhasDeVerdadeBatemComOTextoOriginal() {
        let texto = (1 ... 200).map { "linha \($0)" }.joined(separator: "\n")
        let m = MapaDeLinhas(texto)
        #expect(m.quantidade == 200)
        let ns = texto as NSString
        for i in [0, 1, 99, 198, 199] {
            let inicio = m.starts[i]
            let fim = i + 1 < m.starts.count ? m.starts[i + 1] - 1 : ns.length
            #expect(ns.substring(with: NSRange(location: inicio, length: fim - inicio)) == "linha \(i + 1)")
            #expect(m.linha(de: inicio) == i)
        }
    }
}
