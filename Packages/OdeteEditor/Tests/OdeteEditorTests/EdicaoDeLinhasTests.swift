import Foundation
import OdeteCore
@testable import OdeteEditor
import Testing

/// As contas dos atalhos de linha — ⌘/, ⇧⌥↓, ⇧⌘K e ⌘L — sem editor nenhum na frente.
struct EdicaoDeLinhasTests {
    /// Aplica a troca no texto e devolve o texto novo com a seleção.
    func aplicar(_ texto: String, _ e: EdicaoDeTexto) -> (String, NSRange) {
        let ns = NSMutableString(string: texto)
        ns.replaceCharacters(in: e.faixa, with: e.texto)
        return (ns as String, e.selecao)
    }

    func comentar(
        _ texto: String,
        _ selecao: NSRange,
        _ linguagem: Language = .javascript
    ) throws -> (String, NSRange) {
        let ns = texto as NSString
        let estilo = try #require(LanguageMode.comentario(para: linguagem, em: ns, local: selecao.location))
        return aplicar(texto, EdicaoDeLinhas.alternarComentario(ns, selecao: selecao, estilo: estilo))
    }

    // MARK: comentário de linha

    @Test func comentaELinhaUnicaEDescomentaDeVolta() throws {
        let (um, cursor) = try comentar("let a = 1", NSRange(location: 4, length: 0))
        #expect(um == "// let a = 1")
        #expect(cursor == NSRange(location: 7, length: 0))
        let (dois, volta) = try comentar(um, cursor)
        #expect(dois == "let a = 1")
        #expect(volta == NSRange(location: 4, length: 0))
    }

    @Test func variasLinhasEntramNaColunaDoMenorRecuo() throws {
        let texto = "function f() {\n  a();\n    b();\n}\n"
        // Linhas 2 e 3 selecionadas até o começo da 4: a 4 não entra.
        let (novo, _) = try comentar(texto, NSRange(location: 15, length: 16))
        #expect(novo == "function f() {\n  // a();\n  //   b();\n}\n")
        let (volta, _) = try comentar(novo, NSRange(location: 15, length: 22))
        #expect(volta == texto)
    }

    @Test func misturaDeComentadaESemComentarioComentaTodas() throws {
        let (novo, _) = try comentar("// a\nb", NSRange(location: 0, length: 6))
        #expect(novo == "// // a\n// b")
    }

    @Test func linhaEmBrancoNoMeioFicaComoEsta() throws {
        let (novo, _) = try comentar("a\n\n  \nb", NSRange(location: 0, length: 7))
        #expect(novo == "// a\n\n  \n// b")
    }

    @Test func descomentarTiraUmEspacoSo() throws {
        #expect(try comentar("//a", NSRange(location: 0, length: 0)).0 == "a")
        #expect(try comentar("  //  a", NSRange(location: 0, length: 0)).0 == "   a")
    }

    @Test func selecaoAcompanhaOTexto() throws {
        // "a();" selecionado dentro de "  a();": a seleção passa a incluir o `// `.
        let (novo, sel) = try comentar("  a();", NSRange(location: 2, length: 4))
        #expect(novo == "  // a();")
        #expect(sel == NSRange(location: 2, length: 7))
    }

    @Test func cadaLinguagemComASuaMarca() throws {
        #expect(try comentar("x = 1", NSRange(location: 0, length: 0), .python).0 == "# x = 1")
        #expect(try comentar("select 1", NSRange(location: 0, length: 0), .sql).0 == "-- select 1")
        #expect(try comentar("print(1)", NSRange(location: 0, length: 0), .lua).0 == "-- print(1)")
        #expect(try comentar("a: 1", NSRange(location: 0, length: 0), .yaml).0 == "# a: 1")
        #expect(try comentar("fn main() {}", NSRange(location: 0, length: 0), .rust).0 == "// fn main() {}")
        #expect(LanguageMode.comentario(para: .plain) == nil)
    }

    @Test func documentoVazioGanhaAMarca() throws {
        let (novo, cursor) = try comentar("", NSRange(location: 0, length: 0))
        #expect(novo == "// ")
        #expect(cursor == NSRange(location: 3, length: 0))
    }

    // MARK: comentário de bloco

    @Test func htmlUsaComentarioDeBlocoPorLinha() throws {
        let texto = "<div>\n  <p>oi</p>\n</div>"
        let (novo, _) = try comentar(texto, NSRange(location: 0, length: (texto as NSString).length), .html)
        #expect(novo == "<!-- <div> -->\n  <!-- <p>oi</p> -->\n<!-- </div> -->")
        let (volta, _) = try comentar(novo, NSRange(location: 0, length: (novo as NSString).length), .html)
        #expect(volta == texto)
    }

