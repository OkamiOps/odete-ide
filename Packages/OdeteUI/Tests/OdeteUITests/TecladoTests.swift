@testable import OdeteUI
import Testing
import UIKit

/// A barra de recolher tem que aparecer em campo comum, e não aparecer duas vezes.
///
/// O teclado físico é injetado: o simulador enxerga o teclado do Mac, e sem isso o
/// mesmo teste passaria numa máquina e falharia na outra.
@MainActor
struct TecladoTests {
    init() {
        Teclado.temTecladoFisico = { false }
    }

    @Test func campoComumGanhaABarra() {
        let campo = UITextField()
        Teclado.pendura(campo)
        #expect(campo.inputAccessoryView is BarraDeRecolher, "campo de texto ficou sem barra")
    }

    @Test func textViewTambemGanha() {
        let campo = UITextView()
        Teclado.pendura(campo)
        #expect(campo.inputAccessoryView is BarraDeRecolher)
    }

    /// O editor de código traz a barra dele; duas empilhadas seria pior que nenhuma.
    @Test func quemJaTemBarraPropriaFicaComElA() {
        let campo = UITextView()
        let minha = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        campo.inputAccessoryView = minha
        Teclado.pendura(campo)
        #expect(campo.inputAccessoryView === minha)
    }

    /// Acessório vazio que o SwiftUI pendura sozinho não é barra de ninguém: pode trocar.
    ///
    /// Foi esta a regra errada da primeira versão — "tem acessório, não mexe" — e com ela
    /// a barra não aparecia em campo nenhum do app.
    @Test func acessorioVazioDoSwiftUIDaLugarABarra() {
        let campo = UITextField()
        campo.inputAccessoryView = UIView()
        Teclado.pendura(campo)
        #expect(campo.inputAccessoryView is BarraDeRecolher)
    }

    /// O compositor do agente tem o botão ao lado do de enviar.
    @Test func compositorDoAgenteFicaDeFora() {
        let campo = SendingTextView()
        Teclado.pendura(campo)
        #expect(campo.inputAccessoryView == nil)
    }

    /// Com teclado físico não há teclado de software para recolher.
    @Test func comTecladoFisicoABarraNaoEntra() {
        Teclado.temTecladoFisico = { true }
        let campo = UITextField()
        Teclado.pendura(campo)
        #expect(campo.inputAccessoryView == nil)
        Teclado.temTecladoFisico = { false }
    }

    @Test func aBarraTemBotaoComRotulo() {
        let barra = BarraDeRecolher()
        let botoes = barra.subviews.compactMap { $0 as? UIButton }
        #expect(botoes.count == 1)
        #expect(botoes.first?.accessibilityLabel?.isEmpty == false)
    }
}
