import Foundation
import Observation
import OdeteAgent
import OdeteCore
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
        pendingPatches = patches.pending
        patches.onChange = { [weak self] in Task { @MainActor in self?.pendingPatches = self?.patches.pending ?? [] } }
        if prefs.accountId == nil, let first = accounts.accounts.first {
            setAccount(first)
        }
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
        guard let acc = account, !loadingModels else { return }
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

    public var threads: [ChatThread] {
        chats.list()
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
        if t.id == thread.id {
            thread = chats.list().first ?? .blank(); items = thread.items
        }
    }

    private func upsert(_ item: ChatItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) {
            items[i] = item
        } else {
            items.append(item)
        }
    }

    private func persist() {
        thread.items = items
        chats.save(thread)
        if let t = chats.load(thread.id) {
            thread.title = t.title; thread.updated = t.updated
        }
    }

    /// Envia (ou redireciona, se estiver rodando).
    public func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if running {
            loop?.steer(text); draft = ""; return
        }
        guard let acc = account else {
            items.append(.error(
                id: UUID().uuidString,
                text: "Conecte uma conta em Ajustes → Contas para usar o agente."
            ))
            return
        }
        if acc.needsReconnect {
            items.append(.error(
                id: UUID().uuidString,
                text: "A sessão da conta \(acc.label) expirou. Reconecte em Ajustes → Contas."
            ))
            return
        }
        let images = attachments
        draft = ""
        attachments = []
        let provider = ProviderFactory.make(account: acc, session: accounts.session(for: acc))
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
            persist()
            ws.reload()
            ws.git.scheduleRefresh()
        }
    }

    public func stop() {
        loop?.stop()
    }

    public func approve(_ id: String, _ ok: Bool) {
        loop?.approve(id, ok); pendingPermit = nil
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
        checkpoints.last != nil && !running
    }

    public func undoLastTurn() -> String {
        guard let cp = checkpoints.last else { return "nada pra desfazer" }
        let msg = checkpoints.restore(cp.id)
        patches.rejectAll()
        for p in ws.tabs.map(\.path) {
            ws.reloadBuffer(p)
        }
        ws.reload()
        items.append(.error(id: UUID().uuidString, text: msg))
        persist()
        return msg
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

    public var estimatedTokens: Int {
        var n = thread.messages
            .reduce(0) { $0 + $1.content.count / 4 + ($1.toolCalls ?? []).reduce(0) { $0 + $1.arguments.count / 4 } }
        n += draft.count / 4 + attachments.count * 720
        return n
    }
}
