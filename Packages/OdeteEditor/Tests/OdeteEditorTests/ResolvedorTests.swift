import OdeteCore
@testable import OdeteEditor
import Testing

/// O resolvedor fora do Python: Go, Java, e o índice que lê o projeto inteiro.
///
/// Sempre em duas metades. A primeira é fácil de escrever e a segunda é a que decide se
/// isto vai para as mãos de alguém: **código certo não pode ser acusado**. Um resolvedor
/// que grita em arquivo bom é pior que resolvedor nenhum, porque ensina a pessoa a ignorar
/// a marca vermelha — e aí ele também não serve quando estiver certo.
struct ResolvedorTests {
    func erros(
        _ texto: String,
        _ lang: Language,
        path: String = "",
        indice: Resolvedor.Indice = .init()
    ) -> [LintIssue] {
        Resolvedor.problemas(text: texto, language: lang, path: path, indice: indice)
            .filter { $0.severity == .error }
    }

    func conta(_ achados: [LintIssue]) -> String {
        achados.map { "l\($0.line):\($0.column) \($0.message)" }.joined(separator: " | ")
    }

    // MARK: - Go

    @Test func goAcusaNomeQueNaoExiste() {
        let achados = erros("""
        package main

        import "fmt"

        func main() {
        	total := 1
        	fmt.Println(totaal)
        	_ = total
        }
        """, .go)
        #expect(achados.count == 1, "esperava um só: \(conta(achados))")
        #expect(achados.first?.message.contains("totaal") == true, "não nomeou o culpado")
        #expect(achados.first?.line == 7)
    }

    @Test func goAcusaFuncaoQueNaoExiste() {
        let achados = erros("""
        package main

        func main() {
        	_ = calculaTotal(2)
        }
        """, .go)
        #expect(achados.count == 1, "esperava um só: \(conta(achados))")
        #expect(achados.first?.message.contains("calculaTotal") == true)
    }

    @Test func goAcusaPacoteNaoImportado() {
        let achados = erros("""
        package main

        func main() {
        	fmt.Println("oi")
        }
        """, .go)
        #expect(achados.contains { $0.message.contains("fmt") }, "\(conta(achados))")
    }

    /// A metade que pesa: um arquivo Go inteiro, com tudo que a linguagem tem de comum,
    /// e nenhuma acusação.
    @Test func goNaoAcusaCodigoCerto() {
        let achados = erros("""
        package loja

        import (
        	"fmt"
        	"strings"
        )

        type Pessoa struct {
        	Nome  string
        	Idade int
        }

        type Falante interface {
        	Saudacao() string
        }

        const Maximo = 10

        var padrao = Pessoa{Nome: "ana", Idade: 3}

        func (p Pessoa) Saudacao() string {
        	return strings.ToUpper("oi " + p.Nome)
        }

        func Maior(xs []Pessoa) (Pessoa, error) {
        	if len(xs) == 0 {
        		return Pessoa{}, fmt.Errorf("lista vazia")
        	}
        	melhor := xs[0]
        	for i, p := range xs {
        		if p.Idade > melhor.Idade && i < Maximo {
        			melhor = p
        		}
        	}
        	return melhor, nil
        }

        func main() {
        	var f Falante = padrao
        	m, err := Maior([]Pessoa{padrao})
        	if err != nil {
        		panic(err)
        	}
        	defer fmt.Println(f.Saudacao(), m.Nome)
        }
        """, .go)
        #expect(achados.isEmpty, "acusou código certo: \(conta(achados))")
    }

    @Test func goNaoAcusaGenericoNemFuncaoAnonima() {
        let achados = erros("""
        package util

        func Mapa[T any, R any](xs []T, f func(T) R) []R {
        	out := make([]R, 0, len(xs))
        	for _, x := range xs {
        		out = append(out, f(x))
        	}
        	return out
        }

        func usa() []int {
        	return Mapa([]int{1, 2}, func(n int) int { return n * 2 })
        }
        """, .go)
        #expect(achados.isEmpty, "acusou código certo: \(conta(achados))")
    }

    // MARK: - Java

    @Test func javaAcusaNomeQueNaoExiste() {
        let achados = erros("""
        public class App {
            public static void main(String[] args) {
                int total = 1;
                System.out.println(totaal);
            }
        }
        """, .java)
        #expect(achados.count == 1, "esperava um só: \(conta(achados))")
        #expect(achados.first?.message.contains("totaal") == true)
        #expect(achados.first?.line == 4)
    }

    @Test func javaAcusaClasseSemImport() {
        let achados = erros("""
        public class App {
            void f() {
                ArrayList lista = new ArrayList();
                lista.size();
            }
        }
        """, .java)
        #expect(achados.contains { $0.message.contains("ArrayList") }, "\(conta(achados))")
    }

