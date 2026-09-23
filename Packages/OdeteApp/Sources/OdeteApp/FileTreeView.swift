import OdeteCore
import OdeteGit
import OdeteI18n
import OdeteUI
import SwiftUI
import UniformTypeIdentifiers

/// Aba de arquivos.
///
/// A pergunta que ela precisa responder de relance é "de onde é este arquivo". Por isso
/// a trilha do arquivo aberto em cima, as guias de recuo ligando cada linha à pasta que
/// a contém, a guia acesa no caminho do arquivo aberto, o filtro que mostra a pasta de
/// cada resultado e a marca do git na direita de quem mudou.
struct FileTreeView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @State private var renaming: String?
    @State private var newFolderAt: String?
    @State private var deleting: String?
    @State private var draft = ""
    @State private var busca = ""
    /// Sobe de um em um quando alguém pede para revelar o arquivo aberto.
    @State private var pedido = 0

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(tr("Arquivos"), detail: ws.project.name) {
                HeaderButton("doc.badge.plus", label: tr("Novo arquivo")) { ws.createFile(near: ws.selected) }
                HeaderButton("folder.badge.plus", label: tr("Nova pasta")) {
                    draft = ""; newFolderAt = ws.selected ?? ""
                }
                mais
            }
            filtro
            if busca.isEmpty, let ativo = ws.active {
                trilha(ativo)
            }
            Rectangle().fill(theme.separator).frame(height: 0.5)
            arvore
        }
        .alert(tr("Renomear"), isPresented: Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })) {
            TextField(tr("Nome"), text: $draft)
            Button(tr("Renomear")) {
                if let p = renaming {
                    ws.rename(p, to: draft)
                }; renaming = nil
            }
            Button(tr("Cancelar"), role: .cancel) { renaming = nil }
        }
        .alert(tr("Nova pasta"), isPresented: Binding(get: { newFolderAt != nil }, set: {
            if !$0 {
                newFolderAt = nil
            }
        })) {
            TextField(tr("nome"), text: $draft)
            Button(tr("Criar")) {
                if let at = newFolderAt {
                    ws.createFolder(near: at, name: draft)
                }; newFolderAt = nil
            }
            Button(tr("Cancelar"), role: .cancel) { newFolderAt = nil }
        }
        .confirmationDialog(
            tr("Apagar \"%1$@\"?", "\(deleting ?? "")"),
            isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(tr("Apagar"), role: .destructive) {
                if let p = deleting {
                    ws.delete(p)
                }; deleting = nil
            }
            Button(tr("Cancelar"), role: .cancel) { deleting = nil }
        }
    }

    /// Apagar no iPad não manda nada para a lixeira do sistema: o arquivo fica em
    /// `.odete/lixeira` para o desfazer. Mostrar o tamanho é o que dá para a pessoa
    /// perceber que aquilo ocupa espaço e decidir limpar.
    func medida(_ bytes: Int) -> String {
        Tamanho.arquivo(bytes)
    }

    /// O que não é de uso constante mora aqui, para o cabeçalho continuar legível numa
    /// coluna de 200 pt.
    var mais: some View {
        Menu {
            Button(tr("Revelar arquivo aberto"), systemImage: "scope") { pedido += 1 }
                .disabled(ws.active == nil)
            Button(tr("Recolher tudo"), systemImage: "arrow.down.right.and.arrow.up.left") { recolherTudo() }
            Toggle(isOn: Binding(
                get: { chrome.snapshot.mostrarOcultos },
                set: { chrome.snapshot.mostrarOcultos = $0; ws.reload() }
            )) {
                Label(tr("Mostrar ocultos"), systemImage: "eye")
            }
            Divider()
            if let a = ws.ultimaAcao, a.podeDesfazer {
                Button(tr("Desfazer %1$@", "\(a.descricao)"), systemImage: "arrow.uturn.backward") {
                    ws.desfazerArquivo()
                }
            }
            Button(tr("Recarregar"), systemImage: "arrow.clockwise") { ws.reload() }
            if ws.lixeira > 0 {
                Divider()
                Button(
                    tr("Esvaziar lixeira (%1$@)", "\(medida(ws.lixeira))"),
                    systemImage: "trash",
                    role: .destructive
                ) {
                    ws.esvaziarLixeira()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.fgMuted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(tr("Mais"))
    }

    var filtro: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.fgSubtle)
            TextField(tr("Filtrar arquivos"), text: $busca)
                .textFieldStyle(.plain)
                .font(OdeteFont.ui(12.5))
                .foregroundStyle(theme.fg)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !busca.isEmpty {
                Button { busca = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        .foregroundStyle(theme.fgSubtle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tr("Limpar filtro"))
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(theme.fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
    }

    /// Caminho do arquivo aberto em pedaços tocáveis. Cada pedaço abre a pasta dele na
    /// árvore, que é o caminho mais curto entre "estou vendo este arquivo" e "ele mora ali".
    func trilha(_ path: String) -> some View {
        let partes = path.split(separator: "/").map(String.init)
        return ScrollPane(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.fgSubtle)
                Text(ws.project.name).font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgSubtle).lineLimit(1)
                ForEach(Array(partes.enumerated()), id: \.offset) { i, parte in
                    let ultimo = i == partes.count - 1
                    Image(systemName: "chevron.compact.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(theme.fgSubtle)
                    Button {
                        let alvo = partes.prefix(i + 1).joined(separator: "/")
                        if ultimo {
                            ws.selected = alvo
                        } else {
                            abrirPasta(alvo)
                        }
                        pedido += 1
                    } label: {
                        Text(parte)
                            .font(OdeteFont.ui(11.5, weight: ultimo ? .semibold : .regular))
                            .foregroundStyle(ultimo ? theme.fg : theme.fgMuted)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
        }
        .frame(height: 24)
        .padding(.bottom, 6)
    }

    var arvore: some View {
        let marcas = decoracoes()
        let aceso = acesas(ws.active)
        let itens = linhas
        return ScrollViewReader { proxy in
            ScrollPane {
                // Uma lista só para a árvore e para o filtro. Com um `if` trocando duas
                // listas diferentes aqui dentro, a `LazyVStack` reaproveitava as linhas da
                // árvore para mostrar os resultados do filtro.
                LazyVStack(spacing: 0) {
                    ForEach(itens) { l in
                        FileRow(
                            node: l.node,
                            depth: l.depth,
                            pasta: l.pasta,
                            mudanca: marcas[l.node.path],
                            acesas: aceso,
                            renaming: $renaming,
                            deleting: $deleting,
                            newFolderAt: $newFolderAt,
                            draft: $draft
                        )
                        .id(l.node.path)
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: ws.active) { _, novo in revelar(novo, proxy) }
            .onChange(of: pedido) { _, _ in revelar(ws.active, proxy, centro: true) }
        }
        .overlay {
            if itens.isEmpty {
                vazio
            }
        }
        .dropDestination(for: String.self) { items, _ in
            for p in items {
                ws.move(p, into: "")
            }
            return true
        }
    }

    var vazio: some View {
        VStack(spacing: 8) {
            Image(systemName: busca.isEmpty ? "folder" : "magnifyingglass")
                .font(.system(size: 26)).foregroundStyle(theme.fgSubtle)
            Text(busca.isEmpty ? tr("Pasta vazia") : tr("Nada com \"%1$@\"", "\(busca)"))
                .font(OdeteFont.ui(13, weight: .medium)).foregroundStyle(theme.fgMuted)
            if busca.isEmpty {
                Text(tr("O botão de novo arquivo fica aqui em cima."))
                    .font(OdeteFont.ui(11.5)).foregroundStyle(theme.fgSubtle).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: dados da árvore

    struct Linha: Identifiable {
        var node: FileNode
        var depth: Int
        /// Pasta do arquivo, preenchida só no filtro: fora da árvore o nome sozinho não
        /// diz nada, metade dos projetos tem três `index.ts`.
        var pasta: String?
        var id: String {
            node.path
        }
    }

    /// A árvore visível vira uma lista plana: a `LazyVStack` só monta o que aparece e
    /// cada linha sabe o próprio nível, que é o que as guias de recuo desenham. Com o
    /// filtro ligado a lista passa a ser a dos arquivos que casam, cada um com a pasta.
    var linhas: [Linha] {
        if !busca.isEmpty {
            let alvo = busca.lowercased()
            return ws.filePaths
                .filter { $0.lowercased().contains(alvo) }
                .prefix(200)
                .map { Linha(node: FileNode(path: $0, isDirectory: false), depth: 0, pasta: pastaDe($0)) }
        }
        var out: [Linha] = []
        achatar(ws.tree.children ?? [], 0, &out)
        return out
    }

    func achatar(_ nodes: [FileNode], _ nivel: Int, _ out: inout [Linha]) {
        for n in nodes {
            out.append(Linha(node: n, depth: nivel))
            if n.isDirectory, ws.expanded.contains(n.path) {
                achatar(n.children ?? [], nivel + 1, &out)
            }
        }
    }

    /// Estado do git por caminho. As pastas herdam a mudança mais grave do que têm
    /// dentro, senão só o arquivo lá no fundo dá sinal e a pasta fechada não conta nada.
    func decoracoes() -> [String: Change] {
        var m: [String: Change] = [:]
        for e in ws.git.status {
            let c = e.unstaged ?? e.staged ?? .modified
            m[e.path] = c
            var partes = e.path.split(separator: "/").dropLast()
            while !partes.isEmpty {
                let dir = partes.joined(separator: "/")
                m[dir] = pior(m[dir], c)
                partes = partes.dropLast()
            }
        }
        return m
    }

    func pior(_ a: Change?, _ b: Change) -> Change {
        guard let a else { return b }
        return gravidade(a) >= gravidade(b) ? a : b
    }

    func gravidade(_ c: Change) -> Int {
        switch c {
        case .conflicted: 4
        case .deleted: 3
        case .modified, .typeChange, .renamed: 2
        case .added, .untracked: 1
        case .ignored: 0
        }
    }

    /// Pastas no caminho do arquivo aberto: são as guias que ficam acesas.
    func acesas(_ path: String?) -> Set<String> {
        guard let path else { return [] }
        var out: Set<String> = []
        var partes = path.split(separator: "/").dropLast()
        while !partes.isEmpty {
            out.insert(partes.joined(separator: "/"))
            partes = partes.dropLast()
        }
        return out
    }

    func pastaDe(_ path: String) -> String {
        let partes = path.split(separator: "/").dropLast()
        return partes.isEmpty ? ws.project.name : partes.joined(separator: "/")
    }

    // MARK: ações

    func abrirPasta(_ path: String) {
        if !ws.expanded.contains(path) {
            ws.toggle(path)
        }
        ws.selected = path
    }

    /// Abre o caminho todo até o arquivo e rola até ele. Quando o arquivo só mudou de
    /// aba, a rolagem é a mínima para ele aparecer; quem pediu para revelar leva ele
    /// para o meio da lista.
    func revelar(_ path: String?, _ proxy: ScrollViewProxy, centro: Bool = false) {
        guard let path, busca.isEmpty else { return }
        for pasta in acesas(path) where !ws.expanded.contains(pasta) {
            ws.toggle(pasta)
        }
        Task { @MainActor in
            withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(path, anchor: centro ? .center : nil) }
        }
    }

    func recolherTudo() {
        for p in ws.expanded {
            ws.toggle(p)
        }
    }
}

/// Linha da árvore: guias de recuo, seta, ícone do tipo, nome e a marca do git.
struct FileRow: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    /// Altura fixa: as guias de recuo precisam encostar de uma linha na outra, senão a
    /// linha vertical vira tracejado e deixa de ligar o arquivo à pasta.
    static let altura: CGFloat = 32
    var node: FileNode
    var depth: Int
    /// Fora da árvore (no filtro) a linha troca as guias de recuo pela pasta do arquivo.
    var pasta: String?
    var mudanca: Change?
    var acesas: Set<String>
    @Binding var renaming: String?
    @Binding var deleting: String?
    @Binding var newFolderAt: String?
    @Binding var draft: String
    @State private var over = false

    var aberta: Bool {
        ws.expanded.contains(node.path)
    }

    var ativo: Bool {
        ws.active == node.path
    }

    var selecionado: Bool {
        ws.selected == node.path
    }

    var body: some View {
        Button {
            if node.isDirectory {
                ws.toggle(node.path); ws.selected = node.path
            } else {
                ws.openFile(node.path)
            }
        } label: {
            linha
        }
        .buttonStyle(.plain)
        .draggable(node.path) {
            HStack(spacing: 6) {
                FileGlyph(path: node.path, isDirectory: node.isDirectory)
                Text(node.name).font(OdeteFont.ui(13))
            }
            .padding(8)
            .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 8))
        }
        .dropDestination(for: String.self) { items, _ in
            guard node.isDirectory else { return false }
            for p in items {
                ws.move(p, into: node.path)
            }
            return true
        } isTargeted: { over = $0 && node.isDirectory }
        .contextMenu {
            if node.isDirectory {
                Button(tr("Novo arquivo"), systemImage: "doc.badge.plus") { ws.createFile(near: node.path) }
                Button(tr("Nova pasta"), systemImage: "folder.badge.plus") { draft = ""; newFolderAt = node.path }
                Divider()
            } else {
                Button(tr("Abrir"), systemImage: "doc.text") { ws.openFile(node.path) }
            }
            Button(tr("Renomear"), systemImage: "pencil") { draft = node.name; renaming = node.path }
            Button(tr("Copiar caminho"), systemImage: "doc.on.doc") { UIPasteboard.general.string = node.path }
            if !node.isDirectory {
                ShareLink(item: ws.root.appending(path: node.path)) { Label(
                    tr("Compartilhar"),
                    systemImage: "square.and.arrow.up"
                ) }
            }
            if !node.isDirectory, ws.git.isRepo {
                Divider()
                Button(tr("Histórico"), systemImage: "clock.arrow.circlepath") { ws.historyPath = node.path }
                Button(tr("Blame"), systemImage: "person.text.rectangle") { ws.blamePath = node.path }
            }
            BotaoDoHistoricoLocal(caminho: node.path, pasta: node.isDirectory)
            Divider()
            Button(tr("Apagar"), systemImage: "trash", role: .destructive) { deleting = node.path }
            if let a = ws.ultimaAcao, a.podeDesfazer {
                Button(tr("Desfazer %1$@", "\(a.descricao)"), systemImage: "arrow.uturn.backward") {
                    ws.desfazerArquivo()
                }
            }
        }
    }

    var linha: some View {
        HStack(spacing: 0) {
            if pasta == nil {
                ForEach(Array(0 ..< depth), id: \.self) { k in guia(k) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.fgSubtle)
                    .rotationEffect(.degrees(aberta ? 90 : 0))
                    .opacity(node.isDirectory ? 1 : 0)
                    .frame(width: 14)
            }
            FileGlyph(path: node.path, isDirectory: node.isDirectory, expanded: aberta, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(node.name)
                    .font(OdeteFont.ui(13, weight: ativo ? .semibold : .regular))
                    .foregroundStyle(corNome)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let pasta {
                    Text(pasta)
                        .font(OdeteFont.ui(10.5))
                        .foregroundStyle(theme.fgSubtle)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.leading, 5)
            Spacer(minLength: 4)
            if !node.isDirectory {
                PontoDeAlteracao(path: node.path)
            }
            marca
        }
        .padding(.leading, pasta == nil ? 8 : 12)
        .padding(.trailing, 10)
        .frame(height: pasta == nil ? Self.altura : 44)
        .background(fundo, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 5)
        .contentShape(Rectangle())
    }

    /// Uma guia por nível ancestral, acesa quando aquela pasta está no caminho do
    /// arquivo aberto.
    func guia(_ k: Int) -> some View {
        let dono = node.path.split(separator: "/").prefix(k + 1).joined(separator: "/")
        return Rectangle()
            .fill(acesas.contains(dono) ? theme.accent.opacity(0.5) : theme.fg.opacity(0.11))
            .frame(width: 1, height: Self.altura)
            .frame(width: 14)
    }

    @ViewBuilder var marca: some View {
        if let mudanca {
            if node.isDirectory {
                Circle().fill(corGit(mudanca, theme)).frame(width: 6, height: 6)
            } else {
                Text(letraGit(mudanca))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(corGit(mudanca, theme))
                    .frame(width: 12)
            }
        }
    }

    var fundo: Color {
        if over {
            return theme.accent.opacity(0.2)
        }
        if ativo {
            return theme.accent.opacity(0.16)
        }
        if selecionado {
            return theme.fg.opacity(0.07)
        }
        return .clear
    }

    var corNome: Color {
        if let mudanca, !node.isDirectory {
            return corGit(mudanca, theme)
        }
        if ativo || node.isDirectory {
            return theme.fg
        }
        return theme.fg.opacity(0.84)
    }
}

/// O ponto de alteração não salva de uma linha da árvore.
///
/// View própria para ser a única coisa da linha que depende das abas. A linha inteira lia
/// `ws.tabs` para desenhar este ponto, então toda linha visível se refazia a cada vez que
/// uma aba mudava — com salvamento automático, a cada pausa na digitação. Medido, a linha
/// da árvore aparecia em 7 amostras por tecla sem nada nela ter mudado.
struct PontoDeAlteracao: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let path: String

    var body: some View {
        if ws.sujos.contains(path) {
            Circle().fill(theme.accent).frame(width: 6, height: 6)
        }
    }
}

/// Mesma convenção de cor do painel do git, para a árvore e o painel contarem a mesma
/// história sobre o mesmo arquivo.
func corGit(_ c: Change, _ theme: Theme) -> Color {
    switch c {
    case .added, .untracked: theme.ok
    case .deleted, .conflicted: theme.danger
    case .renamed: .purple
    default: theme.accent
    }
}

func letraGit(_ c: Change) -> String {
    switch c {
    case .untracked: "U"
    case .added: "A"
    case .modified, .typeChange: "M"
    case .deleted: "D"
    case .renamed: "R"
    case .conflicted: "!"
    case .ignored: "·"
    }
}
