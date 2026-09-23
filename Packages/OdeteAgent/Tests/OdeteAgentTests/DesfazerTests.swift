import Foundation
@testable import OdeteAgent
import OdeteI18n
import Testing

/// Desfazer o último turno nunca pode levar o trabalho da pessoa.
///
/// O desfazer apagava tudo o que não existia no começo do turno — inclusive o arquivo que a
/// pessoa criou depois, ou no editor enquanto o agente trabalhava — e voltava ao conteúdo
/// de antes o arquivo que ela editou por cima do turno. Agora só sai o que o turno criou,
/// só volta o que o turno mudou, e o que a pessoa mexeu depois fica e vai na mensagem.
@Suite(.serialized) struct DesfazerTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func projeto() throws -> (URL, ShellDeVerdade, CheckpointStore, ToolRunner) {
        let root = try tmpProject()
        let host = ShellDeVerdade(root: root)
        let cs = CheckpointStore(root: root, host: host)
        return (root, host, cs, ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs))
    }

    /// A pessoa escrevendo, como o editor escreve: por cima, sem passar pelo agente.
    func escrever(_ root: URL, _ p: String, _ texto: String) throws {
        let u = root.appending(path: p)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try texto.write(to: u, atomically: true, encoding: .utf8)
    }

    @Test func oArquivoQueAPessoaCriouDepoisDoTurnoFica() async throws {
        let (root, host, cs, r) = try projeto()
        let cp = cs.take(title: "cria")
        _ = await r.run(call("write_file", ["path": "do-agente.ts", "content": "x"]), mode: .build)
        cs.encerrar()
        try escrever(root, "meu.ts", "da pessoa")
        try escrever(root, "pasta-nova/outro.ts", "da pessoa")
        let v = try #require(cs.desfazer(cp.id))
        #expect(host.read("meu.ts") == "da pessoa", "o desfazer apagou o arquivo que a pessoa criou")
        #expect(host.read("pasta-nova/outro.ts") == "da pessoa")
        #expect(!host.exists("do-agente.ts"))
        #expect(v.apagados == ["do-agente.ts"] && v.mantidos.isEmpty)
    }

    @Test func oQueAPessoaEditouDepoisFicaEVaiNaMensagem() async throws {
        let (root, host, cs, r) = try projeto()
        let cp = cs.take(title: "edita")
        _ = await r.run(call("str_replace", ["path": "a.txt", "old": "b", "new": "B"]), mode: .build)
        _ = await r.run(call("str_replace", ["path": "src/x.ts", "old": "1", "new": "2"]), mode: .build)
        _ = await r.run(call("write_file", ["path": "novo.ts", "content": "do agente"]), mode: .build)
        cs.encerrar()
        try escrever(root, "a.txt", "a\nB\nc\nminha linha\n")
        try escrever(root, "novo.ts", "do agente, e agora meu também")

        // A prévia diz o que vai ficar, e não mexe em nada.
        let previa = try #require(cs.previa(cp.id))
        #expect(previa.mantidos == ["a.txt", "novo.ts"])
        #expect(host.read("src/x.ts") == "export const x = 2;\n" && cs.last?.id == cp.id)

        let v = try #require(cs.desfazer(cp.id))
        #expect(host.read("a.txt") == "a\nB\nc\nminha linha\n", "a edição da pessoa foi sobrescrita")
        #expect(host.read("novo.ts") == "do agente, e agora meu também", "o arquivo editado pela pessoa sumiu")
        #expect(host.read("src/x.ts") == "export const x = 1;\n", "o que só o agente mexeu não voltou")
        #expect(v.mantidos == ["a.txt", "novo.ts"] && v.voltaram == ["src/x.ts"] && v.apagados.isEmpty)
        #expect(v.mensagem == """
        voltou: edita
        Voltaram ao que eram antes do turno: src/x.ts
        Não voltaram, porque você mexeu neles depois do turno: a.txt, novo.ts
        """)
    }

    /// A hora mudou mas o texto não — o editor recarregou e gravou o mesmo: não é edição.
    /// O texto mudou sem mudar de tamanho: é.
    @Test func regravarOMesmoTextoNaoContaComoEdicao() async throws {
        let (root, host, cs, r) = try projeto()
        let cp = cs.take(title: "mesmo")
        _ = await r.run(call("str_replace", ["path": "a.txt", "old": "b", "new": "B"]), mode: .build)
        _ = await r.run(call("str_replace", ["path": "src/x.ts", "old": "1", "new": "2"]), mode: .build)
        cs.encerrar()
        try await Task.sleep(for: .milliseconds(20))
        try escrever(root, "a.txt", "a\nB\nc\n")
        try escrever(root, "src/x.ts", "export const x = 3;\n")
        let v = try #require(cs.desfazer(cp.id))
        #expect(v.voltaram == ["a.txt"] && host.read("a.txt") == "a\nb\nc\n")
        #expect(v.mantidos == ["src/x.ts"] && host.read("src/x.ts") == "export const x = 3;\n")
    }

    /// O que a tela pede para manter (a aba com edição ainda não gravada) fica, mesmo com o
    /// disco dizendo que nada mudou depois do turno.
    @Test func oQueATelaPedeParaManterFica() async throws {
        let (_, host, cs, r) = try projeto()
        let cp = cs.take(title: "aba")
        _ = await r.run(call("str_replace", ["path": "a.txt", "old": "b", "new": "B"]), mode: .build)
        _ = await r.run(call("write_file", ["path": "novo.ts", "content": "x"]), mode: .build)
        cs.encerrar()
        #expect(cs.previa(cp.id)?.voltaram == ["a.txt"])
        let v = try #require(cs.desfazer(cp.id, manter: ["a.txt", "novo.ts"]))
        #expect(v.mantidos == ["a.txt", "novo.ts"] && v.voltaram.isEmpty && v.apagados.isEmpty)
        #expect(host.read("a.txt") == "a\nB\nc\n" && host.exists("novo.ts"))
    }

    /// O shell cria sem avisar: pelo que a linha de comando diz (`touch`) e pelo que não
    /// diz (um gerador que escreve onde quer). Os dois saem.
    @Test func oQueOShellCriouNoTurnoSai() async throws {
        let (_, host, cs, r) = try projeto()
        let cp = cs.take(title: "shell")
        _ = await r.run(call("run_shell", ["command": "touch do-shell.txt"]), mode: .build)
        _ = await r.run(call("run_shell", ["command": "gerar src/gerado.js"]), mode: .build)
        #expect(host.exists("do-shell.txt") && host.exists("src/gerado.js"))
        cs.encerrar()
        let v = try #require(cs.desfazer(cp.id))
        #expect(!host.exists("do-shell.txt") && !host.exists("src/gerado.js"))
        #expect(v.apagados == ["do-shell.txt", "src/gerado.js"])
    }

    /// O shell anotou um alvo e não mexeu nele: não é do turno, e a mensagem não diz que
    /// ele voltou.
    @Test func oQueOShellAnotouENaoMudouNaoEntraNaVolta() async throws {
        let (root, _, cs, r) = try projeto()
        // Grande o bastante para ficar fora do retrato: quem guarda é a cópia antes do shell.
        try escrever(root, "grande.log", String(repeating: "x", count: 300_000))
        let cp = cs.take(title: "nada")
        _ = await r.run(call("run_shell", ["command": "touch grande.log"]), mode: .build)
        #expect(cs.last?.capturados == ["grande.log"])
        cs.encerrar()
        let v = try #require(cs.desfazer(cp.id))
        #expect(v.voltaram.isEmpty && v.mensagem == "voltou: nada")
    }

    /// A pessoa cria e edita no editor enquanto o agente trabalha, fora de qualquer
    /// comando do shell: nada disso é do turno.
    @Test func oQueAPessoaFezDuranteOTurnoFica() async throws {
        let (root, host, cs, r) = try projeto()
        let cp = cs.take(title: "junto")
        _ = await r.run(call("write_file", ["path": "do-agente.ts", "content": "x"]), mode: .build)
        try escrever(root, "rascunho.md", "da pessoa")
        try escrever(root, "src/x.ts", "export const x = 42;\n")
        // Longe o bastante da janela do comando para não ser confundido com ele.
        try await Task.sleep(for: .milliseconds(400))
        _ = await r.run(call("run_shell", ["command": "gerar src/gerado.js"]), mode: .build)
        cs.encerrar()
        let v = try #require(cs.desfazer(cp.id))
        #expect(host.read("rascunho.md") == "da pessoa", "o arquivo criado durante o turno foi apagado")
        #expect(host.read("src/x.ts") == "export const x = 42;\n", "a edição feita durante o turno voltou")
        #expect(!host.exists("do-agente.ts") && !host.exists("src/gerado.js"))
        #expect(v.apagados == ["do-agente.ts", "src/gerado.js"] && v.voltaram.isEmpty && v.mantidos.isEmpty)
    }

    /// Um checkpoint de antes desta versão: sem fim de turno e sem resumo das escritas.
    /// Nada que não dá para conferir é apagado ou sobrescrito — e a varredura de antes,
    /// que apagava o que não estava na lista do começo, não roda.
    @Test func manifestoAntigoNaoApagaNadaSemConferir() throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let id = "0000000000001-000001"
        let pasta = root.appending(path: ".odete/checkpoints/\(id)")
        try escrever(pasta, "files/a.txt", "a\nb\nc\n")
        try escrever(pasta, "files/src/x.ts", "export const x = 1;\n")
        try escrever(pasta, "manifest.json", """
        {"id":"\(id)","title":"velho","at":"2026-01-01T00:00:00Z","paths":["a.txt","src/x.ts"],\
        "saved":["a.txt","src/x.ts"]}
        """)
        try escrever(pasta, "escritas.json", """
        {"capturados":[],"criados":["do-agente.ts"],"pastasCriadas":[],"grandes":[]}
        """)
        try escrever(root, "a.txt", "mudado pela pessoa")
        try escrever(root, "do-agente.ts", "do agente, talvez editado")
        try escrever(root, "meu.ts", "da pessoa")

        let cs = CheckpointStore(root: root, host: host)
        let v = try #require(cs.desfazer(id))
        #expect(host.read("meu.ts") == "da pessoa", "a varredura antiga apagou o arquivo da pessoa")
        #expect(host.read("a.txt") == "mudado pela pessoa", "o retrato antigo sobrescreveu a edição")
        #expect(host.read("do-agente.ts") == "do agente, talvez editado")
        #expect(v.naoConferidos == ["do-agente.ts"] && v.apagados.isEmpty && v.voltaram.isEmpty)
        #expect(v.mensagem.contains("não dá para conferir se você mexeu neles depois do turno: do-agente.ts"))
        #expect(cs.list().isEmpty)

        // Sem `escritas.json`, então, não há nada do agente para desfazer.
        try escrever(pasta, "manifest.json", """
        {"id":"\(id)","title":"mais velho","at":"2026-01-01T00:00:00Z","paths":["a.txt"],"saved":["a.txt"]}
        """)
        try escrever(pasta, "files/a.txt", "a\nb\nc\n")
        let outra = CheckpointStore(root: root, host: host)
        #expect(outra.restore(id) == "voltou: mais velho")
        #expect(host.read("a.txt") == "mudado pela pessoa" && host.read("meu.ts") == "da pessoa")
    }

    /// O app fechou no meio do turno: não há fim anotado. O que o agente escreveu volta se
    /// ainda está como ele deixou; o que a pessoa mexeu depois fica.
    @Test func turnoQueNaoFechouSoVoltaOQueConfere() async throws {
        let (root, host, cs, r) = try projeto()
        let cp = cs.take(title: "interrompido")
        _ = await r.run(call("str_replace", ["path": "a.txt", "old": "b", "new": "B"]), mode: .build)
        _ = await r.run(call("write_file", ["path": "novo.ts", "content": "do agente"]), mode: .build)
        _ = await r.run(call("write_file", ["path": "outro.ts", "content": "do agente"]), mode: .build)
        try escrever(root, "outro.ts", "editado pela pessoa")
        try escrever(root, "meu.ts", "da pessoa")

        let reaberto = CheckpointStore(root: root, host: host)
        #expect(reaberto.fim(cp.id) == nil)
        let v = try #require(reaberto.desfazer(cp.id))
        #expect(host.read("a.txt") == "a\nb\nc\n")
        #expect(!host.exists("novo.ts"))
        #expect(host.read("outro.ts") == "editado pela pessoa")
        #expect(host.read("meu.ts") == "da pessoa")
        #expect(v.voltaram == ["a.txt"] && v.apagados == ["novo.ts"] && v.mantidos == ["outro.ts"])
    }

    /// Parar no meio também é fim de turno: o que o turno fez fica separado do que vem depois.
    @Test func pararNoMeioAnotaOFim() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let p = FakeProvider([
            [.tools([call("write_file", ["path": "novo.ts", "content": "x"])]), .done],
            [.text("a"), .text("b"), .text("c"), .done],
        ])
        p.delay = .milliseconds(60)
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root), checkpoints: cs)
        let r = await runAll(loop, "cria", LoopConfig(mode: .build, permit: .full, model: "m")) { item, loop in
            if case .assistant = item {
                loop.stop()
            }
        }
        #expect(r.items.contains {
            if case let .error(_, t) = $0 {
                t == "parado"
            } else {
                false
            }
        })
        let cp = try #require(cs.last)
        let fim = try #require(cs.fim(cp.id), "parar no meio não anotou o fim do turno")
        #expect(fim.doTurno == ["novo.ts"])
        #expect(fim.assinaturas["a.txt"] != nil && fim.assinaturas["novo.ts"]?.resumo != nil)
        try escrever(root, "depois.ts", "da pessoa")
        let v = try #require(cs.desfazer(cp.id))
        #expect(!host.exists("novo.ts") && host.read("depois.ts") == "da pessoa")
        #expect(v.apagados == ["novo.ts"])
    }

    /// E o turno que termina normalmente, também.
    @Test func oTurnoQueTerminaAnotaOFim() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let p = FakeProvider([
            [.tools([call("str_replace", ["path": "a.txt", "old": "b", "new": "B"])]), .done],
            [.text("feito"), .done],
        ])
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root), checkpoints: cs)
        _ = await runAll(loop, "muda", LoopConfig(mode: .build, permit: .full, model: "m"))
        let cp = try #require(cs.last)
        #expect(cs.fim(cp.id)?.doTurno == ["a.txt"])
        // Fechado, o turno não recebe mais nada: escrever agora é da pessoa.
        cs.capturar("depois.ts")
        #expect(cs.last?.criados.isEmpty == true)
    }
}
