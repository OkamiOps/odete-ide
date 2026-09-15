import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Três telas na primeira abertura: o que é, onde ficam os dados, contas.
struct OnboardingView: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    @State private var page = 0

    struct Page {
        var symbol: String
        var title: String
        var text: String
        var points: [String]
        /// A primeira tela mostra a marca, não um símbolo do sistema: é onde a pessoa
        /// aprende o nome e a cara do app.
        var marca = false
    }

    let pages = [
        Page(
            symbol: "ipad.and.iphone",
            title: tr("Uma IDE inteira no iPad"),
            text: tr(
                "Editor, git, terminal, npm, preview e um agente que edita o projeto. Tudo roda aqui, sem Mac e sem servidor."
            ),
            points: [
                tr("Projetos web (Vite, Astro, HTML) e Swift Playgrounds"),
                tr("Terminal com pipes, jobs e dev server"),
                tr("Preview ao vivo com console"),
            ],
            marca: true
        ),
        Page(
            symbol: "lock.doc",
            title: tr("Seus dados ficam com você"),
            text: tr(
                "Os projetos vivem em Arquivos → Odete (ou no iCloud Drive, se quiser). Nada é enviado a servidores da Odete."
            ),
            points: [
                tr("Sem conta, sem telemetria, sem rastreio"),
                tr("Tokens guardados no Keychain do dispositivo"),
                tr("Abra pastas de outros apps e compartilhe como .zip"),
            ]
        ),
        Page(
            symbol: "sparkles",
            title: tr("Contas são opcionais"),
            text: tr(
                "Conecte GitHub para clonar e abrir PRs, e uma conta de IA (Claude, Codex, Grok ou chave de API) para o agente."
            ),
            points: [
                tr("Tudo em Ajustes → Contas"),
                tr("O agente só edita com a sua aprovação"),
                tr("Funciona offline no que não depende da rede"),
            ]
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                    VStack(spacing: 18) {
                        Spacer(minLength: 0)
                        if p.marca {
                            VStack(spacing: 12) {
                                BrandIcon(size: 76)
                                Wordmark(height: 26)
                            }
                        } else {
                            Image(systemName: p.symbol).font(.system(size: 56, weight: .light))
                                .foregroundStyle(theme.accent)
                                .symbolRenderingMode(.hierarchical)
                        }
                        Text(p.title).font(OdeteFont.ui(26, weight: .semibold)).foregroundStyle(theme.fg)
                            .multilineTextAlignment(.center)
                        Text(p.text).font(OdeteFont.ui(15)).foregroundStyle(theme.fgMuted)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 460)
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(p.points, id: \.self) { pt in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "checkmark.circle.fill").font(.system(size: 13))
                                        .foregroundStyle(theme.ok).padding(
                                            .top,
                                            2
                                        )
                                    Text(pt).font(OdeteFont.ui(13.5)).foregroundStyle(theme.fg)
                                }
                            }
                        }
                        .padding(16)
                        .frame(maxWidth: 460, alignment: .leading)
                        .background(
                            theme.surface,
                            in: RoundedRectangle(cornerRadius: Metrics.rCard, style: .continuous)
                        )
                        Spacer(minLength: 0)
                    }
                    .padding(32)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            HStack {
                Button(tr("Pular")) { finish() }.buttonStyle(.glass)
                Spacer()
                Button(page == pages.count - 1 ? tr("Começar") : tr("Próximo")) {
                    if page < pages.count - 1 {
                        withAnimation(.snappy(duration: 0.25)) { page += 1 }
                    } else {
                        finish()
                    }
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .background(theme.bg)
        .interactiveDismissDisabled()
    }

    func finish() {
        chrome.snapshot.welcomeDone = true
    }
}
