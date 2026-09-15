import Foundation
import Observation
import OdeteAccounts
import OdeteAgent
import OdeteBundler
import OdeteCore
import OdeteEditor
import OdeteFiles
import OdeteGit
import OdetePreview
import OdeteSwift

/// Estado de um projeto aberto: árvore, abas, buffers e salvamento.
@MainActor
@Observable
public final class WorkspaceModel {
    public let project: Project
    public let root: URL
    public let ops: FileOps
    public var tree = FileNode(path: "", isDirectory: true, children: [])
    /// Caminho de todo arquivo do projeto, refeito junto com a árvore.
    ///
    /// O autocompletar, a paleta e o filtro da árvore liam isto com `allFiles()`, que
    /// percorre a árvore inteira e aloca um nó por arquivo. Como o editor se redesenha a
    /// cada tecla, essa varredura acontecia a cada tecla.
    public private(set) var filePaths: [String] = []
    /// Scripts do package.json, na ordem em que estão escritos. Antes só existiam para
    /// quem lembrasse de digitar `npm run` no terminal.
    public private(set) var scripts: [(nome: String, comando: String)] = []
    /// Pacotes que dá para importar: o que o package.json declara mais o que está
    /// instalado em node_modules. É o que o autocompletar do `from "…"` oferece.
    public private(set) var packages: [String] = []
    public var tabs: [EditorTab] = []
    public var active: String?
    public var buffers: [String: String] = [:]
    public var expanded: Set<String> = []
    public var selected: String?
    /// Arquivo do painel da direita no modo Dois. Sem isto ele mostrava sempre a primeira
    /// aba que não fosse a ativa, e não havia como escolher o que comparar.
    public var secondary: String?
    /// Última ação de arquivo, para o desfazer da árvore.
    public var ultimaAcao: AcaoArquivo?
    /// Quanto o apagado guardado em `.odete/lixeira` ocupa. Fica aqui, e não numa conta
    /// dentro do menu, porque menu de SwiftUI só é remontado quando algo observado muda.
    public var lixeira = 0
    public var error: String?
    public var stack: Stack = .html
    public var externalChange = false
    public var reveal: (line: Int, token: Int)?
    /// Incrementa a cada reload da árvore (salvar, watcher); o preview Swift recompila.
    public private(set) var reloadTick = 0
    public var swiftDiagnostics: [SwiftDiagnostic] = []
    public var paletteOpen = false
    public var paletteQuery = ""
    public let git: GitModel
    public let run: RunModel
    public let preview: PreviewModel
    public private(set) var agent: AgentModel!
    /// Arquivos em conflito que o usuário quer editar como texto puro.
    public var forceTextEdit: Set<String> = []
    /// Análise do editor por arquivo aberto: esboço, lint e marcas do git.
    public var outlines: [String: [OutlineItem]] = [:]
    /// Caminhos de import que apontam para arquivos do projeto, por arquivo aberto.
    public var links: [String: [EditorLink]] = [:]
    /// Apelidos de caminho do `tsconfig.json` (`@/` → `src/`).
    public var tsAliases: [String: String] = [:]
    /// Linhas que o patch pendente do agente mexeu, por arquivo aberto.
    public var patchChanges: [String: [EditorLineChange]] = [:]
    public var lint: [String: [LintIssue]] = [:]
    public var syntax: [String: [Diagnostic]] = [:]
    public var gutter: [String: [GutterMark]] = [:]
    public var gutterFiles: [String: FileDiff] = [:]
    public var cursorOffset = 0
    /// Folhas de histórico/blame por arquivo (nil = fechadas).
    public var historyPath: String?
    public var blamePath: String?
    var analysisTasks: [String: Task<Void, Never>] = [:]
    var lintEngine: Esbuild?

    private let chrome: ChromeState
    private var watcher: DirectoryWatcher?
    private var saveTasks: [String: Task<Void, Never>] = [:]

    init(project: Project, root: URL, chrome: ChromeState, accounts: AccountStore, aiAccounts: AIAccountStore) {
        self.project = project
        self.root = root
        self.chrome = chrome
        ops = FileOps(root: root)
        git = GitModel(root: root, accounts: accounts)
        run = RunModel(root: root, git: git)
        preview = PreviewModel(root: root)
        agent = nil
        tabs = chrome.tabs(for: project.id).filter { ops.exists($0.path) }.map { EditorTab(path: $0.path) }
        active = chrome.activeTab(for: project.id).flatMap { p in tabs.contains { $0.path == p } ? p : nil } ?? tabs
            .first?.path
        expanded = Set(chrome.snapshot.expandedByProject[project.id] ?? ["src"])
        reload()
        for t in tabs {
            load(t.path)
        }
        let w = DirectoryWatcher(url: root) { [weak self] in
            Task { @MainActor in self?.externalReload() }
        } onTick: { [weak self] in
            Task { @MainActor in self?.conferirDisco() }
        }
        w.start()
        watcher = w
        agent = AgentModel(ws: self, chrome: chrome, accounts: aiAccounts)
        git.onRefreshed = { [weak self] in self?.refreshGutters() }
        for t in tabs {
            analyze(t.path)
        }
        refreshGutters()
    }

