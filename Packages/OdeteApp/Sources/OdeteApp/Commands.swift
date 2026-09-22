import OdeteCore
import OdeteEditor
import OdeteI18n
import SwiftUI

/// Ações do workspace expostas à barra de menus do iPadOS via `FocusedValue`.
@MainActor
struct WorkspaceActions {
    let ws: WorkspaceModel
    let chrome: ChromeState
    let app: AppModel
}

struct WorkspaceActionsKey: FocusedValueKey {
    typealias Value = WorkspaceActions
}

extension FocusedValues {
    var workspaceActions: WorkspaceActions? {
        get { self[WorkspaceActionsKey.self] }
        set { self[WorkspaceActionsKey.self] = newValue }
    }
}

/// Menus Arquivo, Editar (com os comandos do editor), Ver e Ir. O app target instala com
/// `.commands { OdeteCommands() }`.
///
/// Os atalhos do editor ficam no Editar, junto de recortar e colar: é onde se procura
/// "comentar linhas" num editor de código. ⌥↑, ⌥↓, ⇧⌥↓ e ⌃Tab também moram no próprio
/// editor (`HostDoEditor`), porque com texto em edição o iPadOS entrega essas teclas à
/// navegação de texto antes do menu; aqui eles aparecem para serem achados e clicados.
public struct OdeteCommands: Commands {
    @FocusedValue(\.workspaceActions) private var a

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(tr("Novo arquivo")) { a?.ws.createFile(near: a?.ws.selected) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(a == nil)
            Button(tr("Salvar")) { a?.ws.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(a == nil)
            Button(tr("Salvar todos")) { a?.ws.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(a == nil)
            Divider()
            Button(tr("Fechar aba")) {
                if let p = a?.ws.active {
                    a?.ws.closeTab(p)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(a?.ws.active == nil)
            Button(tr("Voltar aos projetos")) { a?.app.closeWorkspace() }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(a == nil)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button(tr("Ir para a linha…")) { a?.ws.paletteQuery = ":"; a?.ws.paletteOpen = true }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(a?.ws.active == nil)
            Divider()
            editar(tr("Aumentar recuo"), .indentar)
                .keyboardShortcut("]", modifiers: .command)
            editar(tr("Diminuir recuo"), .desindentar)
                .keyboardShortcut("[", modifiers: .command)
            editar(tr("Comentar linhas"), .alternarComentario)
                .keyboardShortcut("/", modifiers: .command)
            editar(tr("Subir linhas"), .subirLinhas)
                .keyboardShortcut(.upArrow, modifiers: .option)
            editar(tr("Descer linhas"), .descerLinhas)
                .keyboardShortcut(.downArrow, modifiers: .option)
            editar(tr("Duplicar linhas"), .duplicarLinhas)
                .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            editar(tr("Apagar linhas"), .apagarLinhas)
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            // ⌘' é o "próximo problema" do Xcode; o ⌘. o iPadOS usa para cancelar.
            editar(tr("Mostrar problema no cursor"), .mostrarProblema)
                .keyboardShortcut("'", modifiers: .command)
        }
        CommandMenu(tr("Ver")) {
            Button(tr("Sidebar")) { a?.chrome.toggleSide() }.keyboardShortcut("b", modifiers: .command)
            Button(tr("Agente")) { a?.chrome.toggleAgent() }.keyboardShortcut("i", modifiers: .command)
            Button(tr("Falar com o agente")) {
                if a?.chrome.snapshot.agentVisible == false {
                    a?.chrome.toggleAgent()
                }
                a?.ws.agent.focusRequest += 1
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            Button(tr("Terminal")) { a?.chrome.toggleTerm() }.keyboardShortcut("j", modifiers: .command)
            Divider()
            ForEach(CenterMode.allCases, id: \.self) { m in
                Button(tr("Modo: %1$@", m.label)) { a?.chrome.snapshot.center = m }
            }
            Divider()
            Button(tr("Restaurar layout")) { a?.chrome.resetLayout() }
        }
        CommandMenu(tr("Ir")) {
            Button(tr("Paleta de comandos")) { a?.ws.paletteQuery = ">"; a?.ws.paletteOpen = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(tr("Ir para arquivo")) { a?.ws.paletteQuery = ""; a?.ws.paletteOpen = true }
                .keyboardShortcut("p", modifiers: .command)
            Button(tr("Ir para definição")) { a?.ws.irParaDefinicao() }
                .keyboardShortcut("j", modifiers: [.command, .control])
            Button(tr("Símbolo no projeto")) { a?.ws.paletteQuery = "#"; a?.ws.paletteOpen = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button(tr("Localizar no arquivo")) { a?.ws.busca.abrir() }
                .keyboardShortcut("f", modifiers: .command)
            Button(tr("Buscar no projeto")) { a?.chrome.snapshot.side = .search; a?.chrome.snapshot.sideOpen = true }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button(tr("Próxima aba")) { a?.ws.irParaAba(deslocamento: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled((a?.ws.tabs.count ?? 0) < 2)
            Button(tr("Aba anterior")) { a?.ws.irParaAba(deslocamento: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled((a?.ws.tabs.count ?? 0) < 2)
            Menu(tr("Aba")) {
                ForEach(1 ... 9, id: \.self) { n in
                    Button(tr("Aba %1$@", "\(n)")) { a?.ws.irParaAba(numero: n) }
                        .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                        .disabled((a?.ws.tabs.count ?? 0) < n)
                }
            }
            Divider()
            ForEach(SidePanel.allCases, id: \.self) { p in
                Button(p.label) { a?.chrome.select(side: p) }
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(tr("Ajustes…")) { a?.chrome.settingsOpen = true }
                .keyboardShortcut(",", modifiers: .command)
        }
    }

    /// Comando de texto do editor. Vai para o editor com o foco, ou para o do arquivo
    /// ativo quando o clique no menu veio com o foco em outro painel.
    private func editar(_ titulo: String, _ acao: AcaoDoEditor) -> some View {
        Button(titulo) { ComandosDoEditor.executar(acao, documento: a?.ws.documentoAtivo) }
            .disabled(a?.ws.active == nil)
    }
}
