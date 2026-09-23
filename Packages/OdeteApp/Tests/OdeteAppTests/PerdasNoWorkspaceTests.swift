import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteEditor
import OdeteFiles
import OdeteGit
import OdeteI18n
import Testing

/// Perdas silenciosas entre o editor e o disco: conflito com mudança de fora, recarregar
/// jogando fora o não salvo, trocar tudo, apagar e fechar aba suja, aparar no salvamento.
///
/// Cada teste aqui falhava antes da correção que ele cobre.
@MainActor
struct PerdasNoWorkspaceTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make(autoSave: Bool = false) throws -> (WorkspaceModel, ChromeState, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-perdas-\(UUID().uuidString)")
        let store = ProjectStore(root: base)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = autoSave
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: AccountStore(url: base.appending(path: "accounts.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: base.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        return (ws, chrome, store.url(for: p))
    }

    func disco(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    func escrever(_ root: URL, _ path: String, _ texto: String) throws {
        try texto.write(to: root.appending(path: path), atomically: true, encoding: .utf8)
    }

    // MARK: - 1. Conflito com o disco

    /// Aba suja + arquivo mudado por fora: salvar gravava por cima, calado.
    @Test func salvarNaoGravaPorCimaDeMudancaDeFora() throws {
        let (ws, _, root) = try make()
        ws.openFile("index.html")
        ws.setText("<h1>meu</h1>\n", for: "index.html")
        try escrever(root, "index.html", "<h1>do agente</h1>\n")
        // Sem o aviso do observador: é o salvamento que confere.
        #expect(ws.save("index.html") == false)
        #expect(try disco(root, "index.html") == "<h1>do agente</h1>\n")
        #expect(ws.conflitos.contains("index.html"))
        #expect(ws.text(for: "index.html") == "<h1>meu</h1>\n")
        #expect(ws.activeTab?.isDirty == true)
    }

    /// O aviso do observador numa aba suja era ignorado. Agora vira conflito, e o
    /// salvamento automático para.
    @Test func avisoDoDiscoNumaAbaSujaViraConflito() async throws {
        let (ws, _, root) = try make(autoSave: true)
        ws.openFile("index.html")
        ws.setText("<h1>meu</h1>\n", for: "index.html")
        try escrever(root, "index.html", "<h1>de fora</h1>\n")
        ws.conferirDisco(root.appending(path: "index.html").path)
        #expect(ws.conflitos.contains("index.html"))
        #expect(ws.text(for: "index.html") == "<h1>meu</h1>\n")
        // O salvamento automático (1 s depois da última tecla) não grava.
        try await Task.sleep(for: .milliseconds(1400))
        #expect(try disco(root, "index.html") == "<h1>de fora</h1>\n")
    }

    @Test func manterOMeuGravaERecarregarVoltaAoDisco() throws {
        let (ws, _, root) = try make()
        ws.openFile("index.html")
        ws.setText("meu\n", for: "index.html")
        try escrever(root, "index.html", "de fora\n")
        #expect(ws.save("index.html") == false)
        #expect(ws.manterOMeu("index.html"))
        #expect(try disco(root, "index.html") == "meu\n")
        #expect(ws.conflitos.isEmpty && ws.activeTab?.isDirty == false)

        ws.setText("meu de novo\n", for: "index.html")
        try escrever(root, "index.html", "de fora de novo\n")
        #expect(ws.save("index.html") == false)
        ws.recarregarDoDisco("index.html")
        #expect(ws.text(for: "index.html") == "de fora de novo\n")
        #expect(ws.conflitos.isEmpty && ws.activeTab?.isDirty == false)
    }

    /// Disco igual ao que a aba já tem, ou mudado só na data: não é conflito.
    @Test func mesmaMudancaNaoEhConflito() throws {
        let (ws, _, root) = try make()
        ws.openFile("index.html")
        let original = ws.text(for: "index.html")
        ws.setText("igual\n", for: "index.html")
        try escrever(root, "index.html", "igual\n")
        ws.conferirDisco(root.appending(path: "index.html").path)
        #expect(ws.conflitos.isEmpty)
        #expect(ws.activeTab?.isDirty == false)

        ws.setText("outro\n", for: "index.html")
        try escrever(root, "index.html", "igual\n") // `touch`: data nova, conteúdo igual
        #expect(ws.save("index.html"))
        #expect(try disco(root, "index.html") == "outro\n")
        _ = original
    }

    // MARK: - 2. reloadBuffer

    /// `reloadBuffer` trocava o buffer pelo disco e marcava a aba como limpa.
    @Test func recarregarNaoJogaForaONaoSalvo() throws {
        let (ws, _, root) = try make()
        ws.openFile("src/main.js")
        ws.setText("// digitado\n", for: "src/main.js")
        try escrever(root, "src/main.js", "// do agente\n")
        ws.reloadBuffer("src/main.js")
        #expect(ws.text(for: "src/main.js") == "// digitado\n")
        #expect(ws.tabs.first { $0.path == "src/main.js" }?.isDirty == true)
        #expect(ws.conflitos.contains("src/main.js"))

        // Aba limpa continua recebendo o disco.
        ws.openFile("index.html")
        try escrever(root, "index.html", "novo\n")
        ws.reloadBuffer("index.html")
        #expect(ws.text(for: "index.html") == "novo\n")
    }

    // MARK: - 3. Pedidos de uso único

    @Test func pedidoDeLinhaEhDeUmArquivoSoEDeUsoUnico() throws {
        let (ws, _, _) = try make()
        ws.openFile("index.html")
        ws.open("src/main.js", line: 3)
        let t = try #require(ws.reveal?.token)
        #expect(ws.pedidoDeLinha(para: "index.html") == nil)
        #expect(ws.pedidoDeLinha(para: "src/main.js")?.line == 3)
        ws.linhaRevelada(t)
        #expect(ws.reveal == nil)
    }

    @Test func trocaDaBuscaEhDeUsoUnicoEDeUmLadoSo() {
        let b = BuscaLocal()
        b.abrir("b.js")
        b.texto = "x"
        b.trocar(todos: true)
        let t = b.replace?.token ?? -1
        #expect(t > 0)
        b.trocaFeita(t)
        #expect(b.replace == nil)
        // No modo Dois, só o lado cuja lupa foi tocada.
        #expect(b.alvo(visiveis: ["a.js", "b.js"], ativo: "a.js") == "b.js")
        #expect(b.alvo(visiveis: ["a.js"], ativo: "a.js") == "a.js")
    }

    // MARK: - 4. Trocar tudo no projeto

    /// A troca ia ao disco e depois relia as abas: o não salvo sumia.
    @Test func trocarTudoMantemONaoSalvoDaAba() throws {
        let (ws, _, root) = try make()
        try escrever(root, "a.js", "import x\nimport y\n")
        try escrever(root, "b.js", "const b = 1\n")
        ws.openFile("b.js")
        ws.setText("const b = 1 // digitado\n", for: "b.js")
        let consulta = ConsultaDeTexto(texto: "const", regex: false, caseSensitive: true)
        let r = ws.trocarNoProjeto(consulta, por: "let", em: ["a.js", "b.js"])
        #expect(r.trocas == 1 && r.arquivos == 1)
        #expect(ws.text(for: "b.js") == "let b = 1 // digitado\n")
        #expect(ws.tabs.first { $0.path == "b.js" }?.isDirty == true)
        #expect(try disco(root, "b.js") == "const b = 1\n")
    }

    /// `^import` achava todas as linhas e trocava só a primeira de cada arquivo; com "Aa"
    /// desligado a busca achava "Button" e a troca não.
    @Test func trocaUsaAsMesmasOpcoesDaBusca() throws {
        let (ws, _, root) = try make()
        try escrever(root, "a.js", "import x\nimport y\n")
        try escrever(root, "c.js", "<Button/>\n")
        let porLinha = ConsultaDeTexto(texto: "^import", regex: true)
        let hits = try TextSearch.search(root: root, query: "^import", regex: true)
        #expect(hits.filter { $0.path == "a.js" }.count == 2)
        #expect(ws.previaDaTroca(porLinha, por: "export", em: ["a.js"]).total == 2)
        ws.trocarNoProjeto(porLinha, por: "export", em: ["a.js"])
        #expect(try disco(root, "a.js") == "export x\nexport y\n")

        let semCaixa = ConsultaDeTexto(texto: "button", regex: true)
        #expect(try TextSearch.search(root: root, query: "button", regex: true).contains { $0.path == "c.js" })
        ws.trocarNoProjeto(semCaixa, por: "Botao", em: ["c.js"])
        #expect(try disco(root, "c.js") == "<Botao/>\n")
    }

    // MARK: - 5. Apagar com aba suja

    /// Apagar fechava a aba à força: o texto digitado sumia, e o desfazer da árvore trazia
    /// o arquivo sem ele.
    @Test func apagarGuardaONaoSalvoNaLixeira() throws {
        let (ws, _, root) = try make()
        ws.openFile("src/main.js")
        ws.setText("// não salvo\n", for: "src/main.js")
        ws.delete("src/main.js")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "src/main.js").path))
        ws.desfazerArquivo()
        #expect(try disco(root, "src/main.js") == "// não salvo\n")
    }

    /// Com o disco em conflito não dá para salvar antes: nada é apagado.
    @Test func apagarComConflitoNaoApaga() throws {
        let (ws, _, root) = try make()
        ws.openFile("src/main.js")
        ws.setText("// meu\n", for: "src/main.js")
        try escrever(root, "src/main.js", "// de fora\n")
        ws.delete("src/main.js")
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "src/main.js").path))
        #expect(ws.error != nil)
        #expect(ws.text(for: "src/main.js") == "// meu\n")
    }

    // MARK: - 6. Fechar aba suja

    /// Sem salvamento automático, fechar gravava sem perguntar.
    @Test func fecharAbaSujaSemAutoSavePergunta() throws {
        let (ws, _, root) = try make(autoSave: false)
        let original = try disco(root, "index.html")
        ws.openFile("index.html")
        ws.setText("rascunho\n", for: "index.html")
        ws.closeTab("index.html")
        #expect(ws.tabs.map(\.path) == ["index.html"])
        #expect(ws.abasParaFechar == ["index.html"])
        #expect(try disco(root, "index.html") == original)
        ws.decidirFechamento("index.html", .cancelar)
        #expect(ws.tabs.count == 1 && ws.abasParaFechar.isEmpty)
        ws.closeTab("index.html")
        ws.decidirFechamento("index.html", .descartar)
        #expect(ws.tabs.isEmpty)
        #expect(try disco(root, "index.html") == original)
    }

    @Test func fecharAbaSujaComAutoSaveGrava() throws {
        let (ws, _, root) = try make(autoSave: true)
        ws.openFile("index.html")
        ws.setText("gravado\n", for: "index.html")
        ws.closeTab("index.html")
        #expect(ws.tabs.isEmpty && ws.abasParaFechar.isEmpty)
        #expect(try disco(root, "index.html") == "gravado\n")
    }

    // MARK: - 7 e 9. Aparar e quebra no fim

    /// Em `\r\n`, o aparar não partia linha nenhuma e a quebra no fim punha um `\n` a mais.
    @Test func apararEQuebraNoFimRespeitamCRLF() throws {
        let (ws, chrome, _) = try make()
        chrome.snapshot.editor.trimOnSave = true
        chrome.snapshot.editor.finalNewline = true
        #expect(ws.arrumado("a  \r\nb\t") == "a\r\nb\r\n")
        #expect(ws.arrumado("a\r\n") == "a\r\n")
    }

    /// O salvamento automático aparava a linha do cursor e comia o espaço recém-digitado.
    @Test func salvamentoAutomaticoNaoAparaALinhaDoCursor() throws {
        let (ws, chrome, root) = try make(autoSave: false)
        chrome.snapshot.editor.trimOnSave = true
        ws.openFile("index.html")
        ws.setText("a  \nb ", for: "index.html")
        ws.anotarCursor(6, em: "index.html")
        #expect(ws.save("index.html", automatico: true))
        #expect(try disco(root, "index.html") == "a\nb ")
        #expect(ws.text(for: "index.html") == "a\nb ")
        // O ⌘S apara tudo.
        ws.setText("a  \nb  ", for: "index.html")
        #expect(ws.save("index.html"))
        #expect(try disco(root, "index.html") == "a\nb")
    }

    // MARK: - 8. .editorconfig

    @Test func editorConfigMandaNoSalvamentoENoRecuo() throws {
        let (ws, _, root) = try make()
        try escrever(root, ".editorconfig", """
        root = true
        [*]
        trim_trailing_whitespace = true
        insert_final_newline = true
        [*.py]
        indent_style = space
        indent_size = 4
        """)
        ws.reload()
        #expect(ws.configDoArquivo("src/a.py").tamanhoDoRecuo == 4)
        #expect(ws.configDoArquivo("src/a.js").tamanhoDoRecuo == nil)
        ws.openFile("index.html")
        ws.setText("x  ", for: "index.html")
        #expect(ws.save("index.html"))
        #expect(try disco(root, "index.html") == "x\n")
    }
}

