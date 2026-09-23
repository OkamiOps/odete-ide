import Foundation
@testable import OdeteAgent
import OdeteI18n
import Synchronization
import Testing

/// Host cujo shell faz de verdade o pouco que os testes pedem: `rm` e `touch` de um
/// arquivo, e `gerar`, que escreve num caminho que não dá para ler na linha de comando —
/// como um gerador de código que escreve onde quer.
final class ShellDeVerdade: FileToolHost, @unchecked Sendable {
    override func runShell(_ command: String) async -> String {
        let partes = command.split(separator: " ").map(String.init)
        let fm = FileManager.default
        for p in partes.dropFirst() where !p.hasPrefix("-") {
            let u = root.appending(path: p)
            switch partes.first {
            case "rm":
                try? fm.removeItem(at: u)
            case "touch" where !fm.fileExists(atPath: u.path):
                fm.createFile(atPath: u.path, contents: Data())
            case "gerar":
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? "gerado\n".write(to: u, atomically: true, encoding: .utf8)
            default:
                break
            }
        }
        return "ok"
    }
}

/// Desfazer o último turno tem que voltar tudo o que o turno mexeu.
///
/// O retrato do começo parava nos 220 primeiros arquivos com menos de 200 kB. O agente
/// editava o arquivo de número 250, ou um bundle de 1 MB, e o desfazer voltava todo o
/// resto menos justamente isso.
@Suite(.serialized) struct CheckpointTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func projetoGrande() throws -> URL {
        let root = try tmpProject()
        for i in 0 ..< 300 {
            try "arquivo \(i)\nlinha dois\n".write(
                to: root.appending(path: String(format: "src/f%03d.txt", i)),
                atomically: true,
                encoding: .utf8
            )
        }
        let grande = String(repeating: "0123456789abcdef\n", count: 62000) // ~1 MB
        try grande.write(to: root.appending(path: "grande.txt"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func voltaTrezentosArquivosEOGrandeQueOAgenteMexeu() async throws {
        let root = try projetoGrande()
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let r = ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs)
        let originais = Dictionary(uniqueKeysWithValues: host.allPaths().map { ($0, host.read($0)!) })
        #expect(originais.count == 303)
        let cp = cs.take(title: "turno")
        #expect(cp.saved.count <= 220, "o retrato continua limitado; quem cobre o resto é a cópia na escrita")

        for i in 0 ..< 300 {
            let p = String(format: "src/f%03d.txt", i)
            let out = await r.run(
                call("str_replace", ["path": p, "old": "linha dois", "new": "mexido \(i)"]),
                mode: .build
            )
            #expect(out.text.hasPrefix("escrito"))
        }
        // Duas escritas no mesmo arquivo: o que volta é o de antes da primeira.
        #expect(await r.run(call("write_file", ["path": "grande.txt", "content": "pequeno agora"]), mode: .build)
            .text.hasPrefix("escrito"))
        #expect(await r.run(call("write_file", ["path": "grande.txt", "content": "de novo"]), mode: .build)
            .text.hasPrefix("escrito"))

        let atual = try #require(cs.last)
        #expect(atual.capturados.contains("grande.txt"))
        #expect(atual.capturados.count + atual.saved.count >= 301)

