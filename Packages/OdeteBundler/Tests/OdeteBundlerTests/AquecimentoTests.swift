import Foundation
@testable import OdeteBundler
import Testing

/// O primeiro `npm run dev` de um projeto recém-instalado, sem e com o aquecimento.
///
/// Como `MedicaoTests`: liga com `ODETE_MEDIR=1`, e `TEST_RUNNER_JSC_useJIT=false` mede
/// como no iPad. "antes" é o caminho de sempre (motor frio, pacote de dependências por
/// fazer); "depois" é o servidor subindo no motor que o aquecimento carregou, com o pacote
/// já em disco. O aquecimento em si roda em segundo plano, logo depois do install.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ODETE_MEDIR"] != nil))
struct MedicaoDoAquecimentoTests {
    @Test func primeiroNpmRunDev() async throws {
        let m = MedicaoTests()
        // Antes: o projeto acabou de ser instalado e ninguém preparou nada.
        let frio = try FixtureReact.projeto()
        let dev1 = DevServer(esbuild: Esbuild(root: frio))
        let antes = try await FixtureReact.mede {
            try await dev1.start(port: 20000 + Int.random(in: 0 ..< 20000))
            _ = try await m.pagina(dev1)
        }
        let s1 = await dev1.estatisticas()
        dev1.stop()

        // Depois: o `npm install` terminou e o aquecimento rodou no motor do projeto.
        let quente = try FixtureReact.projeto()
        let motor = Esbuild(root: quente)
        var r: Aquecimento.Resultado?
        let aquecer = await FixtureReact.mede {
            r = await Aquecimento.aquecer(esbuild: motor, raiz: quente).value
        }
        #expect(r?.feito == true, "\(String(describing: r))")
        let dev2 = DevServer(esbuild: motor)
        let depois = try await FixtureReact.mede {
            try await dev2.start(port: 20000 + Int.random(in: 0 ..< 20000))
            _ = try await m.pagina(dev2)
        }
        let s2 = await dev2.estatisticas()
        dev2.stop()
        #expect(s2["depsBuilds"] == 0 && s2["depsDoDisco"] == 1, "\(s2)")

        // O app reaberto depois do install: motor novo, pacote em disco.
        let dev3 = DevServer(esbuild: Esbuild(root: quente))
        let reaberto = try await FixtureReact.mede {
            try await dev3.start(port: 20000 + Int.random(in: 0 ..< 20000))
            _ = try await m.pagina(dev3)
        }
        dev3.stop()
        print(String(
            format: "ODETE_MEDIDA aquecimento real=%@ antes=%.2fs/%.2fcpu aquecer=%.2fs/%.2fcpu "
                + "depois=%.2fs/%.2fcpu reaberto=%.2fs/%.2fcpu",
            "\(FixtureReact.reactDeVerdade)", antes.parede, antes.cpu, aquecer.parede, aquecer.cpu,
            depois.parede, depois.cpu, reaberto.parede, reaberto.cpu
        ))
        print(
            "ODETE_MEDIDA estatisticas antes \(s1.sorted { $0.key < $1.key }) depois \(s2.sorted { $0.key < $1.key })"
        )
    }
}

/// O primeiro `npm run dev` depois do `npm install`, o lock vigiado e o fim do esm.sh.
@Suite(.serialized) struct AquecimentoTests {
    let base = PreEmpacotamentoTests()

    /// O pacote de dependências feito antes: o servidor que sobe depois, num motor novo,
    /// não empacota nada — acha o pacote em disco pelo nome exato.
    @Test func aquecerDeixaOPrimeiroServidorNoCaminhoRapido() async throws {
        let raiz = try base.projetoComHooks()
        let r = await Aquecimento.aquecer(esbuild: Esbuild(root: raiz), raiz: raiz).value
        #expect(r.feito && r.erro == nil, "\(r)")
        #expect(r.pacotes == 3, "\(r)")
        let pasta = raiz.appending(path: "node_modules/.odete-deps")
        #expect(try FileManager.default.contentsOfDirectory(atPath: pasta.path).contains { $0.hasSuffix(".js") })

        let dev = DevServer(esbuild: Esbuild(root: raiz))
        try await dev.start(port: base.porta())
        defer { dev.stop() }
        let rodou = try await base.roda(dev)
        #expect(rodou.erro == nil && rodou.texto == "42", "\(rodou)")
        let s = await dev.estatisticas()
        #expect(s["depsBuilds"] == 0 && s["depsDoDisco"] == 1, "o servidor empacotou de novo: \(s)")

        // O Preview aparecendo num projeto já aquecido não refaz o build do app.
        let deNovo = await Aquecimento.aquecer(esbuild: Esbuild(root: raiz), raiz: raiz, soSeFaltar: true).value
        #expect(deNovo.motivo == "ja-tinha", "\(deNovo)")
    }

