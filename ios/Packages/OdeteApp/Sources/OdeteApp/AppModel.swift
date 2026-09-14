import Foundation
import Observation
import OdeteAccounts
import OdeteAgent
import OdeteCore
import OdeteFiles

/// Estado do app fora de um projeto: lista do hub e projeto aberto.
@MainActor
@Observable
public final class AppModel {
    public let store: ProjectStore
    public var projects: [Project] = []
    public var workspace: WorkspaceModel?
    public var error: String?

    public let aiAccounts: AIAccountStore

    public init(
        store: ProjectStore = ProjectStore(),
        accounts: AccountStore = AccountStore(),
        aiAccounts: AIAccountStore = AIAccountStore()
    ) {
        self.store = store
        self.accounts = accounts
        self.aiAccounts = aiAccounts
        refresh()
    }

    public func refresh() {
        do { projects = try store.list() } catch { self.error = error.localizedDescription }
    }

    public func create(name: String, template: Template) -> Project? {
        do {
            let p = try store.create(name: name, template: template)
            refresh()
            return p
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    public func rename(_ p: Project, to name: String) {
        do { _ = try store.rename(p, to: name); refresh() } catch { self.error = error.localizedDescription }
    }

    public func duplicate(_ p: Project) {
        do { try store.duplicate(p); refresh() } catch { self.error = error.localizedDescription }
    }

    public func delete(_ p: Project) {
        do { try store.delete(p); refresh() } catch { self.error = error.localizedDescription }
    }

    public let accounts: AccountStore

    public func open(_ p: Project, chrome: ChromeState) {
        let touched = (try? store.touch(p)) ?? p
        workspace = WorkspaceModel(
            project: touched,
            root: store.url(for: touched),
            chrome: chrome,
            accounts: accounts,
            aiAccounts: aiAccounts
        )
        chrome.snapshot.lastProjectId = touched.id
        refresh()
    }

    public func closeWorkspace() {
        workspace?.stop()
        workspace = nil
    }
}
