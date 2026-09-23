import OdeteCore
import OdeteFiles
import OdeteUI
import SwiftUI
import UIKit

/// Raiz do app: carrega o estado persistido, aplica o tema e decide entre hub e workspace.
public struct RootView: View {
    @State private var chrome: ChromeState
    @State private var app = AppModel()
    /// Só para reagir: `OdeteFont` calcula o tamanho na hora, e sem alguém observando
    /// isto a tela não se refaz quando a pessoa muda o tamanho de texto do iPad.
    @Environment(\.dynamicTypeSize) private var tamanhoDoSistema
    /// O servidor de dev não sobrevive ao app sair de cena; ver `BackgroundServers`.
    @Environment(\.scenePhase) private var fase
    /// A janela tem controles do sistema por cima do canto? Vem da geometria, e é
    /// reavaliado a cada mudança de tamanho, que é quando pode mudar.
    @State private var emJanela = false
    /// Esta janela, para o registro de `Janelas`.
    @State private var idDaJanela = UUID()
    @State private var caixaDaCena = CaixaDaCena()
    /// O projeto desta janela, para o sistema devolvê-lo quando recriar a cena: o id,
    /// `hub` para a lista de projetos, vazio para quem nunca escolheu. Cada janela lembra
    /// o seu — antes todas reabriam o mesmo último projeto do `state.json`.
    @SceneStorage("odete.projetoDaJanela") private var projetoDaJanela = ""
    /// A cena está indo embora: fechar o projeto agora não é "voltar para a lista", e
    /// não pode ficar lembrado como se fosse.
    @State private var saindoDeCena = false

    public init() {
        // Todo campo de texto do app ganha a barra com o botão de recolher o teclado.
        // Uma vez, aqui, em vez de um botão por tela — ver `Teclado`.
        Teclado.instalaBarra()
        // O estado de todos: cada janela tem o seu `ChromeState`, mas todos nascem do mesmo
        // e se falam por `Janelas` — ver `Janelas.mudou`.
        let janelas = Janelas.shared
        let snap = janelas.snapshotInicial()
        _chrome = State(initialValue: ChromeState(snapshot: snap))
        // Projetos no iCloud: onde fica o iCloud é perguntado fora do ator principal (ver
        // `LocalDaNuvem`); antes a pergunta era feita aqui, e a janela esperava por ela
        // para aparecer. Se outra janela já perguntou, a resposta está guardada.
        let raiz: URL? = if !snap.projectsInCloud {
            ProjectStore.defaultRoot()
        } else if let sabida = janelas.nuvem.sabido {
            sabida ?? ProjectStore.defaultRoot()
        } else {
            nil
        }
        _app = State(initialValue: AppModel(
            store: ProjectStore(root: raiz ?? ProjectStore.defaultRoot()),
            accounts: janelas.accounts,
            aiAccounts: janelas.aiAccounts,
            external: janelas.external,
            aguardandoRaiz: raiz == nil
        ))
    }

    /// O claro/escuro do iPad, para quando o tema segue o sistema.
    @Environment(\.colorScheme) private var esquema

    public var body: some View {
        // A escala da interface vive numa estática lida por dentro das fontes. Casar o
        // valor aqui, no começo do corpo, garante que já esta passada de desenho saia no
        // tamanho novo — num `onChange` ela chegaria uma passada atrasada.
        OdeteFont.escala = chrome.snapshot.uiScale
        return corpo
    }

