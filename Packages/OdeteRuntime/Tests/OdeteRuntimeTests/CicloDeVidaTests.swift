import Foundation
import JavaScriptCore
@testable import OdeteRuntime
import Testing

/// Prende-se ao closure de saída para o teste saber quando ele foi solto.
private final class Sentinela: Sendable {}

struct CicloDeVidaTests {
    /// Espera (por padrão até ~2 s) a condição virar verdade: a última referência sai num bloco
    /// da fila do runtime logo depois que `run` devolve.
    private func espera(ate vezes: Int = 200, _ cond: () -> Bool) async throws {
        for _ in 0 ..< vezes where !cond() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Roda `codigo` e confere que runtime, contexto JS e closure de saída foram soltos, mesmo
    /// com o `JSProcess` ainda vivo (como fica quem o guarda numa lista de jobs).
    private func confereQueSolta(_ codigo: String, matar: Bool = false) async throws {
        weak var runtime: JSRuntime?
        weak var contexto: JSContext?
        weak var sentinela: Sentinela?
        let p: JSProcess
        do {
            let s = Sentinela()
            sentinela = s
            p = try JSProcess(cwd: tmp(), output: { _, _ in _ = s })
            runtime = p.rt
            contexto = p.rt?.context
        }
        #expect(runtime != nil && contexto != nil && sentinela != nil)
        let tarefa = Task { await p.run(code: codigo) }
        if matar {
            for _ in 0 ..< 100 where p.ports.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!p.ports.isEmpty)
            p.kill()
        }
        _ = await tarefa.value
        try await espera { runtime == nil && contexto == nil && sentinela == nil }
        #expect(p.rt == nil)
        #expect(runtime == nil, "o JSRuntime ficou vivo")
        #expect(contexto == nil, "o JSContext ficou vivo")
        #expect(sentinela == nil, "o closure de saída ficou vivo")
    }

    @Test func processoTrivialSoltaORuntime() async throws {
        try await confereQueSolta("console.log('oi')")
    }

    @Test func processoComTimersEServidorSoltaORuntime() async throws {
        try await confereQueSolta("""
        setTimeout(() => {}, 5); const iv = setInterval(() => clearInterval(iv), 1);
        const srv = require("http").createServer((q, s) => s.end("x"));
        srv.listen(0, async () => { await (await fetch(`http://127.0.0.1:${srv.address().port}/`)).text(); srv.close(); });
        """)
    }

    @Test func processoMortoComServidorSoltaORuntime() async throws {
        try await confereQueSolta("require('http').createServer((q, s) => s.end('x')).listen(0);", matar: true)
    }

