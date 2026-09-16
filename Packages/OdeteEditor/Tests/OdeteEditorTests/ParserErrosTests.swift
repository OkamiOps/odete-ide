import OdeteCore
@testable import OdeteEditor
import Testing

/// O erro vem do parser da linguagem, não de regra minha. O teste é o mesmo de sempre em
/// duas metades: acha o que falta, e não inventa nada em código correto.
struct ParserErrosTests {
    func erros(_ texto: String, _ lang: Language) -> [LintIssue] {
        ParserErros.problemas(text: texto, language: lang)
    }

    func descricao(_ texto: String, _ lang: Language) -> String {
        erros(texto, lang).map { "l\($0.line):\($0.column) \($0.rule) \($0.message)" }.joined(separator: " | ")
    }

    @Test func todaLinguagemColoridaTemParser() {
        // Markdown é o único sem: qualquer texto é Markdown válido.
        for lang in Language.allCases where lang != .plain && lang != .markdown {
            #expect(ParserErros.gramatica(lang) != nil, "\(lang.rawValue) não tem parser")
        }
    }

    /// Dizer "não entendo este trecho" é pouco. Quando inserir uma ficha só deixa a
    /// árvore inteira limpa, o recado passa a ser qual ficha falta — e quem confere é o
    /// parser, que analisou de novo, não um palpite.
    @Test func oConsertoDeUmaFichaDizOQueFalta() {
        let casos: [(Language, String, String, Int)] = [
            (.rust, "fn soma(a: i32) -> i32 {\n    let t = a + 1\n    t\n}\n", ";", 2),
            (.c, "int main(void) {\n  int x = 1\n  return x;\n}\n", ";", 2),
            (.java, "class A {\n  void f() {\n    int x = 1\n    g(x);\n  }\n}\n", ";", 3),
            (.python, "d = {\n    \"a\": 1\n    \"b\": 2,\n}\n", ",", 2),
            (.json, "{\n  \"a\": 1\n  \"b\": 2\n}\n", ",", 2),
            // Fechamento de bloco aponta a linha **depois** do corpo: é onde se digita o
            // `end`, e não no fim da última instrução.
            (.ruby, "def f(x)\n  x + 1\n", "end", 3),
            (.lua, "local function f(x)\n  return x\n", "end", 3),
        ]
        for (lang, codigo, ficha, linha) in casos {
            let achados = erros(codigo, lang)
            #expect(
                achados.first?.rule == "falta-simbolo",
                "\(lang.rawValue): ficou no recado genérico — \(descricao(codigo, lang))"
            )
            #expect(
                achados.first?.message.contains(ficha) == true,
                "\(lang.rawValue): não disse que falta `\(ficha)` — \(descricao(codigo, lang))"
            )
            #expect(
                achados.first?.line == linha,
                "\(lang.rawValue): esperava linha \(linha), veio \(descricao(codigo, lang))"
            )
        }
    }

    /// O conserto não pode inventar: código correto continua sem recado.
    @Test func oConsertoNaoDisparaEmCodigoCerto() {
        #expect(erros("fn f(x: i32) -> i32 {\n    x + 1\n}\n", .rust).isEmpty)
        #expect(erros("d = {\n    \"a\": 1,\n}\n", .python).isEmpty)
    }

    /// A gramática diz **qual** símbolo falta, com a posição. É isso no lugar de eu
    /// escrever uma regra por linguagem.
    @Test func oParserDizQualSimboloFalta() {
        let casos: [(Language, String)] = [
            (.c, "int main(void) {\n  int x = 1\n  return x;\n}\n"),
            (.java, "class A {\n  void f() {\n    int x = 1\n    g(x);\n  }\n}\n"),
            (.rust, "fn main() {\n    let x = 1\n    println!(\"{}\", x);\n}\n"),
            (.go, "package main\nfunc main() {\n\tx := 1\n\t_ = x\n"),
            (.php, "<?php\nfunction f() {\n  $x = 1\n  return $x;\n}\n"),
            (.typescript, "function f() {\n  const a = {\n    x: 1\n    y: 2\n  };\n}\n"),
        ]
        for (lang, codigo) in casos {
            let achados = erros(codigo, lang)
            #expect(!achados.isEmpty, "\(lang.rawValue): o parser não achou nada")
        }
    }

    @Test func aspasQueNaoFecham() {
        #expect(
            !erros("x = 'sem fechar\ny = 1\n", .python).isEmpty,
            "Python: \(descricao("x = 'sem fechar\ny = 1\n", .python))"
        )
        #expect(!erros("const a = \"sem fechar;\nconst b = 1;\n", .typescript).isEmpty)
        #expect(!erros("select 'sem fechar from t;\n", .sql).isEmpty)
    }

    @Test func chaveEParentesesQueNaoFecham() {
        #expect(!erros("fn main() {\n    let x = (1, 2;\n}\n", .rust).isEmpty)
        #expect(!erros("class A {\n  void f() {\n}\n", .java).isEmpty)
        #expect(!erros("def f(:\n    pass\n", .python).isEmpty)
    }

    @Test func endQueFalta() {
        #expect(!erros("def f(x)\n  x + 1\n", .ruby).isEmpty, "Ruby: \(descricao("def f(x)\n  x + 1\n", .ruby))")
        #expect(!erros("local function f(x)\n  return x\n", .lua).isEmpty)
    }

    @Test func virgulaQueFaltaEmJSON() {
        #expect(!erros("{\n  \"a\": 1\n  \"b\": 2\n}\n", .json).isEmpty)
    }

    /// HTML é permissivo por definição — `<li>` sem fechar é HTML válido —, então a
    /// gramática não reclama de tag aberta. É por isso que a regra de marcação escrita à
    /// mão continua existindo: ela cobra o que o parser deixa passar de propósito.
    @Test func gramaticaDeHTMLNaoCobraTagAberta() {
        #expect(erros("<html>\n<body>\n<div>\n</body>\n</html>\n", .html).isEmpty)
        #expect(
            Lint.rules(text: "<html>\n<body>\n<div>\n</body>\n</html>\n", language: .html)
                .contains { $0.rule.hasPrefix("tag-") },
            "a regra de marcação parou de cobrir o que o parser não cobre"
        )
    }

    /// A metade que decide se a ferramenta serve.
    @Test func codigoValidoNaoAcusaNada() {
        let casos: [(Language, String)] = [
            (.rust, """
            use std::collections::HashMap;

            #[derive(Debug, Clone)]
            pub struct Item { pub nome: String, pub preco: f64 }

            pub fn total(itens: &[Item]) -> f64 {
                let mut soma = 0.0;
                for i in itens {
                    soma += i.preco;
                }
                let mapa: HashMap<String, f64> = itens.iter().map(|i| (i.nome.clone(), i.preco)).collect();
                soma + mapa.len() as f64
            }
            """),
            (.python, """
            import json
            from typing import Any


            class Loja:
                \"\"\"Catálogo.\"\"\"

                def __init__(self, nome: str) -> None:
                    self.nome = nome
                    self.itens: list[dict[str, Any]] = []

                def total(self) -> float:
                    return sum(
                        i["preco"]
                        for i in self.itens
                        if "preco" in i
                    )


            if __name__ == "__main__":
                print(json.dumps({"ok": True}))
            """),
            (.java, """
            package app;

            import java.util.ArrayList;
            import java.util.List;

            public class Loja {
                private final List<String> itens = new ArrayList<>();
                private static final String[] NOMES = { "a", "b" };

                public int total() {
                    int soma = 0;
                    for (int i = 0; i < itens.size(); i++) {
                        soma += i;
                    }
                    switch (soma) {
                        case 0: break;
                        default: break;
                    }
                    return soma + NOMES.length;
                }
            }
            """),
            (.go, """
            package main

            import "fmt"

            type Item struct {
            \tNome  string
            \tPreco float64
            }

            func total(itens []Item) float64 {
            \tsoma := 0.0
            \tfor _, i := range itens {
            \t\tsoma += i.Preco
            \t}
            \treturn soma
            }

            func main() {
            \tfmt.Println(total([]Item{{Nome: "a", Preco: 1}}))
            }
            """),
            (.ruby, """
            # frozen_string_literal: true

            class Loja
              attr_reader :nome

              def initialize(nome)
                @nome = nome
                @itens = []
              end

              def total
                @itens.sum { |i| i[:preco] }
              end
            end
            """),
            (.sql, """
            with ativos as (
                select id, nome from clientes where ativo = true
            )
            select a.id, count(p.id) as pedidos
            from ativos a
            left join pedidos p on p.cliente_id = a.id
            group by a.id;
            """),
            (.json, "{\n  \"a\": [1, 2, 3],\n  \"b\": { \"c\": null }\n}\n"),
            (.typescript, """
            type A = { n: number };
            export const f = (a: A): number => a.n + 1;
            """),
            (.lua, """
            local M = {}

            function M.pinta(nome)
                if nome then
                    return nome
                end
                return nil
            end

            return M
            """),
        ]
        for (lang, codigo) in casos {
            #expect(erros(codigo, lang).isEmpty, "\(lang.rawValue) válido acusou: \(descricao(codigo, lang))")
        }
    }
}
