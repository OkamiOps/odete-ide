import Foundation
import OdeteAccounts
import OdeteAgent
import OdeteCore
import OdeteFiles
import OdeteI18n
import SwiftUI
import UIKit

/// As janelas do app: quem está com qual projeto, e o estado que todas dividem.
///
/// O iPadOS abre quantas janelas a pessoa quiser, e cada uma montava o próprio estado a
/// partir do mesmo `state.json` e reabria o último projeto. A segunda janela virava uma
/// segunda cópia viva do mesmo projeto: dois observadores de arquivo, dois shells, dois
/// salvamentos automáticos, e o último a gravar ganhava. Os ajustes também: cada janela
/// gravava o `state.json` inteiro com o que *ela* sabia, por cima do que a outra tinha
/// acabado de mudar.
///
/// Daqui em diante:
/// - um projeto fica aberto numa janela só. Abrir de novo em outra traz para a frente a
///   janela onde ele já está (`AppModel.open` pergunta aqui antes de abrir);
/// - cada janela lembra o próprio projeto (`RootView`, com `SceneStorage`), e uma janela
///   nova começa na lista de projetos;
/// - os ajustes são um só: há um `StateStore` para o app inteiro, e o que uma janela muda
///   chega às outras — menos o que é da janela, como o painel aberto e a largura dele.
@MainActor
public final class Janelas {
    public static let shared = Janelas()

    /// Uma janela aberta. Tudo fraco: janela que o sistema fechou não segura projeto.
    final class Entrada {
        weak var app: AppModel?
        weak var chrome: ChromeState?
        /// Traz esta janela para a frente.
        var ativar: @MainActor () -> Void

        init(app: AppModel, chrome: ChromeState, ativar: @escaping @MainActor () -> Void) {
            self.app = app
            self.chrome = chrome
            self.ativar = ativar
        }
    }

    private var entradas: [UUID: Entrada] = [:]
    let store: StateStore
    /// O estado de todos, como está agora. É dele que uma janela nova nasce — e não do
    /// disco, que pode estar um salvamento atrasado.
    private(set) var canonico: ChromeSnapshot?
    /// Enquanto um ajuste é repassado às outras janelas, a mudança que isso provoca nelas
    /// não volta como mudança nova.
    private var repassando = false
    /// As contas também são uma só: duas cópias da lista, uma por janela, gravavam uma
    /// por cima da outra a conta que a vizinha acabara de adicionar.
    public private(set) lazy var accounts = AccountStore()
    public private(set) lazy var aiAccounts = AIAccountStore()
    /// As pastas de fora do app, uma lista para todas as janelas — pelo mesmo motivo das
    /// contas: duas cópias gravavam o `external.json` uma por cima da outra.
    public let external: ExternalProjects
    /// Onde fica o iCloud, perguntado fora do ator principal.
    let nuvem: LocalDaNuvem
    /// Como um projeto muda de lugar; os testes trocam por um `moveItem` simples.
    var moverProjetos: MudancaDeLugar.Mover = MudancaDeLugar.moverDeVerdade
    /// A mudança dos projetos entre o app e o iCloud, vista por todas as janelas.
    public let mudanca = EstadoDaMudanca()
    /// A leitura do `state.json` falhou nesta execução: não é instalação nova.
    private var leituraFalhou = false
    /// A pasta dos projetos dentro do app; os testes trocam por uma temporária.
    var raizLocal = ProjectStore.defaultRoot()

    init(
        store: StateStore = StateStore(),
        external: ExternalProjects = ExternalProjects(),
        nuvem: LocalDaNuvem = .shared
    ) {
        self.store = store
        self.external = external
        self.nuvem = nuvem
    }

    // MARK: ajustes

    /// O estado com que uma janela nasce. Na primeira vez vem do disco.
    ///
    /// Não pergunta nada ao iCloud: isto roda no `init` da `RootView`, e a pergunta pode
    /// levar segundos. A decisão de instalação nova vem depois, em `prepararNuvem`.
    public func snapshotInicial() -> ChromeSnapshot {
        if let c = canonico {
            return c
        }
        let lido = store.carregar()
        leituraFalhou = lido.falhou
        canonico = lido.snapshot
        return lido.snapshot
    }