        cs.encerrar()
        let volta = try #require(cs.desfazer(cp.id))
        #expect(volta.voltaram.count == 301)
        #expect(volta.apagados.isEmpty && volta.mantidos.isEmpty && volta.semCopia.isEmpty)
        #expect(volta.mensagem.hasPrefix("voltou: turno\nVoltaram ao que eram antes do turno: "))
        #expect(volta.mensagem.contains("e mais 293"), "a lista longa não foi resumida")
        for (p, texto) in originais {
            #expect(host.read(p) == texto, "\(p) não voltou")
        }
        #expect(cs.list().isEmpty, "o checkpoint desfeito continuou na pilha")
    }

    @Test func oQueNasceuNoTurnoSaiComAsPastas() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let r = ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs)
        let cp = cs.take(title: "cria")
        #expect(await r.run(call("write_file", ["path": "novo/fundo/a.ts", "content": "x"]), mode: .build)
            .text.hasPrefix("escrito"))
        // O plano mora em `.odete`, que o retrato nunca vê.
        #expect(await r.run(call("write_file", ["path": ".odete/plan.md", "content": "# plano"]), mode: .plan)
            .text == "escrito .odete/plan.md")
        #expect(host.exists("novo/fundo/a.ts") && host.exists(".odete/plan.md"))
        cs.encerrar()
        _ = cs.restore(cp.id)
        #expect(!host.exists("novo/fundo/a.ts"))
        #expect(!host.exists(".odete/plan.md"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "novo").path), "a pasta vazia ficou")
        #expect(host.read("a.txt") == "a\nb\nc\n")
    }

    @Test func oShellQueApagaTambemVolta() async throws {
        let root = try projetoGrande()
        let host = ShellDeVerdade(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let r = ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs)
        let original = try #require(host.read("grande.txt"))
        let tardio = try #require(host.read("src/f299.txt"))
        let cp = cs.take(title: "rm")
        #expect(await r.run(call("run_shell", ["command": "rm grande.txt src/f299.txt"]), mode: .build).text == "ok")
        #expect(!host.exists("grande.txt") && !host.exists("src/f299.txt"))
        cs.encerrar()
        _ = cs.restore(cp.id)
        #expect(host.read("grande.txt") == original)
        #expect(host.read("src/f299.txt") == tardio)
    }

    @Test func arquivoAcimaDoTetoFicaAnotado() async throws {
        let root = try tmpProject()
        let enorme = String(repeating: "x", count: CheckpointStore.tetoPorArquivo + 10)
        try enorme.write(to: root.appending(path: "enorme.bin"), atomically: true, encoding: .utf8)
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let r = ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs)
        let cp = cs.take(title: "grande")
        _ = await r.run(call("write_file", ["path": "enorme.bin", "content": "curto"]), mode: .build)
        #expect(cs.last?.grandes == ["enorme.bin"])
        let msg = cs.restore(cp.id)
        #expect(msg.hasPrefix("voltou: grande"))
        #expect(msg.contains("enorme.bin"), "o desfazer não avisou do que não pôde voltar")
    }

    /// Oito checkpoints, e a pasta sem manifesto (turno interrompido no meio da cópia)
    /// também sai — antes ela nunca aparecia na lista e por isso nunca era apagada.
    @Test func retencaoELimpeza() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let dir = root.appending(path: ".odete/checkpoints")
        try FileManager.default.createDirectory(
            at: dir.appending(path: "0000000000001-000001/files"),
            withIntermediateDirectories: true
        )
        for i in 0 ..< 11 {
            cs.take(title: "t\(i)")
        }
        #expect(cs.list().count == 8)
        #expect(cs.last?.title == "t10")
        let pastas = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(pastas.count == 8, "sobrou pasta velha ou órfã: \(pastas)")

        // O que o turno escreveu sobrevive a reabrir o projeto.
        let r = ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs)
        _ = await r.run(call("write_file", ["path": "b.txt", "content": "b"]), mode: .build)
        let reaberto = CheckpointStore(root: root, host: host)
        #expect(reaberto.last?.criados == ["b.txt"])
        let ultimo = try #require(reaberto.last)
        _ = reaberto.restore(ultimo.id)
        #expect(!host.exists("b.txt"))
        #expect(reaberto.list().count == 7)
    }

    /// O que o shell vai tocar, lido da linha de comando.
    @Test func alvosDoShell() {
        #expect(Tools.alvosDoShell("rm -rf dist src/a.js") == ["dist", "src/a.js"])
        #expect(Tools.alvosDoShell("cd src && rm a.js; echo oi > ../log.txt") == ["src/a.js", "log.txt"])
        #expect(Tools.alvosDoShell("mv a.txt b/", pasta: "lib") == ["lib/b", "lib/a.txt", "lib/b/a.txt"])
        #expect(Tools.alvosDoShell("npm install left-pad") == ["package.json", "package-lock.json"])
        #expect(Tools.alvosDoShell("echo \"a > b\" >> notas.md 2>&1") == ["notas.md"])
        #expect(Tools.alvosDoShell("rm ../../fora.txt").isEmpty, "caminho fora do projeto passou")
        #expect(Tools.alvosDoShell("ls -la && cat a.txt | grep x").isEmpty)
        #expect(Tools.alvosDoShell("touch /raiz.txt ~/casa.txt", pasta: "src") == ["raiz.txt", "casa.txt"])
    }

    /// `rm *.log` apaga o que casa; o checkpoint guarda o que casa.
    @Test func curingaDoShellViraArquivos() throws {
        let root = try tmpProject()
        // Grandes o bastante para ficar fora do retrato: quem guarda é a cópia na escrita.
        let conteudo = String(repeating: "log\n", count: 60000)
        for n in ["x.log", "y.log", "z.txt"] {
            try conteudo.write(to: root.appending(path: n), atomically: true, encoding: .utf8)
        }
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let cp = cs.take(title: "logs")
        #expect(!cp.saved.contains("x.log"))
        cs.capturar("*.log")
        #expect(Set(cs.last?.capturados ?? []) == ["x.log", "y.log"])
    }
}

/// As duas ferramentas que leem o que o app já sabe.
final class HostComProblemas: FileToolHost, @unchecked Sendable {
    let lista: [Problema]
    let linhas: [LinhaDoConsole]
    init(root: URL, problemas: [Problema], console: [LinhaDoConsole]) {
        lista = problemas
        linhas = console
        super.init(root: root)
    }

    override func problemas() -> [Problema] {
        lista
    }

    override func consolePreview(_ n: Int) -> [LinhaDoConsole] {
        Array(linhas.suffix(n))
    }
}

