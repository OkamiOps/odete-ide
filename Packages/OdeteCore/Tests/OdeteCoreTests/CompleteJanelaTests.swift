import Foundation
@testable import OdeteCore
import Testing

/// O autocompletar por janela e índice tem de sugerir exatamente o que a varredura do
/// documento inteiro sugeria. Os dois caminhos convivem: o antigo (`suggestions(text:…)`)
/// é a régua, o novo é o que o editor usa a cada tecla.
struct CompleteJanelaTests {
    static let js = """
    import React, { useState, useEffect } from "react"
    import Header from "./components/Header"
    import { formatDate } from '../lib/format'

    const counter = 1
    const counterMax = 9
    function handleClick(event) {
      const counterValue = counter + counterMax
      console.log(counterValue, event)
      return counterValue
    }

    export default function App() {
      const [contagem, setContagem] = useState(0)
      useEffect(() => {
        document.title = `Cliques: ${contagem}`
      }, [contagem])
      return <button onClick={handleClick}>ação 🇧🇷 {contagem}</button>
    }
    """

    static let arquivos = [
        "src/App.tsx", "src/components/Header.tsx", "src/components/Footer.tsx",
        "src/lib/format.ts", "src/main.tsx", "package.json",
    ]

    /// Todos os pontos do texto em UTF-16, para comparar em cada posição possível.
    func posicoes(_ texto: String) -> [(chars: Int, utf16: Int)] {
        var out = [(0, 0)]
        var c = 0, u = 0
        for ch in texto {
            c += 1
            u += ch.utf16.count
            out.append((c, u))
        }
        return out
    }

    /// Linha do cursor como o editor a entrega: faixa UTF-16 com a quebra no fim.
    func linha(_ ns: NSString, _ cursor: Int) -> NSRange {
        ns.lineRange(for: NSRange(location: cursor, length: 0))
    }

    func novas(_ texto: String, cursorUTF16: Int, indice: IndiceDePalavras) -> [Completion] {
        let ns = texto as NSString
        guard let ctx = Complete.contexto(em: ns, cursor: cursorUTF16) else { return [] }
        let l = linha(ns, cursorUTF16)
        return Complete.sugestoes(
            para: ctx,
            indice: indice,
            linha: LinhaDoCursor(texto: ns.substring(with: l), inicio: l.location, cursor: cursorUTF16 - l.location),
            language: .tsx,
            files: Self.arquivos,
            currentPath: "src/App.tsx",
            packages: ["react", "react-dom"]
        )
    }

    func antigas(_ texto: String, cursorChars: Int) -> [Completion] {
        Complete.suggestions(
            text: texto,
            cursor: cursorChars,
            language: .tsx,
            files: Self.arquivos,
            currentPath: "src/App.tsx",
            packages: ["react", "react-dom"]
        )
    }

    /// Em todo ponto do arquivo, o contexto por janela acha o mesmo prefixo, o mesmo modo e
    /// o mesmo começo que o do documento inteiro.
    @Test func contextoPorJanelaIgualAoAntigo() {
        let texto = Self.js
        let ns = texto as NSString
        for (c, u) in posicoes(texto) {
            let velho = Complete.context(text: texto, cursor: c)
            let novo = Complete.contexto(em: ns, cursor: u)
            #expect(velho?.prefix == novo?.prefix, "prefixo em \(c)")
            #expect(velho?.mode == novo?.mode, "modo em \(c)")
            #expect(velho?.modulo == novo?.modulo, "módulo em \(c)")
            #expect(velho?.inicioUTF16 == novo?.inicioUTF16, "começo em \(c)")
        }
    }

    /// Índice montado com o texto de agora: em toda posição, as mesmas sugestões na mesma
    /// ordem.
    @Test func sugestoesComIndiceEmDiaIguaisAsAntigas() {
        let texto = Self.js
        let ns = texto as NSString
        for (c, u) in posicoes(texto) {
            let indice = IndiceDePalavras(texto: texto, linhaDoCursor: linha(ns, u))
            #expect(novas(texto, cursorUTF16: u, indice: indice) == antigas(texto, cursorChars: c), "posição \(c)")
        }
    }

