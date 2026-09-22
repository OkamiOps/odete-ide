import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteBundler
import OdeteCore
import OdeteFiles
import OdeteI18n
import OdetePreview
import Testing

/// O Markdown lido aos poucos tem que dar o mesmo que o lido de uma vez.
@MainActor
struct MarkdownIncrementalTests {
    static let resposta = """
    ## O que mudou

    - `src/main.ts` — trocou o **import**
    - `index.html` — título novo
    1. primeiro passo
    2. segundo passo

    Um parágrafo que
    continua na linha de baixo.

    > citação curta
    > que junta linhas

    ---

    ```ts
    const x = 1

    console.log(x)
    ```
    ### Riscos
    * nenhum *grave*
    Texto logo depois da lista.
    ```
    bloco sem fim
    """

    @Test func lotesDaoOMesmoQueALeituraInteira() {
        let texto = Self.resposta
        var cortes: [String.Index] = []
        var i = texto.startIndex
        var passo = 1
        while i < texto.endIndex {
            cortes.append(i)
            i = texto.index(i, offsetBy: passo, limitedBy: texto.endIndex) ?? texto.endIndex
            passo = passo % 7 + 1
        }
        cortes.append(texto.endIndex)
        let leitor = LeitorDeMarkdown()
        for c in cortes {
            let parcial = String(texto[..<c])
            let aos = leitor.blocos(parcial)
            let inteiro = MarkdownText.ler(Substring(parcial)).blocos
            #expect(aos == inteiro, "diferiu com \(parcial.count) caracteres")
            if aos != inteiro {
                return
            }
        }
        #expect(leitor.blocos(texto) == MarkdownText(text: texto).blocks)
    }

    /// Letra por letra, que é o pior caso para o ponto seguro.
    @Test func letraPorLetra() {
        let leitor = LeitorDeMarkdown()
        var parcial = ""
        for c in Self.resposta {
            parcial.append(c)
            #expect(leitor.blocos(parcial) == MarkdownText.ler(Substring(parcial)).blocos)
        }
    }

    /// Texto que não continua o anterior (outra mensagem, "tentar de novo"): recomeça.
    @Test func textoQueNaoContinuaRecomeca() {
        let leitor = LeitorDeMarkdown()
        _ = leitor.blocos("# Um\n\npara um\n\n")
        let outro = "- a\n- b\n\n# Dois\n"
        #expect(leitor.blocos(outro) == MarkdownText.ler(Substring(outro)).blocos)
        #expect(leitor.blocos("") == [])
    }

    /// A interpretação do trecho é guardada: a segunda leitura é a mesma.
    @Test func inlineGuardado() {
        let leitor = LeitorDeMarkdown()
        var vezes = 0
        let um = leitor.inline("**x**") { vezes += 1; return MarkdownText.interpretar($0) }
        let dois = leitor.inline("**x**") { vezes += 1; return MarkdownText.interpretar($0) }
        #expect(um == dois && vezes == 1)
    }
}

/// O menu de `@arquivo` e `/skill` lido do fim, igual à expressão de antes.
struct MencaoTests {
    /// A leitura antiga, copiada como estava.
    static func antiga(_ t: String) -> (arquivo: Bool, query: String, inicio: Int)? {
        guard let m = t.range(of: #"(?:^|\s)([@/])([\w./-]*)$"#, options: .regularExpression) else { return nil }
        var token = String(t[m])
        if token.first == " " || token.first == "\n" {
            token.removeFirst()
        }
        let start = t.index(m.upperBound, offsetBy: -token.count)
        return (token.hasPrefix("@"), String(token.dropFirst()), t.distance(from: t.startIndex, to: start))
    }

    @Test func igualAExpressao() {
        let casos = [
            "", "@", "/", "oi", "oi @", "oi /", "olha @src/ma", "roda /rev", "a@b", "x/y", "foo /a/b",
            "linha\n@index.h", "linha\n/deploy", "@@x", "e-mail a@b.com", "/review no @src/main.ts",
            "ação @açaí.ts", "fim com espaço @x ", "caminho ./src/@x", "-@x", " @./a-b_c.d",
        ]
        for t in casos {
            let nova = Composer.mencaoNoFim(t)
            let velha = Self.antiga(t)
            #expect((nova == nil) == (velha == nil), "\"\(t)\"")
            guard let nova, let velha else { continue }
            #expect((nova.kind == .file) == velha.arquivo, "\"\(t)\"")
            #expect(nova.query == velha.query, "\"\(t)\"")
            #expect(t.distance(from: t.startIndex, to: nova.range.lowerBound) == velha.inicio, "\"\(t)\"")
        }
        // Onde a leitura antiga errava: depois de um tab o `@` virava skill com "@" no nome.
        let tab = Composer.mencaoNoFim("tab\t@x")
        #expect(tab?.kind == .file && tab?.query == "x")
    }
}

/// O agente enxerga o que a tela mostra, e o pedido de conserto sai pronto.
@MainActor
@Suite(.serialized) struct AgenteNaTelaTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> (WorkspaceModel, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "odete-agente-\(UUID().uuidString)")
        let store = ProjectStore(root: root)
        let p = try store.create(name: "T", template: .blank)
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: ChromeState(),
            accounts: AccountStore(url: root.appending(path: "contas-teste.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: root.appending(path: "ia-teste.json"), secrets: MemorySecrets())
        )
        return (ws, store.url(for: p))
    }

