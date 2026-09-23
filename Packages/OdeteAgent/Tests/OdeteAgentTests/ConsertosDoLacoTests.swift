import Foundation
@testable import OdeteAgent
import OdeteI18n
import Synchronization
import Testing

/// Cada teste aqui reproduz um defeito achado no laço e nas ferramentas — falhava antes
/// da correção e passa depois.
@Suite(.serialized) struct FreioDeRepeticaoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    /// Editar → testar → editar → testar é o ciclo normal. O freio contava cada `npm test`
    /// como a mesma chamada, e no quarto o teste nem rodava: voltava "Pare de ler".
    @Test func rodarOTesteVariasVezesNaoEhRepeticao() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        var roteiro: [[StreamEvent]] = []
        for i in 0 ..< 6 {
            roteiro.append([.tools([call("str_replace", ["path": "a.txt", "old": i == 0 ? "b" : "B\(i - 1)",
                                                         "new": "B\(i)"])]), .done])
            roteiro.append([.tools([call("run_shell", ["command": "npm test"])]), .done])
        }
        roteiro.append([.text("pronto"), .done])
        let loop = AgentLoop(provider: FakeProvider(roteiro), host: host, patches: PatchStore(root: root))
        let r = await runAll(loop, "conserta até passar", LoopConfig(mode: .build, permit: .full, model: "m"))
        #expect(host.shellLog.withLock { $0.count } == 6, "o freio impediu o teste de rodar")
        #expect(!r.history.contains { $0.role == .tool && $0.content.contains("Pare de ler") })
    }

    /// Reler o arquivo depois de editar devolve outra coisa: não é repetição.
    @Test func relerDepoisDeEditarNaoEhBloqueado() async throws {
        let root = try tmpProject()
        let ler = [StreamEvent.tools([call("read_file", ["path": "a.txt"])]), .done]
        let roteiro: [[StreamEvent]] = [
            ler, ler, ler,
            [.tools([call("str_replace", ["path": "a.txt", "old": "b", "new": "B"])]), .done],
            ler,
            [.text("pronto"), .done],
        ]
        let loop = AgentLoop(
            provider: FakeProvider(roteiro),
            host: TestHost(root: root),
            patches: PatchStore(root: root)
        )
        let r = await runAll(loop, "muda b", LoopConfig(mode: .build, permit: .full, model: "m"))
        let resultados = r.history.filter { $0.role == .tool }.map(\.content)
        #expect(resultados.last == "a\nB\nc\n", "a releitura depois da edição foi bloqueada: \(resultados.last ?? "")")
    }

    /// O mesmo arquivo, sem mudança, quatro vezes: aí sim o aviso.
    @Test func mesmoResultadoQuatroVezesAindaAvisa() async throws {
        let root = try tmpProject()
        let ler = [StreamEvent.tools([call("read_file", ["path": "a.txt"])]), .done]
        let loop = AgentLoop(
            provider: FakeProvider([ler, ler, ler, ler, [.text("ok"), .done]]),
            host: TestHost(root: root),
            patches: PatchStore(root: root)
        )
        let r = await runAll(loop, "lê", LoopConfig(mode: .chat, permit: .full, model: "m"))
        #expect(r.history.filter { $0.role == .tool }.last?.content.contains("Não repita") == true)
    }

    /// Desistir fechava o turno com um `return`: sem os resultados das chamadas, sem
    /// gravar o histórico e sem `.done`. A conversa guardada terminava numa chamada sem
    /// resposta, e toda mensagem seguinte recebia 400.
    @Test func desistirFechaAConversaEAvisaQueAcabou() async throws {
        let root = try tmpProject()
        let rodada: [StreamEvent] = [
            .tools([
                ToolCall(id: UUID().uuidString, name: "read_file", arguments: #"{"path":"a.txt"}"#),
                ToolCall(id: UUID().uuidString, name: "list_dir", arguments: #"{"path":"src"}"#),
            ]),
            .done,
        ]
        let p = FakeProvider(Array(repeating: rodada, count: 40))
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        var historia: [AgentMessage] = []
        var terminou = false
        for await e in loop.run(
            history: [],
            userText: "lê",
            config: LoopConfig(mode: .build, permit: .full, model: "m")
        ) {
            switch e {
            case let .history(h): historia = h
            case .done: terminou = true
            default: break
            }
        }
        #expect(terminou, "o turno acabou sem .done")
        #expect(Transcricao.fecha(historia), "a conversa gravada terminou numa chamada sem resultado")
        #expect(historia.last?.role == .tool)
    }
}

@Suite(.serialized) struct TranscricaoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    /// Resultado órfão sai; chamada sem resultado ganha um.
    @Test func consertaOsPares() {
        let quebrada: [AgentMessage] = [
            .tool("velha", "resultado de uma chamada que ficou de fora do corte"),
            .user("oi"),
            AgentMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "c1", name: "read_file", arguments: "{}"),
                ToolCall(id: "c2", name: "list_dir", arguments: "{}"),
            ]),
            .tool("c1", "um"),
            .user("e agora?"),
        ]
        let ok = Transcricao.consertar(quebrada)
        #expect(ok.map(\.role) == [.user, .assistant, .tool, .tool, .user])
        #expect(ok[3].toolCallId == "c2" && ok[3].content.contains("cancelado"))
        #expect(Transcricao.fecha(ok) && !Transcricao.fecha(quebrada))
        // Conversa que já fecha sai igual.
        #expect(Transcricao.consertar(ok) == ok)
    }

    /// Uma conversa antiga, gravada quebrada, não chega quebrada ao provedor.
    @Test func conversaGravadaQuebradaVaiConsertada() async throws {
        let root = try tmpProject()
        let p = FakeProvider([[.text("ok"), .done]])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        let quebrada: [AgentMessage] = [
            .user("lê"),
            AgentMessage(
                role: .assistant,
                content: "",
                toolCalls: [ToolCall(id: "x", name: "read_file", arguments: "{}")]
            ),
        ]
        _ = await runAll(loop, "e aí?", LoopConfig(mode: .chat, permit: .full, model: "m"), history: quebrada)
        let enviado = try #require(p.turns.withLock { $0.first })
        #expect(Transcricao.fecha(enviado.messages), "o provedor recebeu a chamada sem resultado")
    }

    /// O corte do `ChatStore` começava a conversa num resultado de ferramenta.
    @Test func conversaGuardadaNaoComecaNumResultadoOrfao() throws {
        let root = try tmpProject()
        let store = ChatStore(root: root)
        var t = ChatThread.blank()
        var ms: [AgentMessage] = [.user("começo")]
        for i in 0 ..< 1600 {
            ms.append(AgentMessage(role: .assistant, content: "", toolCalls: [
                ToolCall(id: "\(i)", name: "read_file", arguments: "{}"),
            ]))
            ms.append(.tool("\(i)", "r\(i)"))
            if i % 50 == 0 {
                ms.append(.user("mais \(i)"))
            }
        }
        t.messages = ms
        t.items = [.user(id: "1", text: "começo", images: nil)]
        store.save(t)
        let lida = try #require(store.load(t.id))
        #expect(
            lida.messages.first?.role == .user,
            "a conversa guardada começa num \(lida.messages.first?.role.rawValue ?? "")"
        )
        #expect(Transcricao.fecha(lida.messages))
        #expect(lida.messages.count <= ChatStore.mensagensGuardadas)
    }

    /// A nota do desfazer (ou um pedido que morreu num erro) segue junto com o pedido
    /// novo, numa mensagem só.
    @Test func mensagemSemRespostaSegueComOPedidoNovo() async throws {
        let root = try tmpProject()
        let p = FakeProvider([[.text("ok"), .done]])
        let loop = AgentLoop(provider: p, host: TestHost(root: root), patches: PatchStore(root: root))
        let antes: [AgentMessage] = [
            .user("pinta de azul"), AgentMessage(role: .assistant, content: "pintei"),
            .user("Nota da Odete: a pessoa desfez o seu último turno."),
        ]
        _ = await runAll(loop, "agora de verde", LoopConfig(mode: .chat, permit: .full, model: "m"), history: antes)
        let enviado = try #require(p.turns.withLock { $0.first })
        let ultima = try #require(enviado.messages.last)
        #expect(ultima.role == .user && ultima.content.contains("desfez") && ultima.content.contains("agora de verde"))
        #expect(enviado.messages.filter { $0.role == .user }.count == 2, "duas mensagens seguidas da pessoa")
    }
}

