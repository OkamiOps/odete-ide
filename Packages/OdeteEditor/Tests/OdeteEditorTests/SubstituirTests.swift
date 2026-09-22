import OdeteCore
@testable import OdeteEditor
import Runestone
import SwiftUI
import Testing
import UIKit

/// Substituir pela barra de busca e depois desfazer.
///
/// O caminho antigo passava pelo `replaceText(in: BatchReplaceSet)` do Runestone, cujo
/// desfazer fecha um grupo de desfazer de dentro do próprio desfazer — o `UndoManager`
/// levanta "endUndoGrouping called with no matching begin" e o app cai no ⌘Z.
@MainActor
struct SubstituirTests {
    @MainActor
    final class Buffer {
        var texto: String
        init(_ texto: String) {
            self.texto = texto
        }
    }

    func montar(_ texto: String) throws -> (CodeEditorView.Coordinator, TextView, Buffer) {
        let b = Buffer(texto)
        let vista = CodeEditorView(
            text: Binding(get: { b.texto }, set: { b.texto = $0 }),
            documentId: "p:a.js",
            language: .javascript,
            palette: ThemePalette.all[0],
            prefs: EditorPrefs()
        )
        let host = HostDoEditor(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let c = CodeEditorView.Coordinator(parent: vista, sessoes: SessoesDoEditor(capacidade: 2))
        c.parent = vista
        c.exibir(em: host)
        c.conferirTema()
        let tv = try #require(c.textView)
        if c.textoAtual != texto {
            c.aplicarTextoDeFora(texto, em: tv)
        }
        return (c, tv, b)
    }

    @Test func substituirTudoEDesfazerVoltaOTextoInteiro() throws {
        let original = "let a = 1\nlet b = a + a\n"
        let (c, tv, b) = try montar(original)
        c.find = EditorFind(texto: "a")
        c.substituir(tv, EditorReplace(por: "xy", todos: true, token: 1))
        #expect(tv.text == "let xy = 1\nlet b = xy + xy\n")
        #expect(b.texto == tv.text)

        tv.undoManager?.undo()
        #expect(tv.text == original)
        #expect(c.textoAtual == original)

        tv.undoManager?.redo()
        #expect(tv.text == "let xy = 1\nlet b = xy + xy\n")
    }

    @Test func substituirUmaOcorrenciaEDesfazer() throws {
        let original = "a a a\n"
        let (c, tv, _) = try montar(original)
        c.find = EditorFind(texto: "a", indice: 1)
        c.substituir(tv, EditorReplace(por: "b", todos: false, token: 1))
        #expect(tv.text == "a b a\n")

        tv.undoManager?.undo()
        #expect(tv.text == original)
    }

    @Test func substituirDepoisDeDigitarDesfazEmDoisPassos() throws {
        let (c, tv, _) = try montar("a\n")
        tv.selectedRange = NSRange(location: 1, length: 0)
        tv.insertText(" a")
        c.find = EditorFind(texto: "a")
        c.substituir(tv, EditorReplace(por: "z", todos: true, token: 1))
        #expect(tv.text == "z z\n")

        // O primeiro ⌘Z desfaz só a substituição, não a digitação junto.
        tv.undoManager?.undo()
        #expect(tv.text == "a a\n")
    }
}
