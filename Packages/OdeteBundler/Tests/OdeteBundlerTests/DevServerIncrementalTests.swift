import Foundation
@testable import OdeteBundler
import Synchronization
import Testing

/// O dev server só trabalha quando algo que o Preview mostra mudou.
///
/// No iPad sem JIT, cada build do zero de um projeto React pequeno passa de seis segundos
/// de CPU, e o salvamento automático regrava o arquivo aberto a cada pausa na digitação.
/// Estes testes provam o que não pode acontecer (rebuild e reload por regravação igual,
/// por arquivo fora do grafo) e o que tem de continuar acontecendo (mudança de verdade
/// refaz, e a saída nova é a certa).
@Suite(.serialized) struct DevServerIncrementalTests {
    func porta() -> Int {
        20000 + Int.random(in: 0 ..< 20000)
    }

    func texto(_ u: URL) async throws -> String {
        let (d, _) = try await URLSession.shared.data(from: u)
        return String(decoding: d, as: UTF8.self)
    }

    /// Espera até a condição valer (ou o prazo acabar) sem dormir o prazo inteiro.
    func ate(_ prazo: Duration = .seconds(10), _ condicao: () async -> Bool) async -> Bool {
        let fim = ContinuousClock.now + prazo
        while ContinuousClock.now < fim {
            if await condicao() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return await condicao()
    }

    /// Sobe o servidor, serve o bundle uma vez e espera o observador armar no grafo.
    func servidorPronto(_ root: URL) async throws -> DevServer {
        let dev = DevServer(root: root)
        try await dev.start(port: porta())
        let js = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(js.contains("soma"))
        let soma = root.appending(path: "src/soma.ts").path
        let armou = await ate { dev.arquivosVigiados.contains(soma) }
        #expect(armou, "o observador não passou a vigiar o que o build leu: \(dev.arquivosVigiados)")
        return dev
    }

    func stats(_ dev: DevServer) async -> (builds: Int, reload: Int, css: Int) {
        let s = await dev.estatisticas()
        return (s["builds"] ?? -1, s["reload"] ?? -1, s["css"] ?? -1)
    }

    @Test func regravarComOMesmoConteudoNaoRefazNemRecarrega() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        #expect(await stats(dev).builds == 1)

        let soma = root.appending(path: "src/soma.ts")
        let igual = try String(contentsOf: soma, encoding: .utf8)
        // Como o editor grava (atômico, arquivo novo por cima) e como `echo >` grava (no lugar).
        try igual.write(to: soma, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))
        try igual.write(to: soma, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(400))

