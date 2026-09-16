import OdeteI18n
import SwiftUI
import WebKit

/// WKWebView do preview, com ponte de console e erros para o `PreviewModel`.
public struct PreviewView: UIViewRepresentable {
    let model: PreviewModel

    public init(model: PreviewModel) {
        self.model = model
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    public func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.setURLSchemeHandler(StaticScheme(root: model.root), forURLScheme: StaticScheme.scheme)
        cfg.allowsInlineMediaPlayback = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        cfg.preferences.isElementFullscreenEnabled = true
        let uc = cfg.userContentController
        uc.add(context.coordinator, name: "odete")
        uc.addUserScript(WKUserScript(source: Self.bridge, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = context.coordinator
        wv.uiDelegate = context.coordinator
        wv.isInspectable = true
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.backgroundColor = .clear
        context.coordinator.webView = wv
        context.coordinator.observe()
        model.snapshotter = { [weak wv] done in
            guard let wv else { done(nil); return }
            wv.takeSnapshot(with: nil) { img, _ in done(img) }
        }
        if let u = model.url {
            wv.load(URLRequest(url: u))
        }
        return wv
    }

    public func updateUIView(_ wv: WKWebView, context: Context) {
        let c = context.coordinator
        if c.navTick != model
            .navTick
        {
            c.navTick = model.navTick; if let u = model.url {
                wv.load(URLRequest(url: u))
            }
        }
        if c.reloadTick != model
            .reloadTick
        {
            c.reloadTick = model.reloadTick; if wv.url != nil {
                wv.reload()
            } else if let u = model.url {
                wv.load(URLRequest(url: u))
            }
        }
        if c.backTick != model.backTick {
            c.backTick = model.backTick; if wv.canGoBack {
                wv.goBack()
            }
        }
    }

    static let bridge = """
    (() => {
      const fmt = (a) => { try { return typeof a === "string" ? a : (a instanceof Error ? (a.stack || a.message) : JSON.stringify(a)); } catch { return String(a); } };
      const post = (level, args, file, line) => { try { window.webkit.messageHandlers.odete.postMessage({ level, text: args.map(fmt).join(" "), file, line }); } catch {} };
      for (const k of ["log", "info", "warn", "error", "debug"]) { const orig = console[k]; console[k] = (...a) => { post(k === "debug" ? "log" : k, a); try { orig.apply(console, a); } catch {} }; }
      window.addEventListener("error", (e) => post("error", [e.message], e.filename, e.lineno));
      window.addEventListener("unhandledrejection", (e) => post("error", ["Promise rejeitada: " + (e.reason && (e.reason.stack || e.reason.message) || e.reason)]));
    })();
    """

    @MainActor
    public final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        let model: PreviewModel
        weak var webView: WKWebView?
        var navTick = 0, reloadTick = 0, backTick = 0
        private var obs: [NSKeyValueObservation] = []
        init(model: PreviewModel) {
            self.model = model; navTick = model.navTick; reloadTick = model.reloadTick; backTick = model.backTick
        }

        func observe() {
            guard let wv = webView else { return }
            obs = [
                wv.observe(\.title) { [weak self] w, _ in Task { @MainActor in self?.model.title = w.title ?? "" } },
                wv
                    .observe(\.isLoading) { [weak self] w, _ in Task { @MainActor in
                        self?.model.loading = w.isLoading
                    } },
                wv
                    .observe(\.canGoBack) { [weak self] w, _ in Task { @MainActor in
                        self?.model.canGoBack = w.canGoBack
                    } },
                wv
                    .observe(\.url) { [weak self] w, _ in Task {
                        @MainActor in if let u = w.url {
                            self?.model.url = u
                        }
                    } },
            ]
        }

        public func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let d = m.body as? [String: Any] else { return }
            let level = ConsoleLine.Level(rawValue: (d["level"] as? String) ?? "log") ?? .log
            var file = d["file"] as? String
            if let f = file, let u = URL(string: f) {
                file = u.path
            }
            model.log(level, (d["text"] as? String) ?? "", file: file, line: d["line"] as? Int)
        }

        public func webView(_ wv: WKWebView, didFail nav: WKNavigation!, withError e: Error) {
            model.log(
                .error,
                "página: \(e.localizedDescription)"
            )
        }

        public func webView(_ wv: WKWebView, didFailProvisionalNavigation nav: WKNavigation!, withError e: Error) {
            if (e as NSError).code == NSURLErrorCancelled {
                return
            }
            model.log(.error, "não carregou \(wv.url?.absoluteString ?? ""): \(e.localizedDescription)")
        }

        public func webView(
            _ wv: WKWebView,
            runJavaScriptAlertPanelWithMessage msg: String,
            initiatedByFrame f: WKFrameInfo
        ) async {
            model.log(.info, "alert: \(msg)")
        }

        public func webView(
            _ wv: WKWebView,
            createWebViewWith cfg: WKWebViewConfiguration,
            for nav: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            // target="_blank": mesma regra do resto — dentro do projeto carrega aqui,
            // fora vai para o Safari.
            if let u = nav.request.url {
                if Self.doProjeto(u) {
                    wv.load(URLRequest(url: u))
                } else {
                    Task { @MainActor in self.model.pedidoExterno = u }
                }
            }
            return nil
        }

        /// O painel serve ao projeto da pessoa: o esquema interno e o servidor de
        /// desenvolvimento, que só escuta em 127.0.0.1.
        ///
        /// Tudo que não é isso sai para o Safari em vez de navegar aqui dentro. Sem esta
        /// regra o painel seguia qualquer link e virava um navegador sem limite, o que é
        /// "acesso irrestrito à web" para a App Store e levava o app inteiro a 17+ — um
        /// preço alto, e injusto, para uma ferramenta de programação.
        nonisolated static func doProjeto(_ u: URL) -> Bool {
            if u.scheme == StaticScheme.scheme {
                return true
            }
            if u.scheme == "about" || u.scheme == "data" || u.scheme == "blob" {
                return true
            }
            guard u.scheme == "http" || u.scheme == "https", let h = u.host?.lowercased() else {
                return false
            }
            return h == "localhost" || h == "127.0.0.1" || h == "::1" || h == "[::1]"
        }

        public func webView(
            _ wv: WKWebView,
            decidePolicyFor nav: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let u = nav.request.url else { return .allow }
            if Self.doProjeto(u) {
                return .allow
            }
            // Só o que a pessoa tocou vai para o Safari; um redirecionamento de terceiro
            // não abre outro app sozinho.
            if nav.navigationType == .linkActivated {
                await MainActor.run { self.model.pedidoExterno = u }
            } else {
                await MainActor.run {
                    self.model.log(.info, tr("fora do projeto, não carregado: %1$@", "\(u.absoluteString)"))
                }
            }
            return .cancel
        }
    }
}
