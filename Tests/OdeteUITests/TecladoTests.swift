import XCTest

/// No iPhone o teclado cobre a barra de abas.
///
/// Sem jeito de fechá-lo, a pessoa fica presa na tela do agente — não dá para voltar
/// aos arquivos, ao terminal, a nada. O campo é um `UITextView`, então não há
/// `@FocusState` para zerar nem tecla de esconder como no iPad.
final class TecladoTests: XCTestCase {
    @MainActor
    func testDaParaFecharOTecladoEVoltarParaAsAbas() throws {
        let app = XCUIApplication()
        app.launch()

        let agente = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Agent")).firstMatch
        let agentePt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Agente")).firstMatch
        let aba = agente.exists ? agente : agentePt
        try XCTSkipUnless(aba.waitForExistence(timeout: 12), "sem barra de abas: layout largo")
        aba.tap()

        let campo = app.textViews.firstMatch
        XCTAssertTrue(campo.waitForExistence(timeout: 6), "não achei o campo de texto")
        campo.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "o teclado não subiu")

        let esconder = app.buttons["Hide the keyboard"].firstMatch.exists
            ? app.buttons["Hide the keyboard"].firstMatch
            : app.buttons["Esconder o teclado"].firstMatch
        XCTAssertTrue(esconder.waitForExistence(timeout: 4), "faltou o botão de esconder o teclado")
        esconder.tap()

        let arquivos = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Files")).firstMatch
        let arquivosPt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Arquivos")).firstMatch
        let voltar = arquivos.exists ? arquivos : arquivosPt
        XCTAssertTrue(
            voltar.waitForExistence(timeout: 6) && voltar.isHittable,
            "a barra de abas continua coberta: a pessoa segue presa"
        )
    }

    /// O bug não era só do agente: busca, renomear, mensagem de commit, URL do remoto,
    /// célula do banco — em toda parte se digita, e em nenhuma dava para fechar o
    /// teclado. A barra acessória vale para qualquer campo, e este teste pega um
    /// `TextField` comum para provar que não é caso especial do compositor.
    @MainActor
    func testQualquerCampoDeTextoTemComoRecolherOTeclado() throws {
        let app = XCUIApplication()
        app.launch()

        let arquivos = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Files")).firstMatch
        let arquivosPt = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Arquivos")).firstMatch
        let aba = arquivos.exists ? arquivos : arquivosPt
        try XCTSkipUnless(aba.waitForExistence(timeout: 12), "sem barra de abas: layout largo")
        aba.tap()

        let campo = app.textFields.firstMatch
        try XCTSkipUnless(campo.waitForExistence(timeout: 8), "nenhum campo de texto nesta aba")
        campo.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 6), "o teclado não subiu")

        let esconder = app.buttons["Hide the keyboard"].firstMatch.exists
            ? app.buttons["Hide the keyboard"].firstMatch
            : app.buttons["Esconder o teclado"].firstMatch
        XCTAssertTrue(
            esconder.waitForExistence(timeout: 4),
            "campo de texto comum ficou sem jeito de recolher o teclado"
        )
        esconder.tap()
        XCTAssertFalse(
            app.keyboards.element.waitForExistence(timeout: 2),
            "o teclado continua na tela depois de pedir para recolher"
        )
    }
}
