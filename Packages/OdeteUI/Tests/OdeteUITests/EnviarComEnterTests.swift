@testable import OdeteUI
import SwiftUI
import Testing
import UIKit

/// O Enter físico do composer envia o texto inteiro, e não um retrato velho dele.
///
/// Antes o Enter era um `UIKeyCommand`, que dispara quando a tecla desce, fora da fila do
/// sistema de texto: "turno um" + Enter digitados rápido enviavam "Turno", e o "um" caía
/// depois no campo limpo. Agora a tecla é só anotada ao descer, e o envio acontece quando o
/// "\n" dela chega ao delegate, depois das teclas de antes.
struct DecisaoDoEnterTests {
    @Test func enterFisicoSemModificadorEnvia() {
        #expect(SendingTextView.deveEnviar(texto: "\n", returnDeHardware: true, modificadores: [], marcado: false))
    }

    /// Caps lock e o "numérico" do Enter do teclado numérico não são modificadores do Enter.
    @Test func capsLockETecladoNumericoNaoContam() {
        #expect(SendingTextView.deveEnviar(
            texto: "\n",
            returnDeHardware: true,
            modificadores: [.alphaShift, .numericPad],
            marcado: false
        ))
    }

    @Test func comModificadorQuebraALinha() {
        for m: UIKeyModifierFlags in [.shift, .alternate, .control, .command, [.shift, .alternate]] {
            #expect(!SendingTextView.deveEnviar(texto: "\n", returnDeHardware: true, modificadores: m, marcado: false))
        }
    }

    /// O Return do teclado virtual quebra a linha: ali o envio é o botão.
    @Test func tecladoVirtualQuebraALinha() {
        #expect(!SendingTextView.deveEnviar(texto: "\n", returnDeHardware: false, modificadores: [], marcado: false))
    }

    /// Com texto marcado (IME, ditado) o Enter confirma a composição.
    @Test func comTextoMarcadoNaoEnvia() {
        #expect(!SendingTextView.deveEnviar(texto: "\n", returnDeHardware: true, modificadores: [], marcado: true))
    }

    @Test func soQuebraDeLinhaContaComoEnter() {
        #expect(!SendingTextView.deveEnviar(texto: "a", returnDeHardware: true, modificadores: [], marcado: false))
        #expect(!SendingTextView.deveEnviar(texto: "a\n", returnDeHardware: true, modificadores: [], marcado: false))
        #expect(!SendingTextView.deveEnviar(texto: "", returnDeHardware: true, modificadores: [], marcado: false))
        #expect(SendingTextView.deveEnviar(texto: "\r", returnDeHardware: true, modificadores: [], marcado: false))
    }
}

@MainActor
struct EnviarComEnterTests {
    @MainActor
    final class Caixa {
        var texto = ""
        var focado = false
        var enviados: [String] = []
        var agora: TimeInterval = 100
    }

    /// Campo com `texto` na tela e `rascunho` no binding. O envio anota o que o binding tinha
    /// e limpa o rascunho, como o `AgentModel.send()`.
    func montar(texto: String, rascunho: String? = nil) -> (SendingTextView, GrowingTextView.Coordinator, Caixa) {
        let b = Caixa()
        b.texto = rascunho ?? texto
        let campo = GrowingTextView(
            text: Binding(get: { b.texto }, set: { b.texto = $0 }),
            placeholder: "",
            focused: Binding(get: { b.focado }, set: { b.focado = $0 }),
            onSend: {
                b.enviados.append(b.texto)
                b.texto = ""
            }
        )
        let c = campo.makeCoordinator()
        let v = SendingTextView()
        v.delegate = c
        v.text = texto
        v.onSend = campo.onSend
        v.relogio = { b.agora }
        return (v, c, b)
    }

    /// Faz o papel da fila do teclado: pergunta ao delegate e, se ele deixa, insere. Chamar
    /// `insertText` não serve: fora do caminho do teclado o `UITextView` não consulta o
    /// delegate (nem com janela e foco).
    func enter(_ v: SendingTextView, _ c: GrowingTextView.Coordinator, _ texto: String = "\n") -> Bool {
        let fim = NSRange(location: (v.text as NSString).length, length: 0)
        let deixa = c.textView(v, shouldChangeTextInRanges: [NSValue(range: fim)], replacementText: texto)
        if deixa {
            v.text += texto
        }
        return deixa
    }

    /// O caso do QA: o "\n" chega depois das teclas de antes, e o envio leva o texto inteiro —
    /// mesmo que o binding ainda estivesse um passo atrás.
    @Test func enterFisicoEnviaOTextoInteiro() {
        let (v, c, b) = montar(texto: "abc", rascunho: "ab")
        v.anotarReturn(modificadores: [])
        #expect(!enter(v, c), "o \\n do Enter entrou no texto")
        #expect(b.enviados == ["abc"])
        // O envio limpou o rascunho, e o campo acompanha na hora: uma tecla que ainda estivesse
        // na fila entraria no texto velho e o traria de volta.
        #expect(v.text == "")
        #expect(b.texto == "")
    }