/// `isReadShell` dividia a linha só no `|`.
struct LeituraDoShellTests {
    @Test func oQueEscreveNaoPassaPorLeitura() {
        let escrevem = [
            "ls && rm -rf src", "echo x > f", "echo x >> f", "cat a >b", "git branch -D main", "git branch nova",
            "find . -delete", "find . -name '*.log' -exec rm {} ;", "ls; rm a", "ls || touch a", "env rm a",
            "git stash", "git remote add o url", "echo $(rm a)", "echo `rm a`", "ls\nrm a", "npm test",
            "git checkout main", "git diff --output=x", "tail -n 1 a | tee b",
        ]
        for c in escrevem {
            #expect(!Tools.isReadShell(c), "\(c) passou como leitura")
        }
    }

    @Test func oQueSoLeContinuaLiberado() {
        let leem = [
            "ls", "ls -la src | grep ts", "git status && git log --oneline -5", "cat a 2>/dev/null",
            "ls 2>&1 | head", "git branch", "git branch -a", "git stash list", "env", "echo 'a > b'",
            "find . -name '*.ts'", "git --no-pager log", "npm run", "node -v", "cd src && ls", "git remote -v",
        ]
        for c in leem {
            #expect(Tools.isReadShell(c), "\(c) deixou de ser leitura")
        }
    }

