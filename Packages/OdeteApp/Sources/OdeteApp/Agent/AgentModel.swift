import Foundation
import Observation
import OdeteAgent
import OdeteCore
import OdeteI18n
import UIKit

/// Estado do agente num projeto: conta/modelo, conversa ativa, execução, patches.
@MainActor
@Observable
public final class AgentModel {
    unowned let ws: WorkspaceModel
    let chrome: ChromeState
    public let accounts: AIAccountStore
    public let chats: ChatStore
    public let patches: PatchStore
    /// Espelho observável do estado de cada patch.
    ///
    /// O `PatchStore` roda fora do ator principal e não é `@Observable`: quem lia dele
    /// direto nunca era redesenhado. O cartão na conversa continuava oferecendo aceitar
    /// e rejeitar depois de a pessoa já ter aceitado — a barra de baixo sumia, o cartão
    /// não, e os dois falavam de estados diferentes do mesmo patch.
    public private(set) var porId: [String: Patch] = [:]
    public let checkpoints: CheckpointStore
    let host: AppToolHost

    public private(set) var thread: ChatThread
    public private(set) var items: [ChatItem] = []
    public private(set) var running = false
    public private(set) var pendingPermit: String?
    public var draft = ""
    public var attachments: [AgentImage] = []
    public var models: [ModelInfo] = []
    public var modelsError: String?
    public private(set) var loadingModels = false
    public var focusRequest = 0
    public private(set) var pendingPatches: [Patch] = []
    public var lastTurnUse = TokenUse()
    /// Quantas conversas há guardadas. Contadas pela pasta, sem abrir nenhuma, na
    /// abertura e depois de cada gravação: o botão do histórico mostrava `threads.count`,
    /// que lia e decodificava todas as conversas do projeto a cada redesenho do painel.
    public private(set) var numeroDeConversas = 0
    /// Há um turno para desfazer? Guardado aqui e atualizado quando um turno termina ou é
    /// desfeito — perguntar ao disco a cada redesenho decodificava os manifestos todos.
    public private(set) var temCheckpoint = false
    /// Sobe a cada mudança num item da conversa. É o que a lista observa para rolar até o
    /// fim — comparar o último item era comparar a resposta inteira a cada ficha.
    public private(set) var versaoDosItens = 0
    /// Sobe quando as conversas do disco mudam; quem lê `threads` fica ligado a ela.
    private var versaoDasConversas = 0
    @ObservationIgnored private var cacheDasConversas: [ChatThread]?
    @ObservationIgnored private var cacheDeSkills: [Skill]?
    /// A estimativa da conversa guardada com as mensagens de que ela saiu. Enquanto as
    /// mensagens forem as mesmas — o mesmo array, comparado de graça —, a conta não se
    /// refaz: ela rodava a cada tecla digitada no compositor.
    @ObservationIgnored private var estimativa: (mensagens: [AgentMessage], tokens: Int) = ([], 0)
    private var loop: AgentLoop?
    private var runTask: Task<Void, Never>?
    private var modelsFor: UUID?

