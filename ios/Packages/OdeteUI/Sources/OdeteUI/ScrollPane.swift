import SwiftUI
import UIKit

/// Rolagem que aceita ponteiro além do dedo.
///
/// O gesto de pan de uma `UIScrollView` só aceita, por padrão, scroll indireto do tipo
/// discreto — a roda do mouse com travas. Trackpad, Magic Mouse e o trackpad do Magic
/// Keyboard mandam scroll contínuo, que nesse estado é ignorado: a página só anda se a
/// pessoa clicar e arrastar. Esta sonda sobe até a `UIScrollView` que envolve o conteúdo
/// e libera os dois tipos.
public struct PointerScrollProbe: UIViewRepresentable {
    public init() {}

    public func makeUIView(context _: Context) -> UIView {
        Sonda()
    }

    public func updateUIView(_ v: UIView, context _: Context) {
        (v as? Sonda)?.liberar()
    }

    public final class Sonda: UIView {
        override public func didMoveToWindow() {
            super.didMoveToWindow()
            liberar()
        }

        func liberar() {
            var atual: UIView? = superview
            while let v = atual {
                if let scroll = v as? UIScrollView {
                    scroll.panGestureRecognizer.allowedScrollTypesMask = .all
                    break
                }
                atual = v.superview
            }
            // `List` e `Form` guardam a rolagem num descendente, não num ancestral, então
            // uma varredura da janela pega os dois casos. Só adiciona capacidade.
            if let janela = window {
                Self.varrer(janela)
            }
        }

        static func varrer(_ v: UIView) {
            if let scroll = v as? UIScrollView {
                scroll.panGestureRecognizer.allowedScrollTypesMask = .all
            }
            for sub in v.subviews {
                varrer(sub)
            }
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
