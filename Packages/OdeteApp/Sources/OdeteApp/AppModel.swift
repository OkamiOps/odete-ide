import CoreTransferable
import Foundation
import Observation
import OdeteAccounts
import OdeteAgent
import OdeteCore
import OdeteFiles
import OdeteI18n
import UniformTypeIdentifiers

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

    /// Zip do projeto em Caches, para compartilhar. Síncrono: quem quer compartilhar pela
    /// folha do sistema usa `compartilhavel(_:)`, que só zipa quando o destino pede.
    public func zip(_ p: Project) -> URL? {
        do {
            return try compartilhavel(p).zipar()
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// O projeto como `.zip` para o `ShareLink`, zipado só quando alguém escolhe o destino.
    ///
    /// O menu de contexto do hub chamava `zip(_:)` para montar o `ShareLink` — e o menu é
    /// montado junto com a grade. Resultado: cada projeto, `.git` incluído, era zipado no
    /// ator principal toda vez que a grade aparecia; medido, todos os zips de
    /// `Caches/share` eram reescritos na abertura do app sem ninguém compartilhar nada.
    public func compartilhavel(_ p: Project) -> ProjetoZipado {
        ProjetoZipado(
            nome: p.name,
            pasta: p.external ? nil : store.url(for: p),
            externo: p.external ? ProjetoZipado.Externo(registro: external, id: p.id) : nil
        )
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
                    // Antes de mover: senão o iCloud começa a subir o node_modules no
                    // próprio movimento. Ver `PastaDeModulos`.
                    _ = PastaDeModulos.migrarSePreciso(item, nuvem: true)
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

    /// O registro das janelas do app — ver `Janelas`. Quem liga é a `RootView`; sem ele
    /// (testes, atalho rodando sem tela) o projeto abre como sempre abriu.
    @ObservationIgnored var janelas: Janelas?

    public func open(_ p: Project, chrome: ChromeState) {
        // Já aberto aqui: nada a fazer. Reabrir montava uma segunda cópia viva do mesmo
        // projeto por cima da primeira, que ninguém parava.
        if workspace?.project.id == p.id {
            return
        }
        // Aberto em outra janela: ela vem para a frente, e esta fica como está. Duas
        // cópias vivas do mesmo projeto são dois observadores, dois shells e dois
        // salvamentos automáticos gravando um por cima do outro.
        if let dona = janelas?.dona(de: p.id, fora: self) {
            dona.ativar()
            return
        }
        // Outro projeto aberto nesta janela para antes de sair de cena.
        if workspace != nil {
            closeWorkspace()
        }
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

/// Um projeto que vira `.zip` quando o destino da folha de compartilhar pede o arquivo.
///
/// Pastas pesadas (`node_modules`, `.build`, `dist`) ficam de fora, como sempre; o `.git`
/// vai junto, porque mandar o projeto com a história é o que se quer ao compartilhar —
/// agora só quando alguém compartilha de fato.
public struct ProjetoZipado: Transferable, Sendable {
    /// Projeto de fora do app: o zip lê a pasta com o acesso aberto só enquanto zipa.
    struct Externo: Sendable {
        let registro: ExternalProjects
        let id: UUID
    }

    let nome: String
    let pasta: URL?
    let externo: Externo?

    /// O bookmark da pasta externa não resolve mais.
    struct SemPasta: LocalizedError {
        let nome: String
        var errorDescription: String? {
            tr("não deu para ler %1$@", nome)
        }
    }

    public static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .zip) { item in
            try SentTransferredFile(item.zipar())
        }
    }

    /// Zipa em `Caches/share` e devolve onde ficou. Roda fora do ator principal quando
    /// vem do `ShareLink`.
    func zipar() throws -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "share")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appending(path: "\(nome).zip")
        if let externo {
            let feito: Void? = try externo.registro.comAcesso(externo.id) { try Zip.create(directory: $0, to: out) }
            guard feito != nil else { throw SemPasta(nome: nome) }
        } else if let pasta {
            try Zip.create(directory: pasta, to: out)
        }
        return out
    }
}