    /// No Plan, `mkdir .odete && rm -rf src` passava inteiro: bastava começar com mkdir.
    @Test func planNaoRodaOQueVemDepoisDoMkdir() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let r = ToolRunner(host: host, patches: PatchStore(root: root))
        let saida = await r.run(call("run_shell", ["command": "mkdir .odete && rm -rf src"]), mode: .plan)
        #expect(saida.text.contains("plan"), "\(saida.text)")
        #expect(host.shellLog.withLock { $0 }.isEmpty, "o Plan rodou o rm")
        #expect(await r.run(call("run_shell", ["command": "mkdir -p .odete/notas"]), mode: .plan).text
            == "ok: mkdir -p .odete/notas")
        #expect(await r.run(call("run_shell", ["command": "echo x > f"]), mode: .chat).text.contains("chat só lê"))
    }

    /// No Build a janela do checkpoint abre sempre: o que a leitura deixasse passar ficava
    /// fora do desfazer.
    @Test func noBuildODesfazerVoltaOQueUmComandoComCaraDeLeituraApagou() async throws {
        Texto.escolher(.ptBR)
        let root = try tmpProject()
        // Grande demais para o retrato do começo: só a cópia na escrita o salva.
        let grande = String(repeating: "linha que ninguém pode perder\n", count: 12000)
        try grande.write(to: root.appending(path: "grande.txt"), atomically: true, encoding: .utf8)
        let host = ShellEmSegmentos(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let r = ToolRunner(host: host, patches: PatchStore(root: root), checkpoints: cs)
        let cp = cs.take(title: "turno")
        _ = await r.run(call("run_shell", ["command": "ls && rm grande.txt"]), mode: .build)
        cs.encerrar()
        #expect(!host.exists("grande.txt"))
        _ = cs.restore(cp.id)
        #expect(host.read("grande.txt") == grande, "o desfazer não trouxe de volta o que o shell apagou")
    }
}

/// Shell de teste que entende `&&` e faz `rm` de verdade.
final class ShellEmSegmentos: FileToolHost, @unchecked Sendable {
    override func runShell(_ command: String) async -> String {
        for seg in command.components(separatedBy: "&&") {
            let partes = seg.split(separator: " ").map(String.init)
            if partes.first == "rm" {
                for p in partes.dropFirst() where !p.hasPrefix("-") {
                    try? FileManager.default.removeItem(at: root.appending(path: p))
                }
            }
        }
        return "ok"
    }
}

