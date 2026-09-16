import Foundation
import OdeteBundler
import OdeteFiles
import OdeteNpm
import Testing

/// O projeto que o Hub cria tem que abrir no Preview.
///
/// Os testes de Astro e de Next montam projetos escritos à mão, o que prova o
/// renderizador e não prova o caminho de quem usa: criar pelo Hub, `npm install`,
/// `npm run dev`, olhar o Preview. Aqui o projeto vem do próprio `Template`, então se o
/// modelo mudar de forma o teste vai junto.
///
/// Rodam no destino do `make unit`, que é o simulador de iPad — é lá que a Odete vive.
struct ProjetoDoHubTests {
    func monta(_ modelo: Template, nome: String) async throws -> URL? {
        let raiz = FileManager.default.temporaryDirectory
            .appending(path: "odete-hub-\(UUID().uuidString)", directoryHint: .isDirectory)
        let fm = FileManager.default
        for (caminho, corpo) in modelo.files(projectName: nome) {
            let f = raiz.appending(path: caminho)
            try fm.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
            try corpo.write(to: f, atomically: true, encoding: .utf8)
        }
        return raiz
    }

    func pagina(_ raiz: URL, preset: DevServer.Preset) async throws -> String {
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: preset)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url)
        return String(decoding: d, as: UTF8.self)
    }

    /// Exatamente o que aparece na tela de quem escolhe "Astro" no Hub e roda
    /// `npm run dev`: a página vem de `src/pages/index.astro`, sem `index.html` na raiz.
    @Test func modeloAstroAbreNoPreview() async throws {
        guard let raiz = try await monta(.astro, nome: "odete-lp") else { return }
        let html = try await pagina(raiz, preset: .astro)
        #expect(!html.contains("não encontrado"), "o Preview não achou a página: \(html.prefix(300))")
        #expect(html.contains("<h1>odete-lp</h1>"), "o título do projeto não renderizou: \(html.prefix(400))")
        #expect(html.contains("Astro no iPad."), "o corpo da página não renderizou")
        #expect(html.contains("<title>odete-lp</title>"), "a expressão do frontmatter não resolveu")
    }

    /// Quando a rota realmente não existe, o recado diz qual arquivo faltou — e não só
    /// "não encontrado: /", que era o que a build antiga mostrava e não ajudava ninguém.
    @Test func rotaQueNaoExisteExplicaOQueFaltou() async throws {
        guard let raiz = try await monta(.astro, nome: "odete-lp") else { return }
        let dev = DevServer(root: raiz)
        try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro)
        defer { dev.stop() }
        let (d, _) = try await URLSession.shared.data(from: dev.url.appending(path: "nao-existe"))
        let texto = String(decoding: d, as: UTF8.self)
        #expect(texto.contains("src/pages"), "o 404 não diz de onde a rota sairia: \(texto)")
        #expect(texto.contains(".astro"), "o 404 não diz qual arquivo criar")
    }

    /// O modelo Vite continua saindo pelo caminho do `index.html` na raiz.
    @Test func modeloViteAbreNoPreview() async throws {
        guard let raiz = try await monta(.viteReact, nome: "app-vite") else { return }
        let html = try await pagina(raiz, preset: .vite)
        #expect(!html.contains("não encontrado"), "o Preview não achou a página: \(html.prefix(300))")
        #expect(html.contains("<div id=\"root\">") || html.contains("<script"), "o index.html não veio")
    }
}
