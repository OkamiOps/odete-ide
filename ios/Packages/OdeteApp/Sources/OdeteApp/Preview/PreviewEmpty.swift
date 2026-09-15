import OdeteCore
import OdeteI18n
import OdetePreview
import OdeteUI
import SwiftUI

/// Tela do preview quando ainda não há nada rodando.
///
/// Em vez de um ícone do sistema solto no meio do painel, uma janela desenhada com o
/// tamanho do viewport escolhido, as duas formas de começar e o que o projeto é. A
/// ilustração sai de cena quando o painel fica baixo ou estreito, para as ações não
/// serem empurradas para fora.
struct PreviewEmpty: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var onDev: () -> Void
    var onStatic: (() -> Void)?

    var body: some View {
        GeometryReader { geo in
            let cabe = geo.size.height >= 330 && geo.size.width >= 300
            VStack(spacing: 18) {
                if cabe {
                    janela
                }
                VStack(spacing: 6) {
                    Text(tr("Nada rodando ainda"))
                        .font(OdeteFont.ui(15, weight: .semibold)).foregroundStyle(theme.fg)
                    Text(tr("O preview abre aqui e recarrega sozinho toda vez que você salva."))
                        .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { acoes }
                    VStack(spacing: 8) { acoes }
                }
                if cabe {
                    rodape
                }
            }
            .padding(24)
            .frame(width: geo.size.width, height: geo.size.height)
            .background {
                // Um respiro de cor atrás da janela, para o painel não ser um retângulo
                // preto vazio.
                RadialGradient(
                    colors: [theme.accent.opacity(theme.dark ? 0.1 : 0.07), .clear],
                    center: .center,
                    startRadius: 0,
                    endRadius: max(geo.size.width, 240) * 0.55
                )
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder var acoes: some View {
        Button(action: onDev) { Label("npm run dev", systemImage: "play.fill") }
            .buttonStyle(.glassProminent)
        if let onStatic {
            Button(action: onStatic) { Label(tr("index.html estático"), systemImage: "doc.richtext") }
                .buttonStyle(.glass)
        }
    }

    /// Janela de navegador desenhada: barra com os três pontos, uma barra de endereço
    /// falsa e, dentro, a marca do play.
    var janela: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach([theme.danger, theme.accent, theme.ok], id: \.self) { c in
                    Circle().fill(c.opacity(0.55)).frame(width: 7, height: 7)
                }
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(theme.fg.opacity(0.07))
                    .frame(height: 12)
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(theme.bgElevated)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            ZStack {
                theme.bgSubtle
                VStack(spacing: 10) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(theme.accent.opacity(0.75))
                    VStack(spacing: 5) {
                        barra(0.55)
                        barra(0.8)
                        barra(0.35)
                    }
                    .frame(width: 96)
                }
            }
        }
        .frame(width: 200, height: 132)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.border, lineWidth: 1)
        }
        .shadow(color: .black.opacity(theme.dark ? 0.45 : 0.12), radius: 18, y: 8)
    }

    func barra(_ f: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(theme.fg.opacity(0.08))
            .frame(width: 96 * f, height: 5)
            .frame(width: 96, alignment: .leading)
    }

    /// O que o projeto é e onde mexer, em vez de deixar a pessoa adivinhar.
    var rodape: some View {
        HStack(spacing: 6) {
            etiqueta(ws.stack.label, "shippingbox")
            if ws.preview.hasIndex {
                etiqueta("index.html", "doc.text")
            }
            etiqueta("terminal: ⌘J", "terminal")
        }
        .padding(.top, 2)
    }

    func etiqueta(_ texto: String, _ simbolo: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: simbolo).font(.system(size: 9, weight: .semibold))
            Text(texto).font(OdeteFont.ui(10.5))
        }
        .foregroundStyle(theme.fgSubtle)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(theme.fg.opacity(0.05), in: Capsule())
    }
}
