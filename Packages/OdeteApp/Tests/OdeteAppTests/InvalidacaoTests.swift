import Foundation
import Observation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// Marca que o aviso da observação chegou. O `onChange` roda fora do ator de quem lê.
final class Aviso: @unchecked Sendable {
    var disparou = false
}

/// Uma tecla só pode avisar quem mostra o texto, o cursor e o ponto de alteração da aba.
/// Estes testes leem o que as views leem, com `withObservationTracking`, e conferem quem
/// é avisado quando o texto, a análise ou o console mudam.
@MainActor
struct InvalidacaoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> (WorkspaceModel, ChromeState, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-inv-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = false
        let accounts = AccountStore(url: root.appending(path: "accounts.json"), keychain: MemorySecrets())
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: accounts,
            aiAccounts: AIAccountStore(url: root.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        return (ws, chrome, store.url(for: p))
    }

    /// `true` se `mudar` avisou quem leu com `ler`.
    func avisa(_ ler: () -> Void, _ mudar: () -> Void) -> Bool {
        let aviso = Aviso()
        withObservationTracking(ler) { aviso.disparou = true }
        mudar()
        return aviso.disparou
    }

    func erro(_ linha: Int, _ msg: String = "quebrou") -> LintIssue {
        LintIssue(rule: "t", message: msg, severity: .error, line: linha, column: 1, length: 1)
    }

    func aviso(_ linha: Int, _ msg: String = "cuidado") -> LintIssue {
        LintIssue(rule: "a", message: msg, severity: .warning, line: linha, column: 1, length: 1)
    }

    // MARK: escrita só quando muda

    /// A análise reescreve o lint a cada pausa na digitação, quase sempre igual. Escrever o
    /// mesmo valor por índice não pode avisar ninguém.
    @Test func escritaIgualNaoAvisa() throws {
        let (ws, _, _) = try make()
        ws.lint["a.js"] = [erro(1)]
        #expect(!avisa({ _ = ws.lint }, { ws.lint["a.js"] = [erro(1)] }))
        #expect(avisa({ _ = ws.lint }, { ws.lint["a.js"] = [erro(2)] }))
        ws.outlines["a.js"] = []
        #expect(!avisa({ _ = ws.outlines }, { ws.outlines["a.js"] = [] }))
        #expect(!avisa({ _ = ws.links }, { ws.links["a.js"] = nil }))
        #expect(!avisa({ _ = ws.gutter }, { ws.gutter = [:] }))
    }

    /// Uma tecla (depois da primeira, que suja a aba) não avisa quem mostra análise,
    /// problemas, abas ou pontos de alteração.
    @Test func teclaSoAvisaOTextoEOCursor() throws {
        let (ws, _, _) = try make()
        ws.openFile("index.html")
        ws.setText("<h1>a</h1>\n", for: "index.html")
        let lerOResto = {
            _ = ws.lint
            _ = ws.syntax
            _ = ws.outlines
            _ = ws.links
            _ = ws.tabs
            _ = ws.sujos
            _ = ws.contagemDeProblemas
            _ = ws.filePaths
            _ = ws.scripts
        }
        #expect(!avisa(lerOResto) { ws.setText("<h1>ab</h1>\n", for: "index.html") })
        #expect(avisa({ _ = ws.buffers }, { ws.setText("<h1>abc</h1>\n", for: "index.html") }))
        #expect(avisa({ _ = ws.cursorOffset }, { ws.cursorOffset = 7 }))
        #expect(!avisa({ _ = ws.cursorOffset }, { ws.cursorOffset = 7 }), "mesmo lugar, nenhum aviso")
    }

    /// O ponto de alteração da árvore lê `sujos`, que só muda quando uma aba suja ou limpa.
    @Test func sujosAcompanhaAsAbas() throws {
        let (ws, _, _) = try make()
        ws.openFile("index.html")
        #expect(ws.sujos.isEmpty)
        #expect(avisa({ _ = ws.sujos }, { ws.setText("x", for: "index.html") }))
        #expect(ws.sujos == ["index.html"])
        #expect(!avisa({ _ = ws.sujos }, { ws.setText("xy", for: "index.html") }))
        ws.save("index.html")
        #expect(ws.sujos.isEmpty)
    }

    // MARK: problemas

    /// A contagem é guardada e refeita quando uma fonte muda; linha de console que não é
    /// erro não avisa quem mostra o número.
    @Test func contagemDeProblemasGuardada() async throws {
        let (ws, _, _) = try make()
        // Aba posta à mão, sem abrir o arquivo: a análise de verdade chegaria depois e
        // reescreveria o lint do teste.
        ws.tabs.append(EditorTab(path: "notas.txt"))
        try await Task.sleep(for: .milliseconds(50))
        let base = ws.contagemDeProblemas
        ws.lint["notas.txt"] = [erro(1), aviso(2)]
        try await Task.sleep(for: .milliseconds(50))
        #expect(ws.contagemDeProblemas.erros == base.erros + 1)
        #expect(ws.contagemDeProblemas.avisos == base.avisos + 1)
        #expect(ws.problemCounts.errors == ws.contagemDeProblemas.erros)

        let aviso = Aviso()
        withObservationTracking { _ = ws.contagemDeProblemas } onChange: { aviso.disparou = true }
        ws.preview.log(.log, "só um log")
        try await Task.sleep(for: .milliseconds(50))
        #expect(!aviso.disparou, "log comum não muda a contagem")
        ws.preview.log(.error, "falhou")
        try await Task.sleep(for: .milliseconds(50))
        #expect(aviso.disparou)
        #expect(ws.contagemDeProblemas.erros == base.erros + 2)
    }

    // MARK: barra de status

    @Test func posicaoDoCursorEFimDeLinha() throws {
        let (ws, _, _) = try make()
        ws.buffers["a.txt"] = "um\ndois\r\ntrês"
        ws.cursorOffset = 5
        #expect(ws.posicaoDoCursor(em: "a.txt") == PosicaoDoCursor(linha: 2, coluna: 3))
        #expect(ws.usaCRLF("a.txt"))
        ws.cursorOffset = 0
        #expect(ws.posicaoDoCursor(em: "a.txt") == PosicaoDoCursor(linha: 1, coluna: 1))
        ws.cursorOffset = 999
        #expect(ws.posicaoDoCursor(em: "a.txt") == PosicaoDoCursor(linha: 3, coluna: 5))
        ws.buffers["a.txt"] = "só\nLF"
        #expect(!ws.usaCRLF("a.txt"), "o mapa acompanha o texto novo")
    }

    /// Emoji e acento ocupam mais de uma unidade UTF-16; a coluna conta como o editor.
    @Test func mapaDeLinhasEmUTF16() {
        let texto = "ação 🇧🇷\nsegunda\n"
        let ns = texto as NSString
        let m = LinhasDoTexto(texto)
        #expect(m.inicios == [0, ns.range(of: "segunda").location, ns.length])
        #expect(m.tamanho == ns.length)
        #expect(!m.crlf)
        let fimDaPrimeira = ns.range(of: "\n").location
        #expect(m.posicao(de: fimDaPrimeira) == PosicaoDoCursor(linha: 1, coluna: fimDaPrimeira + 1))
    }

    /// Mesma conta do laço antigo da barra, em cada posição de um texto misturado.
    @Test func mapaBateComAContaAntiga() {
        let texto = "import x\n\nconst 🇧🇷 = 1\r\n  fim"
        let ns = texto as NSString
        let m = LinhasDoTexto(texto)
        for off in 0 ... ns.length {
            var linha = 1, ultimo = 0
            for i in 0 ..< off where ns.character(at: i) == 10 {
                linha += 1
                ultimo = i + 1
            }
            #expect(m.posicao(de: off) == PosicaoDoCursor(linha: linha, coluna: off - ultimo + 1))
        }
    }

    /// O problema mostrado na barra é o da linha do cursor: erro antes de aviso.
    @Test func problemaDaLinhaDoCursor() throws {
        let (ws, _, _) = try make()
        ws.buffers["a.js"] = "um\ndois\ntrês\n"
        ws.lint["a.js"] = [aviso(2, "aviso da dois"), erro(2, "erro da dois"), aviso(3, "só aviso")]
        ws.cursorOffset = 4
        #expect(ws.problemaNaLinhaDoCursor(em: "a.js")?.message == "erro da dois")
        ws.cursorOffset = 9
        #expect(ws.problemaNaLinhaDoCursor(em: "a.js")?.message == "só aviso")
        ws.cursorOffset = 0
        #expect(ws.problemaNaLinhaDoCursor(em: "a.js") == nil)
    }

    // MARK: arrasto dos divisores

    /// Arrastar muda só a medida ao vivo; as preferências (lidas por quase toda view) só
    /// mudam ao soltar.
    @Test func arrastoNaoMexeNasPreferencias() {
        let chrome = ChromeState()
        let largura = chrome.snapshot.sideWidth
        #expect(!avisa({ _ = chrome.snapshot }, { chrome.arrastar(.lado, para: largura + 40) }))
        #expect(chrome.medida(.lado) == largura + 40)
        #expect(chrome.snapshot.sideWidth == largura)
        #expect(avisa({ _ = chrome.snapshot }, { chrome.soltarArrasto() }))
        #expect(chrome.snapshot.sideWidth == largura + 40)
        #expect(chrome.arrasto == nil)
        #expect(chrome.medida(.lado) == largura + 40)
    }
}
