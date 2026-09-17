import OdeteCore
@testable import OdeteEditor
import Testing

/// "Classe não declarada" — a parte do interpretador que não é sintaxe.
///
/// Como sempre em duas metades, e aqui a segunda pesa mais que em qualquer outra regra:
/// acusar um nome que existe é dizer que o código da pessoa está errado quando não está.
struct ResolvePythonTests {
    func erros(_ texto: String) -> [LintIssue] {
        ResolvePython.problemas(text: texto).filter { $0.severity == .error }
    }

    func descricao(_ texto: String) -> String {
        ResolvePython.problemas(text: texto)
            .map { "l\($0.line):\($0.column) \($0.rule) \($0.message)" }.joined(separator: " | ")
    }

    @Test func classeQueNaoExisteEhAcusada() {
        let achados = erros("""
        class Loja:
            pass


        l = Lojja()
        """)
        #expect(achados.count == 1, "esperava um só: \(descricao("x"))")
        #expect(achados.first?.message.contains("Lojja") == true, "não nomeou o culpado")
        #expect(achados.first?.line == 5)
    }

    @Test func funcaoEVariavelQueNaoExistem() {
        #expect(erros("def f(x):\n    return g(x)\n").contains { $0.message.contains("g") })
        #expect(erros("x = 1\nprint(y)\n").contains { $0.message.contains("y") })
    }

    /// O erro mais comum de todos: o nome escrito quase certo.
    @Test func erroDeDigitacaoNoProprioNome() {
        let achados = erros("total = 10\nprint(totaal)\n")
        #expect(achados.first?.message.contains("totaal") == true)
        #expect(achados.first?.line == 2)
    }

    // MARK: - o que não pode acusar

    @Test func embutidosNaoSaoAcusados() {
        let codigo = """
        print(len([1, 2]))
        d = dict(a=1)
        s = sorted(set(range(10)), reverse=True)
        try:
            raise ValueError("x")
        except ValueError as e:
            print(type(e).__name__)
        """
        #expect(erros(codigo).isEmpty, "acusou embutido: \(descricao(codigo))")
    }

    @Test func importsContam() {
        let codigo = """
        import json
        import os.path
        import numpy as np
        from typing import Any, Optional as Opt
        from pathlib import Path


        def f(p: Path, x: Any, y: Opt[int]) -> str:
            return json.dumps({"n": np.mean([1]), "d": os.path.dirname(str(p)), "x": x, "y": y})
        """
        #expect(erros(codigo).isEmpty, "acusou nome importado: \(descricao(codigo))")
    }

    /// `from x import *` desliga a checagem: dali pode ter vindo qualquer coisa, e
    /// continuar acusando seria inventar.
    @Test func importEstrelaDesligaAChecagem() {
        #expect(erros("from tkinter import *\njanela = Tk()\n").isEmpty)
    }

    @Test func parametrosEEscoposContam() {
        let codigo = """
        def f(a, b=2, *args, c=3, **kwargs):
            total = a + b + c
            for i, j in enumerate(args):
                total += i + j
            with open("x") as arq:
                dados = arq.read()
            xs = [n * 2 for n in range(3) if n]
            g = lambda z: z + 1
            if (m := total) > 0:
                total = m
            return total, dados, xs, g, kwargs
        """
        #expect(erros(codigo).isEmpty, "acusou nome ligado: \(descricao(codigo))")
    }

    @Test func atributoEArgumentoNomeadoNaoSaoNomesDaqui() {
        let codigo = """
        import json

        texto = json.dumps({"a": 1}, indent=2, sort_keys=True)
        tamanho = texto.upper().strip().count("a")
        """
        #expect(erros(codigo).isEmpty, "confundiu atributo ou argumento com nome: \(descricao(codigo))")
    }

    /// Nome definido depois de usar continua valendo: o módulo é lido inteiro, e é assim
    /// que duas funções se chamam.
    @Test func definidoDepoisContinuaValendo() {
        #expect(erros("def a():\n    return b()\n\n\ndef b():\n    return 1\n").isEmpty)
    }

    /// Com erro de sintaxe a árvore é um chute: melhor calar do que despejar nomes
    /// trocados em cima de um erro que a pessoa já está vendo.
    @Test func comErroDeSintaxeNaoOpina() {
        #expect(erros("def f(:\n    return xyz\n").isEmpty)
    }

    @Test func arquivoRealNaoAcusaNada() {
        let codigo = """
        import json
        from dataclasses import dataclass, field
        from typing import Any


        @dataclass
        class Item:
            nome: str
            preco: float = 0.0
            tags: list[str] = field(default_factory=list)

            def barato(self, teto: float = 10.0) -> bool:
                return self.preco < teto


        class Loja:
            def __init__(self, nome: str) -> None:
                self.nome = nome
                self.itens: list[Item] = []

            def adiciona(self, item: Item) -> None:
                self.itens.append(item)

            def total(self) -> float:
                return sum(i.preco for i in self.itens if i.barato())

            def como_json(self) -> str:
                dados: dict[str, Any] = {"nome": self.nome, "total": self.total()}
                return json.dumps(dados, indent=2)


        if __name__ == "__main__":
            loja = Loja("teste")
            loja.adiciona(Item("caneca", 9.5))
            print(loja.como_json())
        """
        #expect(erros(codigo).isEmpty, "acusou erro em Python válido: \(descricao(codigo))")
    }

    // MARK: - import sem uso

    @Test func importQueNinguemUsa() {
        let achados = ResolvePython.problemas(text: "import os\nimport json\n\nprint(json.dumps({}))\n")
        #expect(achados.contains { $0.rule == "import-sem-uso" && $0.message.contains("os") })
        #expect(!achados.contains { $0.message.contains("json") }, "acusou import que é usado")
        #expect(achados.first?.severity == .warning, "import sem uso não é erro, é aviso")
    }
}
