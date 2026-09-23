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
///
/// Uma regra atravessa o modelo: cada tecla pode mudar o texto, o cursor e o ponto de
/// alteração da aba, e mais nada. Medido num arquivo TSX de 60 linhas, uma tecla gastava
/// 17,7 ms de CPU, 59% deles em SwiftUI refazendo views que não tinham nada a ver com a
/// tecla — a barra de status inteira três vezes, todas as abas, as linhas da árvore, o
/// rail e o terminal. O motivo era sempre o mesmo: uma propriedade observada que muda a
/// cada tecla (ou a cada pausa) lida por uma view grande. Por isso aqui se escreve só o
/// que mudou, e o que é derivado fica guardado em vez de recalculado no corpo das views —
/// ver `WorkspaceAnalise.swift` e `WorkspaceEscritas.swift`.
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
    /// Índice de nomes do projeto e a assinatura que diz quando ele envelheceu.
    ///
    /// Esta e as outras contas internas ficam fora da observação: nenhuma tela as lê, e
    /// cada escrita numa propriedade observada passa pelo registro de quem observa.
    @ObservationIgnored var indiceCache: Resolvedor.Indice?
    @ObservationIgnored var assinaturaDoIndice = ""
    /// Scripts do package.json, na ordem em que estão escritos. Antes só existiam para
    /// quem lembrasse de digitar `npm run` no terminal.
    public internal(set) var scripts: [(nome: String, comando: String)] = []
    /// Pacotes que dá para importar: o que o package.json declara mais o que está
    /// instalado em node_modules. É o que o autocompletar do `from "…"` oferece.
    public private(set) var packages: [String] = []
    public var tabs: [EditorTab] = [] {
        didSet { sujos = Set(tabs.lazy.filter(\.isDirty).map(\.path)) }
    }

    /// Caminhos das abas com alteração não salva.
    ///
    /// A árvore mostra um ponto em cada arquivo alterado, e cada linha dela lia `tabs`
    /// para saber disso — toda linha visível era redesenhada quando qualquer aba mudava,
    /// o que com salvamento automático é toda pausa na digitação. Aqui o ponto lê um
    /// conjunto que só muda quando o estado de alguma aba muda de fato.
    public private(set) var sujos: Set<String> = []
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
    /// Pedido de levar o editor de um arquivo a uma linha. De uso único: o editor que o
    /// atende avisa (`linhaRevelada`) e ele some — ficando aqui, todo editor que nascia
    /// depois pulava de novo para a mesma linha.
    public var reveal: PedidoDeLinha?
    /// Abas com alteração não salva cujo arquivo mudou no disco por fora (agente, terminal,
    /// git). Nada é gravado nem descartado nelas até a pessoa escolher na faixa do editor
    /// — ver `WorkspaceDisco.swift`.
    public internal(set) var conflitos: Set<String> = []
    /// Abas esperando a pessoa dizer se salva antes de fechar, na ordem em que foram
    /// fechadas.
    public internal(set) var abasParaFechar: [String] = []
    /// Impressão do conteúdo do disco que cada aba conhece: o que foi lido ao abrir ou
    /// gravado por último. É contra ela que se decide se o disco mudou por fora.
    @ObservationIgnored var baseDisco: [String: UInt64] = [:]
    /// Onde está o cursor de cada arquivo aberto, em UTF-16. Só o salvamento automático lê:
    /// é a linha que ele não apara.
    @ObservationIgnored var cursores: [String: Int] = [:]
    /// Ver `WorkspaceEditorConfig.swift`.
    @ObservationIgnored var cacheDeEditorConfig = CacheDeEditorConfig()
    /// Incrementa a cada reload da árvore (salvar, watcher); o preview Swift recompila.
    public internal(set) var reloadTick = 0
    public var swiftDiagnostics: [SwiftDiagnostic] = []
    public var paletteOpen = false
    public var paletteQuery = ""
    public let git: GitModel
    public let run: RunModel
    public let preview: PreviewModel
    public private(set) var agent: AgentModel!
    /// Arquivos em conflito que o usuário quer editar como texto puro.
    public var forceTextEdit: Set<String> = []
    /// Arquivos abertos que não são texto: ficam sem buffer e nunca são gravados.
    public var naoEhTexto: Set<String> = []
    /// Apelidos de caminho do `tsconfig.json` (`@/` → `src/`).
    public var tsAliases: [String: String] = [:]
    /// Símbolos do projeto inteiro, para ir à definição e para a paleta.
    public var simbolos: [ProjectSymbol] = []
    @ObservationIgnored var indexTask: Task<Void, Never>?
    /// Busca dentro do arquivo aberto. Mora aqui, e não num `@State` do centro, porque o
    /// ⌘F vem do menu de comandos, que só alcança os modelos.
    public let busca = BuscaLocal()
    /// Onde está o cursor do arquivo ativo, em UTF-16. Só a posição na barra de status lê
    /// isto; ver `posicaoDoCursor(em:)`.
    public var cursorOffset = 0
    /// Folhas de histórico/blame por arquivo (nil = fechadas).
    public var historyPath: String?
    public var blamePath: String?
    public let historicoLocal = HistoricoLocalEstado()
    @ObservationIgnored var analysisTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var lintEngine: Esbuild?

    // Onde moram esboço, lint, sintaxe, elos e marcas por arquivo. As propriedades
    // públicas (`outlines`, `lint`, …) estão em `WorkspaceAnalise.swift` e só avisam quem
    // observa quando o valor muda. Não escreva aqui direto: escrever direto não avisa
    // ninguém, e a tela fica velha.
    @ObservationIgnored var guardadoOutlines: [String: [OutlineItem]] = [:]
    @ObservationIgnored var guardadoLinks: [String: [EditorLink]] = [:]
    @ObservationIgnored var guardadoPatchChanges: [String: [EditorLineChange]] = [:]
    @ObservationIgnored var guardadoLint: [String: [LintIssue]] = [:]
    @ObservationIgnored var guardadoSyntax: [String: [Diagnostic]] = [:]
    @ObservationIgnored var guardadoGutter: [String: [GutterMark]] = [:]
    @ObservationIgnored var guardadoGutterFiles: [String: FileDiff] = [:]

    /// Quantos erros e avisos há, somadas todas as fontes — ver `vigiarProblemas()`.
    public internal(set) var contagemDeProblemas = ContagemDeProblemas()

    private let chrome: ChromeState
    private let rascunhos: Rascunhos
    @ObservationIgnored var observador: ObservadorDeArquivos?
    @ObservationIgnored var saveTasks: [String: Task<Void, Never>] = [:]
    /// O que o próprio app gravou e ainda não teve o aviso do observador — ver
    /// `EscritasProprias`.
    @ObservationIgnored var escritas = EscritasProprias()
    /// Mapa de linhas do último texto que a barra de status perguntou.
    @ObservationIgnored var mapaDoCursor: (caminho: String, texto: String, mapa: LinhasDoTexto)?

    init(project: Project, root: URL, chrome: ChromeState, accounts: AccountStore, aiAccounts: AIAccountStore) {
        self.project = project
        self.root = root
        self.chrome = chrome
        rascunhos = Rascunhos(projeto: project.id.uuidString)
        ops = FileOps(root: root)
        git = GitModel(root: root, accounts: accounts)
        run = RunModel(root: root, git: git)
        preview = PreviewModel(root: root)
        agent = nil
        tabs = chrome.tabs(for: project.id).filter { ops.exists($0.path) }.map { EditorTab(path: $0.path) }
        active = chrome.activeTab(for: project.id).flatMap { p in tabs.contains { $0.path == p } ? p : nil } ?? tabs
            .first?.path
        expanded = Set(chrome.snapshot.expandedByProject[project.id] ?? ["src"])
        PastaDeModulos.migrarSePreciso(root) // no iCloud, node_modules sai da sincronização
        reload()
        for t in tabs {
            load(t.path)
        }
        retomarRascunhos()
        // Sem relógio: quem avisa é o sistema de arquivos. A árvore acorda quando algo
        // muda nela, e cada aba aberta tem observador próprio porque conteúdo reescrito
        // não mexe na data da pasta — ver `ObservadorDeArquivos`.
        let obs = ObservadorDeArquivos(raiz: root) { [weak self] in
            Task { @MainActor in self?.externalReload() }
        } aoMudarArquivo: { [weak self] caminho in
            Task { @MainActor in self?.conferirDisco(caminho) }
        }
        obs.comecar()
        observador = obs
        acompanharAbas()
        agent = AgentModel(ws: self, chrome: chrome, accounts: aiAccounts)
        git.onRefreshed = { [weak self] in
            self?.refreshGutters()
            // A lista de mudados pode ter mudado: o observador passa a vigiar os novos.
            self?.acompanharAbas()
        }
        git.painelAberto = { [weak chrome] in chrome?.snapshot.side == .git }
        for t in tabs {
            analyze(t.path)
        }
        refreshGutters()
        vigiarProblemas()
    }

    /// Devolve às abas o que estava digitado e não salvo quando o app saiu de cena.
    ///
    /// Só entra o que difere do disco: se alguém salvou pelo caminho, o rascunho é
    /// passado e voltaria como falsa alteração pendente.
    private func retomarRascunhos() {
        let guardados = rascunhos.ler()
        guard !guardados.isEmpty else { return }
        for (caminho, texto) in guardados {
            guard let i = tabs.firstIndex(where: { $0.path == caminho }),
                  let disco = buffers[caminho], disco != texto else { continue }
            buffers[caminho] = texto
            tabs[i].isDirty = true
        }
    }

    /// Última chance de não perder o que foi digitado: o iPad encerra app suspenso sem
    /// aviso. Com salvamento automático, grava agora em vez de esperar o segundo de
    /// espera; sem ele, guarda o rascunho fora do projeto, sem tocar no arquivo.
    public func aoSairDeCena() {
        if chrome.snapshot.editor.autoSave {
            saveAll(automatico: true)
        }
        guardarRascunhos()
    }

    private func guardarRascunhos() {
        var sujos: [String: String] = [:]
        for t in tabs where t.isDirty {
            sujos[t.path] = buffers[t.path]
        }
        rascunhos.gravar(sujos)
    }

    /// Recarrega o buffer de um arquivo que outra coisa (agente, shell, git, a troca da
    /// busca) escreveu no disco.
    ///
    /// Aba limpa recebe o disco. Aba com alteração não salva não: antes o buffer era
    /// trocado e a aba marcada como limpa, e o que a pessoa tinha digitado sumia sem
    /// aviso. Agora o texto dela fica, e a faixa de conflito pergunta — ver
    /// `absorverDisco`.
    public func reloadBuffer(_ path: String) {
        guard buffers[path] != nil, let novo = try? ops.read(path) else { return }
        marcaDisco[path] = ops.modifiedAt(path)
        guardarBuffer(path, antesDe: novo, origem: .recarregar)
        absorverDisco(path, disco: novo)
    }

    /// Mostra a gaveta do terminal (iPad) sem mexer no resto do layout.
    public func showTerminal() {
        if !chrome.snapshot.termVisible {
            chrome.toggleTerm()
        }
    }

    func stop() {
        observador?.parar()
        run.stopAll()
        agent.stop()
        for t in saveTasks.values {
            t.cancel()
        }
        saveAll()
        guardarRascunhos()
    }

    // MARK: árvore

    public func reload() {
        do {
            tree = try FileTreeBuilder.build(at: root, ocultos: chrome.snapshot.mostrarOcultos)
            filePaths = tree.allFiles().map(\.path).filter { !Ignore.isNoisePath($0) }
            let pkg = try? Data(contentsOf: root.appending(path: "package.json"))
            stack = Stack.detect(paths: filePaths, packageJSON: pkg)
            trocarScripts(Self.lerScripts(pkg))
            packages = Self.lerPacotes(pkg, root: root)
            tsAliases = ImportLinks.aliases(tsconfig: try? Data(contentsOf: root.appending(path: "tsconfig.json")))
            preencherAbertas()
            indexarSimbolos()
            lixeira = ops.tamanhoDaLixeira()
            esquecerEditorConfig()
            reloadTick += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Data de modificação vista por último em cada arquivo aberto — ver `conferirDisco`,
    /// em `WorkspaceDisco.swift`.
    @ObservationIgnored var marcaDisco: [String: Date] = [:]

    /// A mudança veio mesmo de fora: remonta a árvore e relê as abas limpas. Quem chama é
    /// `externalReload`, depois de descartar o aviso que foi só do salvamento do app.
    func recarregarDeFora() {
        // Mudança vinda de fora não tem ninguém esperando na tela, então a árvore é
        // remontada fora do ator principal: percorrer o projeto inteiro aqui travava a
        // digitação toda vez que o agente ou um script mexesse em arquivo.
        recarregarArvoreEmSegundoPlano()
        git.agendarMarcas()
        for t in tabs where t.isDirty && ops.exists(t.path) {
            // Aba suja não recebe o disco, mas fica sabendo que ele mudou: sem isto o
            // próximo salvamento gravava por cima do que chegou de fora.
            if ops.modifiedAt(t.path) != marcaDisco[t.path], let disco = try? ops.read(t.path) {
                marcaDisco[t.path] = ops.modifiedAt(t.path)
                absorverDisco(t.path, disco: disco)
            }
        }
        for t in tabs where !t.isDirty {
            if ops.exists(t.path) {
                if let disk = try? ops.read(t.path), disk != buffers[t.path] {
                    marcaDisco[t.path] = ops.modifiedAt(t.path)
                    guardarBuffer(t.path, antesDe: disk, origem: .externo)
                    absorverDisco(t.path, disco: disk)
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
        // No iCloud, `node_modules` é link para `node_modules.nosync`, e listar pelo link
        // não devolve nada — o autocomplete de import perdia os pacotes instalados.
        let nm = PastaDeModulos.pastaReal(root)
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
    ///
    /// Árvore, caminhos, pilha e pacotes só avisam quem observa quando mudaram (o
    /// `@Observable` compara os `Equatable`); os scripts passam por `trocarScripts`.
    func recarregarArvoreEmSegundoPlano() {
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
                self.trocarScripts(scripts)
                self.packages = pacotes
                self.preencherAbertas()
                self.esquecerEditorConfig()
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
            acompanharAbas()
            load(path)
            analyze(path)
            refreshGutter(path)
        }
        active = path
        selected = path
        // Diff e Preview ocupam o centro inteiro e não mostram editor nenhum: abrir um
        // arquivo com um deles na frente trocava a aba e a trilha e deixava na tela o
        // diff de outro arquivo. Os modos que mostram o editor (Dois, Split) ficam como
        // estão — lá o arquivo aberto aparece.
        if chrome.snapshot.center == .diff || chrome.snapshot.center == .preview {
            chrome.snapshot.center = .code
        }
        persistTabs()
    }

    /// Abre o arquivo no painel da direita do modo Dois, sem tirar o foco da esquerda.
    public func openSecondary(_ path: String) {
        guard path != active else { return }
        if !tabs.contains(where: { $0.path == path }) {
            tabs.append(EditorTab(path: path))
            acompanharAbas()
            load(path)
            analyze(path)
            refreshGutter(path)
            persistTabs()
        }
        secondary = path
    }

    public func open(_ path: String, line: Int) {
        openFile(path)
        reveal = PedidoDeLinha(path: path, line: line, token: TokensDoEditor.proximo())
    }

    /// O pedido de linha deste arquivo, no formato do editor — `nil` para os outros: no
    /// modo Dois só o lado que mostra o arquivo pedido pula.
    public func pedidoDeLinha(para path: String) -> (line: Int, token: Int)? {
        guard let r = reveal, r.path == path else { return nil }
        return (r.line, r.token)
    }

    /// O editor atendeu o pedido de linha: ele não vale mais.
    public func linhaRevelada(_ token: Int) {
        if reveal?.token == token {
            reveal = nil
        }
    }

    /// Guarda onde está o cursor de um arquivo aberto.
    public func anotarCursor(_ offset: Int, em path: String) {
        cursores[path] = offset
        if path == active {
            cursorOffset = offset
        }
    }

    private func load(_ path: String) {
        var lido: String?
        if buffers[path] == nil {
            do {
                let texto = try ops.read(path)
                buffers[path] = texto
                lido = texto
                naoEhTexto.remove(path)
            } catch FileError.naoEhTexto {
                // Sem buffer de propósito: com um buffer vazio o editor abriria em branco
                // e o primeiro salvamento gravaria o vazio por cima do arquivo.
                naoEhTexto.insert(path)
            } catch {
                buffers[path] = ""
            }
        } else {
            lido = try? ops.read(path)
        }
        marcaDisco[path] = ops.modifiedAt(path)
        // O disco como a aba o conheceu: é a base para saber, ao salvar, se alguém mexeu
        // no arquivo por fora enquanto ela estava aberta.
        if let lido {
            baseDisco[path] = EscritasProprias.impressao(lido)
        }
    }

    /// Fecha a aba.
    ///
    /// Com alteração não salva: com salvamento automático ligado, grava e fecha — é o que
    /// a pessoa espera dele. Com ele desligado, ou com o disco em conflito, pergunta
    /// (`abasParaFechar`, respondido em `decidirFechamento`): antes gravava sem perguntar
    /// mesmo com o salvamento automático desligado. `force` fecha sem gravar nada.
    public func closeTab(_ path: String, force: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.path == path }) else { return }
        if tabs[i].isDirty, !force {
            let gravou = chrome.snapshot.editor.autoSave && !conflitos.contains(path) && save(path)
            guard gravou else {
                if !abasParaFechar.contains(path) {
                    abasParaFechar.append(path)
                }
                return
            }
        }
        tabs.remove(at: i)
        acompanharAbas()
        if secondary == path {
            secondary = nil
        }
        saveTasks[path]?.cancel()
        saveTasks[path] = nil
        abasParaFechar.removeAll { $0 == path }
        conflitos.remove(path)
        baseDisco[path] = nil
        cursores[path] = nil
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

    /// A resposta à pergunta de `closeTab` sobre uma aba com alteração não salva.
    public enum DecisaoAoFechar {
        case salvar
        case descartar
        case cancelar
    }

    public func decidirFechamento(_ path: String, _ decisao: DecisaoAoFechar) {
        abasParaFechar.removeAll { $0 == path }
        switch decisao {
        case .salvar:
            // Com o disco em conflito, "salvar" aqui é a pessoa escolhendo o texto dela.
            let gravou = conflitos.contains(path) ? manterOMeu(path) : save(path)
            if gravou {
                closeTab(path, force: true)
            }
        case .descartar:
            closeTab(path, force: true)
        case .cancelar:
            break
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
                self?.save(path, automatico: true)
            }
        }
    }

    func markDirty(_ path: String, _ dirty: Bool) {
        guard let i = tabs.firstIndex(where: { $0.path == path }), tabs[i].isDirty != dirty else { return }
        tabs[i].isDirty = dirty
    }

    /// Grava a aba no disco. Devolve se gravou.
    ///
    /// Nunca por cima de uma mudança de fora: se o disco não é mais o que a aba conheceu
    /// (o agente, um script ou o git escreveram nele), a aba entra em conflito e nada é
    /// gravado — nem pelo salvamento automático, nem pelo ⌘S — até a pessoa escolher na
    /// faixa do editor. Antes o salvamento gravava por cima, calado.
    ///
    /// `automatico`: veio do salvamento automático (a pausa na digitação, o app saindo de
    /// cena). Aí a linha do cursor não é aparada — ver `arrumado`.
    @discardableResult
    public func save(_ path: String? = nil, automatico: Bool = false) -> Bool {
        guard let path = path ?? active, let bruto = buffers[path], !naoEhTexto.contains(path) else { return false }
        guard !conflitos.contains(path) else { return false }
        let cursor = automatico ? (cursores[path] ?? (path == active ? cursorOffset : nil)) : nil
        let text = arrumado(bruto, caminho: path, preservando: cursor)
        if discoMudouPorFora(path, gravando: [bruto, text]) {
            conflitos.insert(path)
            return false
        }
        do {
            if text != bruto {
                buffers[path] = text
            }
            // Arquivo que não existia muda a árvore: esse aviso do observador tem de
            // remontá-la, então a gravação não entra como só do app.
            let existia = ops.exists(path)
            try ops.write(path, text)
            marcaDisco[path] = ops.modifiedAt(path)
            baseDisco[path] = EscritasProprias.impressao(text)
            if existia {
                registrarEscritaPropria(path, text)
            }
            if (path as NSString).lastPathComponent == ".editorconfig" {
                esquecerEditorConfig()
            }
            markDirty(path, false)
            git.agendarMarcas()
            refreshGutter(path)
            // O preview Swift lê os arquivos do disco. Antes ele recompilava porque o
            // salvamento acordava o observador e remontava a árvore; agora que a gravação
            // do próprio app não remonta nada, o aviso sai daqui.
            reloadTick += 1
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// O que os ajustes de salvamento mandam fazer com o texto antes de ele ir ao disco.
    ///
    /// Os dois são o que todo editor de código faz e todo revisor de diff agradece: linha
    /// que termina em espaço e arquivo sem quebra no fim viram ruído no `git diff` de quem
    /// mexer no arquivo depois. Ficam desligados por padrão, porque mexer no arquivo de
    /// alguém sem avisar é pior que o ruído; o `.editorconfig` do projeto, se diz algo,
    /// manda sobre os Ajustes.
    ///
    /// As contas são em UTF-16 (`Arrumacao`): em Swift `"\r\n"` é um caractere só, e o
    /// aparar por `split(separator: "\n")` não partia linha CRLF nenhuma, enquanto o
    /// `hasSuffix("\n")` punha um `\n` a mais depois do `\r\n` do fim.
    ///
    /// `preservando`: posição do cursor cuja linha não é aparada. O salvamento automático
    /// grava um segundo depois de a pessoa parar de digitar; aparar a linha dela comia o
    /// espaço recém-digitado, e o texto sumia debaixo do cursor.
    func arrumado(_ texto: String, caminho: String? = nil, preservando: Int? = nil) -> String {
        let cfg = caminho.map(configDoArquivo)
        var t = texto
        if cfg?.aparar ?? chrome.snapshot.editor.trimOnSave {
            t = Arrumacao.aparar(t, preservando: preservando)
        }
        if cfg?.quebraNoFim ?? chrome.snapshot.editor.finalNewline {
            t = Arrumacao.quebraNoFim(t, padrao: cfg?.fimDeLinha)
        }
        return t
    }

    /// `automatico`: o app saindo de cena, e não o ⌘⌥S — ver `save`.
    public func saveAll(automatico: Bool = false) {
        for t in tabs where t.isDirty {
            save(t.path, automatico: automatico)
        }
    }

    /// `internal` e não `private`: as operações de arquivo vivem numa extensão, noutro
    /// arquivo, e também precisam gravar as abas.
    func persistTabs() {
        chrome.setTabs(tabs.map { EditorTab(path: $0.path) }, for: project.id)
        chrome.setActiveTab(active, for: project.id)
    }
}

/// Levar o editor de um arquivo a uma linha (1-based). O `token` vem de
/// `TokensDoEditor`: é ele que diz ao editor que o pedido é novo.
public struct PedidoDeLinha: Equatable, Sendable {
    public var path: String
    public var line: Int
    public var token: Int
}