    init(ws: WorkspaceModel, chrome: ChromeState, accounts: AIAccountStore) {
        self.ws = ws
        self.chrome = chrome
        self.accounts = accounts
        chats = ChatStore(root: ws.root)
        patches = PatchStore(root: ws.root)
        host = AppToolHost(ws: ws)
        checkpoints = CheckpointStore(root: ws.root, host: host)
        let prefs = chrome.snapshot.agentByProject[ws.project.id] ?? AgentPrefs()
        if let id = prefs.threadId,
           let t = chats.load(id)
        {
            thread = t
        } else {
            thread = chats.list().first ?? .blank()
        }
        items = thread.items
        numeroDeConversas = chats.count()
        temCheckpoint = checkpoints.last != nil
        pendingPatches = patches.pending
        porId = Self.indexar(patches.all)
        patches.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.pendingPatches = self.patches.pending
                self.porId = Self.indexar(self.patches.all)
            }
        }
        // Com o roteiro de QA ligado nada de conta nem modelo vai para o estado do app.
        if prefs.accountId == nil, let first = accounts.accounts.first, !emRoteiro {
            setAccount(first)
        }
    }

    /// O agente está tocando o roteiro de QA em vez de um modelo? Só pode ser verdade em
    /// DEBUG, com `ODETE_AGENTE_ROTEIRO` no ambiente — ver `ProvedorDeRoteiro`. Na versão
    /// da loja nem o nome da variável existe no binário.
    public var emRoteiro: Bool {
        #if DEBUG
            return ProvedorDeRoteiro.caminhoDoAmbiente() != nil
        #else
            return false
        #endif
    }

    // MARK: escolhas

    public var prefs: AgentPrefs {
        get { chrome.snapshot.agentByProject[ws.project.id] ?? AgentPrefs() }
        set { chrome.snapshot.agentByProject[ws.project.id] = newValue }
    }

    public var account: AIAccount? {
        accounts.accounts.first { $0.id == prefs.accountId } ?? accounts.accounts.first
    }

    public var model: String {
        prefs.model.isEmpty ? (account?.kind.defaultModel ?? "") : prefs.model
    }

    public var mode: AgentMode {
        AgentMode(rawValue: prefs.mode) ?? .build
    }

    public var permit: PermitMode {
        PermitMode(rawValue: prefs.permit) ?? .auto
    }

    public var effortOptions: [String] {
        Effort.options(
            kind: account?.kind ?? .openaiCompat,
            model: model,
            fromAPI: models.first { $0.id == model }?.efforts
        )
    }

    public var effort: String {
        let key = "\(account?.kind.rawValue ?? ""):\(model)"
        let stored = chrome.snapshot.agentEffortByModel[key] ?? ""
        return effortOptions.contains(stored) ? stored : Effort.defaultOption(effortOptions)
    }

    public func setAccount(_ a: AIAccount) {
        var p = prefs; p.accountId = a.id; p.model = ""; prefs = p; models = []; Task { await loadModels() }
    }

    public func setModel(_ m: String) {
        var p = prefs; p.model = m; prefs = p
    }

    public func setMode(_ m: AgentMode) {
        var p = prefs; p.mode = m.rawValue; prefs = p
    }

    public func setPermit(_ m: PermitMode) {
        var p = prefs; p.permit = m.rawValue; prefs = p
    }

    public func setEffort(_ e: String) {
        chrome.snapshot.agentEffortByModel["\(account?.kind.rawValue ?? ""):\(model)"] = e
    }

    public var contextWindow: Int {
        models.first { $0.id == model }?.ctx ?? 128_000
    }

    public func loadModels() async {
        // O roteiro não tem lista de modelos, e pedir a de uma conta que exista poderia
        // limpar o modelo escolhido no estado do app.
        guard let acc = account, !loadingModels, !emRoteiro else { return }
        if modelsFor == acc.id, !models.isEmpty {
            return
        }
        loadingModels = true
        modelsError = nil
        defer { loadingModels = false }
        do {
            let p = ProviderFactory.make(account: acc, session: accounts.session(for: acc))
            let list = try await p.models()
            models = list
            modelsFor = acc.id
            if !prefs.model.isEmpty, !list.contains(where: { $0.id == prefs.model }) {
                setModel("")
            }
        } catch { modelsError = error.localizedDescription; models = acc.kind == .grok ? [] : models }
    }

    // MARK: conversa

    /// As conversas guardadas, da mais recente para a mais antiga. Lidas do disco uma vez
    /// e guardadas até a próxima gravação; o histórico lia isto três vezes por desenho.
    public var threads: [ChatThread] {
        _ = versaoDasConversas
        if let c = cacheDasConversas {
            return c
        }
        let l = chats.list()
        cacheDasConversas = l
        return l
    }

    /// As conversas no disco mudaram: a lista é relida quando alguém pedir, e a contagem
    /// é refeita pela pasta.
    private func conversasMudaram() {
        cacheDasConversas = nil
        versaoDasConversas &+= 1
        numeroDeConversas = chats.count()
    }

    /// As skills do projeto para o menu do `/`. Lidas uma vez e de novo ao fim de cada
    /// turno — o agente pode ter criado uma —, em vez de a cada tecla com o menu aberto.
    public var skills: [Skill] {
        if let s = cacheDeSkills {
            return s
        }
        let s = Skills.all(host: host)
        cacheDeSkills = s
        return s
    }

    public func newChat() {
        guard !running else { return }
        if thread.isEmpty {
            return
        }
        thread = .blank()
        items = []
        var p = prefs; p.threadId = thread.id; prefs = p
    }

    public func open(_ t: ChatThread) {
        guard !running else { return }
        thread = t
        items = t.items
        var p = prefs; p.threadId = t.id; prefs = p
    }

    public func remove(_ t: ChatThread) {
        chats.remove(t.id)
        conversasMudaram()
        if t.id == thread.id {
            thread = threads.first ?? .blank(); items = thread.items
        }
    }

    /// Procura do fim para o começo: quem muda enquanto o agente escreve é quase sempre o
    /// último item, e a busca do começo andava a conversa inteira a cada lote.
    private func upsert(_ item: ChatItem) {
        if let i = items.lastIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
        versaoDosItens &+= 1
    }

    private func persist() {
        thread.items = items
        // O título e a hora vêm de quem gravou — ler o arquivo de volta para saber o que
        // acabou de ser escrito decodificava todas as conversas do projeto.
        let gravada = chats.save(thread)
        thread.title = gravada.title
        thread.updated = gravada.updated
        conversasMudaram()
    }

    /// A última pergunta que chegou a ser enviada, para o "Tentar de novo".
    private var ultimaPergunta: (texto: String, imagens: [AgentImage])?

    /// O que repetir. Depois de reabrir o app a pergunta em memória se perdeu, mas o
    /// histórico da conversa ainda termina nela — e é justamente aí, no erro do fim da
    /// sessão, que a pessoa fecha o app e volta depois.
    private var perguntaParaRepetir: String? {
        if let p = ultimaPergunta?.texto {
            return p
        }
        guard let ultima = thread.messages.last, ultima.role == .user else { return nil }
        return ultima.content
    }

    /// Só vale oferecer repetir quando o turno morreu num erro e nada está rodando.
    public var podeTentarDeNovo: Bool {
        !running && perguntaParaRepetir != nil && Self.ehErroQueDaParaRepetir(items.last)
    }

    /// Parar foi escolha da pessoa, não falha: ali não se oferece repetir. Desfazer também.
    nonisolated static func ehErroQueDaParaRepetir(_ ultimo: ChatItem?) -> Bool {
        if case let .error(id, texto) = ultimo {
            return texto != "parado" && !ehAvisoDoDesfazer(id)
        }
        return false
    }

    /// Manda a mesma pergunta outra vez depois de um erro.
    ///
    /// Erro de provedor (modelo que não existe, parâmetro recusado, 429) deixava o
    /// cartão vermelho como beco sem saída: a única saída era redigitar tudo. Quando o
    /// turno não chegou a produzir nada, rebobina de verdade — tira o cartão de erro e a
    /// pergunta do transcript e do histórico — e reenvia. Se já havia resposta ou
    /// ferramenta no meio, não joga esse trabalho fora: pede para continuar de onde
    /// parou.
    public func tentarDeNovo() {
        guard podeTentarDeNovo, let pergunta = perguntaParaRepetir else { return }
        while case .error = items.last {
            items.removeLast()
        }
        let virgem = thread.messages.last?.role == .user
        if virgem {
            thread.messages.removeLast()
            if let i = items.lastIndex(where: {
                if case .user = $0 {
                    return true
                }; return false
            }) {
                items.removeSubrange(i...)
            }
            draft = pergunta
            attachments = ultimaPergunta?.imagens ?? []
        } else {
            draft = tr("Continua de onde parou.")
        }
        send()
    }

    /// Põe um trecho do projeto no compositor, com de onde ele veio.
    ///
    /// É a forma mais direta de dar contexto: em vez de descrever onde mexer, a pessoa
    /// seleciona as linhas e manda. O texto entra como bloco citado e o cursor fica
    /// depois dele, para escrever o pedido em cima.
    public func anexarTrecho(origem: String, texto: String, linguagem: String = "") {
        let corpo = texto.trimmingCharacters(in: .newlines)
        guard !corpo.isEmpty else { return }
        // Cerca maior que qualquer cerca de dentro do trecho: colar markdown com ``` no
        // meio fechava o bloco cedo e o resto virava texto solto.
        let cerca = String(repeating: "`", count: max(3, corpo.components(separatedBy: "```").count > 1 ? 4 : 3))
        let bloco = "\(origem)\n\(cerca)\(linguagem)\n\(corpo)\n\(cerca)\n"
        draft = draft.isEmpty ? bloco : draft + "\n" + bloco
    }

    /// Envia (ou redireciona, se estiver rodando).
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if running {
            loop?.steer(text); draft = ""; return
        }
        guard let provider = provedorParaEnviar() else { return }
        let images = attachments
        draft = ""
        attachments = []
        ultimaPergunta = (text, images)
        let loop = AgentLoop(provider: provider, host: host, patches: patches, checkpoints: checkpoints)
        self.loop = loop
        running = true
        lastTurnUse = TokenUse()
        let cfg = LoopConfig(mode: mode, permit: permit, model: model, effort: effort, conversationId: thread.id)
        let history = thread.messages
        runTask = Task { [weak self] in
            for await e in loop.run(history: history, userText: text, images: images, config: cfg) {
                guard let self else { return }
                switch e {
                case let .item(i):
                    if case let .permit(id, _, _, .pending) = i {
                        pendingPermit = id
                    } else if case .permit = i {
                        pendingPermit = nil
                    }
                    upsert(i)
                case let .usage(u): lastTurnUse += u; thread.usage += u; if u
                    .input > 0 {
                        thread.lastInput = u.input
                    }
                case let .history(h): thread.messages = h
                case .done: break
                }
            }
            guard let self else { return }
            running = false
            pendingPermit = nil
            self.loop = nil
            temCheckpoint = checkpoints.last != nil
            cacheDeSkills = nil
            persist()
            ws.reload()
            ws.git.agendarMarcas()
        }
    }

    /// O provedor desta mensagem, ou o aviso na conversa de por que não há um.
    private func provedorParaEnviar() -> (any Provider)? {
        #if DEBUG
            // Um provedor por mensagem: é assim que cada envio toca o próximo turno.
            if let roteiro = ProvedorDeRoteiro.doAmbiente() {
                return roteiro
            }
        #endif
        guard let acc = account else {
            items.append(.error(
                id: UUID().uuidString,
                text: tr("Conecte uma conta em Ajustes → Contas para usar o agente.")
            ))
            return nil
        }
        if acc.needsReconnect {
            items.append(.error(
                id: UUID().uuidString,
                text: tr("A sessão da conta %1$@ expirou. Reconecte em Ajustes → Contas.", "\(acc.label)")
            ))
            return nil
        }
        return ProviderFactory.make(account: acc, session: accounts.session(for: acc))
    }

    public func stop() {
        loop?.stop()
    }

    public func approve(_ id: String, _ ok: Bool) {
        loop?.approve(id, ok); pendingPermit = nil
    }

    nonisolated static func indexar(_ lista: [Patch]) -> [String: Patch] {
        Dictionary(lista.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }

    // MARK: patches e checkpoints

    public func accept(_ p: Patch) {
        patches.accept(p.id); ws.reloadBuffer(p.path); ws.reload()
    }

    public func acceptHunk(_ p: Patch, _ i: Int) {
        patches.acceptHunk(p.id, index: i); ws.reloadBuffer(p.path)
    }

    public func reject(_ p: Patch) {
        patches.reject(p.id); ws.reloadBuffer(p.path); ws.reload()
    }

    public func undoPatch(_ p: Patch) {
        patches.undo(p.id); ws.reloadBuffer(p.path); ws.reload()
    }

    public func acceptAll() {
        patches.acceptAll(); for p in ws.tabs.map(\.path) {
            ws.reloadBuffer(p)
        }; ws.reload()
    }

    public func rejectAll() {
        patches.rejectAll(); for p in ws.tabs.map(\.path) {
            ws.reloadBuffer(p)
        }; ws.reload()
    }

    public var canUndoTurn: Bool {
        temCheckpoint && !running
    }

    // MARK: anexos

    public func attach(_ image: UIImage) {
        let max: CGFloat = 1600
        var img = image
        if img.size.width > max || img.size.height > max {
            let k = max / Swift.max(img.size.width, img.size.height)
            let size = CGSize(width: img.size.width * k, height: img.size.height * k)
            img = UIGraphicsImageRenderer(size: size).image { _ in img.draw(in: CGRect(origin: .zero, size: size)) }
        }
        guard let data = img.jpegData(compressionQuality: 0.8) else { return }
        attachments.append(AgentImage(mime: "image/jpeg", data: data.base64EncodedString()))
    }

    public func attachPreview() {
        guard let snap = ws.preview.snapshotter else { return }
        snap {
            [weak self] img in if let img {
                self?.attach(img)
            }
        }
    }

    /// Fichas estimadas: quatro bytes por ficha.
    ///
    /// Em bytes UTF-8, e não em `count`: contar caracteres anda pelo texto inteiro, e isto
    /// roda a cada tecla — o anel de contexto do compositor lê daqui.
    public var estimatedTokens: Int {
        tokensDaConversa() + draft.utf8.count / 4 + attachments.count * 720
    }

    private func tokensDaConversa() -> Int {
        let atuais = thread.messages
        if atuais == estimativa.mensagens {
            return estimativa.tokens
        }
        let n = atuais.reduce(0) {
            $0 + $1.content.utf8.count / 4 + ($1.toolCalls ?? []).reduce(0) { $0 + $1.arguments.utf8.count / 4 }
        }
        estimativa = (atuais, n)
        return n
    }
}