/// Descartar um trecho do gutter com a aba suja: ia embora tudo o que estava digitado,
/// não só o trecho.
@MainActor
@Suite(.serialized)
struct DescartarTrechoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func descartarTrechoNaoLevaONaoSalvo() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-trecho-\(UUID().uuidString)")
        let store = ProjectStore(root: base)
        let p = try store.create(name: "T", template: .blank)
        let pasta = store.url(for: p)
        let linhas = (1 ... 20).map { "linha \($0)" }
        try (linhas.joined(separator: "\n") + "\n").write(
            to: pasta.appending(path: "a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let repo = try Repository.initialize(at: pasta)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: Signature(name: "T", email: "t@t"))
        var mudadas = linhas
        mudadas[1] = "linha 2 mudada no disco"
        try (mudadas.joined(separator: "\n") + "\n").write(
            to: pasta.appending(path: "a.txt"),
            atomically: true,
            encoding: .utf8
        )
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = false
        let ws = WorkspaceModel(
            project: p,
            root: pasta,
            chrome: chrome,
            accounts: AccountStore(url: base.appending(path: "accounts.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: base.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        let fim = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < fim, !(ws.git.isRepo && ws.git.repo != nil) {
            try await Task.sleep(for: .milliseconds(50))
        }
        ws.openFile("a.txt")
        var digitado = mudadas
        digitado[17] = "linha 18 digitada e não salva"
        ws.setText(digitado.joined(separator: "\n") + "\n", for: "a.txt")

        ws.discardHunk(at: 2, in: "a.txt")
        var esperado = linhas
        esperado[17] = "linha 18 digitada e não salva"
        let esperadoTexto = esperado.joined(separator: "\n") + "\n"
        let prazo = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < prazo, ws.text(for: "a.txt") != esperadoTexto {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(ws.text(for: "a.txt") == esperadoTexto)
        #expect(try String(contentsOf: pasta.appending(path: "a.txt"), encoding: .utf8) == esperadoTexto)
    }
}
