import Foundation
import OdeteCore
import Testing

/// As regras que um compilador daria. Cada uma tem duas metades: acha o erro, e não
/// inventa erro em código correto — a segunda é a que decide se a ferramenta serve.
struct SintaxeRegrasTests {
    func erros(_ texto: String, _ lang: Language, path: String = "") -> [LintIssue] {
        Lint.rules(text: texto, language: lang, path: path).filter { $0.severity == .error }
    }

    // MARK: - ponto e vírgula

    @Test func pontoEVirgulaQueFaltaEmJava() {
        let achados = erros("""
        class A {
            void f() {
                int x = 1
                System.out.println(x);
            }
        }
        """, .java)
        #expect(achados.contains { $0.rule == "falta-ponto-e-virgula" }, "não cobrou o `;`")
        #expect(achados.first?.line == 3, "apontou a linha \(achados.first?.line ?? -1)")
    }

    @Test func pontoEVirgulaQueFaltaEmCECSharp() {
        #expect(erros("int main(void) {\n  int x = 1\n  return x;\n}\n", .c)
            .contains { $0.rule == "falta-ponto-e-virgula" })
        #expect(erros("class A {\n  void F() {\n    var x = 1\n    Write(x);\n  }\n}\n", .csharp)
            .contains { $0.rule == "falta-ponto-e-virgula" })
    }

    /// O grosso do trabalho: nada disso pode acusar.
    @Test func javaValidoNaoAcusaNada() {
        let codigo = """
        package app;

        import java.util.List;
        import java.util.ArrayList;

        /** Uma classe comum. */
        public class Loja {
            private final List<String> itens = new ArrayList<>();
            private static final int MAX = 10;

            public Loja(String nome) {
                this.nome = nome;
            }

            @Override
            public String toString() {
                return "Loja{" + nome + "}";
            }

            public int total() {
                int soma = 0;
                for (int i = 0; i < itens.size(); i++) {
                    soma += i;
                }
                if (soma > MAX)
                    soma = MAX;
                else
                    soma = 0;
                while (soma > 0) soma--;
                switch (soma) {
                    case 0:
                        break;
                    default:
                        break;
                }
                String longa = "a"
                    + "b"
                    + "c";
                return soma + longa.length();
            }
        }
        """
        #expect(erros(codigo, .java).isEmpty, "acusou erro em Java válido: \(erros(codigo, .java))")
    }

    @Test func cValidoNaoAcusaNada() {
        let codigo = """
        #include <stdio.h>
        #include <stdlib.h>

        #define MAX 10

        typedef struct {
            int x;
            int y;
        } Ponto;

        static const char *NOMES[] = {
            "um",
            "dois",
            "tres"
        };

        int soma(int a, int b) {
            return a + b;
        }

        int main(void) {
            Ponto p = {1, 2};
            int total = soma(p.x, p.y);
            for (int i = 0; i < MAX; i++)
                total += i;
            if (total > MAX) {
                printf("%d\\n", total);
            } else {
                printf("pouco\\n");
            }
            return 0;
        }
        """
        #expect(erros(codigo, .c).isEmpty, "acusou erro em C válido: \(erros(codigo, .c))")
    }

    // MARK: - SQL

    @Test func sqlCobraOPontoEVirgulaEntreComandos() {
        let achados = erros("select 1 from a\nselect 2 from b;\n", .sql)
        #expect(achados.contains { $0.rule == "falta-ponto-e-virgula" }, "não separou os comandos")
        #expect(achados.first?.line == 1)
    }

    @Test func sqlValidoNaoAcusaNada() {
        let codigo = """
        -- clientes ativos
        with ativos as (
            select id, nome
            from clientes
            where ativo = true
        )
        select a.id,
               a.nome,
               count(p.id) as pedidos
        from ativos a
        left join pedidos p on p.cliente_id = a.id
        group by a.id, a.nome
        order by pedidos desc;

        insert into log (mensagem) values ('rodou');
        """
        #expect(erros(codigo, .sql).isEmpty, "acusou erro em SQL válido: \(erros(codigo, .sql))")
    }

    @Test func sqlComAspasAbertas() {
        #expect(erros("select 'sem fechar from a;\n", .sql).contains { $0.rule == "texto-aberto" })
    }

    // MARK: - vírgula

    @Test func virgulaQueFaltaEmPython() {
        let achados = erros("""
        itens = [
            "um"
            "dois",
        ]
        """, .python)
        #expect(achados.contains { $0.rule == "falta-virgula" }, "não cobrou a vírgula")
    }

    @Test func pythonValidoNaoAcusaNada() {
        let codigo = """
        import json
        from typing import Any


        CORES = [
            "vermelho",
            "verde",
            "azul",
        ]

        CONFIG = {
            "nome": "odete",
            "versao": 1,
        }


        def formata(dados: dict[str, Any], *, bonito: bool = False) -> str:
            total = sum(
                v
                for v in dados.values()
                if isinstance(v, int)
            )
            if bonito:
                return json.dumps(dados, indent=2)
            return f"{total}"
        """
        let achados = erros(codigo, .python)
            .map { "l\($0.line) \($0.rule): \($0.message)" }.joined(separator: " | ")
        #expect(achados.isEmpty, "acusou erro em Python válido: \(achados)")
    }

    // MARK: - end

    @Test func endQueFaltaEmRubyLuaEElixir() {
        #expect(erros("def f(x)\n  x + 1\n", .ruby).contains { $0.rule == "falta-end" })
        #expect(erros("local function f(x)\n  return x\n", .lua).contains { $0.rule == "falta-end" })
        #expect(erros("defmodule A do\n  def f(x), do: x\n", .elixir).contains { $0.rule == "falta-end" })
    }

    @Test func endSobrandoTambemEhErro() {
        #expect(erros("def f(x)\n  x\nend\nend\n", .ruby).contains { $0.rule == "end-sem-abertura" })
    }

    @Test func rubyValidoNaoAcusaNada() {
        let codigo = """
        # frozen_string_literal: true

        class Loja
          attr_reader :nome

          def initialize(nome)
            @nome = nome
            @itens = []
          end

          def total
            @itens.sum do |i|
              i[:preco]
            end
          end

          def vazio?
            @itens.empty?
          end
        end
        """
        #expect(erros(codigo, .ruby).isEmpty, "acusou erro em Ruby válido: \(erros(codigo, .ruby))")
    }

    // MARK: - JSON

    @Test func chaveRepetidaEmJSON() {
        let achados = erros("{\n  \"a\": 1,\n  \"b\": 2,\n  \"a\": 3\n}\n", .json)
        #expect(achados.contains { $0.rule == "chave-repetida" }, "chave repetida passou batido")
    }

    @Test func chaveIgualEmObjetosDiferentesNaoEhErro() {
        let bom = "{\n  \"a\": { \"id\": 1 },\n  \"b\": { \"id\": 2 }\n}\n"
        #expect(erros(bom, .json).isEmpty, "acusou erro em JSON válido: \(erros(bom, .json))")
    }

    // MARK: - nome do arquivo

    @Test func classePublicaPrecisaCasarComOArquivo() {
        let achados = erros("public class Loja {\n}\n", .java, path: "src/Produto.java")
        #expect(achados.contains { $0.rule == "nome-do-arquivo" }, "não viu o nome trocado")
        #expect(erros("public class Loja {\n}\n", .java, path: "src/Loja.java").isEmpty)
    }
}
