import Foundation
@testable import OdeteApp
import OdeteFiles
import OdeteI18n
import SQLite3
import Testing

/// A tabela de um banco na tela: editar não pode gravar no lugar errado, perder o que
/// se digitou nem reescrever um `.sql` sem a pessoa saber.
@MainActor
@Suite(.serialized) struct EdicaoDoBancoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    let esquema = """
    CREATE TABLE pecas (id TEXT PRIMARY KEY, nome TEXT, preco REAL, estoque INTEGER NOT NULL DEFAULT 0);
    INSERT INTO pecas VALUES ('01','Tigela funda',128.0,7);
    INSERT INTO pecas VALUES ('02','Caneca alta',96.0,12);
    CREATE TABLE tags (t TEXT);
    INSERT INTO tags VALUES ('azul');
    """

    /// Um `.sqlite` de verdade em disco, para ler de volta o que foi gravado.
    func bancoEmDisco() throws -> URL {
        let u = FileManager.default.temporaryDirectory.appending(path: "banco-\(UUID().uuidString).sqlite")
        var p: OpaquePointer?
        #expect(sqlite3_open(u.path, &p) == SQLITE_OK)
        #expect(sqlite3_exec(p, esquema, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(p)
        return u
    }

    func ler(_ u: URL, _ tabela: String) throws -> [[String]] {
        try SQLiteReader(arquivo: u).pagina(tabela).linhas
    }

    /// Célula aberta em `pecas`, troca para `tags`: gravava o texto em `tags` (e a
    /// coluna 3, que `tags` não tem, derrubava o app).
    @Test func trocarDeTabelaGravaNaTabelaCerta() throws {
        let u = try bancoEmDisco()
        let b = EdicaoDoBanco()
        b.abrir(url: u, script: nil)
        b.escolher("pecas")
        #expect(b.abrirCelula(linha: 0, coluna: 3))
        b.rascunho = "99"
        b.escolher("tags")
        #expect(b.escolhida == "tags")
        #expect(b.editando == nil)
        #expect(try ler(u, "pecas")[0][3] == "99", "o que foi digitado não chegou à tabela certa")
        #expect(try ler(u, "tags") == [["azul"]], "a outra tabela foi mexida")
        #expect(b.erro == nil)
    }

    /// Tocar em outra célula jogava fora o rascunho da primeira.
    @Test func tocarEmOutraCelulaGravaAPrimeira() throws {
        let u = try bancoEmDisco()
        let b = EdicaoDoBanco()
        b.abrir(url: u, script: nil)
        b.escolher("pecas")
        b.abrirCelula(linha: 0, coluna: 1)
        b.rascunho = "Tigela rasa"
        b.abrirCelula(linha: 1, coluna: 1)
        #expect(try ler(u, "pecas")[0][1] == "Tigela rasa")
        #expect(b.editando?.linha == 1)
        #expect(b.rascunho == "Caneca alta")
    }

    /// Mudar de página também grava antes.
    @Test func mudarDePaginaGravaAntes() throws {
        let u = try bancoEmDisco()
        let b = EdicaoDoBanco()
        b.abrir(url: u, script: nil)
        b.escolher("pecas")
        b.abrirCelula(linha: 1, coluna: 2)
        b.rascunho = "90.5"
        b.mover(b.porPagina)
        #expect(try ler(u, "pecas")[1][2] == "90.5")
    }

    /// O banco recusou: antes a tabela inteira virava a tela de erro. Agora é um aviso,
    /// a tabela continua na frente e o rascunho continua aberto.
    @Test func recusaDoBancoViraAvisoEGuardaORascunho() throws {
        let u = try bancoEmDisco()
        let b = EdicaoDoBanco()
        b.abrir(url: u, script: nil)
        b.escolher("pecas")
        b.abrirCelula(linha: 0, coluna: 3)
        b.rascunho = "" // NOT NULL
        #expect(!b.gravarPendente())
        #expect(b.erro == nil, "a tabela foi trocada pela tela de erro")
        #expect(b.aviso != nil)
        #expect(b.editando != nil && b.rascunho == "")
        // E não deixa trocar de tabela levando o rascunho junto para o lixo.
        b.escolher("tags")
        #expect(b.escolhida == "pecas")
        b.rascunho = "3"
        b.escolher("tags")
        #expect(b.escolhida == "tags")
        #expect(try ler(u, "pecas")[0][3] == "3")
    }

    @Test func erroAoApagarOuCriarColunaNaoTiraATabela() throws {
        let u = try bancoEmDisco()
        let b = EdicaoDoBanco()
        b.abrir(url: u, script: nil)
        b.escolher("pecas")
        b.criarColuna("nome") // já existe
        #expect(b.erro == nil)
        #expect(b.aviso != nil)
        #expect(!b.pagina.linhas.isEmpty)
    }

    /// Um `.sql` abre só para ver: editar regrava o arquivo inteiro como dump, e isso
    /// só depois de confirmar.
    @Test func sqlSoEditaDepoisDeConfirmar() {
        let b = EdicaoDoBanco()
        var regravado: [String] = []
        b.abrir(url: URL(filePath: "/dev/null"), script: esquema)
        b.regravarSQL = { regravado.append($0) }
        b.escolher("pecas")
        #expect(!b.podeEditar)
        #expect(b.precisaConfirmarSQL)
        #expect(!b.abrirCelula(linha: 0, coluna: 1))
        b.novaLinha()
        #expect(b.pagina.total == 2, "o banco do .sql mudou sem a pessoa confirmar")
        b.apagarLinha(0)
        b.criarColuna("nova")
        #expect(regravado.isEmpty, "o .sql foi regravado sem a pessoa confirmar")
        #expect(b.pagina.total == 2)
        #expect(b.pagina.colunas == ["id", "nome", "preco", "estoque"])

        b.confirmarEdicaoDoSQL()
        #expect(b.podeEditar)
        #expect(b.abrirCelula(linha: 0, coluna: 1))
        b.rascunho = "Tigela rasa"
        #expect(b.gravarPendente())
        #expect(regravado.count == 1)
        #expect(regravado.first?.contains("Tigela rasa") == true)
    }

    /// Abrir e fechar a célula sem mudar nada não regrava o `.sql`.
    @Test func semMudancaNaoRegrava() {
        let b = EdicaoDoBanco()
        var regravado = 0
        b.abrir(url: URL(filePath: "/dev/null"), script: esquema)
        b.regravarSQL = { _ in regravado += 1 }
        b.escolher("pecas")
        b.confirmarEdicaoDoSQL()
        b.abrirCelula(linha: 0, coluna: 1)
        b.gravarPendente()
        #expect(regravado == 0)
    }
}
