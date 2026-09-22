import SwiftUI
import UIKit

/// Rolagem que aceita ponteiro além do dedo.
///
/// O gesto de pan de uma `UIScrollView` só aceita, por padrão, scroll indireto do tipo
/// discreto — a roda do mouse com travas. Trackpad, Magic Mouse e o trackpad do Magic
/// Keyboard mandam scroll contínuo, que nesse estado é ignorado: a página só anda se a
/// pessoa clicar e arrastar. Esta sonda sobe até a `UIScrollView` que envolve o conteúdo
/// e libera os dois tipos.
///
/// A sonda varria a janela inteira a cada vez que era montada e a cada atualização — e ela
/// mora dentro de todo `ScrollPane`, cujo conteúdo se atualiza a cada linha do terminal,
/// a cada mudança da árvore. Agora ela procura uma vez: primeiro entre os ancestrais
/// (o caso do `ScrollPane`), e, sem achar, só na vizinhança perto dela (o caso de `List` e
/// `Form`, que guardam a rolagem num descendente do vizinho, não num ancestral).
public struct PointerScrollProbe: UIViewRepresentable {
    public init() {}

    public func makeUIView(context _: Context) -> UIView {
        Sonda()
    }

    public func updateUIView(_ v: UIView, context _: Context) {
        (v as? Sonda)?.liberarSePreciso()
    }

    public final class Sonda: UIView {
        /// Já achou a rolagem desta janela.
        private(set) var liberou = false
        /// Quantos níveis acima da sonda a busca por descendentes começa.
        static let alcance = 4

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else {
                liberou = false
                return
            }
            liberarSePreciso()
            // `List` e `Form` montam a rolagem depois da sonda: uma volta do laço depois,
            // ela já existe.
            if !liberou {
                DispatchQueue.main.async { [weak self] in self?.liberarSePreciso() }
            }
        }

        func liberarSePreciso() {
            guard !liberou, window != nil else { return }
            var atual: UIView? = superview
            while let v = atual {
                if let scroll = v as? UIScrollView {
                    scroll.panGestureRecognizer.allowedScrollTypesMask = .all
                    liberou = true
                    return
                }
                atual = v.superview
            }
            var raiz: UIView = self
            for _ in 0 ..< Self.alcance {
                guard let acima = raiz.superview else { break }
                raiz = acima
            }
            liberou = Self.varrer(raiz)
        }

        /// Libera as rolagens abaixo de `v`. Devolve se achou alguma.
        @discardableResult
        static func varrer(_ v: UIView) -> Bool {
            var achou = false
            if let scroll = v as? UIScrollView {
                scroll.panGestureRecognizer.allowedScrollTypesMask = .all
                achou = true
            }
            for sub in v.subviews where varrer(sub) {
                achou = true
            }
            return achou
        }
    }
}

public extension View {
    /// Para `List` e `Form`, que não passam pelo `ScrollPane`.
    func pointerScrolling() -> some View {
        background(PointerScrollProbe().frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

/// `ScrollView` que rola com trackpad e roda do mouse, não só com o dedo.
public struct ScrollPane<Content: View>: View {
    var axes: Axis.Set
    var showsIndicators: Bool
    @ViewBuilder var content: Content

    public init(
        _ axes: Axis.Set = .vertical,
        showsIndicators: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.axes = axes
        self.showsIndicators = showsIndicators
        self.content = content()
    }

    public var body: some View {
        ScrollView(axes, showsIndicators: showsIndicators) {
            content
                .background(PointerScrollProbe().frame(width: 0, height: 0).allowsHitTesting(false))
        }
    }
}
