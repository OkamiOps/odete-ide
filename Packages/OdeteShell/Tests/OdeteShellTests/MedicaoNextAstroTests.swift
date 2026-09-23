import Darwin
import Foundation
import OdeteBundler
import Testing

/// Medição da primeira página e de uma edição no Next (projeto do `create-next-app`) e no
/// Astro (modelo blog do `create-astro`).
///
/// Não roda no `make unit`. Liga com `TEST_RUNNER_ODETE_MEDIR=1`; com
/// `TEST_RUNNER_JSC_useJIT=false` mede como no iPad. Imprime linhas `ODETE_MEDIDA` com
/// relógio e CPU do processo. A edição é contada do aviso ao dev server (o que o
/// observador faria) até a página nova servida.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ODETE_MEDIR"] != nil))
struct MedicaoNextAstroTests {
    struct Medida { var parede: Double; var cpu: Double }

    static func cpu() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        let s = Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec)
        return s + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    func mede(_ f: () async throws -> Void) async throws -> Medida {
        let c0 = Self.cpu(), t0 = ContinuousClock.now
        try await f()
        let d = ContinuousClock.now - t0
        return Medida(
            parede: Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18,
            cpu: Self.cpu() - c0
        )
    }

    func pega(_ dev: DevServer, _ rota: String) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: URL(string: rota, relativeTo: dev.url)!)
        return String(decoding: d, as: UTF8.self)
    }

    func linha(_ nome: String, _ m: [(String, Medida)]) {
        print("ODETE_MEDIDA \(nome) " + m.map { String(format: "%@=%.2fs/%.2fcpu", $0.0, $0.1.parede, $0.1.cpu) }
            .joined(separator: " "))
    }

    @Test func medeNext() async throws {
        guard let raiz = try await NextIlhasTests().projeto(NextCompletoTests.createNextApp) else { return }
        let dev = DevServer(root: raiz)
        let partida = try await mede { try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .next) }
        defer { dev.stop() }
        // A página como o Preview pede: o HTML e a folha.
        let pagina1 = try await mede {
            let html = try await pega(dev, "/")
            #expect(html.contains("To get started"))
            _ = try await pega(dev, "/@odete/css/@next/")
        }
        let page = raiz.appending(path: "app/page.tsx")
        let texto = try String(contentsOf: page, encoding: .utf8)
        let edicao = try await mede {
            try texto.replacingOccurrences(of: "To get started", with: "Para começar").write(
                to: page,
                atomically: true,
                encoding: .utf8
            )
            _ = await dev.arquivosMudaram([page.path])
            let html = try await pega(dev, "/")
            #expect(html.contains("Para começar"))
            _ = try await pega(dev, "/@odete/css/@next/")
        }
        let css = raiz.appending(path: "app/globals.css")
        let soCSS = try await mede {
            try "body { color: red; }".write(to: css, atomically: true, encoding: .utf8)
            let r = await dev.arquivosMudaram([css.path])
            #expect(r == .css)
            _ = try await pega(dev, "/@odete/css/@next/")
        }
        linha("next", [("start", partida), ("pagina1", pagina1), ("edicao", edicao), ("soCSS", soCSS)])
    }

    /// O modelo Astro do Hub: sem collections, o zod não pode pesar.
    @Test func medeAstroDoHub() async throws {
        guard let raiz = try await ProjetoDoHubTests().monta(.astro, nome: "odete-lp") else { return }
        let dev = DevServer(root: raiz)
        let partida = try await mede { try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro) }
        defer { dev.stop() }
        let pagina1 = try await mede {
            let html = try await pega(dev, "/")
            #expect(html.contains("Astro no iPad."))
            _ = try await pega(dev, "/@odete/css/@astro/")
        }
        let index = raiz.appending(path: "src/pages/index.astro")
        let texto = try String(contentsOf: index, encoding: .utf8)
        let edicao = try await mede {
            try texto.replacingOccurrences(of: "Astro no iPad.", with: "Editado.").write(
                to: index,
                atomically: true,
                encoding: .utf8
            )
            _ = await dev.arquivosMudaram([index.path])
            #expect(try await pega(dev, "/").contains("Editado."))
        }
        linha("astroHub", [("start", partida), ("pagina1", pagina1), ("edicao", edicao)])
    }

    @Test func medeAstroBlog() async throws {
        guard let raiz = try await AstroBlogTests().projeto() else { return }
        let dev = DevServer(root: raiz)
        let partida = try await mede { try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000), preset: .astro) }
        defer { dev.stop() }
        let pagina1 = try await mede {
            let html = try await pega(dev, "/")
            #expect(html.contains("Hello, Astronaut!"))
            _ = try await pega(dev, "/@odete/css/@astro/")
        }
        let post1 = try await mede {
            let html = try await pega(dev, "/blog/markdown-style-guide/")
            #expect(html.contains("Headings"))
            _ = try await pega(dev, "/@odete/css/@astro/blog/markdown-style-guide/")
        }
        let footer = raiz.appending(path: "src/components/Footer.astro")
        let texto = try String(contentsOf: footer, encoding: .utf8)
        let edicao = try await mede {
            try texto.replacingOccurrences(of: "Your name here", with: "Marcos").write(
                to: footer,
                atomically: true,
                encoding: .utf8
            )
            _ = await dev.arquivosMudaram([footer.path])
            let html = try await pega(dev, "/")
            #expect(html.contains("Marcos"))
            _ = try await pega(dev, "/@odete/css/@astro/")
        }
        linha("astro", [("start", partida), ("pagina1", pagina1), ("post1", post1), ("edicao", edicao)])
    }
}
