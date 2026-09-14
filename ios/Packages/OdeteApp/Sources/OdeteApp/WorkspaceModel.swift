import Foundation
import Observation
import OdeteAccounts
import OdeteAgent
import OdeteBundler
import OdeteCore
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
    public var tabs: [EditorTab] = []
    public var active: String?
    public var buffers: [String: String] = [:]
    public var expanded: Set<String> = []
    public var selected: String?
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
            tree = try FileTreeBuilder.build(at: root)
            let pkg = try? Data(contentsOf: root.appending(path: "package.json"))
            stack = Stack.detect(paths: tree.allFiles().map(\.path), packageJSON: pkg)
            reloadTick += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func externalReload() {
        reload()
        git.scheduleRefresh()
        for t in tabs where !t.isDirty {
            if ops.exists(t.path) {
                if let disk = try? ops.read(t.path), disk != buffers[t.path] {
                    buffers[t.path] = disk
                    analyze(t.path)
                }
            } else {
                closeTab(t.path, force: true)
            }
        }
    }

    public func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
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

    public func open(_ path: String, line: Int) {
        openFile(path)
        reveal = (line, (reveal?.token ?? 0) + 1)
    }

    private func load(_ path: String) {
        if buffers[path] == nil {
            buffers[path] = (try? ops.read(path)) ?? ""
        }
    }

    public func closeTab(_ path: String, force: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.path == path }) else { return }
        if tabs[i].isDirty, !force {
            save(path)
        }
        tabs.remove(at: i)
        buffers[path] = nil
        outlines[path] = nil
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

    public func rename(_ path: String, to newName: String) {
        do {
            let dest = try ops.rename(path, to: newName)
            remap(path, to: dest)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    public func move(_ path: String, into folder: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let dest = folder.isEmpty ? name : "\(folder)/\(name)"
        guard dest != path else { return }
        do {
            try ops.move(path, to: dest)
            remap(path, to: dest)
            expanded.insert(folder)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    public func delete(_ path: String) {
        do {
            try ops.delete(path)
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
