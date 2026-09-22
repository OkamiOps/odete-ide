import OdeteCore
@testable import OdeteEditor
import Runestone
import SwiftUI
import Testing
import UIKit

/// Um editor por aba: o desfazer, o cursor e a rolagem sobrevivem à troca de aba, e o
/// que sai da fila volta no mesmo ponto. Tudo com `TextView` de verdade, sem SwiftUI —
/// o coordenador é chamado do jeito que `updateUIView` chama.
@MainActor
struct SessoesDoEditorTests {
    /// Os buffers do "workspace", e quantas vezes o editor escreveu neles.
    @MainActor
    final class Buffers {
        var textos: [String: String] = [:]
        var escritas = 0
    }

    func vista(_ doc: String, _ b: Buffers, prefs: EditorPrefs = EditorPrefs()) -> CodeEditorView {
        CodeEditorView(
            text: Binding(get: { b.textos[doc] ?? "" }, set: { b.textos[doc] = $0; b.escritas += 1 }),
            documentId: doc,
            language: .javascript,
            palette: ThemePalette.all[0],
            prefs: prefs
        )
    }

    /// O que `updateUIView` faz com o documento, sem o resto.
    func mostrar(_ c: CodeEditorView.Coordinator, _ v: CodeEditorView, em host: HostDoEditor) {
        c.parent = v
        c.exibir(em: host)
        c.conferirTema()
        if let tv = c.textView, !c.isEditing, c.textoAtual != v.text {
            c.aplicarTextoDeFora(v.text, em: tv)
        }
    }

