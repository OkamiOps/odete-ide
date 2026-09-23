import Foundation
import OdeteAccounts
import OdeteAgent
@testable import OdeteApp
import OdeteCore
import OdeteFiles
import OdeteGit
import OdeteI18n
import Testing

/// Conta as leituras de status do teste de rodadas. Lido de dentro da rodada (fora do
/// ator principal) e do teste, então com trava.
final class Roteiro: @unchecked Sendable {
    private let trava = NSLock()
    private var chamadas = 0
    private var _leu = false

    func chamada() -> Int {
        trava.withLock {
            chamadas += 1
            return chamadas
        }
    }

    var leu: Bool {
        get { trava.withLock { _leu } }
        set { trava.withLock { _leu = newValue } }
    }
}

/// O "M" da árvore e o número do ícone do git têm de acompanhar o disco.
///
/// No QA: arquivo mudado por fora (o `sed -i` grava um temporário e renomeia por cima), o
/// "M" aparece; o conteúdo original devolvido byte a byte com `cp` (que escreve no lugar)
/// e o "M" ficava lá por minutos, com `git status` limpo no disco. Escrever no lugar não
/// mexe na pasta, e o observador de pastas não vê; o observador por arquivo só vigiava
/// as abas, e o aviso dele relia o buffer sem pedir o status ao git.
@MainActor
@Suite(.serialized)
struct MarcasDoGitTests {
    init() {
        Texto.escolher(.ptBR)
    }

