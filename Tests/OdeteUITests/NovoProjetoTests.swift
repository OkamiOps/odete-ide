import XCTest

/// A tela de novo projeto precisa deixar escolher onde o projeto vai morar.
///
/// Sem isto, todo projeto nascia na raiz do app e quem trabalha num SSD externo — ou só
/// quer o código num lugar que sobreviva a desinstalar a Odete — ficava sem saída. É um
/// teste de tela porque o defeito era a ausência de uma seção, coisa que nenhum teste de
/// unidade enxerga.
final class NovoProjetoTests: XCTestCase {
    /// O app segue o idioma do aparelho, então cada rótulo é procurado nos dois. O hub
    /// mostra "Novo projeto" em dois lugares (o cartão vazio e a barra), por isso o
    /// `firstMatch`.
    /// Casa pelo começo do rótulo: uma linha com título e subtítulo chega à árvore de
    /// acessibilidade como um rótulo só, "Pasta da Odete, Dentro do app".
    func botao(_ app: XCUIApplication, _ pt: String, _ en: String) -> XCUIElement {
        for rotulo in [pt, en] {
            let e = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rotulo)).firstMatch
            if e.exists {
                return e
            }
        }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", en)).firstMatch
    }

    /// O app reabre o último projeto, então nem sempre começa no hub.
    func vaiAoHub(_ app: XCUIApplication) {
        if botao(app, "Novo projeto", "New project").waitForExistence(timeout: 12) {
            return
        }
        let arquivos = botao(app, "Arquivos", "Files")
        if arquivos.exists {
            arquivos.tap()
        }
        let projetos = botao(app, "Projetos", "Projects")
        if projetos.waitForExistence(timeout: 5) {
            projetos.tap()
        }
    }

    @MainActor
    func testDaParaEscolherOndeOProjetoVaiMorar() {
        let app = XCUIApplication()
        app.launch()
        vaiAoHub(app)

        let novo = botao(app, "Novo projeto", "New project")
        XCTAssertTrue(novo.waitForExistence(timeout: 8), "não cheguei ao hub")
        novo.tap()

        let daOdete = botao(app, "Pasta da Odete", "Odete folder")
        XCTAssertTrue(daOdete.waitForExistence(timeout: 6), "faltou a opção da pasta padrão")
        XCTAssertTrue(
            botao(app, "Outra pasta…", "Another folder…").exists,
            "faltou a opção de escolher outra pasta"
        )

        // tempo para a captura de fora
        sleep(12)
    }
}
