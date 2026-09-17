import XCTest

/// Tocar na conta no topo do painel do agente tem que abrir a lista.
///
/// Já falhou de dois jeitos, e os dois só aparecem com o app na tela. Primeiro o popover
/// abria com altura zero, porque um `ScrollView` não tem tamanho próprio. Depois, com a
/// medida no lugar, ele voltou a abrir como uma **linha atravessada na tela**: o tamanho
/// de classe lido de dentro do popover responde `.compact` mesmo no iPad — quem está
/// sendo medido é o popover, que é estreito, e não a tela — e o iPad caía no caminho do
/// iPhone, sem largura e sem altura.
///
/// Por isso o teste não pergunta só se existe: pergunta o tamanho. Uma linha de 1 pt de
/// altura, ou um conteúdo de 900 pt de largura dentro de um popover de 280, são as duas
/// formas que esse bug já teve.
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
    func contaVisivel(_ app: XCUIApplication, _ prazo: TimeInterval) -> XCUIElement? {
        for id in ["Conta", "Account"] {
            let e = app.buttons[id].firstMatch
            if e.waitForExistence(timeout: prazo) {
                return e
            }
        }
        return nil
    }

    @MainActor
    func abreALista(_ app: XCUIApplication) -> XCUIElement {
        // O painel do agente precisa estar à vista. O botão do rail alterna, e o estado
        // vem do que ficou guardado da última sessão — e girar o iPad pode fechar a
        // coluna. Então: procura; se não achar, alterna e procura de novo, dos dois lados.
        var conta = contaVisivel(app, 12)
        if conta == nil {
            let aba = botao(app, "Agente", "Agent")
            for _ in 0 ..< 2 where conta == nil {
                guard aba.exists else { break }
                aba.tap()
                conta = contaVisivel(app, 4)
            }
        }
        XCTAssertNotNil(conta, "não achei o botão da conta")
        guard let conta else { return app.buttons.firstMatch }
        conta.tap()

        let gerenciar = botao(app, "Contas de IA…", "AI accounts…")
        XCTAssertTrue(
            gerenciar.waitForExistence(timeout: 6),
            "o popover abriu vazio: nada para tocar"
        )
        // No iPhone o popover vira sheet e sobe animado: perguntar por `isHittable` no
        // instante seguinte ao toque pega a animação no meio.
        let alcancavel = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: gerenciar)
        wait(for: [alcancavel], timeout: 6)
        return gerenciar
    }

    @MainActor
    func confere(_ app: XCUIApplication, _ gerenciar: XCUIElement) {
        let janela = app.windows.firstMatch.frame
        let r = gerenciar.frame

        XCTAssertGreaterThan(
            r.height, 24,
            "a linha de contas ficou com \(Int(r.height)) pt de altura: o popover abriu achatado"
        )
        XCTAssertTrue(
            janela.insetBy(dx: -1, dy: -1).contains(r),
            "a lista abriu fora da tela: \(r) numa janela de \(janela)"
        )
        // No iPad o popover tem 280 pt. Espalhar-se pela tela é o sinal de que o conteúdo
        // caiu no caminho do iPhone, que é `maxWidth: .infinity`.
        if janela.width > 1000 {
            XCTAssertLessThan(
                r.width, 340,
                "o conteúdo esticou para \(Int(r.width)) pt numa tela de \(Int(janela.width)): "
                    + "o popover está se achando estreito"
            )
        }
    }

    @MainActor
    func testTocarNaContaAbreALista() {
        let app = XCUIApplication()
        app.launch()
        confere(app, abreALista(app))
    }

    /// O iPad se usa deitado, e é deitado que a linha da conta encosta no topo da tela —
    /// que é onde um popover sem espaço na direção escolhida se achata.
    @MainActor
    func testAbreNasDuasOrientacoes() {
        defer { XCUIDevice.shared.orientation = .landscapeLeft }
        for orientacao in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientacao
            // Uma volta, um app. Fechar o popover e seguir deixava a segunda volta
            // dependendo de onde o toque de fora caiu, e o teste passava a falhar por
            // um motivo que não é o que ele mede.
            let app = XCUIApplication()
            app.launch()
            confere(app, abreALista(app))
            app.terminate()
        }
    }
}
