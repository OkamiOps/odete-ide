import OdeteCore
@testable import OdeteEditor
import Runestone
import Testing
import UIKit

/// Arquivo sem gramática abre branco, e ninguém percebe olhando o código — só olhando a
/// tela. Estes testes são o olho: toda linguagem que a Odete diz reconhecer tem que ter
/// uma gramática, e cores diferentes para coisas diferentes.
@MainActor
struct ColoracaoTests {
    @Test func todaLinguagemTemGramatica() {
        for lang in Language.allCases where lang != .plain {
            #expect(
                LanguageMode.treeSitter(for: lang) != nil,
                "\(lang.rawValue) não tem gramática: abre em branco"
            )
        }
    }

    @Test func textoPuroContinuaSemGramatica() {
        #expect(LanguageMode.treeSitter(for: .plain) == nil)
    }

    /// Era este o `package-lock.json` inteiro verde: a chave subia até `string` e ficava
    /// da cor do valor.
    @Test func chaveDeJSONNaoTemACorDoValor() {
        let tema = EditorTheme(palette: .all[0], fontSize: 13)
        let chave = tema.textColor(for: "string.special.key")
        let valor = tema.textColor(for: "string")
        #expect(chave != nil, "a chave ficou sem cor")
        #expect(chave != valor, "chave e valor do JSON saem com a mesma cor")
    }

    /// As famílias que as gramáticas embarcadas emitem precisam cair em alguma cor;
    /// o que sobra fica com a cor do texto, e é assim que um arquivo fica monocromático.
    @Test func asFamiliasDeCapturaTemCor() {
        let tema = EditorTheme(palette: .all[0], fontSize: 13)
        let familias = [
            "keyword", "string", "comment", "number", "function", "type", "tag", "attribute",
            "property", "constant", "constant.builtin", "operator", "punctuation.bracket",
            "punctuation.delimiter", "variable", "variable.builtin", "variable.parameter",
            "parameter", "namespace", "constructor", "conditional", "repeat", "include",
            "field", "method", "float", "boolean", "escape", "string.escape", "string.regex",
            "type.builtin", "function.macro", "function.method", "function.builtin", "label",
            "exception", "module", "symbol", "char", "character", "delimiter", "error",
        ]
        for f in familias {
            #expect(tema.textColor(for: f) != nil, "`\(f)` não tem cor e sai como texto comum")
        }
    }

    /// Cores diferentes para papéis diferentes: se tudo caísse na mesma, o arquivo
    /// continuaria monocromático mesmo com a tabela cheia.
    @Test func papeisDiferentesTemCoresDiferentes() {
        let tema = EditorTheme(palette: .all[0], fontSize: 13)
        let distintas = Set(["keyword", "string", "comment", "number", "type", "function"]
            .compactMap { tema.textColor(for: $0) })
        #expect(distintas.count >= 5, "as cores de sintaxe estão quase todas iguais")
    }

    @Test func todoTemaColoreOMesmoConjunto() {
        for palette in ThemePalette.all {
            let tema = EditorTheme(palette: palette, fontSize: 13)
            for f in ["keyword", "string", "comment", "number", "function", "type", "string.special.key"] {
                #expect(tema.textColor(for: f) != nil, "\(palette.label) deixou `\(f)` sem cor")
            }
        }
    }
}

/// Ter a gramática no `Package.swift` não é o mesmo que ela carregar. Este teste monta o
/// estado do editor com um trecho real de cada linguagem — é aí que a gramática é
/// compilada e as queries de destaque são lidas. Se uma delas estiver quebrada, quebra
/// aqui, e não na tela de quem abriu o arquivo.
@MainActor
struct GramaticaCarregaTests {
    static let amostras: [Language: String] = [
        .astro: "---\nconst t = \"oi\";\n---\n<h1>{t}</h1>\n",
        .svelte: "<script>let n = 1;</script>\n<p>{n}</p>\n",
        .rust: "fn main() { println!(\"oi\"); }\n",
        .c: "#include <stdio.h>\nint main(void) { return 0; }\n",
        .cpp: "#include <vector>\nint main() { std::vector<int> v; return v.size(); }\n",
        .csharp: "class A { static void Main() { System.Console.WriteLine(1); } }\n",
        .go: "package main\nfunc main() { println(\"oi\") }\n",
        .java: "class A { public static void main(String[] a) {} }\n",
        .python: "def f(x: int) -> int:\n    return x + 1\n",
        .ruby: "def f(x)\n  x + 1\nend\n",
        .php: "<?php\nfunction f($x) { return $x + 1; }\n",
        .bash: "#!/bin/bash\nset -e\necho \"oi $HOME\"\n",
        .sql: "select id, nome from clientes where ativo = true;\n",
        .toml: "[pacote]\nnome = \"odete\"\nversao = 1\n",
        .lua: "local function f(x) return x + 1 end\n",
        .perl: "my $x = 1;\nprint \"$x\\n\";\n",
        .r: "f <- function(x) x + 1\n",
        .haskell: "main :: IO ()\nmain = putStrLn \"oi\"\n",
        .elixir: "defmodule A do\n  def f(x), do: x + 1\nend\n",
        .elm: "module A exposing (f)\nf x = x + 1\n",
        .ocaml: "let f x = x + 1\n",
        .julia: "function f(x)\n  x + 1\nend\n",
        .latex: "\\documentclass{article}\n\\begin{document}\noi\n\\end{document}\n",
        .scss: "$cor: #fff;\n.a { color: $cor; .b { color: red; } }\n",
        .xml: "<?xml version=\"1.0\"?>\n<raiz><item id=\"1\">oi</item></raiz>\n",
        .html: "<html><body><p>oi</p></body></html>\n",
        .css: ".a { color: red; }\n",
        .javascript: "const a = 1;\n",
        .jsx: "const A = () => <p>oi</p>;\n",
        .typescript: "const a: number = 1;\n",
        .tsx: "const A = (): any => <p>oi</p>;\n",
        .json: "{\"a\": 1}\n",
        .markdown: "# Título\n\nTexto com `código`.\n",
        .swift: "func f() -> Int { 1 }\n",
        .yaml: "a:\n  b: 1\n",
    ]

    /// Toda linguagem colorida precisa de amostra: sem isso, acrescentar uma linguagem
    /// nova e esquecer de testá-la passaria batido.
    @Test func todaLinguagemTemAmostra() {
        for lang in Language.allCases where lang != .plain {
            #expect(Self.amostras[lang] != nil, "falta amostra de \(lang.rawValue)")
        }
    }

    @Test func todaGramaticaMontaOEstadoDoEditor() {
        let tema = EditorTheme(palette: .all[0], fontSize: 13)
        for (lang, amostra) in Self.amostras {
            guard let gramatica = LanguageMode.treeSitter(for: lang) else {
                Issue.record("\(lang.rawValue) ficou sem gramática")
                continue
            }
            let tv = TextView()
            tv.setState(TextViewState(
                text: amostra,
                theme: tema,
                language: gramatica,
                languageProvider: LanguageMode.provider
            ))
            #expect(tv.text == amostra, "\(lang.rawValue): o editor não ficou com o texto")
        }
    }
}
