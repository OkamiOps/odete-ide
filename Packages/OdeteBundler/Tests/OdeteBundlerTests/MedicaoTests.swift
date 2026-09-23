import Foundation
@testable import OdeteBundler
import Testing

/// Medição do dev server e do lint num projeto Vite + React (`FixtureReact`).
///
/// Não roda no `make unit`: sem JIT leva minutos. Liga com `ODETE_MEDIR=1` (no xcodebuild,
/// `TEST_RUNNER_ODETE_MEDIR=1`); `TEST_RUNNER_JSC_useJIT=false` mede como no iPad, e
/// `TEST_RUNNER_ODETE_REACT_DIR=<node_modules>` usa o React de verdade. Imprime linhas
/// `ODETE_MEDIDA` com relógio e CPU do processo.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ODETE_MEDIR"] != nil))
struct MedicaoTests {
    func pega(_ u: URL) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    func ate(_ condicao: () async -> Bool) async {
        let fim = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < fim, await !condicao() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A primeira página como o Preview pede: o HTML, o bundle, o que ele importa e as
    /// folhas. O que o servidor não tem (o pacote de dependências, antes de ele existir)
    /// volta 404 e não pesa.
    func pagina(_ dev: DevServer) async throws -> String {
        _ = try await pega(dev.url)
        let js = try await pega(dev.url.appending(path: "@odete/js/src/main.tsx"))
        _ = try? await pega(dev.url.appending(path: "@odete/deps.js"))
        _ = try? await pega(dev.url.appending(path: "@odete/deps.css"))
        _ = try await pega(dev.url.appending(path: "@odete/css/src/main.tsx"))
        return js
    }

    @Test func medeDevServer() async throws {
        let raiz = try FixtureReact.projeto()
        let dev = DevServer(root: raiz)
        let partida = try await FixtureReact.mede { try await dev.start(port: 20000 + Int.random(in: 0 ..< 20000)) }
        let js = dev.url.appending(path: "@odete/js/src/main.tsx")
        var primeiro = ""
        // Cache de dependências frio: projeto novo.
        let build1 = try await FixtureReact.mede { primeiro = try await pagina(dev) }
        #expect(primeiro.contains("cliques"))
        let app = raiz.appending(path: "src/App.tsx")
        await ate { dev.arquivosVigiados.contains(app.path) }

        // Mesmo conteúdo, gravado como o editor grava: não pode custar nada além do hash.
        let igual = try await FixtureReact.mede {
            try FixtureReact.appTSX(rotulo: "cliques").write(to: app, atomically: true, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(400))
        }
        let buildsDepoisDoIgual = await dev.estatisticas()["builds"] ?? -1

        // Uma linha mudada: do gravar até o Preview ser avisado (observador + rebuild).
        let mudou = try await FixtureReact.mede {
            try FixtureReact.appTSX(rotulo: "toques").write(to: app, atomically: true, encoding: .utf8)
            await ate { await (dev.estatisticas()["reload"] ?? 0) >= 1 }
            let t = try await pega(js)
            #expect(t.contains("toques"))
        }
        // Outra, para ver o segundo rebuild (o primeiro ainda aquece o contexto).
        let mudou2 = try await FixtureReact.mede {
            try FixtureReact.appTSX(rotulo: "vezes").write(to: app, atomically: true, encoding: .utf8)
            await ate { await (dev.estatisticas()["reload"] ?? 0) >= 2 }
            _ = try await pega(js)
        }
        // Um componente dois níveis abaixo do App.
        let cartao = raiz.appending(path: "src/componentes/ui/Cartao.tsx")
        let profundo = try await FixtureReact.mede {
            try FixtureReact.cartaoTSX(rotulo: "total").write(to: cartao, atomically: true, encoding: .utf8)
            await ate { await (dev.estatisticas()["reload"] ?? 0) >= 3 }
            let t = try await pega(js)
            #expect(t.contains("total"))
        }
        let antesDoImport = await dev.estatisticas()
        // Um import de pacote que o projeto ainda não usava: até o Preview ter o que
        // precisa para rodar (bundle e dependências).
        let novoImport = try await FixtureReact.mede {
            try FixtureReact.appTSX(rotulo: "vezes", importaNovo: true).write(to: app, atomically: true, encoding: .utf8)
            await ate { await (dev.estatisticas()["reload"] ?? 0) >= 4 }
            let t = try await pega(js)
            #expect(t.contains("com-react-dom"))
            _ = try? await pega(dev.url.appending(path: "@odete/deps.js"))
        }
        let estatisticas = await dev.estatisticas()
        // `npm run dev` de novo, no mesmo motor: o servidor para e sobe outro.
        dev.stop()
        await dev.esbuild.esperarParadas()
        let dev2 = DevServer(esbuild: dev.esbuild)
        let reinicio = try await FixtureReact.mede {
            try await dev2.start(port: 20000 + Int.random(in: 0 ..< 20000))
            _ = try await pagina(dev2)
        }
        dev2.stop()
        // O app reaberto: motor novo (o esbuild carrega de novo), cache em disco quente.
        let motor = Esbuild(root: raiz)
        let dev3 = DevServer(esbuild: motor)
        defer { dev3.stop() }
        let relancamento = try await FixtureReact.mede {
            try await dev3.start(port: 20000 + Int.random(in: 0 ..< 20000))
            _ = try await pagina(dev3)
        }
        // Do zero, como o botão Rebuild: contextos descartados.
        let frio = try await FixtureReact.mede {
            await dev3.invalidateNow()
            _ = try await pega(dev3.url.appending(path: "@odete/js/src/main.tsx"))
        }
        print(String(
            format: "ODETE_MEDIDA depois real=%@ start=%.2fs/%.2fcpu pagina1=%.2fs/%.2fcpu "
                + "igual=%.2fs/%.2fcpu(builds=%d) mudanca=%.2fs/%.2fcpu mudanca2=%.2fs/%.2fcpu "
                + "profundo=%.2fs/%.2fcpu novoImport=%.2fs/%.2fcpu reinicio=%.2fs/%.2fcpu "
                + "relancamento=%.2fs/%.2fcpu frio=%.2fs/%.2fcpu tamanho=%d",
            "\(FixtureReact.reactDeVerdade)",
            partida.parede, partida.cpu, build1.parede, build1.cpu, igual.parede, igual.cpu, buildsDepoisDoIgual,
            mudou.parede, mudou.cpu, mudou2.parede, mudou2.cpu, profundo.parede, profundo.cpu,
            novoImport.parede, novoImport.cpu, reinicio.parede, reinicio.cpu, relancamento.parede, relancamento.cpu,
            frio.parede, frio.cpu, primeiro.utf8.count
        ))
        print("ODETE_MEDIDA estatisticas antes do import novo \(antesDoImport.sorted { $0.key < $1.key })")
        print("ODETE_MEDIDA estatisticas \(estatisticas.sorted { $0.key < $1.key })")
    }

    /// O lint de um componente de ~200 linhas: a transformação inteira (o que o lint fazia)
    /// contra o lint de agora, texto novo a cada vez; e o texto repetido, que nem chega ao
    /// esbuild.
    @Test func medeLint() async throws {
        let es = Esbuild(root: FileManager.default.temporaryDirectory)
        _ = try await es.ready()
        var corpo = "import { useState } from \"react\";\n\n"
        for i in 0 ..< 40 {
            corpo += """
            export function Cartao\(i)({ titulo, n }: { titulo: string; n: number }) {
              const [aberto, setAberto] = useState<boolean>(false);
              return <section className="cartao"><h2>{titulo} \(i)</h2>{aberto && <p>{n * \(i)}</p>}<button onClick={() => setAberto(!aberto)}>abrir</button></section>;
            }

            """
        }
        let vezes = 10
        let antes = try await FixtureReact.mede {
            for i in 0 ..< vezes {
                _ = try await es.transform(
                    corpo + "// \(i)\n",
                    loader: "tsx",
                    options: ["sourcefile": "a.tsx", "logLevel": "silent"]
                )
            }
        }
        let depois = try await FixtureReact.mede {
            for i in 0 ..< vezes {
                _ = try await es.lint(corpo + "// x\(i)\n", file: "a.tsx")
            }
        }
        let repetido = try await FixtureReact.mede {
            for _ in 0 ..< vezes {
                _ = try await es.lint(corpo + "// x\(vezes - 1)\n", file: "a.tsx")
            }
        }
        print(String(
            format: "ODETE_MEDIDA lint bytes=%d antes=%.1fms/%.1fcpu-ms depois=%.1fms/%.1fcpu-ms repetido=%.2fms",
            corpo.utf8.count,
            antes.parede * 1000 / Double(vezes), antes.cpu * 1000 / Double(vezes),
            depois.parede * 1000 / Double(vezes), depois.cpu * 1000 / Double(vezes),
            repetido.parede * 1000 / Double(vezes)
        ))
    }
}
