import Foundation
import OdeteAgent
import OdeteCore
import OdeteFiles
import OdeteI18n

/// Ponte entre os AppIntents (no alvo do app) e o estado vivo da Odete.
@MainActor
public final class IntentBridge {
    public static let shared = IntentBridge()
    public private(set) weak var app: AppModel?
    public private(set) weak var chrome: ChromeState?

    public struct ProjectRef: Sendable, Hashable {
        public var id: UUID
        public var name: String
    }

    public func bind(app: AppModel, chrome: ChromeState) {
        self.app = app
        self.chrome = chrome
    }

    /// Lista projetos mesmo sem a UI montada (o intent pode rodar em segundo plano).
    public func projects() -> [ProjectRef] {
        if let app {
            return app.projects.map { ProjectRef(id: $0.id, name: $0.name) }
        }
        let snap = StateStore().load()
        let store = ProjectStore(root: AppModel.projectsRoot(cloud: snap.projectsInCloud))
        let local = (try? store.list()) ?? []
        return (local + ExternalProjects().list()).map { ProjectRef(id: $0.id, name: $0.name) }
    }

    public func openProject(_ id: UUID) -> Bool {
        guard let app, let chrome, let p = app.projects.first(where: { $0.id == id }) else { return false }
        app.open(p, chrome: chrome)
        return true
    }

    /// Abre o projeto (se preciso) e roda a linha no terminal.
    public func runCommand(_ line: String, in id: UUID) -> Bool {
        guard let app, let chrome else { return false }
        if app.workspace?.project.id != id {
            guard openProject(id) else { return false }
        }
        guard let ws = app.workspace else { return false }
        ws.showTerminal()
        ws.run.run(line)
        return true
    }

    /// Pergunta de uma vez só ao modelo da conta ativa, com o projeto como contexto quando dado.
    public func ask(_ question: String, in id: UUID?) async throws -> String {
        let accounts = app?.aiAccounts ?? AIAccountStore()
        guard let acc = accounts.accounts.first else {
            throw NSError(
                domain: "Odete",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: tr("Conecte uma conta de IA na Odete.")]
            )
        }
        var system = tr("Você é a Odete, IDE no iPad. Responda em português, curto e direto.")
        if let id, let p = projects().first(where: { $0.id == id }) {
            system += tr(" O usuário está falando do projeto \"%1$@\".", "\(p.name)")
        }
        let provider = ProviderFactory.make(account: acc, session: accounts.session(for: acc))
        let model = app?.workspace?.agent.model ?? ""
        let turn = TurnRequest(
            system: system,
            messages: [.user(question)],
            tools: [],
            model: model,
            conversationId: UUID().uuidString
        )
        var out = ""
        for try await e in provider.stream(turn) {
            if case let .text(t) = e {
                out += t
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func newProject(name: String, template: String) -> ProjectRef? {
        let t = Template(rawValue: template) ?? .blank
        if let app {
            guard let p = app.create(name: name, template: t) else { return nil }
            return ProjectRef(id: p.id, name: p.name)
        }
        let snap = StateStore().load()
        let store = ProjectStore(root: AppModel.projectsRoot(cloud: snap.projectsInCloud))
        guard let p = try? store.create(name: name, template: t) else { return nil }
        return ProjectRef(id: p.id, name: p.name)
    }
}
