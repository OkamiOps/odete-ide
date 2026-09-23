import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import Testing

/// O "desfazer último turno" do painel do agente: o que a pessoa mexeu depois fica, a
/// tela sabe perguntar antes, e o resultado vai para a conversa como aviso, não erro.
@MainActor
@Suite(.serialized) struct DesfazerTurnoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> (ws: WorkspaceModel, raiz: URL, chrome: ChromeState, base: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-desfazer-\(UUID().uuidString)")
        let store = ProjectStore(root: base)
        let p = try store.create(name: "T", template: .blank)
        let chrome = ChromeState()
        let ws = WorkspaceModel(
            project: p,
            root: store.url(for: p),
            chrome: chrome,
            accounts: AccountStore(url: base.appending(path: "contas-teste.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: base.appending(path: "ia-teste.json"), secrets: MemorySecrets())
        )
        return (ws, store.url(for: p), chrome, base)
    }

    func escrever(_ raiz: URL, _ p: String, _ texto: String) throws {
        let u = raiz.appending(path: p)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    func ler(_ raiz: URL, _ p: String) -> String? {
        try? String(contentsOf: raiz.appending(path: p), encoding: .utf8)
    }

    func chamada(_ nome: String, _ args: [String: String]) -> ToolCall {
        ToolCall(
            id: UUID().uuidString,
            name: nome,
            arguments: String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        )
    }

    @Test func oQueAPessoaMexeuDepoisFicaEOAvisoDizPorQue() async throws {
        let (ws, raiz, _, _) = try make()
        let ag = try #require(ws.agent)
        try escrever(raiz, "a.txt", "um\n")
        try escrever(raiz, "b.txt", "dois\n")
        let runner = ToolRunner(host: ag.host, patches: ag.patches, checkpoints: ag.checkpoints)
        ag.checkpoints.take(title: "turno")
        _ = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "um", "new": "UM"]), mode: .build)
        _ = await runner.run(chamada("str_replace", ["path": "b.txt", "old": "dois", "new": "DOIS"]), mode: .build)
        _ = await runner.run(chamada("write_file", ["path": "novo.txt", "content": "do agente"]), mode: .build)
        ag.checkpoints.encerrar()
        // A pessoa, depois do turno: edita por cima de um e cria outro.
        try escrever(raiz, "b.txt", "DOIS, e a minha linha\n")
        try escrever(raiz, "meu.txt", "da pessoa")

        #expect(ag.mexidosDepoisDoUltimoTurno() == ["b.txt"], "a tela não teria como perguntar antes")
        let msg = ag.undoLastTurn()
        #expect(ler(raiz, "a.txt") == "um\n")
        #expect(ler(raiz, "b.txt") == "DOIS, e a minha linha\n", "a edição da pessoa foi sobrescrita")
        #expect(ler(raiz, "novo.txt") == nil)
        #expect(ler(raiz, "meu.txt") == "da pessoa", "o arquivo que a pessoa criou foi apagado")
        #expect(msg.hasPrefix("voltou: turno"))
        #expect(msg.contains("Não voltaram, porque você mexeu neles depois do turno: b.txt"))

        // Aviso, não erro: nada de "Tentar de novo" embaixo dele.
        guard case let .error(id, texto)? = ag.items.last else {
            Issue.record("o resultado do desfazer não foi para a conversa")
            return
        }
        #expect(AgentModel.ehAvisoDoDesfazer(id) && texto == msg)
        #expect(!AgentModel.ehErroQueDaParaRepetir(ag.items.last))
        // Só os patches do que voltou ou saiu são rejeitados; o do arquivo que a pessoa
        // editou continua para ela decidir.
        #expect(ag.patches.pending.map(\.path) == ["b.txt"])
        #expect(!ag.canUndoTurn && ag.mexidosDepoisDoUltimoTurno().isEmpty)
        ws.stop()
    }

    /// O que está digitado no editor e não foi gravado também é trabalho da pessoa.
    ///
    /// O desfazer recarregava todas as abas do disco: a edição não salva sumia, até num
    /// arquivo que o turno nem tinha tocado.
    @Test func aEdicaoNaoSalvaNoEditorNaoSomeNoDesfazer() async throws {
        let (ws, raiz, chrome, _) = try make()
        chrome.snapshot.editor.autoSave = false
        let ag = try #require(ws.agent)
        try escrever(raiz, "a.txt", "um\n")
        try escrever(raiz, "c.txt", "três\n")
        let runner = ToolRunner(host: ag.host, patches: ag.patches, checkpoints: ag.checkpoints)
        ag.checkpoints.take(title: "turno")
        _ = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "um", "new": "UM"]), mode: .build)
        ag.checkpoints.encerrar()
        ws.openFile("a.txt")
        ws.openFile("c.txt")
        ws.setText("UM, e digitei sem salvar\n", for: "a.txt")
        ws.setText("três, sem salvar\n", for: "c.txt")

        #expect(ag.mexidosDepoisDoUltimoTurno() == ["a.txt"])
        let msg = ag.undoLastTurn()
        #expect(ws.text(for: "a.txt") == "UM, e digitei sem salvar\n", "a edição não salva sumiu")
        #expect(ws.text(for: "c.txt") == "três, sem salvar\n", "a aba que o turno nem tocou foi recarregada")
        #expect(ler(raiz, "a.txt") == "UM\n", "com o salvamento desligado, o desfazer não grava pela pessoa")
        #expect(msg.contains("Não voltaram, porque você mexeu neles depois do turno: a.txt"))
        ws.stop()
    }

    /// Com o salvamento automático ligado, o que ia para o disco no segundo seguinte vai
    /// antes do desfazer, e ele enxerga a edição.
    @Test func comSalvamentoAutomaticoOEditorGravaAntesDeDesfazer() async throws {
        let (ws, raiz, chrome, _) = try make()
        chrome.snapshot.editor.autoSave = true
        let ag = try #require(ws.agent)
        try escrever(raiz, "a.txt", "um\n")
        let runner = ToolRunner(host: ag.host, patches: ag.patches, checkpoints: ag.checkpoints)
        ag.checkpoints.take(title: "turno")
        _ = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "um", "new": "UM"]), mode: .build)
        ag.checkpoints.encerrar()
        ws.openFile("a.txt")
        ws.setText("UM, digitado agora\n", for: "a.txt")
        #expect(ag.mexidosDepoisDoUltimoTurno() == ["a.txt"])
        #expect(ler(raiz, "a.txt") == "UM, digitado agora\n")
        _ = ag.undoLastTurn()
        #expect(ler(raiz, "a.txt") == "UM, digitado agora\n" && ws.text(for: "a.txt") == "UM, digitado agora\n")
        ws.stop()
    }

    #if DEBUG
        /// O roteiro de QA toca um turno inteiro pelo agente de verdade, sem conta de IA e
        /// sem gravar nada de conta ou de modelo.
        @Test func oRoteiroDeQATocaSemContaESemGravarNada() async throws {
            let (ws, raiz, chrome, base) = try make()
            let ag = try #require(ws.agent)
            try escrever(raiz, "a.txt", "título\n")
            let roteiro = base.appending(path: "roteiro.json")
            try escrever(base, "roteiro.json", #"""
            {"turnos": [[
              {"ferramenta": "write_file", "argumentos": {"path": "qa/nota.md", "content": "nota do QA\n"}},
              {"ferramenta": "str_replace", "argumentos": {"path": "a.txt", "old": "título", "new": "título do QA"}},
              {"texto": "pronto"}
            ]]}
            """#)
            #expect(!ag.emRoteiro)
            setenv(ProvedorDeRoteiro.variavel, roteiro.path, 1)
            defer { unsetenv(ProvedorDeRoteiro.variavel) }
            #expect(ag.emRoteiro)
            #expect(Composer(agent: ag).nomeModelo == "Roteiro (QA)")
            let antes = chrome.snapshot.agentByProject[ws.project.id]

            ag.draft = "faz o roteiro"
            ag.send()
            #expect(ag.running, "sem conta, o envio parou no aviso de conectar uma conta")
            var espera = 0
            while ag.running, espera < 500 {
                // O modo padrão pede licença para escrever: aprova, como a pessoa faria.
                if let id = ag.pendingPermit {
                    ag.approve(id, true)
                }
                try await Task.sleep(for: .milliseconds(20))
                espera += 1
            }
            #expect(!ag.running)
            #expect(ler(raiz, "qa/nota.md") == "nota do QA\n")
            #expect(ler(raiz, "a.txt") == "título do QA\n")
            #expect(ag.items.contains {
                if case let .assistant(_, t) = $0 {
                    t == "pronto"
                } else {
                    false
                }
            })
            #expect(chrome.snapshot.agentByProject[ws.project.id] == antes, "o roteiro mexeu na conta ou no modelo")
            #expect(!FileManager.default.fileExists(atPath: base.appending(path: "ia-teste.json").path))

            // E o desfazer volta o turno do roteiro como volta o de um modelo.
            #expect(ag.canUndoTurn)
            _ = ag.undoLastTurn()
            #expect(ler(raiz, "qa/nota.md") == nil && ler(raiz, "a.txt") == "título\n")
            ws.stop()
        }
    #endif
}
