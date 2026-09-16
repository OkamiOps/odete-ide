import Foundation
import OdeteBundler
import OdeteNpm
import Testing

/// Um projeto Next precisa aparecer no Preview.
///
/// O Next roda um servidor Node que a Odete não tem. O que ela tem é o mesmo React e o
/// mesmo `require`, então a página é executada aqui. Os testes precisam do npm de
/// verdade, porque é o React do projeto que renderiza — sem rede, eles se calam em vez
/// de falhar por ruído.
struct NextTests {
    func projetoNext(_ arquivos: [String: String]) async throws -> URL? {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-next-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in arquivos {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        try #"{"name":"app","dependencies":{"next":"15.0.0","react":"19.2.0","react-dom":"19.2.0"}}"#
            .write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        guard let rep = try? await Installer(project: raiz, registry: HTTPRegistry())
            .install(add: [.init("react@19.2.0"), .init("react-dom@19.2.0")]),
            !rep.installed.isEmpty
        else { return nil }
        return raiz
    }

    func corpo(_ raiz: URL, _ rota: String) async throws -> String {
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next)
        defer { dev.stop() }
        let u = rota == "/" ? dev.url : dev.url.appending(path: rota)
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    @Test func appRouterComLayout() async throws {
        guard let raiz = try await projetoNext([
            "app/layout.tsx": """
            export default function Layout({ children }: { children: any }) {
              return <div className="wrap"><header>topo</header>{children}</div>;
            }
            """,
            "app/page.tsx": """
            export default function Page() {
              return <h1>Oi do Next</h1>;
            }
            """,
        ]) else { return }
        let html = try await corpo(raiz, "/")
        #expect(html.contains("<h1>Oi do Next</h1>"), "a página não renderizou: \(html.prefix(400))")
        #expect(html.contains("<header>topo</header>"), "o layout não embrulhou")
    }

    /// Componente de servidor é função `async`, que o `renderToString` não aceita. Quem
    /// resolve a árvore antes é o nosso renderizador.
    @Test func componenteDeServidorAsync() async throws {
        guard let raiz = try await projetoNext([
            "app/page.tsx": """
            async function Dados() {
              const n = await Promise.resolve(42);
              return <span id="n">{n}</span>;
            }
            export default async function Page() {
              return <main><Dados /></main>;
            }
            """,
        ]) else { return }
        let html = try await corpo(raiz, "/")
        #expect(html.contains("<span id=\"n\">42</span>"), "async não resolveu: \(html.prefix(400))")
    }

    @Test func rotaAninhadaNoAppRouter() async throws {
        guard let raiz = try await projetoNext([
            "app/blog/page.tsx": "export default function P() { return <p>blog</p>; }",
        ]) else { return }
        #expect(try await corpo(raiz, "blog").contains("<p>blog</p>"))
    }

    @Test func pagesRouterComApp() async throws {
        guard let raiz = try await projetoNext([
            "pages/_app.tsx": """
            export default function App({ Component, pageProps }: any) {
              return <div id="app"><Component {...pageProps} /></div>;
            }
            """,
            "pages/index.tsx": "export default function Home() { return <h2>home</h2>; }",
            "pages/sobre.tsx": "export default function Sobre() { return <h2>sobre</h2>; }",
        ]) else { return }
        let home = try await corpo(raiz, "/")
        #expect(home.contains("<div id=\"app\">"), "o _app não embrulhou: \(home.prefix(300))")
        #expect(home.contains("<h2>home</h2>"))
        #expect(try await corpo(raiz, "sobre").contains("<h2>sobre</h2>"))
    }

    @Test func semReactOServidorExplica() async throws {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-next-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        try fm.createDirectory(at: raiz.appending(path: "app"), withIntermediateDirectories: true)
        try "export default function P() { return null; }"
            .write(to: raiz.appending(path: "app/page.tsx"), atomically: true, encoding: .utf8)
        try #"{"name":"a"}"#.write(to: raiz.appending(path: "package.json"), atomically: true, encoding: .utf8)
        let html = try await corpo(raiz, "/")
        #expect(html.contains("npm install"), "não explicou o que falta: \(html.prefix(300))")
    }
}
