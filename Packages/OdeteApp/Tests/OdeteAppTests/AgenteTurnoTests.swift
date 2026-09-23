import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteShell
import Synchronization
import Testing

/// Provedor com roteiro para o painel do agente: cada pedido tira a próxima rodada.
final class ProvedorDeTeste: Provider, @unchecked Sendable {
    let kind: ProviderKind = .openaiCompat
    let rodadas: Mutex<[[StreamEvent]]>
    let pedidos = Mutex<[TurnRequest]>([])

    init(_ rodadas: [[StreamEvent]]) {
        self.rodadas = Mutex(rodadas)
    }

    func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        pedidos.withLock { $0.append(turn) }
        let eventos = rodadas.withLock { $0.isEmpty ? [.text("fim"), .done] : $0.removeFirst() }
        return AsyncThrowingStream { cont in
            for e in eventos {
                cont.yield(e)
            }
            cont.finish()
        }
    }

    func models() async throws -> [ModelInfo] {
        [ModelInfo(id: "teste")]
    }
}

/// O painel do agente em volta do laço: gravar no meio do turno, patches sem perder o que
/// está no editor, o desfazer avisando o modelo, a saída do terminal e o `/compact`.
@MainActor
@Suite(.serialized) struct AgenteTurnoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func make() throws -> (ws: WorkspaceModel, raiz: URL, chrome: ChromeState) {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-turno-\(UUID().uuidString)")
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
        return (ws, store.url(for: p), chrome)
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

