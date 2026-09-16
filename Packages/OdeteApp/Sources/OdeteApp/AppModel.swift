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
    public private(set) var store: ProjectStore
    public let external = ExternalProjects()
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
        do {
            let local = try store.list()
            projects = (local + external.list())
                .sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
        } catch { self.error = error.localizedDescription }
    }

    /// Pasta do projeto, local ou externa.
    public func url(for p: Project) -> URL {
        if p.external, let u = external.url(for: p.id) {
            return u
        }
        return store.url(for: p)
    }

    // MARK: pastas externas, zip e iCloud

    /// Abre uma pasta de fora (Arquivos, iCloud, outro app) como projeto.
    @discardableResult
    public func addExternal(_ url: URL) -> Project? {
        do {
            let p = try external.add(url)
            refresh()
            return p
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Recebe um arquivo (`.zip` vira projeto; pasta vira projeto externo).
    public func importURL(_ url: URL, chrome: ChromeState) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if url.pathExtension.lowercased() == "zip" {
            do {
                let tmp = FileManager.default.temporaryDirectory.appending(path: "import-\(UUID().uuidString)")
                let root = try Zip.extract(url, to: tmp)
                let src = root.map { tmp.appending(path: $0) } ?? tmp
                var name = root ?? url.deletingPathExtension().lastPathComponent
                var n = 2
                while FileManager.default.fileExists(atPath: store.root.appending(path: name).path) {
                    name = "\(root ?? url.deletingPathExtension().lastPathComponent) \(n)"
                    n += 1
                }
                try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: src, to: store.root.appending(path: name))
                refresh()
                if let p = projects.first(where: { $0.name == name && !$0.external }) {
                    open(p, chrome: chrome)
                }
            } catch {
                self.error = error.localizedDescription
            }
        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let p = addExternal(url) {
                open(p, chrome: chrome)
            }
        }
    }

    /// Zip do projeto em Caches, para compartilhar.
    public func zip(_ p: Project) -> URL? {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "share")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: "\(p.name).zip")
        do {
            try Zip.create(directory: url(for: p), to: out)
            return out
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Raiz dos projetos: iCloud Drive quando ligado e disponível, senão Documents.
    public static func cloudRoot() -> URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?.appending(
            path: "Documents/Projects",
            directoryHint: .isDirectory
        )
    }

    public static func projectsRoot(cloud: Bool) -> URL {
        cloud ? (cloudRoot() ?? ProjectStore.defaultRoot()) : ProjectStore.defaultRoot()
    }

    public var cloudAvailable: Bool {
        Self.cloudRoot() != nil
    }

    /// Move `Projects` entre Documents e o iCloud Drive (mesclando pastas pelo nome).
    public func setCloud(_ on: Bool) -> Bool {
        let from = store.root
        let to = Self.projectsRoot(cloud: on)
        guard from != to else { return on }
        let fm = FileManager.default
        do {
            closeWorkspace()
            try fm.createDirectory(at: to, withIntermediateDirectories: true)
            for item in (try? fm.contentsOfDirectory(at: from, includingPropertiesForKeys: nil)) ?? [] {
                let dest = to.appending(path: item.lastPathComponent)
                if fm.fileExists(atPath: dest.path) {
                    continue
                }
                if on {
                    try fm.setUbiquitous(true, itemAt: item, destinationURL: dest)
                } else {
                    try fm.moveItem(at: item, to: dest)
                }
            }
            store = ProjectStore(root: to)
            refresh()
            return on
        } catch {
            self.error = error.localizedDescription
            return !on
        }
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

    /// Cria o projeto numa pasta escolhida pela pessoa, fora da raiz do app.
    ///
    /// É o caminho para quem trabalha num SSD externo ou quer o projeto num lugar que
    /// sobreviva a desinstalar a Odete. A pasta vem do seletor de arquivos com acesso
    /// concedido; o bookmark do projeto novo é tirado com esse acesso ainda aberto, que
    /// é o que faz ele continuar valendo depois de fechar o app.
    public func create(name: String, template: Template, em pasta: URL) -> Project? {
        let acesso = pasta.startAccessingSecurityScopedResource()
        defer {
            if acesso {
                pasta.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let (_, dir) = try ProjectStore.criar(name: name, template: template, dentroDe: pasta)
            let p = try external.add(dir)
            refresh()
            return p
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    public func rename(_ p: Project, to name: String) {
        guard !p.external else { return }
        do { _ = try store.rename(p, to: name); refresh() } catch { self.error = error.localizedDescription }
    }

    public func duplicate(_ p: Project) {
        guard !p.external else { return }
        do { try store.duplicate(p); refresh() } catch { self.error = error.localizedDescription }
    }

    /// Apaga um projeto local; um externo só sai do hub (a pasta fica onde está).
    public func delete(_ p: Project) {
        if p.external {
            external.remove(p.id)
            refresh()
            return
        }
        do { try store.delete(p); refresh() } catch { self.error = error.localizedDescription }
    }

    public let accounts: AccountStore

    public func open(_ p: Project, chrome: ChromeState) {
        var touched = p
        if p.external {
            external.touch(p.id)
            touched.lastOpenedAt = .now
        } else {
            touched = (try? store.touch(p)) ?? p
        }
        workspace = WorkspaceModel(
            project: touched,
            root: url(for: touched),
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
