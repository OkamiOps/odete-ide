import Foundation
import OdeteAccounts
import OdeteAgent
import OdeteCore
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

    init(store: StateStore = StateStore()) {
        self.store = store
    }

    // MARK: ajustes

    /// O estado com que uma janela nasce. Na primeira vez vem do disco.
    public func snapshotInicial() -> ChromeSnapshot {
        if let c = canonico {
            return c
        }
        var snap = store.load()
        // Instalação nova com iCloud à mão: os projetos nascem no iCloud Drive. Dentro do
        // container do app eles não sobrevivem a uma desinstalação — some tudo, incluindo
        // o histórico git e as conversas do agente. Só vale para instalação nova: mudar o
        // lugar de quem já tem projeto é decisão da pessoa, nos Ajustes.
        if !snap.welcomeDone, !snap.projectsInCloud, AppModel.cloudRoot() != nil {
            snap.projectsInCloud = true
            try? store.saveNow(snap)
        }
        canonico = snap
        return snap
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

    private func podar() {
        entradas = entradas.filter { $0.value.app != nil }
    }

    /// Que projeto uma janela abre ao aparecer.
    ///
    /// - `guardado` é o que a janela lembra (`SceneStorage`): o id do projeto, `hub` para
    ///   a lista de projetos, ou vazio para quem nunca escolheu.
    /// - Com uma janela só, é como sempre foi: sem projeto lembrado, volta o último aberto.
    /// - Com mais de uma, janela sem projeto lembrado começa na lista. Senão toda janela
    ///   nova abriria o mesmo último projeto — que é justamente o que não pode.
    nonisolated static func projetoParaAbrir(guardado: String, sessoes: Int, ultimo: UUID?) -> UUID? {
        if let id = UUID(uuidString: guardado) {
            return id
        }
        return sessoes <= 1 ? ultimo : nil
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
