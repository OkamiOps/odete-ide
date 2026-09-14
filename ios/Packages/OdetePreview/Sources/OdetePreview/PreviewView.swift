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
            if let u = nav.request.url {
                wv.load(URLRequest(url: u))
            }
            return nil
        }
    }
}