    func esperar(_ condicao: () -> Bool) async throws {
        for _ in 0 ..< 200 where !condicao() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A conversa só ia para o disco no fim do turno: um turno morto no meio levava junto
    /// tudo o que tinha feito.
    @Test func aConversaVaiParaODiscoNoMeioDoTurno() async throws {
        let (ws, raiz, _) = try make()
        let ag = try #require(ws.agent)
        ag.setPermit(.ask)
        ag.provedorFixo = ProvedorDeTeste([
            [.text("vou criar"), .tools([chamada("write_file", ["path": "n.txt", "content": "novo\n"])]), .done],
            [.text("criei"), .done],
        ])
        ag.draft = "cria n.txt"
        ag.send()
        // Parado na licença: a rodada já aconteceu, o turno ainda não acabou.
        try await esperar { ag.pendingPermit != nil }
        #expect(ag.running)
        let noDisco = try #require(ChatStore(root: raiz).load(ag.thread.id), "nada foi gravado no meio do turno")
        #expect(noDisco.messages.contains { $0.toolCalls?.first?.name == "write_file" })
        try ag.approve(#require(ag.pendingPermit), true)
        try await esperar { !ag.running }
        #expect(ler(raiz, "n.txt") == "novo\n")
        ws.stop()
    }

    /// Aceitar ou rejeitar todos recarregava todas as abas: a edição não salva de um
    /// arquivo que patch nenhum tocava sumia.
    @Test func aceitarTodosNaoApagaOQueEstaDigitadoEmOutraAba() async throws {
        let (ws, raiz, chrome) = try make()
        chrome.snapshot.editor.autoSave = false
        let ag = try #require(ws.agent)
        try escrever(raiz, "a.txt", "um\n")
        try escrever(raiz, "c.txt", "três\n")
        let runner = ToolRunner(host: ag.host, patches: ag.patches, checkpoints: ag.checkpoints)
        _ = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "um", "new": "UM"]), mode: .build)
        ws.openFile("c.txt")
        ws.setText("três, digitado sem salvar\n", for: "c.txt")
        ag.acceptAll()
        #expect(ws.text(for: "c.txt") == "três, digitado sem salvar\n", "aceitar todos recarregou a aba de fora")
        _ = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "UM", "new": "Um"]), mode: .build)
        ag.rejectAll()
        #expect(ws.text(for: "c.txt") == "três, digitado sem salvar\n", "rejeitar todos recarregou a aba de fora")
        #expect(ler(raiz, "a.txt") == "UM\n")
        ws.stop()
    }

    /// Rejeitar depois de a pessoa mexer no arquivo pergunta, em vez de marcar e sumir.
    @Test func rejeitarComOArquivoMudadoPergunta() async throws {
        let (ws, raiz, _) = try make()
        let ag = try #require(ws.agent)
        try escrever(raiz, "a.txt", "um\n")
        let runner = ToolRunner(host: ag.host, patches: ag.patches, checkpoints: ag.checkpoints)
        let out = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "um", "new": "UM"]), mode: .build)
        let patch = try #require(out.patch)
        try escrever(raiz, "a.txt", "UM, e a pessoa escreveu\n")
        ag.reject(patch)
        #expect(ag.conflitos.map(\.id) == [patch.id])
        #expect(ag.patches.get(patch.id)?.status == .pending)
        ag.resolverConflitos(voltar: false)
        #expect(ler(raiz, "a.txt") == "UM, e a pessoa escreveu\n" && ag.conflitos.isEmpty)
        #expect(ag.patches.pending.isEmpty)
        ws.stop()
    }

    /// O desfazer não contava ao modelo: no turno seguinte ele trabalhava em cima de
    /// mudanças que não existiam mais.
    @Test func oDesfazerFicaAnotadoNaConversa() async throws {
        let (ws, raiz, _) = try make()
        let ag = try #require(ws.agent)
        try escrever(raiz, "a.txt", "um\n")
        let runner = ToolRunner(host: ag.host, patches: ag.patches, checkpoints: ag.checkpoints)
        ag.checkpoints.take(title: "turno")
        _ = await runner.run(chamada("str_replace", ["path": "a.txt", "old": "um", "new": "UM"]), mode: .build)
        _ = await runner.run(chamada("write_file", ["path": "novo.txt", "content": "x"]), mode: .build)
        ag.checkpoints.encerrar()
        _ = ag.undoLastTurn()
        let nota = try #require(ag.thread.messages.last)
        #expect(nota.role == .user && nota.content.contains("desfez"))
        #expect(nota.content.contains("a.txt") && nota.content.contains("novo.txt"))
        // E ela vai junto com a próxima mensagem.
        let provedor = ProvedorDeTeste([[.text("entendi"), .done]])
        ag.provedorFixo = provedor
        ag.draft = "e agora?"
        ag.send()
        try await esperar { !ag.running }
        let enviado = try #require(provedor.pedidos.withLock { $0.first })
        #expect(enviado.messages.last?.content.contains("desfez") == true)
        #expect(enviado.messages.last?.content.contains("e agora?") == true)
        ws.stop()
    }

    /// `/compact` no compositor compacta na hora, sem turno.
    @Test func compactarPeloCompositor() async throws {
        let (ws, _, _) = try make()
        let ag = try #require(ws.agent)
        let provedor = ProvedorDeTeste([[.text("## Objetivo\n- seguir"), .done]])
        ag.provedorFixo = provedor
        var ms: [AgentMessage] = []
        for i in 0 ..< 6 {
            ms.append(.user("pedido \(i)"))
            ms.append(AgentMessage(role: .assistant, content: String(repeating: "resposta \(i) ", count: 1500)))
        }
        ag.carregarParaTeste(ms)
        ag.draft = "/compact"
        ag.send()
        try await esperar { !ag.running && !provedor.pedidos.withLock { $0.isEmpty } }
        try await esperar { !ag.running }
        #expect(try Compactacao.ehResumo(#require(ag.thread.messages.first)))
        #expect(ag.items.contains {
            if case let .compactado(_, resumo, _, _) = $0 {
                !resumo.isEmpty
            } else {
                false
            }
        })
        #expect(provedor.pedidos.withLock { $0.first?.tools.isEmpty } == true)
        #expect(ag.draft.isEmpty)
        ws.stop()
    }

    /// Parar não interrompia o `run_shell`: o agente esperava o comando até cinco minutos,
    /// sem nem mandar o Ctrl-C para a aba.
    @Test func pararInterrompeOComandoDoTerminal() async throws {
        let (ws, _, _) = try make()
        let ag = try #require(ws.agent)
        let host = ag.host
        let inicio = ContinuousClock.now
        let comando = Task.detached { await host.runShell("sleep 30") }
        try await Task.sleep(for: .milliseconds(400))
        comando.cancel()
        let saida = await comando.value
        #expect(ContinuousClock.now - inicio < .seconds(8), "esperou o comando acabar")
        #expect(saida.contains("interrompido"), "\(saida)")
        #expect(ws.run.agentSession().lines.contains { $0.text == "^C" }, "a aba não recebeu o Ctrl-C")
        ws.stop()
    }

    /// A saída do `run_shell` pela marca do `id`, e não pela posição: com a aba cheia (5000
    /// linhas) a posição de início não existia mais e vinha "(sem saída)"; com `clear` no
    /// meio, `lines[start...]` saía do fim da lista.
    @Test func saidaDoTerminalCheioOuLimpo() throws {
        let raiz = FileManager.default.temporaryDirectory.appending(path: "odete-term-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        let s = TerminalSession(shell: Shell(root: raiz), banner: false)
        for i in 0 ..< TerminalSession.teto {
            s.append(.out, "velha \(i)")
        }
        s.append(.input, "odete % npm test")
        let marca = try #require(s.lines.last?.id)
        for i in 0 ..< 10 {
            s.append(.out, "nova \(i)")
        }
        let saida = AppToolHost.saida(s.lines, depoisDe: marca)
        #expect(saida == (0 ..< 10).map { "nova \($0)" }.joined(separator: "\n"))

        // Saída maior que a rolagem: diz quantas linhas se perderam.
        s.append(.input, "odete % npm install")
        let outra = try #require(s.lines.last?.id)
        for i in 0 ..< TerminalSession.teto + 50 {
            s.append(.out, "linha \(i)")
        }
        let longa = AppToolHost.saida(s.lines, depoisDe: outra)
        #expect(longa.hasPrefix("… (as primeiras 50 linhas saíram da rolagem do terminal)"))
        #expect(longa.hasSuffix("linha \(TerminalSession.teto + 49)"))

        // `clear` no meio.
        s.append(.input, "odete % clear && ls")
        let terceira = try #require(s.lines.last?.id)
        s.append(.out, "\u{1B}[clear]")
        s.append(.out, "a.txt")
        #expect(AppToolHost.saida(s.lines, depoisDe: terceira).hasSuffix("a.txt"))
    }
}
