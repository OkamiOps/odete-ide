import OdeteCore
@testable import OdeteEditor
import Runestone
import SwiftUI
import Testing
import UIKit

/// Perdas silenciosas no editor: CRLF, Tab, pedidos que se repetem, texto de fora.
///
/// Cada teste aqui falhava antes da correção que ele cobre.
@MainActor
struct PerdasNoEditorTests {
    @MainActor
    final class Buffer {
        var texto: String
        init(_ texto: String) {
            self.texto = texto
        }
    }

    func vista(_ b: Buffer, doc: String = "p:a.js", config: ConfigDoArquivo? = nil) -> CodeEditorView {
        CodeEditorView(
            text: Binding(get: { b.texto }, set: { b.texto = $0 }),
            documentId: doc,
            language: .javascript,
            palette: ThemePalette.all[0],
            prefs: EditorPrefs(),
            config: config
        )
    }

    /// Segura os coordenadores até o fim do teste: o editor só guarda o delegate (o
    /// coordenador) de forma fraca, e sem dono ele some e as teclas passam direto.
    final class Vivos {
        var coordenadores: [CodeEditorView.Coordinator] = []
    }

    let vivos = Vivos()

    func montar(
        _ texto: String,
        config: ConfigDoArquivo? = nil
    ) throws -> (CodeEditorView.Coordinator, TextView, Buffer) {
        let b = Buffer(texto)
        let v = vista(b, config: config)
        let host = HostDoEditor(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let c = CodeEditorView.Coordinator(parent: v, sessoes: SessoesDoEditor(capacidade: 2))
        vivos.coordenadores.append(c)
        c.parent = v
        c.exibir(em: host)
        c.conferirTema()
        let tv = try #require(c.textView)
        return (c, tv, b)
    }

    // MARK: - CRLF

    /// O Runestone insere `\n` por padrão, e a quebra detectada ao abrir era jogada fora.
    @Test func enterEmArquivoCRLFInsereCRLF() throws {
        let (_, tv, b) = try montar("a\r\nb")
        tv.selectedRange = NSRange(location: 1, length: 0)
        tv.insertText("\n")
        #expect(tv.text == "a\r\n\r\nb")
        #expect(b.texto == "a\r\n\r\nb")
    }

    /// "Substituir todos" trocava o documento inteiro, e o Runestone convertia todas as
    /// quebras dele para LF.
    @Test func substituirTodosNaoConverteCRLF() throws {
        let original = "a\r\nfoo\r\nfoo\r\n"
        let (c, tv, b) = try montar(original)
        c.find = EditorFind(texto: "foo")
        c.substituir(tv, EditorReplace(por: "bar", todos: true, token: 1))
        #expect(tv.text == "a\r\nbar\r\nbar\r\n")
        #expect(b.texto == tv.text)
        tv.undoManager?.undo()
        #expect(tv.text == original)
    }

    /// Troca com quebra dentro, num arquivo CRLF: entra CRLF, não LF nem `\r\r\n`.
    @Test func trocaComQuebraEmArquivoCRLF() throws {
        let (c, tv, _) = try montar("x\r\ny\r\n")
        c.find = EditorFind(texto: "x")
        c.substituir(tv, EditorReplace(por: "1\n2", todos: true, token: 1))
        #expect(tv.text == "1\r\n2\r\ny\r\n")
    }

    /// Texto que já chega com `\r\n` (colar, envolver a seleção) num arquivo CRLF: o
    /// Runestone o estragava para `\r\r\n\r\n`.
    @Test func textoComCRLFEntraInteiro() throws {
        let (_, tv, b) = try montar("a\r\nb\r\n")
        tv.replace(NSRange(location: 0, length: 1), withText: "x\r\ny")
        #expect(tv.text == "x\r\ny\r\nb\r\n")
        #expect(b.texto == tv.text)
    }

    /// ⌘⇧K na última linha de um arquivo CRLF deixava um `\r` solto.
    @Test func apagarUltimaLinhaCRLF() throws {
        let ns = "a\r\nb" as NSString
        let e = try #require(EdicaoDeLinhas.apagar(ns, selecao: NSRange(location: 4, length: 0)))
        #expect(ns.replacingCharacters(in: e.faixa, with: e.texto) == "a")
        // Cursor na coluna 1 da linha apagada: fica na coluna 1 da de cima.
        #expect(e.selecao == NSRange(location: 1, length: 0))
    }

    /// Duplicar a última linha (sem quebra no fim) num arquivo CRLF usava `\n`.
    @Test func duplicarUltimaLinhaCRLF() {
        let ns = "a\r\nb" as NSString
        let e = EdicaoDeLinhas.duplicar(ns, selecao: NSRange(location: 3, length: 0))
        #expect(ns.replacingCharacters(in: e.faixa, with: e.texto) == "a\r\nb\r\nb")
    }

    @Test func minimapaContaLinhasCRLF() {
        #expect(MinimapView.medir("a\r\nb\r\nc", tabWidth: 2).count == 3)
    }

    @Test func apararEQuebraNoFimEmCRLF() {
        #expect(Arrumacao.aparar("a  \r\nb\t\r\nc ") == "a\r\nb\r\nc")
        #expect(Arrumacao.quebraNoFim("a\r\nb") == "a\r\nb\r\n")
        #expect(Arrumacao.quebraNoFim("a\r\n") == "a\r\n")
        #expect(Arrumacao.quebraNoFim("a") == "a\n")
        #expect(Arrumacao.quebraNoFim("a", padrao: .crlf) == "a\r\n")
        // A linha do cursor fica como está.
        #expect(Arrumacao.aparar("a  \nb  \n", preservando: 7) == "a\nb  \n")
    }

    // MARK: - Tab

    /// Com várias linhas selecionadas, o Tab trocava a seleção por um `\t`.
    @Test func tabComSelecaoDeLinhasRecua() throws {
        let (_, tv, b) = try montar("a\nb\n")
        tv.selectedRange = NSRange(location: 0, length: 3)
        tv.insertText("\t")
        #expect(tv.text == "  a\n  b\n")
        #expect(b.texto == tv.text)
    }

    /// Num arquivo de espaços, o Tab inseria um `\t` literal.
    @Test func tabEmArquivoDeEspacosInsereEspacos() throws {
        let (_, tv, _) = try montar("x")
        tv.selectedRange = NSRange(location: 0, length: 0)
        tv.insertText("\t")
        #expect(tv.text == "  x")
        // Da coluna 3, até a próxima parada: mais um espaço só.
        tv.selectedRange = NSRange(location: 3, length: 0)
        tv.insertText("\t")
        #expect(tv.text == "  x ")
    }

    /// O recuo vem do arquivo: quatro espaços num arquivo de quatro, tab num de tabs.
    @Test func recuoVemDoArquivo() throws {
        let (_, quatro, _) = try montar("a {\n    b\n    c\n}\n")
        #expect(quatro.indentStrategy == .space(length: 4))
        let (_, tabs, _) = try montar("a {\n\tb\n\tc\n}\n")
        #expect(tabs.indentStrategy == .tab(length: 2))
        tabs.selectedRange = NSRange(location: 0, length: 0)
        tabs.insertText("\t")
        #expect(tabs.text.hasPrefix("\ta {"))
    }

    /// O `.editorconfig` manda sobre o que o texto usa e sobre os Ajustes.
    @Test func editorConfigMandaNoRecuoENaQuebra() throws {
        let cfg = ConfigDoArquivo(recuo: .tab, larguraDoTab: 8, fimDeLinha: .crlf)
        let (_, tv, _) = try montar("x", config: cfg)
        #expect(tv.indentStrategy == .tab(length: 8))
        // Texto de uma linha não diz a quebra: vale a do `.editorconfig`.
        #expect(tv.lineEndings == .crlf)
    }

    /// ⇧Tab desindenta: a tecla não existia.
    @Test func shiftTabDesindenta() throws {
        let host = HostDoEditor(frame: .zero)
        let comando = host.keyCommands?.first { $0.input == "\t" && $0.modifierFlags == .shift }
        #expect(comando != nil)
        let (c, tv, _) = try montar("  a\n  b\n")
        tv.selectedRange = NSRange(location: 0, length: 7)
        c.executar(.desindentar)
        #expect(tv.text == "a\nb\n")
    }

    /// A tecla ⇥ da barra inseria dois espaços fixos, em qualquer arquivo.
    @Test func teclaDaBarraSegueORecuo() throws {
        let (c, tv, _) = try montar("a {\n    b\n}\n")
        tv.selectedRange = NSRange(location: 0, length: 0)
        c.sessao?.barra.onTab()
        #expect(tv.text.hasPrefix("    a {"))
    }

    // MARK: - Texto que muda por fora

    /// O salvamento que apara espaços devolvia o texto inteiro ao editor, e o cursor ia
    /// parar em outro lugar (o fim do documento, se o texto encolheu).
    @Test func textoDeForaMantemOCursor() throws {
        let (c, tv, _) = try montar("a   \nbcd")
        tv.selectedRange = NSRange(location: 7, length: 0) // antes do "d"
        c.aplicarTextoDeFora("a\nbcd", em: tv)
        #expect(tv.text == "a\nbcd")
        #expect(tv.selectedRange == NSRange(location: 4, length: 0))
        tv.undoManager?.undo()
        #expect(tv.text == "a   \nbcd")
    }

    @Test func recuoDetectadoEmArquivoPequeno() {
        /// `DetectedIndentStrategy` não é `Equatable`: compara pela descrição.
        func recuo(_ t: String) -> String {
            "\(RecuoDoTexto.detectar(t))"
        }
        #expect(recuo("a {\n    b\n}\n") == "space(length: 4)")
        #expect(recuo("a {\n  b {\n    c\n  }\n}\n") == "space(length: 2)")
        #expect(recuo("a {\r\n\tb\r\n}\r\n") == "tab")
        #expect(recuo("x\ny\n") == "unknown")
    }

    @Test func diferencaDeTextoPorLinha() {
        let t = DiferencaDeTexto.trocas(de: "a  \nb\nc  \n", para: "a\nb\nc\n")
        #expect(t == [
            .init(faixa: NSRange(location: 1, length: 2), texto: ""),
            .init(faixa: NSRange(location: 7, length: 2), texto: ""),
        ])
        #expect(DiferencaDeTexto.trocas(de: "igual", para: "igual").isEmpty)
        // Nunca parte um `\r\n` no meio.
        let crlf = DiferencaDeTexto.trocas(de: "a\r\nb", para: "a\nb")
        #expect(crlf.allSatisfy { !($0.texto.hasPrefix("\n") && $0.faixa.location == 2) })
    }

    // MARK: - Pedidos de uso único

    func hospedar(_ v: CodeEditorView) async throws -> UIWindow {
        let janela = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        janela.rootViewController = UIHostingController(rootView: v)
        janela.makeKeyAndVisible()
        janela.rootViewController?.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        return janela
    }

    /// Um editor novo para o mesmo documento (trocar de modo, o modo Dois) refazia a
    /// última substituição, porque cada coordenador nascia sem lembrar dela.
    @Test func substituicaoNaoSeRepeteEmEditorNovo() async throws {
        let b = Buffer("foo")
        let doc = "prova:\(UUID().uuidString).js"
        let v = CodeEditorView(
            text: Binding(get: { b.texto }, set: { b.texto = $0 }),
            documentId: doc,
            language: .javascript,
            palette: ThemePalette.all[0],
            prefs: EditorPrefs(),
            find: EditorFind(texto: "o"),
            replace: EditorReplace(por: "oo", todos: true, token: 7)
        )
        let primeira = try await hospedar(v)
        #expect(b.texto == "foooo")
        let segunda = try await hospedar(v)
        #expect(b.texto == "foooo")
        _ = (primeira, segunda)
    }

    /// O mesmo com o salto de linha: o editor novo voltava o cursor para a linha pedida
    /// antes, por cima de onde a pessoa estava.
    @Test func saltoDeLinhaNaoSeRepeteEmEditorNovo() async throws {
        let b = Buffer("a\nb\nc\nd\n")
        let doc = "prova:\(UUID().uuidString).js"
        let v = CodeEditorView(
            text: Binding(get: { b.texto }, set: { b.texto = $0 }),
            documentId: doc,
            language: .javascript,
            palette: ThemePalette.all[0],
            prefs: EditorPrefs(),
            reveal: (line: 3, token: 9)
        )
        let primeira = try await hospedar(v)
        let tv = try #require(SessoesDoEditor.shared.sessao(doc)?.textView)
        #expect(tv.selectedRange.location == 4)
        tv.selectedRange = NSRange(location: 0, length: 0)
        let segunda = try await hospedar(v)
        #expect(tv.selectedRange == NSRange(location: 0, length: 0))
        _ = (primeira, segunda)
    }

    // MARK: - .editorconfig

    @Test func editorConfigLeSecoesEPadroes() {
        let raiz = """
        root = true

        [*]
        indent_style = space
        indent_size = 2
        end_of_line = lf

        [*.{py,rb}]
        indent_size = 4

        [Makefile]
        indent_style = tab

        [src/**.go]
        indent_style = tab
        tab_width = 8
        """
        let arquivos = [(pasta: "", texto: raiz)]
        let py = EditorConfig.config(para: "lib/a.py", arquivos: arquivos)
        #expect(py.recuo == .espacos && py.tamanhoDoRecuo == 4 && py.fimDeLinha == .lf)
        let js = EditorConfig.config(para: "a.js", arquivos: arquivos)
        #expect(js.tamanhoDoRecuo == 2)
        let make = EditorConfig.config(para: "Makefile", arquivos: arquivos)
        #expect(make.recuo == .tab)
        let go = EditorConfig.config(para: "src/x/y.go", arquivos: arquivos)
        #expect(go.recuo == .tab && go.larguraDoTab == 8)
        // O mais próximo manda; `root = true` corta a subida.
        let perto = [(pasta: "web", texto: "[*.js]\nindent_size = 3\n"), (pasta: "", texto: raiz)]
        #expect(EditorConfig.config(para: "web/a.js", arquivos: perto).tamanhoDoRecuo == 3)
        let comRaiz = [(pasta: "web", texto: "root = true\n[*.css]\nindent_size = 3\n"), (pasta: "", texto: raiz)]
        #expect(EditorConfig.config(para: "web/a.js", arquivos: comRaiz).tamanhoDoRecuo == nil)
        #expect(EditorConfig.config(
            para: "a.txt",
            arquivos: [(pasta: "", texto: "[*]\ntrim_trailing_whitespace = true\ninsert_final_newline = false\n")]
        ).aparar == true)
    }
}
