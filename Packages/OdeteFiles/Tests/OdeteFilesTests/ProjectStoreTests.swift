import Foundation
import OdeteCore
@testable import OdeteFiles
import OdeteI18n
import Testing

struct ProjectStoreTests {
    /// Os testes conferem a frase exata que está no código, que é o português. Sem
    /// travar o idioma, o mesmo teste passa no Mac e falha no simulador em inglês.
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func createListRenameDuplicateDelete() throws {
        let store = try ProjectStore(root: tempDir())
        #expect(try store.list().isEmpty)
        let a = try store.create(name: "Alpha")
        _ = try store.create(name: "Beta", template: .viteReact)
        var list = try store.list()
        #expect(list.map(\.name).sorted() == ["Alpha", "Beta"])
        #expect(FileManager.default.fileExists(atPath: store.root.appending(path: "Beta/src/App.tsx").path))

        let renamed = try store.rename(a, to: "Alfa")
        #expect(renamed.id == a.id)
        list = try store.list()
        #expect(list.map(\.name).sorted() == ["Alfa", "Beta"])

        let dup = try store.duplicate(renamed)
        #expect(dup.name == "Alfa cópia")
        #expect(dup.id != renamed.id)

        try store.delete(dup)
        #expect(try store.list().count == 2)
    }

    @Test func rejectsBadNames() throws {
        let store = try ProjectStore(root: tempDir())
        #expect(throws: FileError.invalidName("a/b")) { try store.create(name: "a/b") }
        #expect(throws: FileError.invalidName("..")) { try store.create(name: "..") }
        _ = try store.create(name: "X")
        #expect(throws: FileError.alreadyExists("X")) { try store.create(name: "X") }
    }

    @Test func touchOrdersByLastOpened() throws {
        let store = try ProjectStore(root: tempDir())
        let a = try store.create(name: "A")
        _ = try store.create(name: "B")
        _ = try store.touch(a)
        #expect(try store.list().first?.name == "A")
    }
}

/// Criar projeto fora da raiz do app — numa pasta escolhida no app Arquivos, que pode
/// ser o iCloud ou um SSD externo.
struct CriarEmPastaTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func nasceNaPastaEscolhidaENaoNaRaiz() throws {
        let raiz = try tempDir()
        let escolhida = try tempDir()
        let store = ProjectStore(root: raiz)

        let (p, dir) = try ProjectStore.criar(name: "no-ssd", template: .blank, dentroDe: escolhida)

        #expect(p.name == "no-ssd")
        #expect(dir == escolhida.appending(path: "no-ssd", directoryHint: .isDirectory))
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: ".odete/project.json").path))
        // a raiz do app continua vazia: o projeto não foi parar lá
        #expect(try store.list().isEmpty)
    }

    @Test func escreveOsArquivosDoModelo() throws {
        let escolhida = try tempDir()
        let (_, dir) = try ProjectStore.criar(name: "site", template: .blank, dentroDe: escolhida)
        for (caminho, _) in Template.blank.files(projectName: "site") {
            #expect(FileManager.default.fileExists(atPath: dir.appending(path: caminho).path))
        }
    }

    @Test func naoSobrescreveOqueJaExiste() throws {
        let escolhida = try tempDir()
        _ = try ProjectStore.criar(name: "igual", template: .blank, dentroDe: escolhida)
        #expect(throws: FileError.self) {
            try ProjectStore.criar(name: "igual", template: .blank, dentroDe: escolhida)
        }
    }

    @Test func recusaNomeInvalido() throws {
        let escolhida = try tempDir()
        #expect(throws: FileError.self) {
            try ProjectStore.criar(name: "../fora", template: .blank, dentroDe: escolhida)
        }
    }

    /// O caminho normal continua igual: criar sem escolher pasta cai na raiz do app.
    @Test func semEscolhaContinuaNaRaiz() throws {
        let raiz = try tempDir()
        let store = ProjectStore(root: raiz)
        let p = try store.create(name: "normal", template: .blank)
        #expect(try store.list().map(\.name) == [p.name])
        #expect(FileManager.default.fileExists(atPath: raiz.appending(path: "normal").path))
    }
}

