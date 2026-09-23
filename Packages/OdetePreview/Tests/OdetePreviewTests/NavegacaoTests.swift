import Foundation
@testable import OdetePreview
import Testing
import WebKit

/// O que o painel carrega e o que ele manda para o Safari.
///
/// O painel é o preview do projeto da pessoa, não um navegador. Seguir qualquer link
/// fazia dele um navegador sem limite — "acesso irrestrito à web" para a App Store, que
/// leva o app inteiro a 17+. Errar para o outro lado é pior ainda: bloquear o servidor
/// de desenvolvimento deixa o preview em branco e ninguém entende por quê.
struct NavegacaoTests {
    func doProjeto(_ s: String) -> Bool {
        PreviewView.Coordinator.doProjeto(URL(string: s)!)
    }

    @Test func carregaOProjeto() {
        #expect(doProjeto("odete://local/index.html"))
        #expect(doProjeto("http://127.0.0.1:5173/"))
        #expect(doProjeto("http://localhost:3000/rota?x=1"))
        #expect(doProjeto("http://LocalHost:5173/"))
        #expect(doProjeto("https://127.0.0.1:8443/"))
        #expect(doProjeto("about:blank"))
    }

    @Test func mandaORestoParaOSafari() {
        #expect(!doProjeto("https://apple.com"))
        #expect(!doProjeto("http://example.com/localhost"))
        #expect(!doProjeto("https://esm.sh/react@19"))
        #expect(!doProjeto("https://github.com/OkamiOps/odete-ide"))
    }

    /// Um host que só *parece* local não vale: `localhost.evil.com` é de terceiro.
    @Test func naoCaiEmHostParecido() {
        #expect(!doProjeto("http://localhost.evil.com/"))
        #expect(!doProjeto("http://127.0.0.1.evil.com/"))
        #expect(!doProjeto("http://notlocalhost/"))
    }

    @Test func esquemaDesconhecidoNaoPassa() {
        #expect(!doProjeto("tel:+4917922105"))
        #expect(!doProjeto("mailto:a@b.com"))
        #expect(!doProjeto("itms-apps://apps.apple.com/app/id123"))
    }
}

/// A regra existe no código — mas o WebKit precisa mesmo chamá-la.
///
/// `decidePolicyFor` tem versão com callback e versão assíncrona. Se a que está escrita
/// não for a que o WebKit chama, nada é bloqueado e o painel continua navegando para
/// qualquer lugar — em silêncio, sem erro de compilação. Aí declarar "sem acesso
/// irrestrito à web" para a App Store seria declaração falsa. Este teste carrega um
/// endereço de fora num WKWebView de verdade e cobra a recusa.
@Suite(.serialized)
@MainActor
struct PoliticaDeNavegacaoTests {
    /// Espera a condição acontecer, em vez de dormir um tempo fixo.
    ///
    /// Aqui estava `Task.sleep(for: .seconds(2))`, e dois segundos são bastante num
    /// simulador quente e pouco num simulador que o `xcodebuild` acabou de ligar: o
    /// WebKit ainda está subindo o processo de conteúdo quando o teste já foi cobrar o
    /// resultado. Isso falhava as duas checagens de uma vez, e por um motivo que não é o
    /// que elas medem. Esperando pela condição, o caso rápido termina em milissegundos e
    /// o lento tem folga.
    func espera(_ prazo: Duration = .seconds(20), ate condicao: () -> Bool) async {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim, !condicao() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func recusaEnderecoDeFora() async throws {
        let model = PreviewModel(root: FileManager.default.temporaryDirectory)
        let coord = PreviewView.Coordinator(model: model)
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480))
        wv.navigationDelegate = coord
        coord.webView = wv

        try wv.load(URLRequest(url: #require(URL(string: "https://example.com/"))))
        await espera { model.console.contains { $0.text.contains("example.com") } }

        let recusou = model.console.contains { $0.text.contains("example.com") }
        #expect(recusou, "a política não foi chamada: o painel carregaria qualquer site")
        #expect(wv.backForwardList.currentItem == nil, "a página de fora não pode ter entrado")
    }

    /// O erro para o outro lado é pior: bloquear o próprio projeto deixa o preview em
    /// branco e ninguém descobre por quê.
    @Test(.semNavegadorNoCI) func carregaAPaginaDoProjeto() async throws {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-nav-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        try "<h1>oi</h1>".write(to: raiz.appending(path: "index.html"), atomically: true, encoding: .utf8)

        let model = PreviewModel(root: raiz)
        let coord = PreviewView.Coordinator(model: model)
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(StaticScheme(root: raiz), forURLScheme: StaticScheme.scheme)
        let wv = WKWebView(frame: .init(x: 0, y: 0, width: 320, height: 480), configuration: cfg)
        wv.navigationDelegate = coord
        coord.webView = wv

        wv.load(URLRequest(url: model.staticURL()))
        await espera { !wv.isLoading && wv.backForwardList.currentItem != nil }

        #expect(wv.backForwardList.currentItem != nil, "a página do projeto foi bloqueada")
        let texto = try await wv.evaluateJavaScript("document.body.innerText") as? String
        #expect(texto?.contains("oi") == true)
    }
}
