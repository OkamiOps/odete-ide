import Foundation
@testable import OdeteI18n
import Testing

@Suite("Idioma e tradução")
struct TextoTests {
    /// Trocar o idioma no meio do teste mexe num estado global; devolver ao fim evita
    /// que a ordem dos testes mude o resultado.
    func comIdioma(_ i: Idioma, _ corpo: () -> Void) {
        let antes = Texto.idioma
        Texto.escolher(i)
        corpo()
        Texto.escolher(antes)
    }

    @Test("português devolve a própria chave, sem tabela")
    func portuguesEhAChave() {
        comIdioma(.ptBR) {
            #expect(tr("Idioma") == "Idioma")
            #expect(tr("uma frase que não existe no catálogo") == "uma frase que não existe no catálogo")
        }
    }

    @Test("cada idioma traduzido acha a tabela dele")
    func tabelas() {
        comIdioma(.en) { #expect(tr("Idioma") == "Language") }
        comIdioma(.de) { #expect(tr("Idioma") == "Sprache") }
        comIdioma(.fr) { #expect(tr("Idioma") == "Langue") }
        comIdioma(.es) { #expect(tr("Idioma") == "Idioma") }
    }

    @Test("chave sem tradução cai no português em vez de sumir")
    func semTraducaoCaiNoPortugues() {
        comIdioma(.de) { #expect(tr("isto não está no catálogo") == "isto não está no catálogo") }
    }

    @Test("sistema resolve para um idioma que a Odete fala")
    func sistemaResolve() {
        #expect(Idioma.traduzidos.contains(Idioma.doAparelho))
        #expect(Idioma.sistema.codigo == Idioma.doAparelho.rawValue)
    }

    @Test("todo idioma traduzido tem nome e bandeira próprios")
    func nomes() {
        let nomes = Set(Idioma.traduzidos.map(\.nome))
        #expect(nomes.count == Idioma.traduzidos.count)
        #expect(Set(Idioma.traduzidos.map(\.bandeira)).count == Idioma.traduzidos.count)
    }

    @Test("argumentos entram por format, não por interpolação")
    func comArgumentos() {
        comIdioma(.ptBR) { #expect(tr("%d arquivos", 3) == "3 arquivos") }
    }
}