    @Test func osProblemasDaTelaChegamAoAgente() async throws {
        let (ws, root) = try make()
        // Um arquivo sem análise de linguagem: nada do editor escreve por cima do lint do
        // teste depois que a primeira análise termina.
        try "notas\n".write(to: root.appending(path: "notas.txt"), atomically: true, encoding: .utf8)
        ws.reload()
        ws.openFile("notas.txt")
        try await Task.sleep(for: .milliseconds(400))
        ws.lint["notas.txt"] = [LintIssue(
            rule: "no-var",
            message: "use let",
            severity: .warning,
            line: 2,
            column: 1,
            length: 3
        )]
        ws.run.diagnostics = [OdeteBundler.Diagnostic(
            kind: .error,
            text: "Expected \";\"",
            file: root.appending(path: "src/main.js").path,
            line: 4,
            column: 9,
            source: "esbuild"
        )]
        ws.preview.log(.error, "x is not defined", file: "http://127.0.0.1:5173/src/main.js", line: 7)
        ws.preview.log(.log, "oi")

        let runner = ToolRunner(host: ws.agent.host, patches: ws.agent.patches)
        let texto = await runner.run(ToolCall(id: "1", name: "read_problems", arguments: "{}"), mode: .chat).text
        let linhas = texto.split(separator: "\n").map(String.init)
        #expect(linhas.first == "2 erros, 1 aviso")
        #expect(linhas.contains("src/main.js:4:9 error Expected \";\" (esbuild)"))
        #expect(linhas.contains("src/main.js:7 error x is not defined (preview)"))
        #expect(linhas.contains("notas.txt:2:1 warning use let (lint)"))

        let console = await runner.run(
            ToolCall(id: "2", name: "read_preview_console", arguments: #"{"n":1}"#),
            mode: .chat
        )
        #expect(console.text == "[log] oi")
        ws.stop()
    }

    @Test func consertarComOdetePreparaOPedido() throws {
        let (ws, _) = try make()
        let ag = try #require(ws.agent)
        ag.setMode(.chat)
        ag.draft = "o que eu estava escrevendo"
        let p = Problema(
            arquivo: "src/a.ts",
            linha: 3,
            coluna: 7,
            gravidade: .error,
            mensagem: "boom",
            fonte: "esbuild"
        )
        ag.consertarComOdete([p], enviar: false)
        #expect(ag.mode == .build, "no Chat o agente não edita — o conserto não andaria")
        #expect(ag.draft.contains("src/a.ts:3:7 error boom (esbuild)"))
        #expect(ag.draft.hasSuffix("o que eu estava escrevendo"), "o rascunho da pessoa sumiu")
        ws.stop()
    }

    /// A contagem do botão do histórico vem da pasta, não de decodificar tudo.
    @Test func contagemDeConversasSemDecodificar() throws {
        let (ws, _) = try make()
        let ag = try #require(ws.agent)
        #expect(ag.numeroDeConversas == 0)
        var t = ChatThread.blank()
        t.items = [.user(id: "1", text: "oi", images: nil)]
        ag.chats.save(t)
        #expect(ag.chats.count() == 1)
        #expect(ag.threads.count == 1)
        ag.remove(ag.threads[0])
        #expect(ag.numeroDeConversas == 0 && ag.threads.isEmpty)
        ws.stop()
    }
}
