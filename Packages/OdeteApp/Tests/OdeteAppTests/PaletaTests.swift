@testable import OdeteApp
import OdeteI18n
import Testing

/// O filtro da paleta, sem a view: `:` para linha, arquivos por relevância e as abas
/// abertas na frente.
@MainActor
struct PaletaTests {
    init() {
        Texto.escolher(.ptBR)
    }

    @Test func doisPontosLevaALinhaEColuna() throws {
        let itens = FiltroDaPaleta.linha("12:5", arquivo: "src/app.js", totalDeLinhas: 100)
        let item = try #require(itens.first)
        #expect(itens.count == 1)
        #expect(item.kind == .line)
        #expect(item.id == ":12:5")
        #expect(item.title == "Ir para a linha 12, coluna 5")
        #expect(item.detail == "app.js")
    }

    @Test func linhaAlemDoFimJaApareceNaUltima() throws {
        let item = try #require(FiltroDaPaleta.linha("999", arquivo: "a.js", totalDeLinhas: 10).first)
        #expect(item.id == ":10")
        #expect(item.title == "Ir para a linha 10")
    }

    @Test func semNumeroMostraADica() throws {
        let dica = try #require(FiltroDaPaleta.linha("", arquivo: "a.js", totalDeLinhas: 7).first)
        #expect(dica.id == ":")
        #expect(dica.detail.contains("7"))
        #expect(FiltroDaPaleta.linha("abc", arquivo: "a.js", totalDeLinhas: 7).first?.id == ":")
        #expect(FiltroDaPaleta.linha("3", arquivo: nil, totalDeLinhas: 0).first?.id == ":")
    }

    @Test func arquivosPorRelevancia() {
        let indice = ["src/app/main.ts", "README.md", "src/App.tsx", "lib/mapa.js"].sorted().map(ArquivoNaPaleta.init)
        let achados = FiltroDaPaleta.arquivos("app", indice, abertas: []).map(\.id)
        // Nome começando com a consulta vem antes de pasta com o nome.
        #expect(achados.first == "src/App.tsx")
        #expect(achados.contains("src/app/main.ts"))
        #expect(!achados.contains("README.md"))
        // Subsequência: "mp" acha "mapa".
        #expect(FiltroDaPaleta.arquivos("mpa", indice, abertas: []).map(\.id).contains("lib/mapa.js"))
    }

    @Test func consultaVaziaPoeAsAbasNaFrente() {
        let indice = ["a.js", "b.js", "c.js", "d.js"].map(ArquivoNaPaleta.init)
        let ids = FiltroDaPaleta.arquivos("", indice, abertas: ["d.js", "b.js"]).map(\.id)
        #expect(ids == ["d.js", "b.js", "a.js", "c.js"])
    }

    @Test func indiceGuardaCaminhoEmMinusculas() {
        let a = ArquivoNaPaleta("Src/MeuArquivo.TSX")
        #expect(a.caminho == "src/meuarquivo.tsx")
        #expect(a.nome == "meuarquivo.tsx")
        #expect(a.item.title == "MeuArquivo.TSX")
        #expect(FiltroDaPaleta.contem("marq", em: a.nome))
        #expect(!FiltroDaPaleta.contem("xyz", em: a.nome))
    }
}
