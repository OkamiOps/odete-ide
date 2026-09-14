import Foundation
@testable import OdeteAgent
import Synchronization
import Testing

/// Provedor com roteiro: cada turno devolve uma lista de eventos.
final class FakeProvider: Provider, @unchecked Sendable {
    let kind: ProviderKind = .openaiCompat
    let script = Mutex<[[StreamEvent]]>([])
    let turns = Mutex<[TurnRequest]>([])
    var delay: Duration = .zero
    init(_ s: [[StreamEvent]]) {
        script.withLock { $0 = s }
    }

    func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        turns.withLock { $0.append(turn) }
        let events = script.withLock { $0.isEmpty ? [.text("(sem roteiro)"), .done] : $0.removeFirst() }
        let d = delay
        return AsyncThrowingStream { cont in
            let t = Task {
                for e in events {
                    if d > .zero {
                        try? await Task.sleep(for: d)
                    }; if Task.isCancelled {
                        break
                    }; cont.yield(e)
                }
                cont.finish()
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    func models() async throws -> [ModelInfo] {
        [ModelInfo(id: "fake")]
    }
}

final class TestHost: FileToolHost, @unchecked Sendable {
    let shellLog = Mutex<[String]>([])
    override func runShell(_ command: String) async -> String {
        shellLog
            .withLock { $0.append(command) }; return "ok: \(command)"
    }

    override func terminalTail(_ n: Int) -> String {
        "linha 1\nlinha 2"
    }
}

func tmpProject() throws -> URL {
    let u = FileManager.default.temporaryDirectory.appending(
        path: "odete-agent-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: u.appending(path: "src"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: u.appending(path: "node_modules/x"), withIntermediateDirectories: true)
    try "a\nb\nc\n".write(to: u.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "export const x = 1;\n".write(to: u.appending(path: "src/x.ts"), atomically: true, encoding: .utf8)
    try "junk".write(to: u.appending(path: "node_modules/x/i.js"), atomically: true, encoding: .utf8)
    return u
}

func call(_ name: String, _ args: [String: Any], id: String = UUID().uuidString) -> ToolCall {
    ToolCall(
        id: id,
        name: name,
        arguments: String(decoding: try! JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    )
}

func runAll(
    _ loop: AgentLoop,
    _ text: String,
    _ cfg: LoopConfig,
    history: [AgentMessage] = [],
    onItem: (@Sendable (ChatItem, AgentLoop) -> Void)? = nil
) async -> (items: [ChatItem], history: [AgentMessage]) {
    var items: [String: ChatItem] = [:]
    var order: [String] = []
    var hist: [AgentMessage] = []
    for await e in loop.run(history: history, userText: text, config: cfg) {
        switch e {
        case let .item(i): if items[i.id] == nil {
                order.append(i.id)
            }; items[i.id] = i; onItem?(i, loop)
        case let .history(h): hist = h
        default: break
        }
    }
    return (order.compactMap { items[$0] }, hist)
}

@Suite(.serialized) struct ToolsTests {
    @Test func readListGrepTerminal() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let r = ToolRunner(host: host, patches: PatchStore(root: root))
        #expect(await r.run(call("read_file", ["path": "/a.txt"]), mode: .chat).text == "a\nb\nc\n")
        #expect(await r.run(call("read_file", ["path": "nope"]), mode: .chat).text == "não existe: nope")
        #expect(await r.run(call("list_dir", ["path": ""]), mode: .chat).text == "a.txt\nsrc/")
        #expect(await r.run(call("grep", ["pattern": "const"]), mode: .chat).text == "src/x.ts:1:export const x = 1;")
        #expect(await r.run(call("read_terminal", ["n": 5]), mode: .chat).text == "linha 1\nlinha 2")
        #expect(await r.run(ToolCall(id: "x", name: "grep", arguments: "{"), mode: .chat)
            .text == "argumentos JSON inválidos")
        #expect(host.allPaths() == ["a.txt", "src/x.ts"])
    }

    @Test func editsAndModes() async throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let patches = PatchStore(root: root)
        let r = ToolRunner(host: host, patches: patches)
        #expect(await r.run(call("str_replace", ["path": "a.txt", "old": "b", "new": "B"]), mode: .chat).text
            .contains("chat não edita"))
        #expect(await r.run(call("str_replace", ["path": "a.txt", "old": "z", "new": "B"]), mode: .build).text
            .contains("não encontrado"))
        #expect(await r.run(call("str_replace", ["path": "a.txt", "old": "\n", "new": "B"]), mode: .build).text
            .contains("vezes"))
        let out = await r.run(call("str_replace", ["path": "a.txt", "old": "b\n", "new": "B\n"]), mode: .build)
        #expect(out.text == "escrito a.txt" && out.patch?.path == "a.txt" && host.read("a.txt") == "a\nB\nc\n")
        #expect(await r.run(call("write_file", ["path": "src/y.ts", "content": "y"]), mode: .plan).text
            .contains("plan só escreve"))
        #expect(await r.run(call("write_file", ["path": ".odete/plan.md", "content": "# plano"]), mode: .plan)
            .text == "escrito .odete/plan.md")
        #expect(patches.pending.count == 1)
        #expect(await r.run(call("run_shell", ["command": "npm install"]), mode: .chat).text.contains("chat só lê"))
        #expect(await r.run(call("run_shell", ["command": "git status"]), mode: .chat).text == "ok: git status")
        #expect(await r.run(call("run_shell", ["command": "mkdir src/z"]), mode: .plan).text.contains(".odete/"))
        #expect(await r.run(call("run_shell", ["command": "mkdir -p .odete"]), mode: .plan)
            .text == "ok: mkdir -p .odete")
        #expect(await r.run(call("run_shell", ["command": "rm -rf ."]), mode: .build).text.contains("não é permitido"))
        #expect(await r.run(call("run_shell", ["command": "git push --force"]), mode: .build).text
            .contains("não é permitido"))
        #expect(await r.run(call("run_shell", ["command": "npm run dev"]), mode: .build).text == "ok: npm run dev")
    }
}