    @Test func tecladoVirtualQuebraALinha() {
        let (v, c, b) = montar(texto: "abc")
        #expect(enter(v, c))
        #expect(b.enviados.isEmpty)
        #expect(v.text == "abc\n")
    }

    @Test func shiftEnterQuebraALinha() {
        let (v, c, b) = montar(texto: "abc")
        v.anotarReturn(modificadores: [.shift])
        #expect(enter(v, c))
        #expect(b.enviados.isEmpty)
        #expect(v.returnsNaFila.isEmpty, "a anotação do shift+Enter ficou na fila")
    }

    /// As anotações andam na ordem das teclas: shift+Enter e logo Enter, com os dois "\n"
    /// ainda na fila, dão quebra e depois envio.
    @Test func shiftEnterEEnterRapidosSaemNaOrdem() {
        let (v, c, b) = montar(texto: "abc")
        v.anotarReturn(modificadores: [.shift])
        v.anotarReturn(modificadores: [])
        #expect(enter(v, c))
        #expect(!enter(v, c))
        #expect(b.enviados == ["abc\n"])
    }

    /// Control e command+Enter não são anotados: não se sabe se o sistema insere o "\n", e uma
    /// anotação sem "\n" ficaria para a tecla seguinte.
    @Test func controlECommandNaoSaoAnotados() {
        let (v, c, b) = montar(texto: "abc")
        v.anotarReturn(modificadores: [.control])
        v.anotarReturn(modificadores: [.command])
        #expect(v.returnsNaFila.isEmpty)
        #expect(enter(v, c))
        #expect(b.enviados.isEmpty)
    }

    /// Uma anotação que nunca recebeu o seu "\n" (um Enter que confirmou texto marcado) vence,
    /// e o shift+Enter de depois não a toma por sua.
    @Test func anotacaoVencidaNaoEnvia() {
        let (v, c, b) = montar(texto: "abc")
        v.anotarReturn(modificadores: [])
        v.soltouReturn()
        b.agora += SendingTextView.validadeDaAnotacao + 1
        v.anotarReturn(modificadores: [.shift])
        #expect(enter(v, c))
        #expect(b.enviados.isEmpty)
    }

    /// Segurar o Enter: o primeiro "\n" envia, a repetição da tecla não enche o campo de
    /// linhas em branco. Solta a tecla, o Return volta ao normal.
    @Test func repeticaoDoEnterSeguradoNaoQuebraALinha() {
        let (v, c, b) = montar(texto: "abc")
        v.anotarReturn(modificadores: [])
        #expect(!enter(v, c))
        #expect(!enter(v, c))
        #expect(b.enviados == ["abc"])
        #expect(v.text == "")
        v.soltouReturn()
        #expect(enter(v, c))
        #expect(b.enviados == ["abc"])
    }

    @Test func semOnSendOEnterEhSoQuebra() {
        let v = SendingTextView()
        let b = Caixa()
        let campo = GrowingTextView(
            text: Binding(get: { b.texto }, set: { b.texto = $0 }),
            placeholder: "",
            focused: Binding(get: { b.focado }, set: { b.focado = $0 })
        )
        let c = campo.makeCoordinator()
        v.delegate = c
        v.text = "abc"
        v.anotarReturn(modificadores: [])
        #expect(v.returnsNaFila.isEmpty)
        #expect(enter(v, c))
    }

    /// Com texto marcado o Enter confirma a composição: não é anotado nem envia.
    @Test func comTextoMarcadoNaoEnvia() throws {
        let (v, c, b) = montar(texto: "abc")
        v.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        try #require(v.markedTextRange != nil)
        v.anotarReturn(modificadores: [])
        #expect(v.returnsNaFila.isEmpty)
        #expect(c.textView(
            v,
            shouldChangeTextInRanges: [NSValue(range: NSRange(location: 4, length: 0))],
            replacementText: "\n"
        ))
        #expect(b.enviados.isEmpty)
    }

    /// Perder o foco esquece o que estava na fila.
    @Test func perderOFocoEsqueceAFila() {
        let (v, c, b) = montar(texto: "abc")
        v.anotarReturn(modificadores: [])
        c.textViewDidEndEditing(v)
        #expect(v.returnsNaFila.isEmpty)
        #expect(!v.segurandoReturn)
        #expect(enter(v, c))
        #expect(b.enviados.isEmpty)
    }

    /// O UIKit acha o método pelo seletor do Objective-C; um nome quase igual compilaria e
    /// nunca seria chamado.
    @Test func oUIKitEnxergaODelegateDoEnter() {
        let (_, c, _) = montar(texto: "")
        let seletor = #selector(UITextViewDelegate.textView(_:shouldChangeTextInRanges:replacementText:))
        #expect(c.responds(to: seletor))
    }

    /// O Esc continua atalho de teclado; o Enter não é mais.
    @Test func soOEscEhAtalho() {
        let (v, _, _) = montar(texto: "")
        #expect(v.keyCommands?.isEmpty == true)
        v.onEscape = {}
        let cmds = v.keyCommands ?? []
        #expect(cmds.map(\.input) == [UIKeyCommand.inputEscape])
    }
}