    @Test func intervaloComPisoDeUmMsEOrdem() async throws {
        let (code, c) = try await run("""
        const ordem = [];
        setTimeout(() => ordem.push("a5"), 5);
        setTimeout(() => ordem.push("b5"), 5);
        setTimeout(() => ordem.push("c1"), 1);
        setImmediate(() => { ordem.push("i1"); setImmediate(() => ordem.push("i3")); });
        setTimeout(() => ordem.push("e0"), 0);
        setTimeout(() => ordem.push("neg"), -10);
        setTimeout(() => ordem.push("nan"), "abc");
        setImmediate(() => ordem.push("i2"));
        const t1 = setTimeout(() => clearTimeout(t2), 2);
        const t2 = setTimeout(() => ordem.push("cancelado"), 2);
        let ticks = 0;
        const iv = setInterval(() => { ticks++; }, 0);
        const t0 = Date.now();
        setTimeout(() => { clearInterval(iv); console.log(ordem.join(" ")); console.log("ticks", ticks, Date.now() - t0 >= 59); }, 60);
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        let linhas = c.stdout.split(separator: "\n").map(String.init)
        let ordem = (linhas.first ?? "").split(separator: " ").map(String.init)
        // setTimeout de 0/negativo/NaN roda na próxima volta junto com os setImmediate, na ordem de
        // criação; o setImmediate criado dentro de um callback fica para a volta seguinte. Entre
        // essa volta e o timer de 1 ms a ordem depende do relógio (no Node também).
        func emOrdem(_ nomes: [String]) -> Bool {
            let pos = nomes.compactMap { ordem.firstIndex(of: $0) }
            return pos.count == nomes.count && pos == pos.sorted()
        }
        #expect(ordem.count == 9, Comment(rawValue: c.stdout))
        #expect(emOrdem(["i1", "e0", "neg", "nan", "i2", "i3"]), Comment(rawValue: c.stdout))
        #expect(emOrdem(["c1", "a5", "b5"]), Comment(rawValue: c.stdout))
        #expect(!ordem.contains("cancelado"))
        // Piso de 1 ms no intervalo: em 60 ms cabem no máximo ~60 voltas (antes eram milhares, a 0 ns).
        let partes = (linhas.last ?? "").split(separator: " ")
        let ticks = partes.count > 1 ? Int(partes[1]) ?? -1 : -1
        #expect(ticks >= 3 && ticks <= 65, Comment(rawValue: c.stdout))
        #expect(partes.last == "true")
    }

    @Test func servidorEsqueceConexoesFechadas() async throws {
        let cap = Capture()
        let p = try JSProcess(cwd: tmp(), output: cap.handler)
        let tarefa = Task {
            await p.run(code: """
            const srv = require("http").createServer((req, res) => {
              if (req.url === "/fecha") res.setHeader("connection", "close");
              res.end("ok");
            });
            srv.on("odete:ws", (sock) => { sock.on("close", () => console.log("ws fechou")); sock.send("oi"); });
            srv.listen(0, () => console.log("porta " + srv.address().port));
            """)
        }
        var porta = 0
        for _ in 0 ..< 200 where porta == 0 {
            try await Task.sleep(for: .milliseconds(10))
            porta = cap.stdout.split(separator: "\n").first { $0.hasPrefix("porta ") }.flatMap { Int($0.dropFirst(6)) } ?? 0
        }
        #expect(porta > 0)
        func contagem() -> (conexoes: Int, ws: Int, respostas: Int) {
            guard let rt = p.rt else { return (-1, -1, -1) }
            return rt.queue.sync {
                let s = rt.serversBox?.servers.values.first
                return (s?.connections.count ?? -1, s?.wsClients.count ?? -1, s?.pendingBodies.count ?? -1)
            }
        }
        // resposta com `connection: close`: a conexão sai do dicionário quando a resposta termina
        let sessao = URLSession(configuration: .ephemeral)
        let (dados, _) = try await sessao.data(from: #require(URL(string: "http://127.0.0.1:\(porta)/fecha")))
        #expect(String(decoding: dados, as: UTF8.self) == "ok")
        try await espera { contagem().conexoes == 0 }
        #expect(contagem().conexoes == 0 && contagem().respostas == 0)
        // WebSocket: entra, e ao fechar sai de `wsClients` e de `connections`
        let ws = try sessao.webSocketTask(with: #require(URL(string: "ws://127.0.0.1:\(porta)/")))
        ws.resume()
        // A mensagem do servidor garante que o handshake terminou também do lado do cliente.
        if case let .string(texto) = try await ws.receive() {
            #expect(texto == "oi")
        }
        #expect(contagem().ws == 1 && contagem().conexoes == 1)
        ws.cancel(with: .normalClosure, reason: nil)
        try await espera(ate: 500) { contagem().ws == 0 && contagem().conexoes == 0 }
        #expect(contagem().ws == 0 && contagem().conexoes == 0)
        try await espera { cap.stdout.contains("ws fechou") }
        #expect(cap.stdout.contains("ws fechou"))
        p.kill()
        #expect(await tarefa.value == 130)
    }

    @Test func fechamentoWebSocketDepoisDeOutroFrame() {
        let texto: [UInt8] = [0x81, 0x82, 1, 2, 3, 4, 0x61, 0x62] // "ab" mascarado
        let fecha: [UInt8] = [0x88, 0x80, 9, 9, 9, 9]
        let longo: [UInt8] = [0x82, 0xFE, 0x01, 0x00, 1, 2, 3, 4] + [UInt8](repeating: 7, count: 256)
        #expect(HttpServer.temFechamento(Data(fecha)))
        #expect(HttpServer.temFechamento(Data(texto + fecha)))
        #expect(HttpServer.temFechamento(Data(longo + fecha)))
        #expect(!HttpServer.temFechamento(Data(texto)))
        #expect(!HttpServer.temFechamento(Data(texto.prefix(5))))
    }

    @Test func dataHttpSemFormatador() {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        for segundos in [0.0, 784_111_777, 951_782_400, 1_700_000_000, 1_790_000_123.9, Date.now.timeIntervalSince1970] {
            let d = Date(timeIntervalSince1970: segundos.rounded(.down))
            #expect(HttpParser.httpDate(d) == f.string(from: d))
        }
        #expect(HttpParser.httpDate(Date(timeIntervalSince1970: 784_111_777)) == "Sun, 06 Nov 1994 08:49:37 GMT")
    }

    @Test func cacheDeResolucaoAcompanhaODisco() async throws {
        let (code, c) = try await run("""
        const fs = require("fs"), path = require("path");
        const nome = (r) => path.basename(r);
        fs.mkdirSync("node_modules/pk", { recursive: true });
        fs.writeFileSync("node_modules/pk/a.js", "module.exports = 'a'");
        fs.writeFileSync("node_modules/pk/b.js", "module.exports = 'b'");
        fs.writeFileSync("node_modules/pk/package.json", JSON.stringify({ main: "a.js" }));
        const r1 = nome(require.resolve("pk")), r1b = nome(require.resolve("pk"));
        fs.writeFileSync("node_modules/pk/package.json", JSON.stringify({ main: "./b.js" }));
        const r2 = nome(require.resolve("pk"));
        fs.rmSync("node_modules/pk/b.js");
        fs.writeFileSync("node_modules/pk/index.js", "module.exports = 'i'");
        const r3 = nome(require.resolve("pk"));
        let r4; try { require.resolve("novo"); r4 = "achou"; } catch (e) { r4 = e.code; }
        fs.mkdirSync("node_modules/novo", { recursive: true });
        fs.writeFileSync("node_modules/novo/index.js", "module.exports = 'n'");
        const r5 = nome(require.resolve("novo"));
        console.log(r1, r1b, r2, r3, r4, r5);
        """)
        #expect(code == 0, Comment(rawValue: c.stderr))
        #expect(c.stdout == "a.js a.js b.js index.js MODULE_NOT_FOUND index.js")
    }
}