        let s = await stats(dev)
        #expect(s.builds == 1, "regravar com o mesmo texto refez o build")
        #expect(s.reload == 0, "regravar com o mesmo texto recarregou o Preview")
    }

    /// Mesmo quando alguém diz que o arquivo mudou e o build é refeito, a saída igual não
    /// vira reload: quem decide é o hash do que o esbuild produziu.
    @Test func saidaIgualNaoRecarrega() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        let reacao = await dev.arquivosMudaram([root.appending(path: "src/soma.ts").path])
        #expect(reacao == .nada)
        let s = await stats(dev)
        #expect(s.builds == 2 && s.reload == 0)
    }

    @Test func mudancaDeVerdadeRefazERecarregaComASaidaCerta() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }

        // Um cliente de verdade no socket do Preview, para ver o aviso chegar.
        let ws = try URLSession.shared
            .webSocketTask(with: #require(URL(string: "ws://127.0.0.1:\(dev.port)/@odete/ws")))
        ws.resume()
        defer { ws.cancel(with: .normalClosure, reason: nil) }
        let recebido = Mutex<[String]>([])
        let escuta = Task {
            while let m = try? await ws.receive() {
                if case let .string(s) = m {
                    recebido.withLock { $0.append(s) }
                }
            }
        }
        defer { escuta.cancel() }
        _ = await ate(.seconds(3)) { await dev.estatisticas()["sockets"] == 1 }

        try "export const soma = (a: number, b: number): number => a * b + 7;".write(
            to: root.appending(path: "src/soma.ts"), atomically: true, encoding: .utf8
        )
        let recarregou = await ate { await stats(dev).reload == 1 }
        #expect(recarregou, "mudança de verdade não recarregou o Preview")
        #expect(await stats(dev).builds == 2)
        let js = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(js.contains("a * b + 7"), "o rebuild serviu a saída velha")
        let chegou = await ate(.seconds(3)) { recebido.withLock { $0.contains("reload") } }
        #expect(chegou, "o aviso de reload não chegou ao socket: \(recebido.withLock { $0 })")
    }

    /// Edições seguidas no mesmo arquivo: cada uma refaz e recarrega. A gravação atômica
    /// troca o arquivo por outro a cada vez, e o observador tem de seguir o novo.
    @Test func edicoesSeguidasRecarregamTodas() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        let soma = root.appending(path: "src/soma.ts")
        for i in 1 ... 4 {
            try "export const soma = (a: number, b: number): number => a + b + \(i * 1111);".write(
                to: soma, atomically: i % 2 == 1, encoding: .utf8
            )
            let recarregou = await ate { await stats(dev).reload >= i }
            let s = await stats(dev)
            #expect(recarregou, "a edição \(i) não recarregou: \(s)")
            let js = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
            #expect(js.contains("a + b + \(i * 1111)"), "a edição \(i) serviu a saída velha")
        }
    }

    @Test func arquivoForaDoGrafoNaoRefaz() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        try "# nada a ver\n".write(to: root.appending(path: "README.md"), atomically: true, encoding: .utf8)
        try "export const solto = 1;\n".write(
            to: root.appending(path: "src/solto.ts"),
            atomically: true,
            encoding: .utf8
        )
        try await Task.sleep(for: .milliseconds(500))
        try "export const solto = 2;\n".write(
            to: root.appending(path: "src/solto.ts"),
            atomically: true,
            encoding: .utf8
        )
        try await Task.sleep(for: .milliseconds(500))
        // Pelo caminho direto também: o JS confere o grafo, não confia em quem avisou.
        let reacao = await dev.arquivosMudaram([root.appending(path: "README.md").path])
        #expect(reacao == .nada)
        let s = await stats(dev)
        #expect(s.builds == 1, "arquivo que nenhum build lê fez o build ser refeito")
        #expect(s.reload == 0)
    }

    @Test func soCssTrocaAFolhaSemRecarregar() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        _ = try await texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        try "body { color: blue }".write(to: root.appending(path: "src/style.css"), atomically: true, encoding: .utf8)
        let trocou = await ate { await stats(dev).css == 1 }
        #expect(trocou, "CSS mudou e o Preview não foi avisado")
        #expect(await stats(dev).reload == 0, "só o CSS mudou e a página recarregou inteira")
        let css = try await texto(dev.url.appending(path: "@odete/css/src/main.tsx"))
        #expect(css.contains("color: blue"))
        let html = try await texto(dev.url)
        #expect(html.contains("\"css\""), "o cliente do Preview não sabe trocar a folha")
    }

    @Test func arquivoNovoConsertaImportQuebrado() async throws {
        let root = try tmpProject()
        try "import { novo } from './componentes/novo'; document.body.innerHTML = String(novo);".write(
            to: root.appending(path: "src/main.tsx"), atomically: true, encoding: .utf8
        )
        let dev = DevServer(root: root)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let quebrado = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(quebrado.contains("Não achei"))
        let main = root.appending(path: "src/main.tsx").path
        #expect(await ate { dev.arquivosVigiados.contains(main) })
        // A pasta nem existia: nasce a pasta e depois o arquivo dentro dela.
        try FileManager.default.createDirectory(
            at: root.appending(path: "src/componentes"), withIntermediateDirectories: true
        )
        try await Task.sleep(for: .milliseconds(300))
        try "export const novo = 'apareceu';".write(
            to: root.appending(path: "src/componentes/novo.ts"), atomically: true, encoding: .utf8
        )
        let recarregou = await ate { await stats(dev).reload >= 1 }
        #expect(recarregou, "o arquivo que faltava apareceu e o build não foi refeito")
        let js = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(js.contains("apareceu"))
    }

    /// Build que já nasce quebrado não tem metafile — e mesmo assim consertar o erro tem de
    /// refazer o build.
    @Test func consertarErroDoPrimeiroBuildRefaz() async throws {
        let root = try tmpProject()
        let soma = root.appending(path: "src/soma.ts")
        try "export const soma = (a: number, b: number): number => a +;".write(
            to: soma, atomically: true, encoding: .utf8
        )
        let dev = DevServer(root: root)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let quebrado = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(quebrado.contains("soma.ts"), "o erro não apontou o arquivo: \(quebrado.prefix(300))")
        #expect(await ate { dev.arquivosVigiados.contains(soma.path) }, "o arquivo com erro ficou sem vigia")
        try "export const soma = (a: number, b: number): number => a + b + 4321;".write(
            to: soma, atomically: true, encoding: .utf8
        )
        #expect(await ate { await stats(dev).reload >= 1 })
        #expect(try await texto(dev.url.appending(path: "@odete/js/src/main.tsx")).contains("a + b + 4321"))
    }

    /// Projeto do iCloud: os pacotes moram em `node_modules.nosync` e `node_modules` é um
    /// atalho. O build passa pelo atalho, nada de pacote entra no que é vigiado arquivo a
    /// arquivo, e instalar um pacote novo refaz tudo — uma vez, quando a instalação sossega.
    @Test func pacotesNoICloudPeloAtalho() async throws {
        let root = try tmpProject()
        let fm = FileManager.default
        try fm.moveItem(at: root.appending(path: "node_modules"), to: root.appending(path: "node_modules.nosync"))
        try fm.createSymbolicLink(
            atPath: root.appending(path: "node_modules").path,
            withDestinationPath: "node_modules.nosync"
        )
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        #expect(!dev.arquivosVigiados.contains { $0.contains("/node_modules") }, "\(dev.arquivosVigiados)")
        try fm.createDirectory(
            at: root.appending(path: "node_modules.nosync/pacote-novo"), withIntermediateDirectories: true
        )
        try #"{"name":"pacote-novo"}"#.write(
            to: root.appending(path: "node_modules.nosync/pacote-novo/package.json"), atomically: true, encoding: .utf8
        )
        let refez = await ate { await stats(dev).reload == 1 }
        #expect(refez, "pacote novo não refez o build")
        try await Task.sleep(for: .seconds(2))
        #expect(await stats(dev).reload == 1, "uma instalação virou mais de uma recarga")
        #expect(try await texto(dev.url.appending(path: "@odete/js/src/main.tsx")).contains("soma"))
    }

    @Test func packageJsonRefazTudo() async throws {
        let root = try tmpProject()
        let dev = try await servidorPronto(root)
        defer { dev.stop() }
        let reacao = await dev.arquivosMudaram([root.appending(path: "package.json").path])
        #expect(reacao == .reload)
        let contextos = try await dev.esbuild.engine.call("__contextosVivos")
        #expect(contextos == "0", "invalidar tudo deixou contexto do esbuild vivo")
    }

    /// Um motor por projeto: o servidor, o lint e quem mais pedir recebem o mesmo, e
    /// parar o servidor não derruba o motor dos outros.
    @Test func umMotorPorProjetoEPararNaoDerrubaOMotor() async throws {
        let root = try tmpProject()
        let motor = Esbuild.doProjeto(root)
        #expect(Esbuild.doProjeto(root) === motor)
        #expect(Esbuild.existente(root) === motor)
        let dev = DevServer(root: root)
        #expect(dev.esbuild === motor)
        try await dev.start(port: porta())
        _ = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        // O bundle do app e o pacote de dependências (o `react/jsx-dev-runtime` do JSX).
        #expect(try await motor.engine.call("__contextosVivos") == "2")
        dev.stop()
        await motor.esperarParadas()
        #expect(try await motor.engine.call("__contextosVivos") == "0", "o servidor parou e deixou o contexto vivo")
        // o motor segue servindo: lint e um servidor novo
        let d = try await motor.lint("const a = ;", file: "a.ts")
        #expect(d.contains { $0.kind == .error })
        let outro = DevServer(esbuild: motor)
        try await outro.start(port: porta())
        defer { outro.stop() }
        #expect(try await texto(outro.url.appending(path: "@odete/js/src/main.tsx")).contains("soma"))
    }

    @Test func doisServidoresNoMesmoMotor() async throws {
        let root = try tmpProject()
        let motor = Esbuild.doProjeto(root)
        let a = DevServer(esbuild: motor)
        let b = DevServer(esbuild: motor)
        try await a.start(port: porta())
        try await b.start(port: porta(), preset: .plain)
        defer { a.stop(); b.stop() }
        #expect(a.port != b.port)
        #expect(try await texto(a.url.appending(path: "@odete/js/src/main.tsx")).contains("soma"))
        #expect(try await texto(b.url.appending(path: "@odete/js/src/main.tsx")).contains("soma"))
        b.stop()
        await motor.esperarParadas()
        #expect(try await texto(a.url.appending(path: "@odete/js/src/main.tsx")).contains("soma"))
    }

    /// O `vite build` não sai com o mapa embutido, e o bundle do dev server também não o
    /// gera à toa (o console do Preview não usa).
    @Test func semSourcemapEmbutido() async throws {
        let root = try tmpProject()
        let es = Esbuild(root: root)
        let prod = try await es.build(entries: ["src/main.tsx"], dev: false, minify: true)
        #expect(prod.ok)
        #expect(!prod.files.contains { $0.text.contains("sourceMappingURL") })
        let dev = DevServer(esbuild: es)
        try await dev.start(port: porta())
        defer { dev.stop() }
        let js = try await texto(dev.url.appending(path: "@odete/js/src/main.tsx"))
        #expect(js.contains("soma") && !js.contains("sourceMappingURL"))
    }
}

