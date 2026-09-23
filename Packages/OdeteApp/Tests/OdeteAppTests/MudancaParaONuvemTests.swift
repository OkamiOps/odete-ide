import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// Levar os projetos para o iCloud e trazer de volta sem perder nenhum no caminho.
@MainActor
@Suite(.serialized) struct MudancaParaONuvemTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func pasta(_ nome: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "odete-\(nome)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func nomes(_ u: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: u.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    nonisolated static let moverSimples: MudancaDeLugar.Mover = { de, para, _ in
        try FileManager.default.moveItem(at: de, to: para)
    }

    /// Nome que já existia no destino: o `continue` deixava o projeto na origem, e o
    /// hub, que passava a olhar só o destino, não o mostrava mais.
    @Test func nomeRepetidoGanhaOutroNomeEmVezDeSumir() throws {
        let de = try pasta("origem"), para = try pasta("destino")
        for n in ["A", "B"] {
            _ = try ProjectStore(root: de).create(name: n, template: .blank)
        }
        _ = try ProjectStore(root: para).create(name: "A", template: .blank)
        let renomeados = try MudancaDeLugar.executar(de: de, para: para, paraNuvem: true, mover: Self.moverSimples)
        #expect(renomeados == [MudancaDeLugar.Renomeado(de: "A", para: "A 2")])
        #expect(try nomes(para) == ["A", "A 2", "B"])
        #expect(try nomes(de).isEmpty)
    }

    /// Falhou no meio: antes, metade ia e metade ficava, e o app continuava olhando a
    /// origem — os que já tinham ido sumiam. Agora os que foram voltam.
    @Test func falhaNoMeioDesfazOQueJaFoi() throws {
        let de = try pasta("origem"), para = try pasta("destino")
        for n in ["A", "B", "C"] {
            _ = try ProjectStore(root: de).create(name: n, template: .blank)
        }
        let mover: MudancaDeLugar.Mover = { a, b, x in
            if a.lastPathComponent == "C" {
                throw CocoaError(.fileWriteNoPermission)
            }
            try Self.moverSimples(a, b, x)
        }
        #expect(throws: MudancaDeLugar.Falha.self) {
            try MudancaDeLugar.executar(de: de, para: para, paraNuvem: true, mover: mover)
        }
        #expect(try nomes(de) == ["A", "B", "C"])
        #expect(try nomes(para).isEmpty)
    }

    struct Mundo {
        let janelas: Janelas
        let local: URL
        let nuvem: URL
        let raiz: URL
    }

    func mundo(estado: String? = nil) throws -> Mundo {
        let raiz = try pasta("mundo")
        let local = raiz.appending(path: "Local"), nuvem = raiz.appending(path: "Nuvem")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let arquivo = raiz.appending(path: "state.json")
        if let estado {
            try estado.write(to: arquivo, atomically: true, encoding: .utf8)
        }
        let j = Janelas(
            store: StateStore(url: arquivo, debounce: .milliseconds(1)),
            external: ExternalProjects(file: raiz.appending(path: "external.json")),
            nuvem: LocalDaNuvem { nuvem }
        )
        j.raizLocal = local
        j.moverProjetos = Self.moverSimples
        return Mundo(janelas: j, local: local, nuvem: nuvem, raiz: raiz)
    }

    func app(_ m: Mundo, raiz: URL) -> AppModel {
        AppModel(
            store: ProjectStore(root: raiz),
            accounts: AccountStore(url: m.raiz.appending(path: "contas.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: m.raiz.appending(path: "ia.json"), secrets: MemorySecrets()),
            external: m.janelas.external
        )
    }

    /// Todas as janelas passam a olhar o lugar novo — antes só a que mudou, e as outras
    /// ficavam listando (e gravando) a pasta velha.
    @Test func todasAsJanelasVaoJunto() async throws {
        let m = try mundo()
        _ = m.janelas.snapshotInicial()
        let p = try ProjectStore(root: m.local).create(name: "Um", template: .blank)
        let a = app(m, raiz: m.local), b = app(m, raiz: m.local)
        let ca = ChromeState(snapshot: m.janelas.snapshotInicial()),
            cb = ChromeState(snapshot: m.janelas.snapshotInicial())
        ca.snapshot.editor.autoSave = false
        m.janelas.entrar(UUID(), app: a, chrome: ca) {}
        m.janelas.entrar(UUID(), app: b, chrome: cb) {}
        a.refresh()
        a.open(p, chrome: ca)
        a.workspace?.openFile("index.html")
        a.workspace?.setText("<p>digitado</p>", for: "index.html")

        await m.janelas.mudarLugar(paraNuvem: true)

        #expect(m.janelas.mudanca.aviso == nil, "\(m.janelas.mudanca.aviso ?? "")")
        #expect(a.workspace == nil)
        #expect(a.store.root == m.nuvem && b.store.root == m.nuvem)
        #expect(b.projects.map(\.name) == ["Um"])
        #expect(ca.snapshot.projectsInCloud && cb.snapshot.projectsInCloud)
        let texto = try String(contentsOf: m.nuvem.appending(path: "Um/index.html"), encoding: .utf8)
        #expect(texto == "<p>digitado</p>")

        // E de volta.
        await m.janelas.mudarLugar(paraNuvem: false)
        #expect(a.store.root == m.local && b.store.root == m.local)
        #expect(!cb.snapshot.projectsInCloud)
        #expect(try nomes(m.local) == ["Um"])
    }

    /// Falhou: ninguém muda de lugar, e a pessoa fica sabendo.
    @Test func falhaDeixaTudoNoLugarEAvisa() async throws {
        let m = try mundo()
        _ = m.janelas.snapshotInicial()
        _ = try ProjectStore(root: m.local).create(name: "Um", template: .blank)
        m.janelas.moverProjetos = { _, _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        let a = app(m, raiz: m.local)
        let ca = ChromeState(snapshot: m.janelas.snapshotInicial())
        m.janelas.entrar(UUID(), app: a, chrome: ca) {}
        await m.janelas.mudarLugar(paraNuvem: true)
        #expect(m.janelas.mudanca.aviso != nil)
        #expect(a.store.root == m.local)
        #expect(!ca.snapshot.projectsInCloud)
        #expect(a.projects.map(\.name) == ["Um"])
    }

    /// Um `state.json` que não deu para ler não é instalação nova: não liga o iCloud.
    @Test func estadoIlegivelNaoLigaONuvem() async throws {
        let m = try mundo(estado: "{ isto não é json")
        let snap = m.janelas.snapshotInicial()
        #expect(snap.welcomeDone)
        let a = app(m, raiz: m.local)
        let ca = ChromeState(snapshot: snap)
        m.janelas.entrar(UUID(), app: a, chrome: ca) {}
        await m.janelas.prepararNuvem()
        #expect(!ca.snapshot.projectsInCloud)
        #expect(a.store.root == m.local)
    }

    /// Instalação nova de verdade, com iCloud: os projetos nascem lá, como antes.
    @Test func instalacaoNovaLigaONuvem() async throws {
        let m = try mundo()
        let snap = m.janelas.snapshotInicial()
        #expect(!snap.welcomeDone)
        let a = app(m, raiz: m.local)
        let ca = ChromeState(snapshot: snap)
        m.janelas.entrar(UUID(), app: a, chrome: ca) {}
        await m.janelas.prepararNuvem()
        #expect(ca.snapshot.projectsInCloud)
        #expect(a.store.root == m.nuvem)
    }

    /// A raiz do iCloud não é perguntada no ator principal, e só uma vez.
    @Test func nuvemEhPerguntadaUmaVezForaDoAtorPrincipal() async {
        final class Contador: @unchecked Sendable {
            var vezes = 0
            var naPrincipal = false
        }
        let c = Contador()
        let n = LocalDaNuvem {
            c.vezes += 1
            c.naPrincipal = Thread.isMainThread
            return nil
        }
        #expect(n.sabido == nil)
        _ = await n.raiz()
        _ = await n.raiz()
        #expect(c.vezes == 1)
        #expect(!c.naPrincipal)
        #expect(n.sabido == .some(nil))
    }
}