    var corpo: some View {
        // `VStack` e não `safeAreaInset`: o `TabView` do layout estreito desenhava a
        // própria barra por baixo da faixa, e aqui a divisão é dura para qualquer layout.
        VStack(spacing: 0) {
            if emJanela {
                BarraDaJanela(titulo: app.workspace?.project.name ?? "Odete")
                    .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
            }
            Group {
                if let ws = app.workspace {
                    WorkspaceView()
                        .environment(ws)
                        .id(ws.project.id)
                } else {
                    HubView()
                }
            }
        }
        .environment(\.emJanela, emJanela)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in emJanela = Janela.temControles }
        .task { emJanela = Janela.temControles }
        // O tamanho da interface entra por uma estática nas fontes: quem não lê o valor
        // não se redesenha sozinho, então a árvore do app é refeita quando ele muda.
        // Só a do app: os Ajustes ficam de fora de propósito, senão cada toque no mais
        // jogava a lista de volta para o topo e ninguém conseguia ajustar olhando.
        .id("\(chrome.snapshot.uiScale)·\(tamanhoDoSistema)")
        // Duas `.sheet` no mesmo nível competem; esta fica um degrau abaixo da de boas-vindas.
        .sheet(isPresented: Binding(get: { chrome.settingsOpen }, set: { chrome.settingsOpen = $0 })) {
            SettingsSheet()
                .environment(chrome).environment(app).environment(app.accounts).environment(app.aiAccounts)
                .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
        }
        .onChange(of: fase) { _, nova in
            // Os atalhos falam com a janela que a pessoa usou por último.
            if nova == .active {
                IntentBridge.shared.bind(app: app, chrome: chrome)
            }
            guard let ws = app.workspace else { return }
            switch nova {
            case .background:
                ws.run.aoSairDeCena()
                ws.aoSairDeCena()
            case .active: ws.run.aoVoltarParaCena()
            default: break
            }
        }
        // Quem manda no claro/escuro é o iPad, e quem lê é aqui: com `themeAuto` ligado
        // o app não força esquema nenhum, então este valor é mesmo o do sistema.
        .onChange(of: esquema, initial: true) { chrome.sistemaEscuro = esquema == .dark }
        .environment(chrome)
        .environment(app)
        .environment(app.accounts)
        .environment(app.aiAccounts)
        .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
        .sheet(isPresented: Binding(
            get: { !chrome.snapshot.welcomeDone },
            set: {
                if !$0 {
                    chrome.snapshot.welcomeDone = true
                }
            }
        )) {
            OnboardingView().environment(chrome).odeteTheme(Theme(
                chrome.palette,
                seguirSistema: chrome.snapshot.themeAuto
            ))
            .presentationSizing(.page)
        }
        .onOpenURL { url in app.importURL(url, chrome: chrome) }
        .background(LeitorDeCena { [caixaDaCena] cena in caixaDaCena.cena = cena }.frame(width: 0, height: 0))
        .onAppear {
            let outras = Janelas.shared.haOutras(alem: idDaJanela)
            Janelas.shared.entrar(idDaJanela, app: app, chrome: chrome) { [caixaDaCena] in caixaDaCena.ativar() }
            IntentBridge.shared.bind(app: app, chrome: chrome)
            let sessoes = outras ? 2 : UIApplication.shared.openSessions.count
            if app.aguardandoRaiz {
                // A lista só existe depois que o iCloud responde; o projeto da janela
                // abre quando ela chegar.
                Task {
                    await app.prepararRaiz(nuvem: Janelas.shared.nuvem)
                    abrirOProjetoDaJanela(sessoes: sessoes)
                }
            } else {
                abrirOProjetoDaJanela(sessoes: sessoes)
            }
        }
        // Instalação nova com iCloud: os projetos passam a nascer lá (ver `Janelas`).
        .task { await Janelas.shared.prepararNuvem() }
        .onChange(of: app.workspace?.project.id) { _, id in
            guard !saindoDeCena else { return }
            projetoDaJanela = id?.uuidString ?? "hub"
        }
        // Janela fechada: o projeto dela para e fica livre para outra janela abrir.
        .onReceive(NotificationCenter.default.publisher(for: UIScene.didDisconnectNotification)) { aviso in
            guard let cena = aviso.object as? UIWindowScene, cena === caixaDaCena.cena else { return }
            saindoDeCena = true
            app.closeWorkspace()
            Janelas.shared.sair(idDaJanela)
        }
    }

    /// Reabre o projeto que esta janela tinha — ou, com uma janela só, o último aberto,
    /// como sempre foi. Se ele já está aberto em outra janela, esta fica na lista: trazer
    /// a outra para a frente na hora de restaurar as janelas seria roubar a tela.
    private func abrirOProjetoDaJanela(sessoes: Int) {
        guard app.workspace == nil,
              let id = Janelas.projetoParaAbrir(
                  guardado: projetoDaJanela,
                  sessoes: sessoes,
                  ultimo: chrome.snapshot.lastProjectId
              ),
              let p = app.projects.first(where: { $0.id == id }),
              Janelas.shared.dona(de: id, fora: app) == nil
        else { return }
        app.open(p, chrome: chrome)
    }
}