/// O lint do editor: só diagnósticos, e só quando o texto mudou.
struct LintSoQuandoMudaTests {
    @Test func textoIgualNaoVoltaAoEsbuild() async throws {
        let es = Esbuild(root: FileManager.default.temporaryDirectory)
        let quebrado = "const a = 'sem fechar;\n"
        let d1 = try await es.lint(quebrado, file: "a.ts")
        let d2 = try await es.lint(quebrado, file: "a.ts")
        #expect(d1 == d2 && d1.contains { $0.kind == .error })
        #expect(es.lintsExecutados.withLock { $0 } == 1, "o mesmo texto foi lintado duas vezes")
        _ = try await es.lint("const a = 1;\n", file: "a.ts")
        _ = try await es.lint(quebrado, file: "b.ts")
        #expect(es.lintsExecutados.withLock { $0 } == 3)
    }

    @Test func pelaPonteSoPassamDiagnosticos() async throws {
        let es = Esbuild(root: FileManager.default.temporaryDirectory)
        _ = try await es.ready()
        let json = try await es.engine.call("__lint", ["export const f = (a: number) => a + 1;", "ts", "a.ts"])
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(Set(obj.keys) == ["errors", "warnings"], "o lint devolveu mais que diagnósticos: \(obj.keys)")
    }
}
