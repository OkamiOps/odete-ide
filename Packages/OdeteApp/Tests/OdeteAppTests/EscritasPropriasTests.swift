import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// O salvamento automático grava o arquivo, a pasta dele muda, e o observador avisa. Esse
/// aviso remontava o projeto inteiro um segundo depois de cada pausa na digitação. Quando
/// o aviso é só da gravação do app, nada muda; quando alguém de fora mexeu, tudo continua
/// sendo relido.
@MainActor
struct EscritasPropriasTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func pasta() throws -> URL {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-escritas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raiz.appending(path: "src"), withIntermediateDirectories: true)
        try "velho".write(to: raiz.appending(path: "src/a.js"), atomically: true, encoding: .utf8)
        return raiz
    }

    func ler(_ raiz: URL) -> (String) -> String? {
        { try? String(contentsOf: raiz.appending(path: $0), encoding: .utf8) }
    }

    /// O app grava; as pastas estão como na fotografia de depois da gravação e o arquivo
    /// tem o que o app escreveu: o aviso é só dele.
    @Test func gravacaoDoAppEIgnorada() throws {
        let raiz = try pasta()
        var e = EscritasProprias()
        try "novo".write(to: raiz.appending(path: "src/a.js"), atomically: true, encoding: .utf8)
        let seq = e.registrar("src/a.js", texto: "novo")
        e.anotarBase(EscritasProprias.assinaturaDasPastas(raiz: raiz), sequencia: seq)
        let base = try #require(e.base)
        let agora = EscritasProprias.assinaturaDasPastas(raiz: raiz)
        #expect(EscritasProprias.soProprias(pendentes: e.pendentes, base: base, agora: agora, ler: ler(raiz)))
    }

    /// Alguém criou um arquivo depois da gravação: a pasta mudou, e o aviso recarrega.
    @Test func arquivoNovoDeForaRecarrega() throws {
        let raiz = try pasta()
        var e = EscritasProprias()
        try "novo".write(to: raiz.appending(path: "src/a.js"), atomically: true, encoding: .utf8)
        let seq = e.registrar("src/a.js", texto: "novo")
        e.anotarBase(EscritasProprias.assinaturaDasPastas(raiz: raiz), sequencia: seq)
        Thread.sleep(forTimeInterval: 0.02)
        try "de fora".write(to: raiz.appending(path: "src/b.js"), atomically: true, encoding: .utf8)
        let agora = EscritasProprias.assinaturaDasPastas(raiz: raiz)
        #expect(!EscritasProprias.soProprias(pendentes: e.pendentes, base: e.base ?? [:], agora: agora, ler: ler(raiz)))
    }

    /// O mesmo arquivo foi reescrito por fora com outro conteúdo, sem mexer na pasta
    /// (escrita no lugar): a impressão não bate, e o aviso recarrega.
    @Test func conteudoTrocadoPorForaRecarrega() throws {
        let raiz = try pasta()
        var e = EscritasProprias()
        let alvo = raiz.appending(path: "src/a.js")
        try "novo".write(to: alvo, atomically: true, encoding: .utf8)
        let seq = e.registrar("src/a.js", texto: "novo")
        e.anotarBase(EscritasProprias.assinaturaDasPastas(raiz: raiz), sequencia: seq)
        let h = try FileHandle(forWritingTo: alvo)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: Data("outro".utf8))
        try h.close()
        let agora = EscritasProprias.assinaturaDasPastas(raiz: raiz)
        #expect(!EscritasProprias.soProprias(pendentes: e.pendentes, base: e.base ?? [:], agora: agora, ler: ler(raiz)))
    }

    /// Sem gravação pendente, todo aviso é de fora.
    @Test func semPendentesNaoEProprio() throws {
        let raiz = try pasta()
        let a = EscritasProprias.assinaturaDasPastas(raiz: raiz)
        #expect(!EscritasProprias.soProprias(pendentes: [:], base: a, agora: a, ler: ler(raiz)))
    }

    /// A fotografia de uma gravação antiga que chega depois da nova não vale.
    @Test func fotografiaAtrasadaNaoValePelaNova() {
        var e = EscritasProprias()
        let primeira = e.registrar("a", texto: "1")
        _ = e.registrar("b", texto: "2")
        e.anotarBase(["x": .distantPast], sequencia: primeira)
        #expect(e.base == nil)
    }

    /// A impressão é a mesma entre execuções (FNV-1a), diferente de `hashValue`.
    @Test func impressaoEstavel() {
        #expect(EscritasProprias.impressao("") == 0xCBF2_9CE4_8422_2325)
        #expect(EscritasProprias.impressao("a") == 0xAF63_DC4C_8601_EC8C)
        #expect(EscritasProprias.impressao("ab") != EscritasProprias.impressao("ba"))
    }

    /// De ponta a ponta, com o observador de verdade: salvar não remonta a árvore;
    /// arquivo criado por fora remonta.
    @Test func salvarNaoRemontaMasMudancaDeForaSim() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-ws-esc-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = false
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: AccountStore(url: root.appending(path: "accounts.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: root.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        let pasta = store.url(for: p)
        ws.openFile("index.html")
        try await Task.sleep(for: .milliseconds(600))
        ws.setText("<h1>oi</h1>\n", for: "index.html")
        ws.save("index.html")
        let depoisDeSalvar = ws.reloadTick
        try await Task.sleep(for: .milliseconds(900))
        #expect(ws.reloadTick == depoisDeSalvar, "o aviso da própria gravação não remonta a árvore")
        try "novo".write(to: pasta.appending(path: "outro.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(900))
        #expect(ws.reloadTick > depoisDeSalvar, "mudança de fora remonta")
        #expect(ws.filePaths.contains("outro.txt"))
        ws.stop()
    }
}
