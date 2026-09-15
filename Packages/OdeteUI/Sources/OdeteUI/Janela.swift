import SwiftUI
import UIKit

/// O canto que a iPadOS 26 toma para si.
///
/// Numa janela — e não em tela cheia — o sistema desenha fechar, minimizar e
/// redimensionar por cima do canto superior esquerdo do app, e **não** reserva espaço
/// por nós: medido numa janela de 375 pt, a área segura vem com `leading` zero. O canto
/// é o mesmo em qualquer layout da Odete — o rail no iPad, a barra de abas no estreito —
/// e ali moram justamente a marca e o botão "Projetos", que ficavam cobertos e sem
/// receber toque.
///
/// Em vez de empurrar cada barra para a direita, a Odete devolve o alto para o sistema
/// com uma faixa, que é o que uma janela tem mesmo: uma barra de título. Em tela cheia
/// os controles não existem e a faixa não aparece.
@MainActor
public enum Janela {
    /// Cabe o capsule dos controles (28 pt) com folga em cima e embaixo.
    public static let alturaDaFaixa: CGFloat = 38

    /// Há controles de janela na tela?
    ///
    /// Não existe API que responda isso, então a resposta vem da geometria: em tela
    /// cheia a janela mede o mesmo que a tela. Quando a pessoa arrasta a janela até
    /// ocupar tudo, a própria iPadOS troca para tela cheia — então o empate é confiável.
    public static var temControles: Bool {
        let cenas = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let cena = cenas.first(where: { $0.activationState == .foregroundActive }) ?? cenas.first,
              let janela = cena.keyWindow else { return false }
        let tela = cena.screen.bounds.size
        return janela.bounds.width < tela.width - 1 || janela.bounds.height < tela.height - 1
    }
}

public extension EnvironmentValues {
    /// Verdadeiro quando a faixa de título está na tela. Quem já mostra o nome do
    /// projeto lê daqui para não repetir.
    @Entry var emJanela: Bool = false
}

/// A faixa que segura o alto da janela, com o título no meio.
public struct BarraDaJanela: View {
    @Environment(\.theme) private var theme
    var titulo: String

    public init(titulo: String) {
        self.titulo = titulo
    }

    public var body: some View {
        ZStack {
            theme.surface
            Text(titulo)
                .font(OdeteFont.ui(12, weight: .medium))
                .foregroundStyle(theme.fgSubtle)
                .lineLimit(1)
                // Os controles ficam à esquerda: o título não pode encostar neles nem
                // roubar o toque deles.
                .padding(.horizontal, 100)
                .allowsHitTesting(false)
        }
        .frame(height: Janela.alturaDaFaixa)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }
}
