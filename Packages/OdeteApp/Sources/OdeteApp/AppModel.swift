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
    /// As pastas de fora do app. Um registro só para todas as janelas (ver
    /// `Janelas.external`): com um por janela, cada um gravava o `external.json` inteiro
    /// com o que *ele* sabia, e a pasta que uma janela abria sumia pela outra.
    public let external: ExternalProjects
    public var projects: [Project] = []
    /// Projetos de fora do app cuja pasta não se acha mais. Ficam no hub, apagados, com a
    /// opção de apontar para a pasta de novo — antes sumiam sem aviso.
    public private(set) var indisponiveis: [Project] = []
    public var workspace: WorkspaceModel?
    public var error: String?

    /// A raiz dos projetos ainda não é sabida: está no iCloud, e onde fica o iCloud é
    /// perguntado fora do ator principal (ver `LocalDaNuvem`). Enquanto isso o hub
    /// mostra que está carregando, em vez de uma lista vazia ou a lista da pasta errada.
    public private(set) var aguardandoRaiz = false
    /// Há iCloud Drive neste aparelho? `nil` enquanto não se sabe.
    public private(set) var nuvemDisponivel: Bool?

    public let aiAccounts: AIAccountStore

    public init(
        store: ProjectStore = ProjectStore(),
        accounts: AccountStore = AccountStore(),
        aiAccounts: AIAccountStore = AIAccountStore(),
        external: ExternalProjects = Janelas.shared.external,
        aguardandoRaiz: Bool = false
    ) {
        self.store = store
        self.accounts = accounts
        self.aiAccounts = aiAccounts
        self.external = external
        self.aguardandoRaiz = aguardandoRaiz
        refresh()
    }

    /// Quantas vezes seguidas a lista foi relida esperando um metadado baixar do iCloud.
    @ObservationIgnored private var releituras = 0
    @ObservationIgnored private var releitura: Task<Void, Never>?

    public func refresh() {
        guard !aguardandoRaiz else { return }
        do {
            let lida = try store.listar()
            projects = (lida.projetos + external.list())
                .sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
            indisponiveis = external.indisponiveis()
            // Projeto cujo `project.json` ainda está na nuvem aparece com um id
            // provisório; o download foi pedido, e a lista é relida até ele chegar.
            if lida.aguardando > 0, releituras < 20 {
                releituras += 1
                releitura?.cancel()
                releitura = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    self?.refresh()
                }
            } else if lida.aguardando == 0 {
                releituras = 0
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Pasta do projeto, local ou externa.
    public func url(for p: Project) -> URL {
        if p.external, let u = external.url(for: p.id) {
            return u
        }
        return store.url(for: p)
    }

    // MARK: onde moram os projetos

    /// Passa a olhar outra raiz de projetos — depois de o iCloud responder, ou de os
    /// projetos mudarem de lugar.
    func apontar(para root: URL) {
        store = ProjectStore(root: root)
        aguardandoRaiz = false
        refresh()
    }

    /// Descobre a raiz no iCloud sem travar a tela e passa a olhar para ela.
    func prepararRaiz(nuvem: LocalDaNuvem = .shared) async {
        guard aguardandoRaiz else { return }
        let u = await nuvem.raiz()
        nuvemDisponivel = u != nil
        // Sem iCloud (conta saiu, iCloud Drive desligado): a pasta de dentro do app,
        // como sempre foi.
        apontar(para: u ?? ProjectStore.defaultRoot())
    }

    /// Atualiza `nuvemDisponivel`, perguntando fora do ator principal.
    func atualizarNuvem(_ nuvem: LocalDaNuvem = .shared) async {
        nuvemDisponivel = await nuvem.raiz() != nil
    }

    /// Relê a lista nesta janela e nas outras: o que muda no disco muda para todas.
    private func avisarMudanca() {
        if let janelas {
            janelas.projetosMudaram()
        } else {
            refresh()
        }
    }

    // MARK: pastas externas, zip e iCloud

    /// Abre uma pasta de fora (Arquivos, iCloud, outro app) como projeto.
    ///
    /// Se a pasta é a de um projeto do próprio app, é ele que abre: registrar de novo
    /// fazia dois projetos, com dois ids, nos mesmos arquivos.
    @discardableResult
    public func addExternal(_ url: URL) -> Project? {
        if let p = store.projeto(naPasta: url) {
            return p
        }
        do {
            let p = try external.add(url)
            avisarMudanca()
            return p
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Fecha o acesso às pastas de fora que nenhuma janela está usando. O registro é um
    /// só: a pasta aberta em outra janela continua aberta.
    public func liberarPastasSemUso() {
        var abertos = janelas?.projetosAbertos() ?? []
        if let id = workspace?.project.id {
            abertos.insert(id)
        }
        external.liberarTodos(exceto: abertos)
    }

    /// Aponta um projeto externo indisponível para a pasta onde ele está agora.
    public func reapontar(_ p: Project, para url: URL) {
        do {
            try external.reapontar(p.id, para: url)
        } catch {
            self.error = error.localizedDescription
        }
        avisarMudanca()
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
                avisarMudanca()
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

    public func create(name: String, template: Template) -> Project? {
        do {
            let p = try store.create(name: name, template: template)
            avisarMudanca()
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
            avisarMudanca()
            return p
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// O projeto está aberto em outra janela? O hub avisa antes de renomear ou apagar.
    public func abertoEmOutraJanela(_ p: Project) -> Bool {
        janelas?.dona(de: p.id, fora: self) != nil
    }

    /// Fecha o projeto onde quer que ele esteja aberto — esta janela ou outra —, com o
    /// que estava sendo digitado gravado antes.
    ///
    /// Renomear ou apagar pelo hub de uma janela o projeto aberto em outra deixava a
    /// outra trabalhando no caminho velho: o salvamento automático dela recriava a pasta,
    /// e nascia um projeto-fantasma só com os arquivos que estavam abertos.
    private func fecharEmTodasAsJanelas(_ p: Project) {
        if workspace?.project.id == p.id {
            closeWorkspace()
        }
        janelas?.fechar(p.id, fora: self)
    }

    public func rename(_ p: Project, to name: String) {
        guard !p.external else { return }
        fecharEmTodasAsJanelas(p)
        do { _ = try store.rename(p, to: name) } catch { self.error = error.localizedDescription }
        avisarMudanca()
    }

    public func duplicate(_ p: Project) {
        guard !p.external else { return }
        do { try store.duplicate(p) } catch { self.error = error.localizedDescription }
        avisarMudanca()
    }

    /// Apaga um projeto local; um externo só sai do hub (a pasta fica onde está).
    public func delete(_ p: Project) {
        fecharEmTodasAsJanelas(p)
        if p.external {
            external.remove(p.id)
        } else {
            do { try store.delete(p) } catch { self.error = error.localizedDescription }
        }
        avisarMudanca()
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
/// Pastas pesadas (`node_modules`, `.build`, `dist`) ficam de fora, como sempre, e `.odete`
/// também — conversas do agente, checkpoints e lixeira não são para quem recebe o zip (ver
/// `Zip.pastasDeFora`); o `.git` vai junto, porque mandar o projeto com a história é o que
/// se quer ao compartilhar — agora só quando alguém compartilha de fato.
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