/// As ferramentas não saem do projeto.
@Suite(.serialized) struct CaminhosForaDoProjetoTests {
    func vizinhos() throws -> (raiz: URL, fora: URL) {
        let base = FileManager.default.temporaryDirectory.appending(path: "odete-vizinhos-\(UUID().uuidString)")
        let raiz = base.appending(path: "meu-app")
        let vizinho = base.appending(path: "meu-app-2")
        try FileManager.default.createDirectory(at: raiz, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vizinho, withIntermediateDirectories: true)
        try "SEGREDO=1\n".write(to: vizinho.appending(path: ".env"), atomically: true, encoding: .utf8)
        try "oi\n".write(to: raiz.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        // Um link dentro do projeto apontando para fora dele.
        try FileManager.default.createSymbolicLink(
            at: raiz.appending(path: "atalho"),
            withDestinationURL: vizinho.appending(path: ".env")
        )
        try FileManager.default.createSymbolicLink(at: raiz.appending(path: "pasta-fora"), withDestinationURL: vizinho)
        return (raiz, vizinho)
    }

    /// `inside` comparava o prefixo sem a barra: `…/meu-app-2` começa com `…/meu-app`.
    @Test func irmaoComOMesmoComecoNaoEhDentro() throws {
        let (raiz, _) = try vizinhos()
        let host = FileToolHost(root: raiz)
        #expect(host.read("../meu-app-2/.env") == nil, "leu o .env do projeto vizinho")
        #expect(!host.exists("../meu-app-2/.env"))
        #expect(host.list("..").isEmpty, "listou a pasta de cima do projeto")
        #expect(host.tamanho("../meu-app-2/.env") == nil)
        #expect(throws: (any Error).self) { try host.write("../meu-app-2/.env", "x") }
        #expect(host.read("a.txt") == "oi\n" && host.list("").contains("a.txt"))
    }

    /// Link simbólico era seguido para fora.
    @Test func linkParaForaNaoEhSeguido() throws {
        let (raiz, fora) = try vizinhos()
        let host = FileToolHost(root: raiz)
        #expect(host.read("atalho") == nil, "leu pelo link o arquivo de fora")
        #expect(host.read("pasta-fora/.env") == nil)
        #expect(host.list("pasta-fora").isEmpty)
        #expect(throws: (any Error).self) { try host.write("pasta-fora/novo.txt", "x") }
        #expect(!FileManager.default.fileExists(atPath: fora.appending(path: "novo.txt").path))
        #expect(!host.grep("SEGREDO", in: nil).contains("SEGREDO"))
    }

    /// E nas @menções, que leem pelo mesmo `read`.
    @Test func mencaoNaoPuxaArquivoDeFora() throws {
        let (raiz, _) = try vizinhos()
        let host = FileToolHost(root: raiz)
        let texto = Mentions.expand("olha @../meu-app-2/.env e @atalho e @a.txt", host: host)
        #expect(!texto.contains("SEGREDO"), "a menção trouxe o arquivo de fora")
        #expect(texto.contains("Arquivo `a.txt`"))
    }

    /// As ferramentas, de ponta a ponta.
    @Test func ferramentasRecusamCaminhoDeFora() async throws {
        let (raiz, _) = try vizinhos()
        let host = TestHost(root: raiz)
        let r = ToolRunner(host: host, patches: PatchStore(root: raiz))
        #expect(await r.run(call("read_file", ["path": "../meu-app-2/.env"]), mode: .chat).text.hasPrefix("não existe"))
        #expect(await r.run(call("list_dir", ["path": ".."]), mode: .chat).text == "(vazio)")
        #expect(await !r.run(call("read_file", ["path": "atalho"]), mode: .chat).text.contains("SEGREDO"))
    }
}

/// Parar interrompe a ferramenta que está rodando.
@Suite(.serialized) struct PararAFerramentaTests {
    /// Shell que só volta quando é cancelado (ou em dez segundos).
    final class ShellQueEspera: FileToolHost, @unchecked Sendable {
        let comecou = Mutex(false)
        let viuCancelar = Mutex(false)
        override func runShell(_: String) async -> String {
            comecou.withLock { $0 = true }
            for _ in 0 ..< 200 {
                if Task.isCancelled {
                    viuCancelar.withLock { $0 = true }
                    return "interrompido"
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return "terminou sozinho"
        }
    }

    @Test func pararNoMeioDoComandoNaoEsperaEleAcabar() async throws {
        Texto.escolher(.ptBR)
        let root = try tmpProject()
        let host = ShellQueEspera(root: root)
        let p = FakeProvider([[.tools([call("run_shell", ["command": "npm run build"])]), .done], [.text("x"), .done]])
        let loop = AgentLoop(provider: p, host: host, patches: PatchStore(root: root))
        let inicio = ContinuousClock.now
        let turno = Task { await runAll(loop, "builda", LoopConfig(mode: .build, permit: .full, model: "m")) }
        while !host.comecou.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        loop.stop()
        let r = await turno.value
        #expect(ContinuousClock.now - inicio < .seconds(5), "o parar esperou o comando terminar")
        #expect(host.viuCancelar.withLock { $0 }, "o comando não soube que devia parar")
        #expect(Transcricao.fecha(r.history))
    }
}

/// Patches: sem teto, textos em arquivos, e nada de perder o que a pessoa escreveu.
@Suite(.serialized) struct PatchesTests {
    init() {
        Texto.escolher(.ptBR)
    }