    /// O caso de todo dia: o índice é de uma tecla atrás e a pessoa segue digitando na
    /// mesma linha. A conta por linha tem de dar o mesmo que a varredura inteira.
    @Test func indiceAtrasadoNaMesmaLinhaDaOMesmo() {
        let base = Self.js
        let ns = base as NSString
        let alvo = (base as NSString).range(of: "console.log(counterValue")
        let cursor0 = alvo.location + alvo.length
        let indice = IndiceDePalavras(texto: base, linhaDoCursor: linha(ns, cursor0))
        var texto = base
        var cursor = cursor0
        // Digita ", counte" depois de counterValue, uma tecla por vez, sem remontar o índice.
        for tecla in [",", " ", "c", "o", "u", "n", "t", "e"] {
            let m = NSMutableString(string: texto)
            m.insert(tecla, at: cursor)
            texto = m as String
            cursor += 1
            let chars = (texto as NSString).substring(to: cursor).count
            #expect(novas(texto, cursorUTF16: cursor, indice: indice) == antigas(texto, cursorChars: chars), "\(tecla)")
        }
        // E apagando de volta: a palavra que sumiu não pode voltar como sugestão.
        for _ in 0 ..< 3 {
            let m = NSMutableString(string: texto)
            m.deleteCharacters(in: NSRange(location: cursor - 1, length: 1))
            texto = m as String
            cursor -= 1
            let chars = (texto as NSString).substring(to: cursor).count
            #expect(novas(texto, cursorUTF16: cursor, indice: indice) == antigas(texto, cursorChars: chars))
        }
    }

    /// O cursor foi para outra linha e o índice já está em dia com o texto: tirar só a
    /// palavra do cursor basta.
    @Test func indiceEmDiaDeOutraLinha() {
        let texto = Self.js
        let ns = texto as NSString
        let outraLinha = linha(ns, 0)
        let indice = IndiceDePalavras(texto: texto, linhaDoCursor: outraLinha)
        let alvo = ns.range(of: "return counterValue")
        let u = alvo.location + alvo.length - 3
        let c = ns.substring(to: u).count
        #expect(novas(texto, cursorUTF16: u, indice: indice) == antigas(texto, cursorChars: c))
    }

    /// Linha com emoji antes do cursor: o começo do prefixo em UTF-16 é o que o editor usa
    /// para substituir, e errar ali apaga o caractere errado.
    @Test func inicioEmUTF16ComEmoji() {
        let texto = "const 🇧🇷 = conta"
        let ns = texto as NSString
        let ctx = Complete.contexto(em: ns, cursor: ns.length)
        #expect(ctx?.prefix == "conta")
        #expect(ctx?.inicioUTF16 == ns.range(of: "conta").location)
    }

    /// Arquivo CRLF: a volta até as aspas para na quebra, em vez de atravessar para a
    /// linha de cima como fazia a versão que só conhecia `\n`.
    @Test func crlfNaoAtravessaALinha() {
        let texto = "import x from \"./a\"\r\nconst b = foo"
        let ns = texto as NSString
        let ctx = Complete.contexto(em: ns, cursor: ns.length)
        #expect(ctx?.prefix == "foo")
        #expect(ctx?.mode == .word)
    }

    /// Linha minificada de muitos quilobytes: a janela para no teto e não lê a linha toda.
    @Test func linhaGiganteParaNoTeto() {
        let texto = String(repeating: "a+", count: 20000) + " valor"
        let ns = texto as NSString
        let ctx = Complete.contexto(em: ns, cursor: ns.length)
        #expect(ctx?.prefix == "valor")
        #expect(Complete.inicioDaJanela(cursor: ns.length, inicioDaLinha: 0) == ns.length - Complete.tetoDaJanela)
    }

    /// Minúscula uma vez por palavra, e busca pelo grupo da letra.
    @Test func indiceAchaPorPrefixoSemDiferenciarCaixa() {
        let indice = IndiceDePalavras(texto: "Contador contagem CONTAR outra", linhaDoCursor: nil)
        #expect(Set(indice.comecandoCom("cont")) == ["Contador", "contagem", "CONTAR"])
        #expect(indice.contagem("contagem") == 1)
        #expect(indice.comecandoCom("xy").isEmpty)
    }
}