    @Test func cssUsaBarraAsterisco() throws {
        #expect(try comentar("a { color: red; }  ", NSRange(location: 0, length: 0), .css)
            .0 == "/* a { color: red; } */")
        #expect(try comentar("  /* b */", NSRange(location: 0, length: 0), .css).0 == "  b")
    }

    @Test func dentroDeScriptEStyleValeALinguagemDeDentro() {
        let html = "<p>x</p>\n<script>\nlet a = 1\n</script>\n<style>\np { }\n</style>\n<p>y</p>" as NSString
        let script = html.range(of: "let a").location
        let estilo = html.range(of: "p { }").location
        let depois = html.range(of: "<p>y").location
        #expect(LanguageMode.comentario(para: .html, em: html, local: script) == .linha("//"))
        #expect(LanguageMode.comentario(para: .html, em: html, local: estilo) == .bloco("/*", "*/"))
        #expect(LanguageMode.comentario(para: .html, em: html, local: depois) == .bloco("<!--", "-->"))
        let astro = "---\nconst a = 1\n---\n<h1>oi</h1>" as NSString
        #expect(LanguageMode.comentario(para: .astro, em: astro, local: 6) == .linha("//"))
        #expect(LanguageMode.comentario(para: .astro, em: astro, local: astro.length - 3) == .bloco("<!--", "-->"))
    }

    // MARK: duplicar e apagar

    @Test func duplicarCopiaParaBaixoELevaASelecao() {
        let (novo, sel) = aplicar("a\nb\n", EdicaoDeLinhas.duplicar("a\nb\n", selecao: NSRange(location: 1, length: 0)))
        #expect(novo == "a\na\nb\n")
        #expect(sel == NSRange(location: 3, length: 0))
        // Última linha sem quebra no fim: a quebra vem junto na cópia.
        let (fim, sel2) = aplicar("a\nb", EdicaoDeLinhas.duplicar("a\nb", selecao: NSRange(location: 2, length: 1)))
        #expect(fim == "a\nb\nb")
        #expect(sel2 == NSRange(location: 4, length: 1))
    }

    @Test func apagarLinhaMantemAColuna() throws {
        let e = try #require(EdicaoDeLinhas.apagar("abc\nde\nfgh", selecao: NSRange(location: 6, length: 0)))
        let (novo, sel) = aplicar("abc\nde\nfgh", e)
        #expect(novo == "abc\nfgh")
        #expect(sel == NSRange(location: 6, length: 0))
    }

    @Test func apagarAUltimaLinhaLevaAQuebraDeCima() throws {
        let e = try #require(EdicaoDeLinhas.apagar("abc\nde", selecao: NSRange(location: 5, length: 0)))
        let (novo, sel) = aplicar("abc\nde", e)
        #expect(novo == "abc")
        #expect(sel == NSRange(location: 1, length: 0))
        let unica = try #require(EdicaoDeLinhas.apagar("só", selecao: NSRange(location: 1, length: 0)))
        #expect(aplicar("só", unica).0 == "")
        #expect(EdicaoDeLinhas.apagar("", selecao: NSRange(location: 0, length: 0)) == nil)
    }

    @Test func apagarVariasLinhasSelecionadas() throws {
        let e = try #require(EdicaoDeLinhas.apagar("a\nb\nc\nd", selecao: NSRange(location: 2, length: 3)))
        #expect(aplicar("a\nb\nc\nd", e).0 == "a\nd")
    }

    // MARK: ir para a linha

    @Test func lerLinhaELinhaColuna() {
        #expect(AlvoDeLinha("12") == AlvoDeLinha(linha: 12))
        #expect(AlvoDeLinha("12:5") == AlvoDeLinha(linha: 12, coluna: 5))
        #expect(AlvoDeLinha(" 12 : 5 ") == AlvoDeLinha(linha: 12, coluna: 5))
        #expect(AlvoDeLinha("12,5") == AlvoDeLinha(linha: 12, coluna: 5))
        #expect(AlvoDeLinha(":7") == AlvoDeLinha(linha: 7))
        // Ainda digitando a coluna: vale a linha.
        #expect(AlvoDeLinha("12:") == AlvoDeLinha(linha: 12))
        #expect(AlvoDeLinha("abc") == nil)
        #expect(AlvoDeLinha("") == nil)
        #expect(AlvoDeLinha(":") == nil)
        #expect(AlvoDeLinha("-3") == nil)
        #expect(AlvoDeLinha("1:2:3") == nil)
        #expect(AlvoDeLinha("4:x") == nil)
    }

    @Test func foraDoArquivoPrendeNoQueExiste() {
        let mapa = MapaDeLinhas("ab\ncd\n")
        #expect(AlvoDeLinha(linha: 2, coluna: 2).deslocamento(em: mapa) == 4)
        #expect(AlvoDeLinha(linha: 99).deslocamento(em: mapa) == 6)
        #expect(AlvoDeLinha(linha: 2, coluna: 99).deslocamento(em: mapa) == 5)
        #expect(AlvoDeLinha(linha: 0).deslocamento(em: mapa) == 0)
        #expect(AlvoDeLinha(linha: 0, coluna: 0).deslocamento(em: mapa) == 0)
        #expect(AlvoDeLinha(linha: 99).linhaPresa(total: mapa.quantidade) == 3)
        // Quebra do Windows: a última coluna fica antes do `\r`.
        #expect(AlvoDeLinha(linha: 1, coluna: 50).deslocamento(em: MapaDeLinhas("ab\r\ncd")) == 2)
    }
}