    func escrever(_ root: URL, _ p: String, _ t: String) throws {
        try t.write(to: root.appending(path: p), atomically: true, encoding: .utf8)
    }

    func ler(_ root: URL, _ p: String) -> String? {
        try? String(contentsOf: root.appending(path: p), encoding: .utf8)
    }

    /// Só doze pendentes sobreviviam na memória, e só os menores de 80 mil caracteres no
    /// disco: o resto sumia da barra, e "Rejeitar tudo" não voltava.
    @Test func vintePendentesEUmGrandeSobrevivemAoReabrir() throws {
        let root = try tmpProject()
        let ps = PatchStore(root: root)
        for i in 0 ..< 20 {
            ps.queue(path: "f\(i).txt", before: "antes \(i)\n", after: "depois \(i)\n")
        }
        let grande = String(repeating: "x", count: 120_000)
        ps.queue(path: "grande.txt", before: "", after: grande, criado: true)
        #expect(ps.pending.count == 21)
        let reaberto = PatchStore(root: root)
        #expect(reaberto.pending.count == 21, "patches pendentes sumiram ao reabrir")
        #expect(reaberto.pending(for: "grande.txt")?.after == grande)
        // O JSON não carrega mais os textos.
        let json = try Data(contentsOf: root.appending(path: ".odete/patches.json"))
        #expect(json.count < 20000)
    }

    /// `acceptHunk` gravava `antes + hunk` por cima do arquivo: a edição da pessoa sumia.
    @Test func aceitarHunkNaoApagaAEdicaoDaPessoa() throws {
        let root = try tmpProject()
        let ps = PatchStore(root: root)
        let antes = (1 ... 20).map(String.init).joined(separator: "\n")
        let depois = antes.replacingOccurrences(of: "\n2\n", with: "\ndois\n")
            .replacingOccurrences(of: "19", with: "dezenove")
        let p = ps.queue(path: "h.txt", before: antes, after: depois)
        let daPessoa = depois.replacingOccurrences(of: "10", with: "dez, escrito pela pessoa")
        try escrever(root, "h.txt", daPessoa)
        ps.acceptHunk(p.id, index: 0)
        #expect(ler(root, "h.txt") == daPessoa, "aceitar um hunk apagou a edição da pessoa")
    }

    /// Rejeitar num arquivo que não é UTF-8 apagava o arquivo: o `antes` virava "".
    @Test func arquivoNaoUTF8NaoEhApagado() async throws {
        let root = try tmpProject()
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) // "café\n" em latin-1
        try latin1.write(to: root.appending(path: "velho.txt"))
        let host = TestHost(root: root)
        let ps = PatchStore(root: root)
        let r = ToolRunner(host: host, patches: ps)
        let out = await r.run(call("write_file", ["path": "velho.txt", "content": "novo\n"]), mode: .build)
        #expect(out.patch == nil && out.text.contains("UTF-8"), "\(out.text)")
        #expect(try Data(contentsOf: root.appending(path: "velho.txt")) == latin1)
        // E um patch de antes desta versão (antes vazio) sobre um arquivo que não é texto
        // não apaga nada: é conflito, e quem decide é a pessoa.
        let antigo = Patch(id: "v", path: "velho.txt", before: "", after: "", orig: "", status: .pending, at: .now)
        let legado = try JSONEncoder.iso([antigo])
        try FileManager.default.createDirectory(at: root.appending(path: ".odete"), withIntermediateDirectories: true)
        try legado.write(to: root.appending(path: ".odete/patches.json"))
        let reaberto = PatchStore(root: root)
        #expect(reaberto.reject("v") == .conflito)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "velho.txt").path))
    }

