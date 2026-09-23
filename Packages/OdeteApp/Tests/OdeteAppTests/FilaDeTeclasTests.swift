@testable import OdeteApp
import SwiftUI
import Testing

/// O Tab do terminal completa o texto inteiro, e não um retrato velho dele.
///
/// O `onKeyPress` dispara quando a tecla desce, antes do sistema de texto inserir as
/// letras de antes: `npm ru` + Tab digitados rápido completavam `npm r`, e o "u" caía no
/// fim do texto completado. A fila segura o Tab até o texto dessas letras chegar ao campo.
@MainActor
struct FilaDeTeclasTests {
    final class Relogio {
        var agora: TimeInterval = 100
    }

    func fila(_ r: Relogio) -> FilaDeTeclas {
        let f = FilaDeTeclas()
        f.relogio = { r.agora }
        f.agendar = { _, _ in }
        return f
    }

    /// O caso de sempre: nada a caminho, o Tab roda na hora, como antes.
    @Test func semNadaPendenteRodaNaHora() {
        let r = Relogio()
        let f = fila(r)
        var rodou = 0
        f.depoisDoTexto { rodou += 1 }
        #expect(rodou == 1 && f.fila.isEmpty)
        // Letra que já chegou não segura nada.
        f.desceuTexto()
        f.chegouTexto()
        f.depoisDoTexto { rodou += 1 }
        #expect(rodou == 2)
    }

    /// "ru" + Tab com o "u" ainda na fila do sistema: o Tab espera o "u" chegar.
    @Test func tabEsperaAsLetrasDeAntes() {
        let r = Relogio()
        let f = fila(r)
        var texto = "npm "
        var completouSobre: String?
        f.desceuTexto() // r
        texto += "r"; f.chegouTexto()
        f.desceuTexto() // u, ainda a caminho
        f.depoisDoTexto { completouSobre = texto }
        #expect(completouSobre == nil && f.pendentes == 1)
        texto += "u"; f.chegouTexto()
        #expect(completouSobre == "npm ru" && f.fila.isEmpty)
    }

    /// Letra digitada depois do Tab não entra na conta dele.
    @Test func letraDepoisDoTabNaoSeguraOTab() {
        let r = Relogio()
        let f = fila(r)
        var ordem: [String] = []
        f.desceuTexto() // a, antes do Tab
        f.depoisDoTexto { ordem.append("tab") }
        f.desceuTexto() // b, depois do Tab
        f.chegouTexto() // chega o a
        #expect(ordem == ["tab"] && f.pendentes == 1)
        f.chegouTexto() // chega o b
        #expect(f.fila.isEmpty)
    }

    /// Dois Tabs seguidos com letra a caminho rodam os dois, na ordem.
    @Test func doisTabsNaOrdem() {
        let r = Relogio()
        let f = fila(r)
        var ordem: [Int] = []
        f.desceuTexto()
        f.depoisDoTexto { ordem.append(1) }
        f.depoisDoTexto { ordem.append(2) }
        #expect(ordem.isEmpty)
        f.chegouTexto()
        #expect(ordem == [1, 2])
    }

    /// Tecla anotada que não virou texto (apagar sem nada antes do cursor, tecla morta)
    /// não segura o Tab para sempre: vence no prazo.
    @Test func anotacaoVencida() {
        let r = Relogio()
        let f = fila(r)
        var rodou = false
        f.desceuTexto()
        f.depoisDoTexto { rodou = true }
        #expect(!rodou)
        r.agora += FilaDeTeclas.validade
        f.drenar() // o que o `agendar` faz de verdade
        #expect(rodou && f.fila.isEmpty)
        // E um Tab novo, depois de uma anotação vencida, roda na hora.
        f.desceuTexto()
        r.agora += FilaDeTeclas.validade
        var novo = false
        f.depoisDoTexto { novo = true }
        #expect(novo)
    }

    /// O Tab à espera pede para ser acordado no prazo, sem depender de outra tecla.
    @Test func tabAEsperaAgendaOPrazo() {
        let r = Relogio()
        let f = fila(r)
        var pedidos: [TimeInterval] = []
        f.agendar = { atraso, _ in pedidos.append(atraso) }
        f.depoisDoTexto {}
        #expect(pedidos.isEmpty)
        f.desceuTexto()
        f.depoisDoTexto {}
        #expect(pedidos == [FilaDeTeclas.validade])
    }

    /// Mais textos que anotações (repetição de tecla, colar) não quebram a conta.
    @Test func textoSemAnotacaoNaoFazNada() {
        let r = Relogio()
        let f = fila(r)
        f.chegouTexto()
        f.chegouTexto()
        var rodou = false
        f.depoisDoTexto { rodou = true }
        #expect(rodou)
    }

    @Test func quaisTeclasViramTexto() {
        let sim: [String] = ["a", "U", " ", "/", "~", "é", "ç", "1"]
        for c in sim {
            #expect(FilaDeTeclas.produzTexto(caracteres: c, modificadores: [], temTexto: false), "\(c)")
        }
        #expect(FilaDeTeclas.produzTexto(caracteres: "A", modificadores: .shift, temTexto: false))
        #expect(FilaDeTeclas.produzTexto(caracteres: "£", modificadores: .option, temTexto: false))
        // Tab, Enter, Esc, setas e teclas de função não inserem nada.
        for c in ["\t", "\r", "\u{1B}", "\u{F700}", "\u{F701}", "\u{F728}", ""] {
            #expect(
                !FilaDeTeclas.produzTexto(caracteres: c, modificadores: [], temTexto: true),
                "\(c.debugDescription)"
            )
        }
        // Atalhos não são texto: ⌃C, ⌃L, ⌘V.
        #expect(!FilaDeTeclas.produzTexto(caracteres: "c", modificadores: .control, temTexto: true))
        #expect(!FilaDeTeclas.produzTexto(caracteres: "v", modificadores: .command, temTexto: true))
        // Apagar só mexe no texto quando há texto.
        #expect(FilaDeTeclas.produzTexto(caracteres: "\u{7F}", modificadores: [], temTexto: true))
        #expect(!FilaDeTeclas.produzTexto(caracteres: "\u{7F}", modificadores: [], temTexto: false))
    }
}