    /// Instalação nova com iCloud à mão: os projetos nascem no iCloud Drive. Dentro do
    /// container do app eles não sobrevivem a uma desinstalação — some tudo, incluindo
    /// o histórico git e as conversas do agente.
    ///
    /// Só vale para instalação nova de verdade. Um `state.json` que não deu para ler
    /// voltava como estado novo, com as boas-vindas por fazer, e isto ligava o iCloud —
    /// o app passava a olhar outra pasta e os projetos de quem já usava sumiam do hub.
    /// Mudar o lugar de quem já tem projeto é decisão da pessoa, nos Ajustes.
    func prepararNuvem() async {
        guard let snap = canonico, !leituraFalhou, !snap.welcomeDone, !snap.projectsInCloud else { return }
        guard let raiz = await nuvem.raiz() else { return }
        // Enquanto o iCloud respondia a pessoa pode ter criado um projeto aqui dentro:
        // aí ela já tem projeto, e a decisão não é mais de instalação nova.
        let temProjeto = entradas.values.contains { !($0.app?.projects.isEmpty ?? true) }
        guard !temProjeto, canonico?.projectsInCloud == false else { return }
        definirNuvem(true, raiz: raiz)
    }

    /// Todas as janelas passam a olhar `raiz`, e o ajuste vai para o estado de todos.
    private func definirNuvem(_ ligada: Bool, raiz: URL) {
        podar()
        for e in entradas.values {
            e.app?.apontar(para: raiz)
        }
        if var s = canonico {
            s.projectsInCloud = ligada
            canonico = s
            store.scheduleSave(s)
        }
        repassando = true
        defer { repassando = false }
        for e in entradas.values {
            if let c = e.chrome, c.snapshot.projectsInCloud != ligada {
                c.snapshot.projectsInCloud = ligada
            }
        }
    }

    // MARK: projetos no iCloud

    /// Leva os projetos para o iCloud Drive, ou de volta para dentro do app.
    ///
    /// Roda fora do ator principal, com andamento em `mudanca`. Os projetos abertos em
    /// qualquer janela fecham antes (com o que estava sendo digitado gravado), e todas as
    /// janelas passam a olhar o lugar novo ao fim. Se algo falha no meio, o que já tinha
    /// ido volta, e o app continua olhando o lugar de antes.
    func mudarLugar(paraNuvem: Bool) async {
        guard !mudanca.andando else { return }
        podar()
        let atual = canonico?.projectsInCloud ?? false
        guard atual != paraNuvem else { return }
        let raizNuvem = await nuvem.raiz()
        guard let raizNuvem else {
            mudanca.aviso = MudancaDeLugar.Falha.semICloud.errorDescription
            return
        }
        let origem = entradas.values.compactMap(\.app).first?.store.root
            ?? (atual ? raizNuvem : raizLocal)
        let destino = paraNuvem ? raizNuvem : raizLocal
        for e in entradas.values {
            e.app?.closeWorkspace()
        }
        mudanca.andando = true
        mudanca.feitos = 0
        mudanca.total = 0
        let mover = moverProjetos
        let estado = mudanca
        let resultado = await Task.detached(priority: .userInitiated) {
            Result {
                try MudancaDeLugar.executar(de: origem, para: destino, paraNuvem: paraNuvem, mover: mover) { f, t in
                    Task { @MainActor in
                        estado.feitos = f
                        estado.total = t
                    }
                }
            }
        }.value
        mudanca.andando = false
        switch resultado {
        case let .success(renomeados):
            definirNuvem(paraNuvem, raiz: destino)
            if !renomeados.isEmpty {
                mudanca.aviso = tr(
                    "Já havia projetos com estes nomes no destino; os que chegaram ganharam outro nome: %1$@.",
                    renomeados.map { "\($0.de) → \($0.para)" }.joined(separator: ", ")
                )
            }
        case let .failure(erro):
            mudanca.aviso = erro.localizedDescription
            for e in entradas.values {
                e.app?.refresh()
            }
        }
    }

    /// Uma janela mudou o estado dela: vira o estado de todos, é gravado uma vez, e as
    /// outras janelas recebem — cada uma com o próprio layout mantido.
    func mudou(_ origem: ChromeState) {
        guard !repassando else { return }
        let novo = origem.snapshot
        guard novo != canonico else { return }
        canonico = novo
        store.scheduleSave(novo)
        repassando = true
        defer { repassando = false }
        for e in entradas.values {
            guard let c = e.chrome, c !== origem else { continue }
            var s = novo
            s.manterDaJanela(c.snapshot)
            if s != c.snapshot {
                c.snapshot = s
            }
        }
    }

    // MARK: janelas