    /// Rejeitar com o arquivo mudado depois marcava "rejeitado" sem voltar e sem avisar.
    @Test func rejeitarDepoisDeAPessoaMexerAvisaENaoMexe() throws {
        let root = try tmpProject()
        let ps = PatchStore(root: root)
        let p = ps.queue(path: "a.txt", before: "a\nb\nc\n", after: "a\nB\nc\n")
        try escrever(root, "a.txt", "a\nB\nc\nlinha da pessoa\n")
        #expect(ps.reject(p.id) == .conflito)
        #expect(ps.get(p.id)?.status == .pending, "o patch sumiu sem voltar nada")
        #expect(ler(root, "a.txt") == "a\nB\nc\nlinha da pessoa\n")
        #expect(ps.rejectAll().map(\.id) == [p.id])
        ps.reject(p.id, forcar: true)
        #expect(ler(root, "a.txt") == "a\nb\nc\n" && ps.get(p.id)?.status == .rejected)
        // Sem mudança depois, volta sozinho, como sempre.
        let q = ps.queue(path: "n.txt", before: "", after: "novo\n", criado: true)
        try escrever(root, "n.txt", "novo\n")
        #expect(ps.reject(q.id) == .voltou && ler(root, "n.txt") == nil)
    }
}

/// O que entra na conversa tem teto — e o teto guarda o começo e o fim.
@Suite(.serialized) struct TetoDeContextoTests {
    init() {
        Texto.escolher(.ptBR)
    }

    /// Resultado de ferramenta ia até 200 mil caracteres, cortando o fim — onde mora o erro.
    @Test func resultadoGrandeGuardaComecoEFim() {
        let meio = String(repeating: "npm WARN barulho\n", count: 8000)
        let saida = "COMEÇO\n" + meio + "ERRO NO FIM\n"
        let cortado = ToolRunner.clip(saida)
        #expect(cortado.count <= ToolRunner.tetoDoResultado + 200)
        #expect(cortado.hasPrefix("COMEÇO") && cortado.contains("ERRO NO FIM") && cortado.contains("omitidos"))
        #expect(ToolRunner.clip("curto") == "curto")
    }

    /// `read_file` com `offset`/`limit`, e arquivo longo vem em partes com o rodapé.
    @Test func lerPorPartes() async throws {
        let root = try tmpProject()
        let texto = (1 ... 5000).map { "linha \($0)" }.joined(separator: "\n")
        try texto.write(to: root.appending(path: "longo.txt"), atomically: true, encoding: .utf8)
        let r = ToolRunner(host: TestHost(root: root), patches: PatchStore(root: root))
        let primeira = await r.run(call("read_file", ["path": "longo.txt"]), mode: .chat).text
        #expect(primeira.hasPrefix("linha 1\n") && primeira.contains("offset=") && !primeira.contains("linha 4999"))
        let parte = await r.run(call("read_file", ["path": "longo.txt", "offset": 4001, "limit": 3]), mode: .chat).text
        #expect(parte.hasPrefix("linha 4001\nlinha 4002\nlinha 4003\n"))
        #expect(parte.contains("offset=4004"))
        // Arquivo pequeno volta byte a byte, sem rodapé: é dele que o str_replace copia.
        #expect(await r.run(call("read_file", ["path": "a.txt"]), mode: .chat).text == "a\nb\nc\n")
    }

    /// O grep lia binário e arquivo enorme inteiros.
    @Test func grepPulaBinarioEArquivoEnorme() throws {
        let root = try tmpProject()
        var binario = Data("agulha".utf8)
        binario.append(contentsOf: [0, 1, 2, 0])
        try binario.write(to: root.appending(path: "img.bin"))
        let enorme = String(repeating: "palha\n", count: 400_000) + "agulha\n"
        try enorme.write(to: root.appending(path: "enorme.txt"), atomically: true, encoding: .utf8)
        try "agulha aqui\n".write(to: root.appending(path: "ok.txt"), atomically: true, encoding: .utf8)
        let achados = FileToolHost(root: root).grep("agulha", in: nil)
        #expect(achados.contains("ok.txt:1:agulha aqui"))
        #expect(!achados.contains("img.bin") && !achados.contains("enorme.txt"), "\(achados)")
    }
}

extension JSONEncoder {
    /// Codifica como o `PatchStore` de antes gravava: datas em ISO 8601.
    static func iso(_ valor: some Encodable) throws -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(valor)
    }
}