// MARK: desfazer o último turno

/// No mesmo arquivo da classe: o desfazer mexe em `items` e `temCheckpoint`, que só se
/// escrevem daqui.
public extension AgentModel {
    /// Os arquivos que o último turno mexeu e a pessoa mudou depois. O desfazer deixa esses
    /// como estão; a tela pergunta antes, com a lista, para ninguém achar que voltaram.
    func mexidosDepoisDoUltimoTurno() -> [String] {
        guard !running, let cp = checkpoints.last else { return [] }
        return checkpoints.previa(cp.id, manter: protegerOEditor())?.mantidos ?? []
    }

    func undoLastTurn() -> String {
        guard !running, let cp = checkpoints.last,
              let volta = checkpoints.desfazer(cp.id, manter: protegerOEditor())
        else {
            return tr("nada pra desfazer")
        }
        // O checkpoint desfeito sai da pilha: o próximo toque volta o turno anterior.
        temCheckpoint = checkpoints.last != nil
        // Só os patches do que voltou ou saiu. Rejeitar todos devolvia ao original também
        // os pendentes de turnos anteriores, em arquivos que este turno nem tocou — e o
        // patch de um arquivo que a pessoa apagou depois o recriava.
        let tocados = Set(volta.voltaram + volta.apagados)
        for p in patches.pending where tocados.contains(p.path) {
            patches.reject(p.id)
        }
        // E só as abas do que voltou: o resto do disco não mudou.
        for p in volta.voltaram {
            ws.reloadBuffer(p)
        }
        ws.reload()
        let msg = volta.mensagem
        items.append(.error(id: Self.prefixoDoDesfazer + UUID().uuidString, text: msg))
        persist()
        return msg
    }

    /// O resultado do desfazer entra na conversa como os outros avisos, mas não é erro:
    /// com este começo de id a lista o desenha neutro e não oferece "Tentar de novo".
    nonisolated static let prefixoDoDesfazer = "desfeito-"

    nonisolated static func ehAvisoDoDesfazer(_ id: String) -> Bool {
        id.hasPrefix(prefixoDoDesfazer)
    }

    /// O que está no editor e ainda não foi para o disco.
    ///
    /// Com o salvamento automático ligado, grava agora — a edição ia para o disco em um
    /// segundo de qualquer jeito, e assim o desfazer a enxerga. Desligado, não grava por
    /// cima da escolha da pessoa: devolve as abas sujas, que o desfazer deixa como estão.
    /// Antes o desfazer recarregava todas as abas do disco, e o que estava digitado e não
    /// salvo — até em arquivo que o turno nem tocou — sumia.
    private func protegerOEditor() -> Set<String> {
        if chrome.snapshot.editor.autoSave {
            ws.saveAll()
        }
        return Set(ws.tabs.filter(\.isDirty).map(\.path))
    }
}
