import Foundation
import OdeteCore
import Testing

/// Linguagem sem gramática fica branca na tela, e linguagem sem lint não avisa nada.
/// Estes testes existem porque os dois sintomas eram invisíveis: o arquivo abria.
struct LinguagemTests {
    @Test func astroEOsOutrosSaemDoPlain() {
        let casos: [(String, Language)] = [
            ("src/pages/index.astro", .astro), ("App.svelte", .svelte), ("main.rs", .rust),
            ("main.c", .c), ("main.cpp", .cpp), ("Program.cs", .csharp), ("main.go", .go),
            ("App.java", .java), ("app.py", .python), ("app.rb", .ruby), ("index.php", .php),
            ("deploy.sh", .bash), ("schema.sql", .sql), ("Cargo.toml", .toml), ("init.lua", .lua),
            ("icone.svg", .xml), ("Info.plist", .xml), ("estilo.scss", .scss),
            ("script.pl", .perl), ("analise.r", .r), ("Main.hs", .haskell), ("app.ex", .elixir),
            ("Main.elm", .elm), ("lib.ml", .ocaml), ("calc.jl", .julia), ("tese.tex", .latex),
        ]
        for (caminho, esperado) in casos {
            #expect(Language.detect(path: caminho) == esperado, "\(caminho) virou \(Language.detect(path: caminho))")
        }
    }

    /// Arquivo sem extensão que todo projeto tem.
    @Test func arquivoSemExtensaoTambemTemDono() {
        #expect(Language.detect(path: "Dockerfile") == .bash)
        #expect(Language.detect(path: "a/b/Makefile") == .bash)
        #expect(Language.detect(path: "Gemfile") == .ruby)
        #expect(Language.detect(path: "package.json") == .json)
    }

    /// Toda linguagem precisa de pelo menos um jeito de chegar até ela, senão ela existe
    /// no enum e nunca é escolhida — que é o mesmo que não existir.
    @Test func todaLinguagemTemExtensao() {
        for lang in Language.allCases where lang != .plain {
            let exts = Language.extensoes[lang] ?? []
            #expect(!exts.isEmpty, "\(lang.rawValue) não tem extensão nenhuma")
            for e in exts {
                #expect(Language.detect(path: "arquivo.\(e)") == lang, ".\(e) não leva a \(lang.rawValue)")
            }
        }
    }

    @Test func oQueNaoConheceContinuaSendoTexto() {
        #expect(Language.detect(path: "notas.xyz") == .plain)
        #expect(Language.detect(path: "sem-ponto") == .plain)
    }
}

/// O linter tinha quatro linguagens. Um `}` sobrando em Rust não aparecia em lugar nenhum.
struct SintaxeTests {
    func erros(_ texto: String, _ lang: Language) -> [LintIssue] {
        Lint.rules(text: texto, language: lang).filter { $0.severity == .error }
    }

    @Test func chaveSobrandoApareceEmQualquerLinguagem() {
        let casos: [(Language, String, Int)] = [
            (.rust, "fn main() {\n    println!(\"oi\");\n}\n}\n", 4),
            (.c, "int main(void) {\n  return 0;\n}\n}\n", 4),
            (.go, "func main() {\n}\n}\n", 3),
            (.java, "class A {\n}\n}\n", 3),
            (.php, "<?php\nfunction f() {\n}\n}\n", 4),
        ]
        for (lang, codigo, esperada) in casos {
            let achados = erros(codigo, lang)
            #expect(!achados.isEmpty, "\(lang.rawValue): não achou a chave sobrando")
            #expect(
                achados.first?.line == esperada,
                "\(lang.rawValue): apontou a linha \(achados.first?.line ?? -1) e não a \(esperada)"
            )
        }
    }

    @Test func chaveQueNaoFechaApontaOndeAbriu() {
        let achados = erros("fn main() {\n    let x = 1;\n", .rust)
        #expect(achados.count == 1)
        #expect(achados.first?.line == 1, "tem que apontar onde abriu, que é onde se conserta")
    }

    @Test func parTrocadoEhErro() {
        let achados = erros("int f(void) {\n  int a[2] = (1, 2];\n}\n", .c)
        #expect(achados.contains { $0.rule == "par-trocado" }, "fechar `[` com `)` passou batido")
    }

    /// O ponto que faz um verificador de chaves servir ou atrapalhar: chave dentro de
    /// texto e de comentário não conta.
    @Test func chaveEmTextoEEmComentarioNaoConta() {
        let casos: [(Language, String)] = [
            (.rust, "fn main() {\n    let s = \"} } }\";\n    // }\n    /* } */\n}\n"),
            (.python, "s = '}'\n# }\nd = \"\"\"\n}\n\"\"\"\n"),
            (.bash, "echo \"}\"\n# }\n"),
            (.sql, "select '}' from t; -- }\n"),
            (.lua, "local s = \"}\"\n-- }\n"),
        ]
        for (lang, codigo) in casos {
            #expect(
                erros(codigo, lang).isEmpty,
                "\(lang.rawValue): acusou erro em código válido: \(erros(codigo, lang))"
            )
        }
    }

    @Test func textoQueNaoFechaEhErro() {
        let achados = erros("let s = \"não fecha\nlet t = 1\n", .rust)
        #expect(achados.contains { $0.rule == "texto-aberto" })
        #expect(achados.first?.line == 1)
    }

    @Test func tagDeMarcacaoQueNaoFecha() {
        let achados = erros("<html>\n<body>\n<div>\n</body>\n</html>\n", .html)
        #expect(!achados.isEmpty, "fechar body com div aberta passou batido")
    }

    @Test func tagQueFechaSozinhaNaoEhErro() {
        let bom = "<html>\n<head><meta charset=\"utf-8\" /><br></head>\n<body><img src=\"a.png\"></body>\n</html>\n"
        #expect(erros(bom, .html).isEmpty, "acusou erro em HTML válido: \(erros(bom, .html))")
    }

    @Test func pythonCobraDoisPontosERecuoMisturado() {
        let achados = erros("def f()\n    return 1\n", .python)
        #expect(achados.contains { $0.rule == "py-dois-pontos" }, "não cobrou o `:`")
        let recuo = erros("def f():\n \tif True:\n\t\treturn 1\n", .python)
        #expect(recuo.contains { $0.rule == "py-recuo" }, "não viu espaço misturado com tabulação")
    }

    @Test func yamlNaoAceitaTabulacao() {
        #expect(erros("a:\n\tb: 1\n", .yaml).contains { $0.rule == "yaml-tab" })
        #expect(erros("a:\n  b: 1\n", .yaml).isEmpty)
    }

    /// Um arquivo de verdade, correto, não pode acusar nada.
    @Test func codigoValidoNaoAcusaNada() {
        let rust = """
        use std::collections::HashMap;

        /// Soma os valores de um mapa.
        fn soma(m: &HashMap<String, i32>) -> i32 {
            let mut total = 0;
            for (_, v) in m {
                total += *v;
            }
            total
        }

        fn main() {
            let mut m = HashMap::new();
            m.insert("a".to_string(), 1);
            println!("{}", soma(&m));
        }
        """
        #expect(erros(rust, .rust).isEmpty, "acusou erro em Rust válido: \(erros(rust, .rust))")
    }
}