    /// Sem node_modules, o aquecimento só carrega o motor.
    @Test func semPacotesSoCarregaOMotor() async throws {
        let raiz = try base.projetoComHooks()
        try FileManager.default.removeItem(at: raiz.appending(path: "node_modules"))
        let es = Esbuild(root: raiz)
        let r = await Aquecimento.aquecer(esbuild: es, raiz: raiz).value
        #expect(r.motivo == "sem-node-modules")
        #expect(try await es.engine.call("__contextosVivos") == "0")
    }

    /// `git pull` que só muda o lock, seguido de `npm install`: o observador tem de ver
    /// o package-lock.json e o lock escondido de node_modules, senão o servidor segue
    /// servindo o pacote velho.
    @Test func lockEOLockEscondidoSaoVigiados() async throws {
        let raiz = try base.projetoComHooks()
        try base.grava(#"{"name":"app","lockfileVersion":3,"packages":{}}"#, raiz, "node_modules/.package-lock.json")
        let dev = DevServer(esbuild: Esbuild(root: raiz))
        try await dev.start(port: base.porta())
        defer { dev.stop() }
        _ = try await base.roda(dev)
        let lock = raiz.appending(path: "package-lock.json").path
        let oculto = raiz.appending(path: "node_modules/.package-lock.json").path
        #expect(await base.ate { dev.arquivosVigiados.contains(lock) }, "\(dev.arquivosVigiados)")
        #expect(await base.ate { dev.arquivosVigiados.contains(oculto) }, "\(dev.arquivosVigiados)")

        // O lock muda, como no `git pull`: recarrega e refaz o pacote com a chave nova.
        try base.grava(
            #"{"name":"app","lockfileVersion":3,"packages":{"node_modules/react":{"version":"19.0.1"}}}"#,
            raiz, "package-lock.json"
        )
        #expect(await base.ate { await (dev.estatisticas()["reload"] ?? 0) >= 1 }, "o lock mudou e nada aconteceu")
        _ = try await base.roda(dev)
        #expect(await dev.estatisticas()["depsBuilds"] == 2)

        // Depois o `npm install` reinstala o React: o lock escondido muda, e o pacote de
        // dependências é refeito com o arquivo novo.
        try base.grava(
            "exports.jsxDEV = function (t, p) { return { t: t, p: p, reinstalado: 1 }; }; exports.Fragment = 'f';",
            raiz, "node_modules/react/jsx-dev-runtime.js"
        )
        try base.grava(
            #"{"name":"app","lockfileVersion":3,"packages":{"x":{}}}"#,
            raiz,
            "node_modules/.package-lock.json"
        )
        #expect(await base.ate { await (dev.estatisticas()["reload"] ?? 0) >= 2 }, "o install não recarregou")
        _ = try await base.roda(dev)
        #expect(try await base.texto(dev.url.appending(path: "@odete/deps.js")).contains("reinstalado: 1"))
    }

    /// Dependência que falta não vai mais para o esm.sh (misturar com node_modules dá
    /// duas cópias do React): a página diz o que falta.
    @Test func semEsmShEComRecadoDoQueFalta() async throws {
        let raiz = try base.projetoComHooks()
        try base.grava(
            #"{"name":"app","private":true,"type":"module","dependencies":{"react":"^19","left-pad":"^1.3.0"}}"#,
            raiz, "package.json"
        )
        let dev = DevServer(esbuild: Esbuild(root: raiz))
        try await dev.start(port: base.porta())
        defer { dev.stop() }
        let html = try await base.texto(dev.url)
        #expect(!html.contains("esm.sh"), "\(html)")
        #expect(html.contains("left-pad") && !html.contains("\"react\""), "\(html)")
        #expect(html.contains("npm install"))
    }
}
