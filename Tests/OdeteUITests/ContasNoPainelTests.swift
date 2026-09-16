import XCTest

/// Tocar na conta no topo do painel do agente tem que abrir a lista.
///
/// O popover abria com altura zero — só a setinha aparecia no alto do painel, e não
/// havia nada para tocar. Parecia que o botão estava morto, e o único caminho para
/// conectar era pelos Ajustes. Nenhum teste de unidade vê isso: o botão existia, a
/// ação disparava, o conteúdo é que não tinha tamanho.
final class ContasNoPainelTests: XCTestCase {
    func botao(_ app: XCUIApplication, _ pt: String, _ en: String) -> XCUIElement {
        for rotulo in [pt, en] {
            let e = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", rotulo)).firstMatch
            if e.exists {
                return e
            }
        }
        return app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", en)).firstMatch
    }

    @MainActor
    func testTocarNaContaAbreALista() {
        let app = XCUIApplication()
        app.launch()

        // O painel do agente precisa estar à vista; no layout compacto ele é uma aba.
        let aba = botao(app, "Agente", "Agent")
        if aba.exists {
            aba.tap()
        }

        let conta = app.buttons["Conta"].firstMatch.exists
            ? app.buttons["Conta"].firstMatch
            : app.buttons["Account"].firstMatch
        XCTAssertTrue(conta.waitForExistence(timeout: 12), "não achei o botão da conta")
        conta.tap()

        // O popover tem que trazer conteúdo tocável, não só a setinha.
        let gerenciar = botao(app, "Contas de IA…", "AI accounts…")
        XCTAssertTrue(
            gerenciar.waitForExistence(timeout: 6),
            "o popover abriu vazio: nada para tocar"
        )
        // No iPhone o popover vira sheet e sobe animado: perguntar por `isHittable` no
        // instante seguinte ao toque pega a animação no meio.
        let alcancavel = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: gerenciar)
        wait(for: [alcancavel], timeout: 6)
    }
}