@Suite(.serialized) struct StoreTests {
    @Test func patches() throws {
        let root = try tmpProject()
        let ps = PatchStore(root: root)
        let p = ps.queue(path: "a.txt", before: "a\nb\nc\n", after: "a\nB\nc\n")
        try "a\nB\nc\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        #expect(p.hunks.count == 1 && p.additions == 1 && p.deletions == 1)
        // funde com o pendente do mesmo caminho
        let p2 = ps.queue(path: "a.txt", before: "a\nB\nc\n", after: "a\nB\nC\n")
        #expect(p2.id == p.id && p2.before == "a\nb\nc\n" && ps.pending.count == 1)
        try "a\nB\nC\n".write(to: root.appending(path: "a.txt"), atomically: true, encoding: .utf8)
        ps.reject(p.id)
        let rejected = try String(contentsOf: root.appending(path: "a.txt"), encoding: .utf8)
        #expect(rejected == "a\nb\nc\n" && ps.pending.isEmpty)
        // persistência
        let q = ps.queue(path: "n.txt", before: "", after: "novo\n")
        try "novo\n".write(to: root.appending(path: "n.txt"), atomically: true, encoding: .utf8)
        #expect(PatchStore(root: root).pending.map(\.id) == [q.id])
        ps.undo(q.id)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "n.txt").path))
        // aceitar por hunk
        let before = (1 ... 20).map(String.init).joined(separator: "\n")
        let after = before.replacingOccurrences(of: "\n2\n", with: "\ndois\n").replacingOccurrences(
            of: "19",
            with: "dezenove"
        )
        try before.write(to: root.appending(path: "h.txt"), atomically: true, encoding: .utf8)
        let h = ps.queue(path: "h.txt", before: before, after: after)
        try after.write(to: root.appending(path: "h.txt"), atomically: true, encoding: .utf8)
        #expect(h.hunks.count == 2)
        ps.acceptHunk(h.id, index: 0)
        let mid = try String(contentsOf: root.appending(path: "h.txt"), encoding: .utf8)
        #expect(mid.contains("dois") && mid.contains("19") && !mid.contains("dezenove") && ps.get(h.id)?
            .status == .pending)
        ps.acceptHunk(h.id, index: 0)
        let final = try String(contentsOf: root.appending(path: "h.txt"), encoding: .utf8)
        #expect(ps.get(h.id)?.status == .accepted && final == after)
    }

    @Test func checkpoints() throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let cs = CheckpointStore(root: root, host: host)
        let cp = cs.take(title: "antes")
        #expect(cp.saved == ["a.txt", "src/x.ts"] && cs.list().count == 1)
        try host.write("a.txt", "mudado")
        try host.write("novo.txt", "x")
        try FileManager.default.removeItem(at: root.appending(path: "src/x.ts"))
        #expect(cs.restore(cp.id) == "voltou: antes")
        #expect(host.read("a.txt") == "a\nb\nc\n" && host.read("src/x.ts") == "export const x = 1;\n" && !host
            .exists("novo.txt"))
        cs.limit = 2
        cs.take(title: "1"); cs.take(title: "2"); cs.take(title: "3")
        #expect(cs.list().count == 2 && cs.last?.title == "3")
    }

    @Test func chats() throws {
        let root = try tmpProject()
        let store = ChatStore(root: root)
        var t = ChatThread.blank()
        t.items = [
            .user(
                id: "1",
                text: "  cria um  botão bem grande com muitas palavras para testar o corte do título aqui ",
                images: nil
            ),
            .think(id: "2", text: String(repeating: "x", count: 9000), live: true),
        ]
        store.save(t)
        let back = try #require(store.list().first)
        #expect(back.title.count == 49 && back.title.hasSuffix("…"))
        if case let .think(_, text, live) = back.items[1] {
            #expect(text.count == 8000 && !live)
        } else {
            Issue.record("think")
        }
        store.remove(t.id)
        #expect(store.list().isEmpty)
    }

    @Test func contextRulesSkillsMentions() throws {
        let root = try tmpProject()
        let host = TestHost(root: root)
        try host.write("AGENTS.md", "Use tabs.")
        try host.write(
            ".odete/skills/deploy.md",
            "---\nname: Deploy\ndescription: sobe pro ar\n---\nRode npm run build."
        )
        #expect(Rules.prompt(host: host).contains("## AGENTS.md\nUse tabs."))
        let all = Skills.all(host: host)
        #expect(all.first?.id == "deploy" && all.count == 5)
        #expect(Skills.prompt(all: all, userText: "faz /deploy agora").contains("Rode npm run build.") && Skills.prompt(
            all: all,
            userText: "oi"
        ).hasPrefix("Skills via /nome"))
        #expect(Mentions.expand("olha @a.txt e @nada.md", host: host).contains("Arquivo `a.txt`:\n```\na\nb\nc\n\n```"))
    }
}