    /// Projeto em branco com tudo commitado, e o workspace aberto nele.
    func projetoComGit() async throws -> (WorkspaceModel, URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-marcas-\(UUID().uuidString)")
        let store = ProjectStore(root: base)
        let p = try store.create(name: "T", template: .blank)
        let pasta = store.url(for: p)
        let repo = try Repository.initialize(at: pasta)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: Signature(name: "T", email: "t@t"))
        let chrome = ChromeState()
        chrome.snapshot.editor.autoSave = false
        let ws = WorkspaceModel(
            project: p,
            root: pasta,
            chrome: chrome,
            accounts: AccountStore(url: base.appending(path: "accounts.json"), keychain: MemorySecrets()),
            aiAccounts: AIAccountStore(url: base.appending(path: "ai.json"), secrets: MemorySecrets())
        )
        return (ws, pasta)
    }

    func espera(_ prazo: Duration = .seconds(5), ate condicao: () -> Bool) async {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim, !condicao() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Espera o git ler o repositório e o observador armar nas pastas.
    ///
    /// O observador arma na fila dele, com prioridade baixa. Com a suíte inteira rodando em
    /// paralelo, a escrita logo depois de abrir o projeto chegava antes de ele vigiar a
    /// pasta, e o teste falhava por um motivo que não é o que ele mede.
    func pronto(_ ws: WorkspaceModel) async throws {
        await espera { ws.git.isRepo && ws.git.log.count == 1 }
        try await Task.sleep(for: .milliseconds(600))
    }

    /// A rodada que marcou o arquivo como mudado é a que manda o observador vigiá-lo;
    /// escrever antes de ele armar seria testar a fila do observador.
    func observadorArmado() async throws {
        try await Task.sleep(for: .milliseconds(600))
    }

    /// Como o `cp`: trunca e escreve no mesmo arquivo, sem renomear nada.
    func escreverNoLugar(_ dados: Data, em arquivo: URL) throws {
        let h = try FileHandle(forWritingTo: arquivo)
        try h.truncate(atOffset: 0)
        try h.write(contentsOf: dados)
        try h.close()
    }

    func modificado(_ ws: WorkspaceModel, _ caminho: String) -> Bool {
        modificado(ws.git, caminho)
    }

    func modificado(_ git: GitModel, _ caminho: String) -> Bool {
        git.status.contains { $0.path == caminho && $0.unstaged == .modified }
    }

    /// Mudar e voltar ao original, sem aba aberta.
    @Test func voltaAoOriginalSemAbaLimpaAMarca() async throws {
        let (ws, pasta) = try await projetoComGit()
        defer { ws.stop() }
        let arquivo = pasta.appending(path: "src/main.js")
        let original = try Data(contentsOf: arquivo)
        try await pronto(ws)
        #expect(ws.git.isClean)

        try Data("// mudou por fora\n".utf8).write(to: arquivo, options: .atomic)
        await espera { modificado(ws, "src/main.js") }
        #expect(modificado(ws, "src/main.js"), "a mudança de fora não virou M")

        try await observadorArmado()
        try escreverNoLugar(original, em: arquivo)
        await espera { ws.git.isClean }
        #expect(ws.git.isClean, "o arquivo voltou ao original e o M ficou: \(ws.git.status)")
    }

    /// Duas rodadas de status ao mesmo tempo: a velha leu o disco antes de o arquivo voltar
    /// ao original e termina depois da nova. O que ela leu é passado e não pode ganhar.
    @Test func rodadaVelhaNaoGravaPorCimaDaNova() async throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-rodadas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let arquivo = base.appending(path: "a.txt")
        let original = Data("original\n".utf8)
        try original.write(to: arquivo)
        let repo = try Repository.initialize(at: base)
        try await repo.stageAll()
        try await repo.commit(message: "base", author: Signature(name: "T", email: "t@t"))
        try Data("mudou\n".utf8).write(to: arquivo, options: .atomic)

        // Sem workspace: só o modelo do git, sem observador acordando rodadas por fora.
        let contas = FileManager.default.temporaryDirectory.appending(path: "odete-contas-\(UUID().uuidString).json")
        let git = GitModel(root: base, accounts: AccountStore(url: contas, keychain: MemorySecrets()))
        await espera { git.log.count == 1 && modificado(git, "a.txt") }
        #expect(modificado(git, "a.txt"))

        // A primeira rodada lê o status agora (com o M) e só devolve bem depois.
        let roteiro = Roteiro()
        git.lerStatus = { repo in
            let lido = try await repo.status()
            if roteiro.chamada() == 1 {
                roteiro.leu = true
                try await Task.sleep(for: .milliseconds(800))
            }
            return lido
        }
        let velha = Task { await git.atualizarMarcas() }
        await espera { roteiro.leu }
        #expect(roteiro.leu, "a rodada velha não chegou a ler")

        try escreverNoLugar(original, em: arquivo)
        await git.atualizarMarcas()
        #expect(git.isClean, "a rodada nova não viu o arquivo limpo: \(git.status)")

        await velha.value
        #expect(git.isClean, "a rodada velha gravou o status de antes por cima: \(git.status)")
    }

    /// O mesmo, com o arquivo aberto numa aba: o aviso do arquivo relia o buffer e parava ali.
    @Test func voltaAoOriginalComAbaLimpaAMarca() async throws {
        let (ws, pasta) = try await projetoComGit()
        defer { ws.stop() }
        ws.openFile("src/main.js")
        let arquivo = pasta.appending(path: "src/main.js")
        let original = try Data(contentsOf: arquivo)
        try await pronto(ws)
        #expect(ws.git.isClean)

        try Data("// mudou por fora\n".utf8).write(to: arquivo, options: .atomic)
        await espera { modificado(ws, "src/main.js") && ws.text(for: "src/main.js") == "// mudou por fora\n" }
        #expect(modificado(ws, "src/main.js"), "a mudança de fora não virou M")

        // O observador da aba rearma depois do renome do temporário por cima.
        try await observadorArmado()
        try escreverNoLugar(original, em: arquivo)
        await espera { ws.git.isClean }
        #expect(ws.git.isClean, "o arquivo voltou ao original e o M ficou: \(ws.git.status)")
        #expect(ws.text(for: "src/main.js") == String(decoding: original, as: UTF8.self))
    }
}
