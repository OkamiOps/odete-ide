@testable import OdeteApp
import Testing

/// O leitor de blocos da prévia de Markdown.
struct MarkdownPreviewTests {
    func blocos(_ t: String) -> [BlocoMarkdown] {
        LeitorDeMarkdown.blocos(t)
    }

    @Test func titulosComCerquilhaESublinhados() {
        #expect(blocos("# Um\n## Dois ##\n###### Seis") == [
            .titulo(nivel: 1, texto: "Um"),
            .titulo(nivel: 2, texto: "Dois"),
            .titulo(nivel: 6, texto: "Seis"),
        ])
        #expect(blocos("Grande\n===\n\nMenor\n---") == [
            .titulo(nivel: 1, texto: "Grande"),
            .titulo(nivel: 2, texto: "Menor"),
        ])
        // Sem espaço depois do `#` é texto, não título.
        #expect(blocos("#hashtag") == [.paragrafo("#hashtag")])
    }

    @Test func paragrafoJuntaLinhasEQuebraSoComDoisEspacos() {
        #expect(blocos("uma\nsó linha\n\noutro") == [.paragrafo("uma só linha"), .paragrafo("outro")])
        #expect(blocos("quebra  \naqui") == [.paragrafo("quebra\naqui")])
    }

    @Test func listasComNumeroRecuoETarefa() {
        #expect(blocos("- a\n- b\n  - dentro\n- [ ] fazer\n- [x] feito") == [
            .lista(ordenada: false, inicio: 1, itens: [
                ItemDeLista(texto: "a", nivel: 0),
                ItemDeLista(texto: "b", nivel: 0),
                ItemDeLista(texto: "dentro", nivel: 1),
                ItemDeLista(texto: "fazer", nivel: 0, marcado: false),
                ItemDeLista(texto: "feito", nivel: 0, marcado: true),
            ]),
        ])
        #expect(blocos("3. três\n4) quatro") == [
            .lista(ordenada: true, inicio: 3, itens: [
                ItemDeLista(texto: "três", nivel: 0),
                ItemDeLista(texto: "quatro", nivel: 0),
            ]),
        ])
        // Linha recuada depois do item continua o item.
        #expect(blocos("- começo\n  e fim") == [
            .lista(ordenada: false, inicio: 1, itens: [ItemDeLista(texto: "começo e fim", nivel: 0)]),
        ])
    }

    @Test func blocoDeCodigoGuardaOTextoComoEsta() {
        #expect(blocos("```swift\nlet a = 1\n\n# não é título\n```\ndepois") == [
            .codigo(linguagem: "swift", texto: "let a = 1\n\n# não é título"),
            .paragrafo("depois"),
        ])
        #expect(blocos("~~~\nx\n~~~") == [.codigo(linguagem: "", texto: "x")])
    }

    @Test func citacaoReguaEImagem() {
        #expect(blocos("> dito\n> por alguém\n\n---\n\n![logo](img/logo.png \"título\")") == [
            .citacao("dito por alguém"),
            .regua,
            .imagem(alt: "logo", fonte: "img/logo.png"),
        ])
    }

    @Test func tabela() {
        let t = "| Nome | Tipo |\n|:-----|-----:|\n| a | x |\n| b |\n\nfim"
        #expect(blocos(t) == [
            .tabela(cabecalho: ["Nome", "Tipo"], linhas: [["a", "x"], ["b", ""]]),
            .paragrafo("fim"),
        ])
        #expect(LeitorDeMarkdown.celulas("a \\| b | c") == ["a | b", "c"])
    }

    @Test func cabecalhoYAMLEComentarioHTMLSomem() {
        #expect(blocos("---\ntitle: Oi\n---\n# Oi\n<!-- TOC -->\ntexto") == [
            .titulo(nivel: 1, texto: "Oi"),
            .paragrafo("texto"),
        ])
        #expect(blocos("<p align=\"center\">\n  <b>oi</b>\n</p>\n\nfim") == [
            .html("<p align=\"center\">\n  <b>oi</b>\n</p>"),
            .paragrafo("fim"),
        ])
    }

    @Test func inlineViraAtributos() {
        let pronto = BlocoPronto.montar("Um **forte** e `código`")
        guard case let .paragrafo(t)? = pronto.first?.tipo else {
            Issue.record("esperava parágrafo")
            return
        }
        #expect(String(t.characters) == "Um forte e código")
    }
}