@Suite(.serialized) struct LoopTests {
    func make(_ script: [[StreamEvent]]) throws -> (AgentLoop, TestHost, FakeProvider, PatchStore) {
        let root = try tmpProject()
        let host = TestHost(root: root)
        let patches = PatchStore(root: root)
        let p = FakeProvider(script)
        return (
            AgentLoop(provider: p, host: host, patches: patches, checkpoints: CheckpointStore(root: root, host: host)),
            host,
            p,
            patches
        )
    }

    @Test func textOnly() async throws {
        let (loop, _, p, _) = try make([[
            .think("hm"),
            .text("Oi"),
            .text("!"),
            .usage(TokenUse(input: 10, output: 2)),
            .done,
        ]])
        let r = await runAll(loop, "olá @a.txt", LoopConfig(mode: .chat, permit: .auto, model: "m"))
        #expect(r.items.count == 3)
        if case let .assistant(_, t) = r.items[2] {
            #expect(t == "Oi!")
        } else {
            Issue.record("assistant")
        }
        #expect(r.history.count == 2 && r.history[0].content.contains("Arquivo `a.txt`") && r.history[1]
            .content == "Oi!")
        let turn = p.turns.withLock { $0[0] }
        #expect(turn.system.contains("Modo CHAT") && turn.system.contains("a.txt\nsrc/x.ts") && turn.tools.map(\.name)
            .contains("run_shell") && !turn.tools.map(\.name).contains("write_file"))
    }

    @Test func toolsThenAnswerWithPatch() async throws {
        let (loop, host, p, patches) = try make([
            [
                .tools([
                    call("read_file", ["path": "a.txt"], id: "c1"),
                    call("str_replace", ["path": "a.txt", "old": "b", "new": "B"], id: "c2"),
                ]),
                .done,
            ],
            [.text("Feito."), .done],
        ])
        let r = await runAll(loop, "muda b", LoopConfig(mode: .build, permit: .full, model: "m"))
        #expect(r.items
            .contains {
                if case let .tool(_, n, d) = $0 {
                    n == "read_file" && d == "a.txt"
                } else {
                    false
                }
            })
        #expect(r.items.contains {
            if case .patch = $0 {
                true
            } else {
                false
            }
        } && patches.pending.count == 1 && host
            .read("a.txt") == "a\nB\nc\n")
        let t2 = p.turns.withLock { $0[1] }
        #expect(t2.messages.filter { $0.role == .tool }.count == 2 && t2.messages.filter { $0.role == .tool }[0]
            .content == "a\nb\nc\n")
        #expect(r.history.last?.content == "Feito." && CheckpointStore(root: host.root, host: host).list().count == 1)
    }

    @Test func permitDenied() async throws {
        let (loop, host, _, _) = try make([
            [.tools([call("write_file", ["path": "z.txt", "content": "z"], id: "w1")]), .done],
            [.text("ok"), .done],
        ])
        let r = await runAll(loop, "cria z", LoopConfig(mode: .build, permit: .auto, model: "m")) { item, loop in
            if case let .permit(id, _, _, .pending) = item {
                loop.approve(id, false)
            }
        }
        #expect(!host.exists("z.txt"))
        #expect(r.items.contains {
            if case .permit(_, _, _, .no) = $0 {
                true
            } else {
                false
            }
        })
        #expect(r.history.contains { $0.role == .tool && $0.content == "usuário recusou esta ação" })
    }

    @Test func roundCapAndStop() async throws {
        var script: [[StreamEvent]] = []
        for _ in 0 ..< 9 {
            script.append([.tools([call("list_dir", ["path": ""])]), .done])
        }
        let (loop, _, p, _) = try make(script)
        let r = await runAll(loop, "loop", LoopConfig(mode: .chat, permit: .full, model: "m"))
        #expect(p.turns.withLock { $0.count } == 8)
        #expect(r.items.contains {
            if case let .error(_, t) = $0 {
                t.contains("8 rodadas")
            } else {
                false
            }
        })
        let (loop2, _, p2, _) = try make([[.text("a"), .text("b"), .text("c"), .done]])
        p2.delay = .milliseconds(100)
        let r2 = await runAll(loop2, "x", LoopConfig(mode: .chat, permit: .full, model: "m")) { item, loop in
            if case .assistant = item {
                loop.stop()
            }
        }
        #expect(r2.items.contains {
            if case let .error(_, t) = $0 {
                t == "parado"
            } else {
                false
            }
        })
        #expect(p2.turns.withLock { $0.count } == 1)
    }

    @Test func steerRedirects() async throws {
        let (loop, _, p, _) = try make([
            [.text("primeiro "), .text("plano"), .done],
            [.text("mudei o rumo"), .done],
        ])
        p.delay = .milliseconds(80)
        let r = await runAll(loop, "faz A", LoopConfig(mode: .chat, permit: .full, model: "m")) { item, loop in
            if case let .assistant(_, t) = item, t == "primeiro " {
                loop.steer("faz B")
            }
        }
        #expect(p.turns.withLock { $0.count } == 2)
        let second = p.turns.withLock { $0[1] }
        #expect(second.messages.last?.content.contains("Redireciona a execução agora") == true && second.messages.last?
            .content.contains("faz B") == true)
        #expect(r.history.last?.content == "mudei o rumo")
        #expect(r.items.filter {
            if case .user = $0 {
                true
            } else {
                false
            }
        }.count == 2)
    }
}