    @Test func javaNaoAcusaCodigoCerto() {
        let achados = erros("""
        package br.com.loja;

        import java.util.ArrayList;
        import java.util.List;

        public class Loja implements Comparable<Loja> {
            private final List<String> nomes = new ArrayList<>();
            private String titulo;

            public Loja(String titulo) {
                this.titulo = titulo;
            }

            public void add(String nome) {
                nomes.add(nome);
            }

            @Override
            public int compareTo(Loja outra) {
                return titulo.compareTo(outra.titulo);
            }

            public static void main(String[] args) {
                Loja loja = new Loja("centro");
                for (String a : args) {
                    loja.add(a);
                }
                try {
                    System.out.println(loja.nomes.size());
                } catch (RuntimeException e) {
                    e.printStackTrace();
                }
            }
        }
        """, .java)
        #expect(achados.isEmpty, "acusou código certo: \(conta(achados))")
    }

    /// `import java.util.*` traz nomes que a Odete não enxerga. O certo é calar o arquivo
    /// inteiro, não chutar.
    @Test func javaComImportCoringaCala() {
        let achados = erros("""
        import java.util.*;

        public class App {
            void f() {
                ArrayList lista = new ArrayList();
                lista.size();
            }
        }
        """, .java)
        #expect(achados.isEmpty, "com `*` não dá para saber o que entrou: \(conta(achados))")
    }

    // MARK: - o índice do projeto

    let tela = """
    package loja

    type Tela struct {
    	Titulo string
    }

    func NovaTela(t string) Tela {
    	return Tela{Titulo: t}
    }
    """

    /// Em Go o pacote é a pasta: `NovaTela` declarada em `tela.go` vale em `main.go` sem
    /// import nenhum. Sem ler o projeto, isto viraria erro em todo arquivo com mais de um
    /// arquivo — que é todo projeto de verdade.
    @Test func goEnxergaDeclaracaoDoArquivoVizinho() {
        let main = """
        package loja

        func main() {
        	_ = NovaTela("centro")
        }
        """
        #expect(!erros(main, .go, path: "loja/main.go").isEmpty, "sem índice o nome é mesmo desconhecido")

        let indice = Resolvedor.Indice(arquivos: [("loja/tela.go", tela)])
        let achados = erros(main, .go, path: "loja/main.go", indice: indice)
        #expect(achados.isEmpty, "o vizinho declara: \(conta(achados))")
    }

    /// E não pode virar vale-tudo: em Go, outra pasta é outro pacote.
    @Test func goNaoEnxergaOutraPasta() {
        let main = """
        package outro

        func main() {
        	_ = NovaTela("centro")
        }
        """
        let indice = Resolvedor.Indice(arquivos: [("loja/tela.go", tela)])
        #expect(
            !erros(main, .go, path: "outro/main.go", indice: indice).isEmpty,
            "pasta diferente é pacote diferente"
        )
    }

    /// Java acha a classe pelo nome no projeto todo.
    @Test func javaEnxergaClasseDeOutraPasta() {
        let indice = Resolvedor.Indice(arquivos: [("br/com/loja/Tela.java", """
        package br.com.loja;

        public class Tela {
            public String titulo;
        }
        """)])
        let main = """
        package br.com.app;

        public class App {
            void f() {
                Tela t = new Tela();
                t.titulo = "x";
            }
        }
        """
        #expect(!erros(main, .java, path: "br/com/app/App.java").isEmpty, "sem índice, desconhecida")
        let achados = erros(main, .java, path: "br/com/app/App.java", indice: indice)
        #expect(achados.isEmpty, "a classe existe no projeto: \(conta(achados))")
    }

    @Test func declaracoesDoArquivoSaemPeloNome() {
        let nomes = Resolvedor.declaracoes(text: tela, language: .go)
        #expect(nomes.contains("NovaTela"))
        #expect(nomes.contains("Tela"))
    }

    /// Python não entra no índice: lá o módulo é a unidade e o que vem de fora vem por
    /// import. Enxergar o vizinho seria aceitar nome que o interpretador recusa.
    @Test func pythonNaoEnxergaVizinho() {
        let indice = Resolvedor.Indice(arquivos: [("app/loja.py", "class Loja:\n    pass\n")])
        #expect(
            !erros("l = Loja()\n", .python, path: "app/main.py", indice: indice).isEmpty,
            "em Python o vizinho só chega por import"
        )
    }

    // MARK: - o resto

    /// Com erro de sintaxe os nomes saem trocados: quem fala é o ParserErros, não este.
    @Test func comSintaxeQuebradaNaoInventa() {
        #expect(erros("package main\n\nfunc main() {\n\t_ = foo(\n}\n", .go).isEmpty)
    }

    /// Ler o projeto inteiro só se paga onde muda a resposta.
    @Test func soIndexaQuemPrecisaDoIndice() {
        #expect(Resolvedor.usaIndice(.go) && Resolvedor.usaIndice(.java))
        #expect(!Resolvedor.usaIndice(.python), "em Python o que vem de fora vem por import")
        #expect(!Resolvedor.usaIndice(.typescript) && !Resolvedor.usaIndice(.tsx))
        #expect(!Resolvedor.usaIndice(.rust))
    }

    @Test func linguagemSemPerfilNaoDizNada() {
        #expect(!Resolvedor.temResolvedor(.rust))
        #expect(!Resolvedor.temResolvedor(.c))
        #expect(erros("fn main() { let x = yyy(); }", .rust).isEmpty)
        #expect(Resolvedor.temResolvedor(.go) && Resolvedor.temResolvedor(.java))
    }
}
