import Foundation
@testable import OdetePreview
import Testing
import WebKit

/// O console é história; os problemas são da página que está no painel agora.
///
/// Com um erro de build no dev server, o overlay escreve o erro no console. Consertado o
/// arquivo, a página recarrega limpa — e o erro seguia contado no painel Problemas e na
/// barra de status até alguém limpar o console à mão.
@MainActor
struct ErrosDaPaginaTests {
    func modelo() -> PreviewModel {
        PreviewModel(root: FileManager.default.temporaryDirectory)
    }

    @Test func recargaTiraOErroDosProblemasEDeixaNoConsole() {
        let m = modelo()
        m.paginaNova(URL(string: "http://127.0.0.1:5173/"))
        m.log(.error, "src/App.tsx:17: Unexpected closing \"headr\" tag")
        m.log(.log, "oi")
        #expect(m.errosDaPagina.map(\.text) == ["src/App.tsx:17: Unexpected closing \"headr\" tag"])
        #expect(m.errorCount == 1)

        m.paginaNova(URL(string: "http://127.0.0.1:5173/"))
        #expect(m.errosDaPagina.isEmpty, "o erro da página anterior seguiu como problema")
        #expect(m.errorCount == 0)
        #expect(m.console.contains { $0.level == .error && $0.text.contains("headr") }, "o console perdeu a história")
    }

    /// Erro que a página nova escreve é problema de agora.
    @Test func erroDaPaginaNovaConta() {
        let m = modelo()
        m.log(.error, "velho")
        m.paginaNova(URL(string: "http://127.0.0.1:5173/"))
        m.log(.error, "novo")
        #expect(m.errosDaPagina.map(\.text) == ["novo"])
    }

    /// A troca de página ganha uma linha no console, para o erro lá de cima não parecer
    /// da página de agora — mas só quando a anterior escreveu algo: recargas seguidas de
    /// páginas caladas não enchem o console de linhas iguais.
    @Test func linhaQueMarcaATroca() {
        let m = modelo()
        m.paginaNova(URL(string: "http://127.0.0.1:5173/"))
        #expect(m.console.isEmpty, "a primeira página não tem o que separar")
        m.log(.error, "falhou")
        m.paginaNova(URL(string: "http://127.0.0.1:5173/"))
        #expect(m.console.count == 2)
        #expect(m.console.last?.level == .info)
        #expect(m.console.last?.text.contains("http://127.0.0.1:5173/") == true)
        m.paginaNova(URL(string: "http://127.0.0.1:5173/"))
        #expect(m.console.count == 2, "página calada ganhou outra linha de troca")
        #expect(m.errosDaPagina.isEmpty)
    }

    /// Servidor parou e o painel voltou para "nada rodando": não há página, não há erro
    /// de página.
    @Test func semPaginaSemErro() {
        let m = modelo()
        m.log(.error, "falhou")
        m.go(nil)
        #expect(m.errosDaPagina.isEmpty)
        #expect(m.console.count == 1)
    }

    /// Limpar o console continua limpando tudo.
    @Test func limparConsole() {
        let m = modelo()
        m.log(.error, "falhou")
        m.clearConsole()
        #expect(m.errosDaPagina.isEmpty && m.console.isEmpty)
    }
}

/// A marca só vale se o WebKit avisar a recarga que acontece dentro da página.
///
/// O dev server recarrega o Preview com `location.reload()`, de dentro da página, e o
/// modelo não fica sabendo por outro caminho. Este teste faz a mesma coisa num WKWebView
/// de verdade, com a ponte do console ligada, e cobra que o erro saia dos problemas.
@Suite(.serialized)
@MainActor
struct RecargaDentroDaPaginaTests {
    func espera(_ prazo: Duration = .seconds(20), ate condicao: () -> Bool) async {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim, !condicao() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test(.semNavegadorNoCI) func locationReloadLimpaOsProblemas() async throws {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-recarga-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        let index = raiz.appending(path: "index.html")
        // O overlay do dev server é isto: um script que joga o erro no console.
        try "<h1>quebrado</h1><script>console.error('src/App.tsx:17: Unexpected closing tag')</script>"
            .write(to: index, atomically: true, encoding: .utf8)

        let model = PreviewModel(root: raiz)
        let coord = PreviewView.Coordinator(model: model)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(StaticScheme(root: raiz), forURLScheme: StaticScheme.scheme)
        cfg.userContentController.add(coord, name: "odete")
        cfg.userContentController.addUserScript(WKUserScript(
            source: PreviewView.bridge,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        ))
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480), configuration: cfg)
        wv.navigationDelegate = coord
        coord.webView = wv
        defer { cfg.userContentController.removeScriptMessageHandler(forName: "odete") }

        wv.load(URLRequest(url: model.staticURL()))
        await espera { model.errorCount == 1 }
        #expect(model.errorCount == 1, "o erro da página não chegou ao modelo")

        // Consertado o arquivo, a página recarrega sozinha, como o dev server faz.
        try "<h1>ok</h1><script>console.log('pronto')</script>".write(to: index, atomically: true, encoding: .utf8)
        _ = try? await wv.evaluateJavaScript("location.reload()")
        await espera { model.console.contains { $0.text == "pronto" } }

        #expect(model.console.contains { $0.text == "pronto" }, "a página não recarregou")
        #expect(model.errosDaPagina.isEmpty, "o erro de antes da recarga seguiu como problema")
        #expect(model.console.contains { $0.level == .error }, "o console perdeu o erro de antes")
    }
}