/// O `project.json` guarda o id do projeto, e o id é a chave das abas, dos rascunhos e
/// das conversas. Regravar com um id novo quando a leitura falha é perder tudo isso.
struct MetadadoDoProjetoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func meta(_ store: ProjectStore, _ nome: String) -> URL {
        store.root.appending(path: "\(nome)/.odete/project.json")
    }

    @Test func metaIlegivelNaoEhRegravado() throws {
        let store = try ProjectStore(root: tempDir())
        _ = try store.create(name: "A")
        try "{ quebrado".write(to: meta(store, "A"), atomically: true, encoding: .utf8)
        let um = try store.list()
        let dois = try store.list()
        #expect(um.map(\.name) == ["A"])
        #expect(try String(contentsOf: meta(store, "A"), encoding: .utf8) == "{ quebrado")
        #expect(um.first?.id == dois.first?.id, "o id mudou de uma listagem para outra")
    }

    /// Um campo que não decodifica não pode levar o id junto.
    @Test func idSobreviveACampoQuebrado() throws {
        let store = try ProjectStore(root: tempDir())
        let a = try store.create(name: "A")
        let json = #"{"id":"\#(a.id.uuidString)","name":"A","createdAt":"ontem"}"#
        try json.write(to: meta(store, "A"), atomically: true, encoding: .utf8)
        #expect(try store.list().first?.id == a.id)
        #expect(try String(contentsOf: meta(store, "A"), encoding: .utf8) == json)
    }

    /// Ainda na nuvem: o `project.json` é só o marcador `.project.json.icloud`. Criar um
    /// novo por cima fazia o de verdade, ao chegar, virar conflito — ou sumir.
    @Test func aindaNaNuvemNaoViraProjetoNovo() throws {
        let store = try ProjectStore(root: tempDir())
        let dir = store.root.appending(path: "Baixando/.odete")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appending(path: ".project.json.icloud"))
        let lista = try store.list()
        #expect(lista.map(\.name) == ["Baixando"])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "project.json").path))
        // Quem lista fica sabendo que vale tentar de novo.
        #expect(try store.listar().aguardando == 1)
        // Quando o de verdade chega, vale o id dele.
        let real = Project(name: "Baixando")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try FileManager.default.removeItem(at: dir.appending(path: ".project.json.icloud"))
        try enc.encode(real).write(to: dir.appending(path: "project.json"))
        let p = try #require(lista.first)
        #expect(try store.touch(p).id == real.id)
        #expect(try store.list().first?.id == real.id)
    }

    /// Um projeto com problema não esvazia o hub inteiro.
    @Test func umErroNaoEsvaziaOHub() throws {
        let store = try ProjectStore(root: tempDir())
        _ = try store.create(name: "Bom")
        let ruim = store.root.appending(path: "Ruim")
        try FileManager.default.createDirectory(at: ruim, withIntermediateDirectories: true)
        // `.odete` é um arquivo: não dá para criar o metadado ali.
        try Data("x".utf8).write(to: ruim.appending(path: ".odete"))
        let nomes = try store.list().map(\.name)
        #expect(nomes.contains("Bom"))
    }

    @Test func achaOProjetoDaPasta() throws {
        let store = try ProjectStore(root: tempDir())
        let a = try store.create(name: "A")
        #expect(store.projeto(naPasta: store.url(for: a))?.id == a.id)
        #expect(store.projeto(naPasta: store.url(for: a).appending(path: "src")) == nil)
        #expect(try store.projeto(naPasta: tempDir()) == nil)
    }

    /// Abrir o projeto marca a data — mas não por cima de um metadado que não deu para ler.
    @Test func abrirNaoRegravaMetaIlegivel() throws {
        let store = try ProjectStore(root: tempDir())
        _ = try store.create(name: "A")
        try "{ quebrado".write(to: meta(store, "A"), atomically: true, encoding: .utf8)
        let p = try #require(try store.list().first)
        _ = try store.touch(p)
        #expect(try String(contentsOf: meta(store, "A"), encoding: .utf8) == "{ quebrado")
    }
}