    func montar(_ textos: [String: String], capacidade: Int = 6) -> (
        CodeEditorView.Coordinator, HostDoEditor, Buffers, SessoesDoEditor
    ) {
        let b = Buffers()
        b.textos = textos
        let s = SessoesDoEditor(capacidade: capacidade)
        let host = HostDoEditor(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let primeiro = textos.keys.sorted()[0]
        let c = CodeEditorView.Coordinator(parent: vista(primeiro, b), sessoes: s)
        return (c, host, b, s)
    }

    @Test func desfazerSobreviveATrocaDeAba() throws {
        let (c, host, b, _) = montar(["p:a.js": "let a = 1\n", "p:b.js": "let b = 2\n"])
        mostrar(c, vista("p:a.js", b), em: host)
        let editorA = try #require(c.textView)
        editorA.selectedRange = NSRange(location: 10, length: 0)
        editorA.insertText("x")
        #expect(b.textos["p:a.js"] == "let a = 1\nx")

        mostrar(c, vista("p:b.js", b), em: host)
        #expect(c.textView !== editorA)
        #expect(editorA.superview == nil)
        #expect(c.textView?.text == "let b = 2\n")

        mostrar(c, vista("p:a.js", b), em: host)
        #expect(c.textView === editorA)
        #expect(editorA.superview === host)
        editorA.undoManager?.undo()
        #expect(editorA.text == "let a = 1\n")
        #expect(b.textos["p:a.js"] == "let a = 1\n")
    }

    @Test func trocarDeAbaNaoReanalisaNemRecriaOEditor() throws {
        let (c, host, b, s) = montar(["p:a.js": "a", "p:b.js": "b"])
        mostrar(c, vista("p:a.js", b), em: host)
        let a = try #require(c.textView)
        mostrar(c, vista("p:b.js", b), em: host)
        mostrar(c, vista("p:a.js", b), em: host)
        mostrar(c, vista("p:b.js", b), em: host)
        mostrar(c, vista("p:a.js", b), em: host)
        #expect(c.textView === a)
        #expect(s.sessoes.count == 2)
        // Ninguém escreveu no buffer só por trocar de aba.
        #expect(b.escritas == 0)
    }

    @Test func despejadoVoltaComCursorERolagem() throws {
        let longo = (1 ... 400).map { "linha \($0)" }.joined(separator: "\n")
        let (c, host, b, s) = montar(["p:a.js": longo, "p:b.js": "b", "p:c.js": "c"], capacidade: 2)
        mostrar(c, vista("p:a.js", b), em: host)
        let a = try #require(c.textView)
        a.selectedRange = NSRange(location: 50, length: 3)
        a.layoutIfNeeded()
        a.contentOffset = CGPoint(x: 0, y: 400)

        mostrar(c, vista("p:b.js", b), em: host)
        mostrar(c, vista("p:c.js", b), em: host)
        // Capacidade 2: o de "a" era o mais antigo fora da tela e foi embora.
        #expect(s.sessao("p:a.js") == nil)
        #expect(s.estadoSalvo("p:a.js")?.selecao == NSRange(location: 50, length: 3))

        mostrar(c, vista("p:a.js", b), em: host)
        let novo = try #require(c.textView)
        #expect(novo !== a)
        #expect(novo.selectedRange == NSRange(location: 50, length: 3))
        #expect(abs(novo.contentOffset.y - 400) < 1)
        #expect(s.sessoes.count <= 2)
    }

    @Test func fecharAbaSoltaOEditor() {
        let (c, host, b, s) = montar(["p:a.js": "a", "p:b.js": "b"])
        mostrar(c, vista("p:a.js", b), em: host)
        mostrar(c, vista("p:b.js", b), em: host)
        #expect(s.sessao("p:a.js") != nil)
        // "a" fechou; "b" está na tela e continua.
        s.manter(prefixo: "p:", abertos: ["p:b.js"])
        #expect(s.sessao("p:a.js") == nil)
        #expect(s.sessao("p:b.js") != nil)
        // Fechar a que está na tela: sai quando a tela trocar.
        s.manter(prefixo: "p:", abertos: [])
        #expect(s.sessao("p:b.js") != nil)
        b.textos["p:c.js"] = "c"
        mostrar(c, vista("p:c.js", b), em: host)
        #expect(s.sessao("p:b.js") == nil)
        // Outro projeto não é tocado.
        b.textos["q:x.js"] = "x"
        mostrar(c, vista("q:x.js", b), em: host)
        s.manter(prefixo: "p:", abertos: [])
        #expect(s.sessao("q:x.js") != nil)
    }

    @Test func textoDeForaEntraSemApagarODesfazer() throws {
        let (c, host, b, _) = montar(["p:a.js": "um\n"])
        mostrar(c, vista("p:a.js", b), em: host)
        let tv = try #require(c.textView)
        tv.selectedRange = NSRange(location: 3, length: 0)
        tv.insertText("dois")
        let escritas = b.escritas
        // O disco mudou (checkout, agente): o buffer troca por fora.
        b.textos["p:a.js"] = "do disco\n"
        mostrar(c, vista("p:a.js", b), em: host)
        #expect(tv.text == "do disco\n")
        #expect(c.textoAtual == "do disco\n")
        // Aplicar o que veio do buffer não escreve de volta nele.
        #expect(b.escritas == escritas)
        tv.undoManager?.undo()
        #expect(tv.text == "um\ndois")
        tv.undoManager?.undo()
        #expect(tv.text == "um\n")
    }

    @Test func trocarATemaOuFonteNaoApagaODesfazer() throws {
        let (c, host, b, _) = montar(["p:a.js": "a"])
        mostrar(c, vista("p:a.js", b), em: host)
        let tv = try #require(c.textView)
        tv.selectedRange = NSRange(location: 1, length: 0)
        tv.insertText("b")
        var maior = EditorPrefs()
        maior.fontSize = 18
        mostrar(c, vista("p:a.js", b, prefs: maior), em: host)
        #expect(c.sessao?.assinatura.fontSize == 18)
        tv.undoManager?.undo()
        #expect(tv.text == "a")
    }

    @Test func comentarEhUmPassoSoNoDesfazer() throws {
        let (c, host, b, _) = montar(["p:a.js": "a();\nb();\n"])
        mostrar(c, vista("p:a.js", b), em: host)
        let tv = try #require(c.textView)
        // Digitação ainda aberta no grupo de um segundo do Runestone.
        tv.selectedRange = NSRange(location: 10, length: 0)
        tv.insertText("c();")
        tv.selectedRange = NSRange(location: 0, length: 10)
        c.executar(.alternarComentario)
        #expect(tv.text == "// a();\n// b();\nc();")
        #expect(b.textos["p:a.js"] == "// a();\n// b();\nc();")
        tv.undoManager?.undo()
        #expect(tv.text == "a();\nb();\nc();")
        tv.undoManager?.undo()
        #expect(tv.text == "a();\nb();\n")
    }

    @Test func duplicarApagarERecuarPeloCoordenador() throws {
        let (c, host, b, _) = montar(["p:a.js": "a\nb"])
        mostrar(c, vista("p:a.js", b), em: host)
        let tv = try #require(c.textView)
        tv.selectedRange = NSRange(location: 0, length: 0)
        c.executar(.duplicarLinhas)
        #expect(tv.text == "a\na\nb")
        #expect(tv.selectedRange == NSRange(location: 2, length: 0))
        c.executar(.apagarLinhas)
        #expect(tv.text == "a\nb")
        // O recuo vem das preferências em `updateUIView`, que aqui não roda.
        tv.indentStrategy = .space(length: 2)
        tv.selectedRange = NSRange(location: 0, length: 0)
        c.executar(.indentar)
        #expect(tv.text.hasPrefix("  a"))
        c.executar(.desindentar)
        #expect(tv.text == "a\nb")
        tv.undoManager?.undo()
        #expect(tv.text.hasPrefix("  a"))
    }

    @Test func irParaLinhaEColuna() throws {
        let (c, host, b, _) = montar(["p:a.js": "abc\ndef\nghi"])
        mostrar(c, vista("p:a.js", b), em: host)
        let tv = try #require(c.textView)
        c.irPara(AlvoDeLinha(linha: 2, coluna: 3))
        #expect(tv.selectedRange == NSRange(location: 6, length: 0))
        c.irPara(AlvoDeLinha(linha: 40, coluna: 1))
        #expect(tv.selectedRange == NSRange(location: 8, length: 0))
    }

    @Test func problemaNoCursorAbreOBalaoEAndaAteOProximo() throws {
        let (c, host, b, _) = montar(["p:a.js": "ok\nruim(\nok"])
        mostrar(c, vista("p:a.js", b), em: host)
        let tv = try #require(c.textView)
        c.issues = [EditorIssue(line: 2, column: 5, length: 1, severity: .error, message: "falta )", fonte: "sintaxe")]
        tv.selectedRange = NSRange(location: 0, length: 0)
        c.executar(.mostrarProblema)
        #expect(c.linhaDe(tv.selectedRange.location) == 1)
        #expect(c.problemaVisivel)
        #expect(c.balao.mensagens.map(\.message) == ["falta )"])
        // Mudou o texto: o balão fecha.
        tv.insertText("x")
        c.conferirBalao()
        #expect(!c.problemaVisivel)
    }

    @Test func doisHostsComOMesmoDocumentoNaoDividemOEditor() throws {
        let (c, host, b, s) = montar(["p:a.js": "a"])
        mostrar(c, vista("p:a.js", b), em: host)
        let editor = try #require(c.textView)
        // Troca de modo: o host novo nasce e pede o mesmo documento.
        let outroHost = HostDoEditor(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let outro = CodeEditorView.Coordinator(parent: vista("p:a.js", b), sessoes: s)
        mostrar(outro, vista("p:a.js", b), em: outroHost)
        #expect(outro.textView === editor)
        #expect(editor.superview === outroHost)
        #expect(c.textView == nil)
        // O velho foi desmontado: o editor continua com o novo.
        c.desmontar()
        #expect(editor.superview === outroHost)
        #expect(s.sessao("p:a.js")?.coordenador === outro)
    }
}