    /// Recarrega o buffer de um arquivo que outra coisa (agente, shell) escreveu no disco.
    public func reloadBuffer(_ path: String) {
        guard buffers[path] != nil else { return }
        buffers[path] = (try? ops.read(path)) ?? ""
        markDirty(path, false)
        analyze(path)
    }

    /// Mostra a gaveta do terminal (iPad) sem mexer no resto do layout.
    public func showTerminal() {
        if !chrome.snapshot.termVisible {
            chrome.toggleTerm()
        }
    }

    func stop() {
        watcher?.stop()
        run.stopAll()
        agent.stop()
        for t in saveTasks.values {
            t.cancel()
        }
        saveAll()
    }

    // MARK: árvore

    public func reload() {
        do {
            tree = try FileTreeBuilder.build(at: root, ocultos: chrome.snapshot.mostrarOcultos)
            filePaths = tree.allFiles().map(\.path).filter { !Ignore.isNoisePath($0) }
            let pkg = try? Data(contentsOf: root.appending(path: "package.json"))
            stack = Stack.detect(paths: filePaths, packageJSON: pkg)
            scripts = Self.lerScripts(pkg)
            packages = Self.lerPacotes(pkg, root: root)
            tsAliases = ImportLinks.aliases(tsconfig: try? Data(contentsOf: root.appending(path: "tsconfig.json")))
            preencherAbertas()
            lixeira = ops.tamanhoDaLixeira()
            reloadTick += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Data de modificação vista por último em cada arquivo aberto.
    private var marcaDisco: [String: Date] = [:]

    /// Arquivo aberto reescrito por fora volta para a tela.
    ///
    /// Sem isto o editor seguia mostrando o texto velho depois de um `git checkout`, de um
    /// script no terminal ou do agente escrevendo, e o salvamento automático gravava o
    /// velho por cima do novo. Buffer com alteração não salva é deixado em paz: ali quem
    /// manda é o que a pessoa digitou.
    func conferirDisco() {
        for t in tabs {
            guard let data = ops.modifiedAt(t.path) else { continue }
            let antes = marcaDisco[t.path]
            marcaDisco[t.path] = data
            guard let antes, antes != data, !t.isDirty else { continue }
            if let disco = try? ops.read(t.path), disco != buffers[t.path] {
                buffers[t.path] = disco
                reloadTick += 1
                analyze(t.path)
                refreshGutter(t.path)
            }
        }
    }

    private func externalReload() {
        // Mudança vinda de fora não tem ninguém esperando na tela, então a árvore é
        // remontada fora do ator principal: percorrer o projeto inteiro aqui travava a
        // digitação toda vez que o agente ou um script mexesse em arquivo.
        recarregarArvoreEmSegundoPlano()
        git.scheduleRefresh()
        for t in tabs where !t.isDirty {
            if ops.exists(t.path) {
                if let disk = try? ops.read(t.path), disk != buffers[t.path] {
                    buffers[t.path] = disk
                    analyze(t.path)
                }
            } else {
                // Ferramenta que reescreve o arquivo gravando um temporário e renomeando
                // por cima deixa uma fresta em que ele não existe. Fechar a aba nessa
                // fresta some com o arquivo aberto sem ninguém ter pedido, então confere
                // de novo antes.
                let alvo = t.path
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, !ops.exists(alvo) else { return }
                    closeTab(alvo, force: true)
                }
            }
        }
    }

    /// Problemas de todas as fontes: build, Swift, lint do editor e erros do preview.
    /// A barra de status e a barra lateral leem daqui, para contarem a mesma coisa.
    public var problemCounts: (errors: Int, warnings: Int) {
        var e = 0, w = 0
        for d in run.diagnostics {
            d.kind == .error ? (e += 1) : (w += 1)
        }
        for d in swiftDiagnostics {
            d.kind == .error ? (e += 1) : (w += 1)
        }
        for item in allLint {
            item.issue.severity == .error ? (e += 1) : (w += 1)
        }
        e += preview.console.filter { $0.level == .error }.count
        return (e, w)
    }

    /// Dependências declaradas mais o que está de fato em node_modules, incluindo
    /// escopos (`@vitejs/plugin-react`). Uma leitura de diretório, não a árvore inteira.
    nonisolated static func lerPacotes(_ pkg: Data?, root: URL) -> [String] {
        var nomes = Set<String>()
        if let pkg, let obj = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any] {
            for chave in ["dependencies", "devDependencies", "peerDependencies"] {
                for nome in (obj[chave] as? [String: String] ?? [:]).keys {
                    nomes.insert(nome)
                }
            }
        }
        let nm = root.appending(path: "node_modules", directoryHint: .isDirectory)
        let fm = FileManager.default
        for item in (try? fm.contentsOfDirectory(at: nm, includingPropertiesForKeys: nil)) ?? [] {
            let nome = item.lastPathComponent
            if nome.hasPrefix(".") {
                continue
            }
            if nome.hasPrefix("@") {
                for dentro in (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? [] {
                    nomes.insert("\(nome)/\(dentro.lastPathComponent)")
                }
            } else {
                nomes.insert(nome)
            }
        }
        return nomes.sorted()
    }

    /// Depois de remontar a árvore, as pastas pesadas que estavam abertas voltam a ser
    /// lidas: sem isto elas apareciam abertas e vazias depois de qualquer mudança.
    func preencherAbertas() {
        for p in expanded.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count }) {
            lerSePreciso(p)
        }
    }

    /// Pasta pesada (node_modules, .git, dist) entra na árvore por ler; o conteúdo só é
    /// lido quando a pessoa abre, senão abrir o projeto esperaria por milhares de arquivos.
    func lerSePreciso(_ path: String) {
        guard let node = tree.find(path), node.naoLido else { return }
        let filhos = (try? FileTreeBuilder.children(
            of: root.appending(path: path),
            prefix: path,
            ocultos: chrome.snapshot.mostrarOcultos
        )) ?? []
        tree.inserir(filhos, em: path)
    }

    /// Lê `scripts` do package.json preservando a ordem do arquivo, que é a ordem em que
    /// a pessoa pensa neles (dev, build, test…).
    nonisolated static func lerScripts(_ pkg: Data?) -> [(nome: String, comando: String)] {
        guard let pkg, let obj = try? JSONSerialization.jsonObject(with: pkg) as? [String: Any],
              let scripts = obj["scripts"] as? [String: String]
        else { return [] }
        let texto = String(decoding: pkg, as: UTF8.self)
        return scripts.map { ($0.key, $0.value) }.sorted {
            let a = texto.range(of: "\"\($0.nome)\"")?.lowerBound
            let b = texto.range(of: "\"\($1.nome)\"")?.lowerBound
            guard let a, let b else { return $0.nome < $1.nome }
            return a < b
        }
    }

    /// Igual a `reload()`, mas a varredura do disco acontece fora do ator principal.
    private func recarregarArvoreEmSegundoPlano() {
        let raiz = root
        let ocultos = chrome.snapshot.mostrarOcultos
        Task.detached(priority: .utility) { [weak self] in
            let arvore = try? FileTreeBuilder.build(at: raiz, ocultos: ocultos)
            let pkg = try? Data(contentsOf: raiz.appending(path: "package.json"))
            guard let arvore else { return }
            let caminhos = arvore.allFiles().map(\.path).filter { !Ignore.isNoisePath($0) }
            let stack = Stack.detect(paths: caminhos, packageJSON: pkg)
            let scripts = Self.lerScripts(pkg)
            let pacotes = Self.lerPacotes(pkg, root: raiz)
            await MainActor.run {
                guard let self else { return }
                self.tree = arvore
                self.filePaths = caminhos
                self.stack = stack
                self.scripts = scripts
                self.packages = pacotes
                self.preencherAbertas()
                self.reloadTick += 1
            }
        }
    }

    public func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            lerSePreciso(path)
            reloadTick += 1
        }
        chrome.snapshot.expandedByProject[project.id] = Array(expanded)
    }

    // MARK: abas

    public var activeTab: EditorTab? {
        tabs.first { $0.path == active }
    }

    public func openFile(_ path: String) {
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(EditorTab(path: path))
            load(path)
            analyze(path)
            refreshGutter(path)
        }
        active = path
        selected = path
        persistTabs()
    }

    /// Abre o arquivo no painel da direita do modo Dois, sem tirar o foco da esquerda.
    public func openSecondary(_ path: String) {
        guard path != active else { return }
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(EditorTab(path: path))
            load(path)
            analyze(path)
            refreshGutter(path)
            persistTabs()
        }
        secondary = path
    }

    public func open(_ path: String, line: Int) {
        openFile(path)
        reveal = (line, (reveal?.token ?? 0) + 1)
    }

    private func load(_ path: String) {
        if buffers[path] == nil {
            buffers[path] = (try? ops.read(path)) ?? ""
        }
        marcaDisco[path] = ops.modifiedAt(path)
    }

    public func closeTab(_ path: String, force: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.path == path }) else { return }
        if tabs[i].isDirty, !force {
            save(path)
        }
        tabs.remove(at: i)
        if secondary == path {
            secondary = nil
        }
        buffers[path] = nil
        outlines[path] = nil
        links[path] = nil
        lint[path] = nil
        syntax[path] = nil
        gutter[path] = nil
        gutterFiles[path] = nil
        analysisTasks[path]?.cancel()
        if active == path {
            active = tabs.isEmpty ? nil : tabs[min(i, tabs.count - 1)].path
        }
        persistTabs()
    }

    public func closeOthers(_ path: String) {
        for t in tabs where t.path != path {
            closeTab(t.path)
        }
    }

    public func text(for path: String) -> String {
        buffers[path] ?? ""
    }

    public func setText(_ text: String, for path: String) {
        guard buffers[path] != text else { return }
        buffers[path] = text
        markDirty(path, true)
        scheduleAnalysis(path)
        if chrome.snapshot.editor.autoSave {
            saveTasks[path]?.cancel()
            saveTasks[path] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    return
                }
                self?.save(path)
            }
        }
    }

    private func markDirty(_ path: String, _ dirty: Bool) {
        guard let i = tabs.firstIndex(where: { $0.path == path }), tabs[i].isDirty != dirty else { return }
        tabs[i].isDirty = dirty
    }

    public func save(_ path: String? = nil) {
        guard let path = path ?? active, let text = buffers[path] else { return }
        do {
            try ops.write(path, text)
            marcaDisco[path] = ops.modifiedAt(path)
            markDirty(path, false)
            git.scheduleRefresh()
            refreshGutter(path)
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func saveAll() {
        for t in tabs where t.isDirty {
            save(t.path)
        }
    }

    private func persistTabs() {
        chrome.setTabs(tabs.map { EditorTab(path: $0.path) }, for: project.id)
        chrome.setActiveTab(active, for: project.id)
    }

    // MARK: operações de arquivo

    private func dir(of path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        if ops.isDirectory(path) {
            return path
        }
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }

    @discardableResult
    public func createFile(near path: String?, name: String? = nil) -> String? {
        let d = dir(of: path)
        let rel = name.map { d.isEmpty ? $0 : "\(d)/\($0)" } ?? ops.freeName(in: d, base: "sem-titulo", ext: "txt")
        do {
            try ops.createFile(rel)
            expanded.insert(d)
            reload()
            openFile(rel)
            return rel
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    public func createFolder(near path: String?, name: String) {
        let d = dir(of: path)
        let rel = d.isEmpty ? name : "\(d)/\(name)"
        do {
            try ops.createDirectory(rel)
            expanded.insert(d)
            expanded.insert(rel)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    public func rename(_ path: String, to newName: String, registrando: Bool = true) {
        do {
            let dest = try ops.rename(path, to: newName)
            remap(path, to: dest)
            if registrando {
                ultimaAcao = .renomeado(de: path, para: dest)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    public func move(_ path: String, into folder: String, registrando: Bool = true) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let dest = folder.isEmpty ? name : "\(folder)/\(name)"
        guard dest != path else { return }
        do {
            try ops.move(path, to: dest)
            remap(path, to: dest)
            expanded.insert(folder)
            if registrando {
                ultimaAcao = .movido(de: path, para: dest)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    public func delete(_ path: String) {
        do {
            let lixo = try ops.delete(path)
            ultimaAcao = .apagado(path: path, lixo: lixo)
            for t in tabs where t.path == path || t.path.hasPrefix(path + "/") {
                closeTab(t.path, force: true)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func remap(_ old: String, to new: String) {
        for i in tabs.indices {
            let p = tabs[i].path
            if p == old || p.hasPrefix(old + "/") {
                let np = new + p.dropFirst(old.count)
                tabs[i].path = np
                buffers[np] = buffers.removeValue(forKey: p)
                if active == p {
                    active = np
                }
            }
        }
        persistTabs()
    }
}