struct DiagnosticosTests {
    func problemas() -> [Problema] {
        var out: [Problema] = []
        for i in 0 ..< 90 {
            out.append(Problema(
                arquivo: "src/f\(i % 7).ts",
                linha: i + 1,
                coluna: 3,
                gravidade: .warning,
                mensagem: "aviso \(i)",
                fonte: "lint"
            ))
        }
        for i in 0 ..< 40 {
            out.append(Problema(
                arquivo: i.isMultiple(of: 10) ? nil : "src/main.ts",
                linha: i + 1,
                coluna: i.isMultiple(of: 2) ? 7 : nil,
                gravidade: .error,
                mensagem: "Expected \";\"\n  em algum lugar \(i)",
                fonte: i.isMultiple(of: 10) ? "preview" : "esbuild"
            ))
        }
        return out
    }

    @Test func formatoOrdemETeto() async throws {
        let root = try tmpProject()
        let host = HostComProblemas(root: root, problemas: problemas(), console: [])
        let r = ToolRunner(host: host, patches: PatchStore(root: root))
        let texto = await r.run(call("read_problems", [:]), mode: .chat).text
        let linhas = texto.split(separator: "\n").map(String.init)
        // Os quatro erros sem arquivo são o mesmo texto: contam uma vez.
        #expect(linhas.first == "37 erros, 90 avisos")
        #expect(linhas.count == 1 + Diagnosticos.tetoDeProblemas + 1)
        #expect(linhas.last == "… e mais 27 omitidos")
        // Erros primeiro; a mensagem de várias linhas vira a primeira; sem coluna, sem ela.
        #expect(linhas[1] == "src/main.ts:2 error Expected \";\" (esbuild)")
        #expect(linhas[2] == "src/main.ts:3:7 error Expected \";\" (esbuild)")
        // Sem arquivo vai para o fim dos erros, sem local na frente.
        #expect(linhas[37] == "error Expected \";\" (preview)")
        #expect(linhas[38] == "src/f0.ts:1:3 warning aviso 0 (lint)")
    }

    @Test func filtroPorCaminho() async throws {
        let root = try tmpProject()
        let r = ToolRunner(
            host: HostComProblemas(root: root, problemas: problemas(), console: []),
            patches: PatchStore(root: root)
        )
        let so = await r.run(call("read_problems", ["path": "src/f3.ts"]), mode: .chat).text
        #expect(so.split(separator: "\n").dropFirst().allSatisfy { $0.hasPrefix("src/f3.ts:") })
        #expect(so.hasPrefix("0 erros, 13 avisos"))
        #expect(await r.run(call("read_problems", ["path": "lib"]), mode: .chat).text == "(nenhum problema em lib)")
        let vazio = ToolRunner(host: TestHost(root: root), patches: PatchStore(root: root))
        #expect(await vazio.run(call("read_problems", [:]), mode: .chat).text == "(nenhum problema)")
    }

    @Test func consoleComNivelETeto() async throws {
        let root = try tmpProject()
        let linhas = (0 ..< 300).map {
            LinhaDoConsole(
                nivel: $0.isMultiple(of: 3) ? "error" : "log",
                texto: "linha \($0)",
                arquivo: "src/app.js",
                linha: $0
            )
        }
        let r = ToolRunner(
            host: HostComProblemas(root: root, problemas: [], console: linhas),
            patches: PatchStore(root: root)
        )
        let padrao = await r.run(call("read_preview_console", [:]), mode: .chat).text.split(separator: "\n")
        #expect(padrao.count == 50)
        #expect(padrao.last == "[log] linha 299 (src/app.js:299)")
        #expect(padrao.first == "[log] linha 250 (src/app.js:250)")
        let muitas = await r.run(call("read_preview_console", ["n": 5000]), mode: .chat).text.split(separator: "\n")
        #expect(muitas.count == 200, "passou do máximo")
        let uma = await r.run(call("read_preview_console", ["n": 0]), mode: .chat).text
        #expect(uma == "[log] linha 299 (src/app.js:299)")
        #expect(padrao.contains("[error] linha 297 (src/app.js:297)"))
        let vazio = ToolRunner(host: TestHost(root: root), patches: PatchStore(root: root))
        #expect(await vazio.run(call("read_preview_console", [:]), mode: .chat).text == "(console do preview vazio)")
    }

    /// Ler o que o app já sabe é leitura: vale em todo modo e não pede licença.
    @Test func lerNaoPedeLicencaEValeEmTodoModo() {
        for nome in ["read_problems", "read_preview_console"] {
            #expect(!Tools.needsPermit(.auto, nome))
            for modo in AgentMode.allCases {
                #expect(Tools.forMode(modo).contains { $0.name == nome }, "\(nome) faltou no modo \(modo)")
            }
        }
    }

    /// No aparelho, `read_problems` entra e o console inteiro fica de fora; na nuvem, tudo.
    @Test func oModeloDoAparelhoRecebeOsProblemasMasNaoOConsole() {
        let local = AppleProvider.especificacoes(TurnRequest(
            system: "",
            messages: [],
            tools: Tools.all,
            model: AppleProvider.idLocal
        ))
        #expect(local.contains { $0.name == "read_problems" })
        #expect(!local.contains { $0.name == "read_preview_console" })
        let nuvem = AppleProvider.especificacoes(TurnRequest(
            system: "",
            messages: [],
            tools: Tools.all,
            model: AppleProvider.idNuvem
        ))
        #expect(nuvem.count == Tools.all.count)
    }
}