    /// Registra a janela. A partir daqui, o que ela muda nos ajustes passa por `mudou`.
    func entrar(_ id: UUID, app: AppModel, chrome: ChromeState, ativar: @escaping @MainActor () -> Void) {
        entradas[id] = Entrada(app: app, chrome: chrome, ativar: ativar)
        app.janelas = self
        if canonico == nil {
            canonico = chrome.snapshot
        }
        chrome.onChange = { [weak self, weak chrome] _ in
            guard let self, let chrome else { return }
            mudou(chrome)
        }
    }

    func sair(_ id: UUID) {
        entradas[id] = nil
    }

    /// Há outra janela viva além desta?
    func haOutras(alem id: UUID) -> Bool {
        podar()
        return entradas.keys.contains { $0 != id }
    }

    /// A janela que está com o projeto aberto, fora a de `app`.
    func dona(de projeto: UUID, fora app: AppModel) -> Entrada? {
        podar()
        return entradas.values.first { $0.app !== app && $0.app?.workspace?.project.id == projeto }
    }

    /// Fecha o projeto nas outras janelas — antes de renomear ou apagar a pasta dele.
    /// Fechar grava o que estava sendo digitado e para o salvamento automático, que de
    /// outro jeito recriaria a pasta no caminho velho.
    func fechar(_ projeto: UUID, fora app: AppModel) {
        podar()
        for e in entradas.values where e.app !== app && e.app?.workspace?.project.id == projeto {
            e.app?.closeWorkspace()
        }
    }

    /// Os projetos abertos agora, em qualquer janela.
    func projetosAbertos() -> Set<UUID> {
        podar()
        return Set(entradas.values.compactMap { $0.app?.workspace?.project.id })
    }

    /// Os projetos mudaram no disco (criado, renomeado, apagado): toda janela relê a
    /// lista, e não só a que fez a mudança.
    func projetosMudaram() {
        podar()
        for e in entradas.values {
            e.app?.refresh()
        }
    }

    private func podar() {
        entradas = entradas.filter { $0.value.app != nil }
    }

    /// Que projeto uma janela abre ao aparecer.
    ///
    /// - `guardado` é o que a janela lembra (`SceneStorage`): o id do projeto, `hub` para
    ///   a lista de projetos, ou vazio para quem nunca escolheu.
    /// - Com uma janela só, é como sempre foi: volta o último aberto, lembrado ou não.
    /// - Com mais de uma, janela sem projeto lembrado começa na lista. Senão toda janela
    ///   nova abriria o mesmo último projeto — que é justamente o que não pode.
    nonisolated static func projetoParaAbrir(guardado: String, sessoes: Int, ultimo: UUID?) -> UUID? {
        // Uma janela só: o último projeto aberto, gravado na hora no state.json. O que a
        // cena lembra (`@SceneStorage`) só é gravado quando o app vai para o fundo; depois
        // de um fechamento à força ele ainda aponta para o projeto de antes, e o app
        // reabria no projeto errado.
        if sessoes <= 1 {
            return ultimo
        }
        return UUID(uuidString: guardado)
    }
}

extension ChromeSnapshot {
    /// O que é de cada janela: que painel está aberto, de que largura, que modo o centro
    /// mostra. Uma janela esconder o agente não esconde o agente da outra.
    mutating func manterDaJanela(_ outra: ChromeSnapshot) {
        side = outra.side
        sideOpen = outra.sideOpen
        center = outra.center
        agentVisible = outra.agentVisible
        termVisible = outra.termVisible
        sideWidth = outra.sideWidth
        agentWidth = outra.agentWidth
        termHeight = outra.termHeight
        phoneTab = outra.phoneTab
    }
}

/// A cena de uma janela, guardada sem segurá-la: a cena é do sistema, e a view dentro
/// dela não pode ser o que a mantém viva.
final class CaixaDaCena {
    weak var cena: UIWindowScene?

    /// Traz a janela para a frente, pedindo ao sistema pela sessão dela.
    @MainActor
    func ativar() {
        guard let sessao = cena?.session else { return }
        UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: sessao))
    }
}

/// Descobre em que cena a view está: o SwiftUI não diz, o `UIView` diz quando entra na janela.
struct LeitorDeCena: UIViewRepresentable {
    var achou: (UIWindowScene) -> Void

    func makeUIView(context _: Context) -> Sonda {
        let v = Sonda()
        v.isUserInteractionEnabled = false
        v.achou = achou
        return v
    }

    func updateUIView(_ v: Sonda, context _: Context) {
        v.achou = achou
    }

    final class Sonda: UIView {
        var achou: ((UIWindowScene) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let cena = window?.windowScene {
                achou?(cena)
            }
        }
    }
}
