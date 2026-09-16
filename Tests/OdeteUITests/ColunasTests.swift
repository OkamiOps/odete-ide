import XCTest

/// Recolher os dois lados tem que devolver a tela para o centro.
///
/// No iPad, com a barra lateral e o agente fechados, sobrava a coluna do meio com a
/// largura antiga e o resto da tela preto. Num app de escrever código, é a tela inteira
/// virando moldura.
final class ColunasTests: XCTestCase {
    @MainActor
    func testRecolherOsLadosDevolveALarguraAoCentro() throws {
        let app = XCUIApplication()
        app.launch()

        let janela = app.windows.firstMatch
        XCTAssertTrue(janela.waitForExistence(timeout: 12))
        try XCTSkipUnless(janela.frame.width > 1000, "layout estreito: não é o caso de colunas")

        let centro = app.otherElements["colunaCentral"]
        XCTAssertTrue(centro.waitForExistence(timeout: 8), "não achei a coluna central")

        // Os botões do rail alternam, e o estado inicial é o que ficou guardado da última
        // sessão. Então não dá para "fechar": tem que tocar e ficar com o lado em que o
        // centro é maior — que é, por definição, o lado fechado.
        for (pt, en) in [("Agente", "Agent"), ("Arquivos", "Files"), ("Buscar", "Search"), ("Git", "Git")] {
            let b = botao(app, pt, en)
            guard b.exists else { continue }
            let antes = assenta(centro)
            b.tap()
            if assenta(centro) < antes {
                b.tap(); _ = assenta(centro)
            }
        }

        // O rail tem 56 pt; o que sobra é do centro. Uma folga de 8 pt cobre arredondamento.
        let esperado = janela.frame.width - 56
        XCTAssertGreaterThan(
            centro.frame.width, esperado - 8,
            "com os lados recolhidos o centro ficou com \(Int(centro.frame.width)) pt "
                + "numa janela de \(Int(janela.frame.width)) pt: sobra tela preta"
        )
    }

    /// Girar o iPad muda a largura da janela. Se a medida usada para dimensionar as
    /// colunas ficar presa na anterior, o app desenha o rail de uma tela e as colunas de
    /// outra — foi esse o desencontro do bug de recolher os lados.
    @MainActor
    func testGirarNaoDeixaAsColunasPresasNaMedidaAntiga() throws {
        let app = XCUIApplication()
        app.launch()
        let janela = app.windows.firstMatch
        XCTAssertTrue(janela.waitForExistence(timeout: 12))
        try XCTSkipUnless(janela.frame.width > 1000, "layout estreito: não é o caso de colunas")

        let centro = app.otherElements["colunaCentral"]
        XCTAssertTrue(centro.waitForExistence(timeout: 8), "não achei a coluna central")

        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        for orientacao in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientacao
            _ = assenta(centro)
            let largura = janela.frame.width
            guard largura > 1000 else { continue } // em retrato o layout é de abas
            XCTAssertGreaterThan(
                centro.frame.width + 56 + 320, largura,
                "depois de girar o centro ficou com \(Int(centro.frame.width)) pt "
                    + "numa janela de \(Int(largura)) pt"
            )
            XCTAssertLessThanOrEqual(
                centro.frame.width, largura,
                "a coluna ficou maior que a janela: a medida usada é de outra tela"
            )
        }
    }

    /// A largura depois que o painel parou de animar. Ler logo depois do toque pega a
    /// animação no meio, e a comparação "ficou maior ou menor" vira sorteio.
    @MainActor
    private func assenta(_ e: XCUIElement) -> CGFloat {
        var anterior = e.frame.width
        for _ in 0 ..< 20 {
            usleep(100_000)
            let agora = e.frame.width
            if abs(agora - anterior) < 0.5 {
                return agora
            }
            anterior = agora
        }
        return anterior
    }

    private func botao(_ app: XCUIApplication, _ pt: String, _ en: String) -> XCUIElement {
        let a = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", pt)).firstMatch
        return a.exists ? a : app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", en)).firstMatch
    }
}
