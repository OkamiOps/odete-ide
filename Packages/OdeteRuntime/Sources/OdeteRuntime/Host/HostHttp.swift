import Foundation
import JavaScriptCore
import Network

/// Servidor HTTP/1.1 real em 127.0.0.1 com Network.framework. Cada requisição vira uma chamada JS
/// `__odete_httpRequest(serverId, reqId, method, url, headers, corpo)` com o corpo num `Uint8Array`;
/// o JS responde com `__odete.httpWriteHead(...)` e `__odete.httpWrite(serverId, reqId, bytes, fim)`.
final class HttpServer: @unchecked Sendable {
    let id: Int
    let port: UInt16
    let listener: NWListener
    let fila: DispatchQueue
    /// Fraco: um callback do Network já enfileirado pode chegar depois que o runtime morreu.
    weak var rt: JSRuntime?
    /// Todas as conexões abertas, por número de conexão — keep-alive ociosas e WebSockets
    /// inclusive. Saem daqui quando fecham; `stop()` fecha o que sobrar.
    var connections: [Int: NWConnection] = [:]
    var nextConn = 1
    var nextReq = 1
    /// Respostas em andamento, por reqId.
    var pendingBodies: [Int: Resposta] = [:]
    /// WebSockets abertos, por reqId (o id que o JS conhece).
    var wsClients: [Int: NWConnection] = [:]
    private var wsConexao: [Int: Int] = [:] // reqId → conexão

    struct Resposta {
        var conn: NWConnection
        var connId: Int
        var keepAlive: Bool
        var chunked = false
        var headersSent = false
    }

    init(id: Int, port: UInt16, rt: JSRuntime) throws {
        self.id = id
        self.rt = rt
        fila = rt.queue
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        listener = try NWListener(using: params)
        self.port = port
    }

    deinit {
        listener.cancel()
        for c in connections.values {
            c.cancel()
        }
    }

    var actualPort: UInt16 {
        listener.port?.rawValue ?? port
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: fila)
    }

    func stop() {
        listener.cancel()
        for (_, c) in connections {
            c.cancel()
        }
        connections.removeAll()
        pendingBodies.removeAll()
        wsClients.removeAll()
        wsConexao.removeAll()
    }

    private func accept(_ conn: NWConnection) {
        let cid = nextConn
        nextConn += 1
        connections[cid] = conn
        conn.start(queue: fila)
        readRequest(conn, cid, buffer: Data())
    }

    /// Fecha uma conexão e esquece o que era dela.
    private func fechar(_ cid: Int) {
        guard let conn = connections.removeValue(forKey: cid) else { return }
        conn.cancel()
        pendingBodies = pendingBodies.filter { $0.value.connId != cid }
    }

    private func readRequest(_ conn: NWConnection, _ cid: Int, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                conn.cancel(); return
            }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if error != nil {
                fechar(cid); return
            }
            // Pode ter chegado mais de uma requisição no mesmo pacote.
            while let (req, rest) = HttpParser.parse(buf) {
                buf = rest
                if handle(req, conn: conn, connId: cid) {
                    return // virou WebSocket: `readWs` é o único a ler desta conexão agora
                }
            }
            if isComplete {
                // O cliente parou de mandar. Com resposta em andamento, fecha quando ela terminar.
                let emAndamento = pendingBodies.filter { $0.value.connId == cid }.map(\.key)
                if emAndamento.isEmpty {
                    fechar(cid)
                } else {
                    for rid in emAndamento {
                        pendingBodies[rid]?.keepAlive = false
                    }
                }
                return
            }
            readRequest(conn, cid, buffer: buf)
        }
    }

    /// Entrega a requisição ao JS. Devolve `true` se a conexão virou WebSocket.
    private func handle(_ req: HttpParser.Request, conn: NWConnection, connId: Int) -> Bool {
        guard let rt else { return false }
        let reqId = nextReq
        nextReq += 1
        let keepAlive = (req.headers["connection"] ?? (req.version == "HTTP/1.1" ? "keep-alive" : "close"))
            .lowercased() != "close"
        if req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] {
            // handshake WebSocket (só para o reload do dev server)
            let accept = Data(SHA1Digest.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            wsClients[reqId] = conn
            wsConexao[reqId] = connId
            rt.call("__odete_wsOpen", [id, reqId, req.url])
            readWs(conn, reqId: reqId)
            return true
        }
        pendingBodies[reqId] = Resposta(conn: conn, connId: connId, keepAlive: keepAlive)
        rt.call("__odete_httpRequest", [id, reqId, req.method, req.url, req.headers, rt.bytes(req.body)])
        return false
    }

    private func readWs(_ conn: NWConnection, reqId: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            // O cliente do reload não manda mensagens; o que importa é o frame de fechamento
            // (opcode 8) quando a página recarrega. Responder e fechar já, em vez de esperar o
            // navegador desistir da conexão.
            let fechamento = data.map(Self.temFechamento) ?? false
            if isComplete || error != nil || fechamento {
                wsClients[reqId] = nil
                let cid = wsConexao.removeValue(forKey: reqId)
                if fechamento {
                    // Sai dos mapas já; a conexão só é cancelada depois que a resposta sair.
                    if let cid {
                        connections[cid] = nil
                    }
                    conn.send(content: Data([0x88, 0x00]), completion: .contentProcessed { _ in conn.cancel() })
                } else if let cid {
                    fechar(cid)
                }
                rt?.call("__odete_wsClose", [id, reqId])
                return
            }
            readWs(conn, reqId: reqId)
        }
    }

    /// Algum frame inteiro neste pedaço é de fechamento? Anda de frame em frame pelo cabeçalho
    /// (frames do cliente vêm mascarados) e para no primeiro que não coube inteiro.
    static func temFechamento(_ d: Data) -> Bool {
        let b = [UInt8](d)
        var i = 0
        while i + 2 <= b.count {
            if b[i] & 0x0F == 0x8 {
                return true
            }
            var tamanho = Int(b[i + 1] & 0x7F), cabecalho = 2
            if tamanho == 126, i + 4 <= b.count {
                tamanho = Int(b[i + 2]) << 8 | Int(b[i + 3]); cabecalho = 4
            } else if tamanho == 127, i + 10 <= b.count {
                tamanho = (0 ..< 8).reduce(0) { $0 << 8 | Int(b[i + 2 + $1]) }; cabecalho = 10
            } else if tamanho >= 126 {
                return false
            }
            if b[i + 1] & 0x80 != 0 {
                cabecalho += 4
            }
            i += cabecalho + tamanho
        }
        return false
    }

    /// Envia um frame de texto WebSocket.
    func wsSend(_ reqId: Int, text: String) {
        guard let conn = wsClients[reqId] else { return }
        let payload = Data(text.utf8)
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 65536 {
            frame.append(126); frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127); for i in (0 ..< 8).reversed() {
                frame.append(UInt8((payload.count >> (i * 8)) & 0xFF))
            }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    func writeHead(_ reqId: Int, status: Int, headers: [String: String]) {
        guard var p = pendingBodies[reqId], !p.headersSent else { return }
        var hdrs = headers
        var lower = Set(hdrs.keys.map { $0.lowercased() })
        if !lower.contains("content-length"),
           !lower
           .contains("transfer-encoding")
        {
            hdrs["Transfer-Encoding"] = "chunked"; p.chunked = true; lower.insert("transfer-encoding")
        }
        if !lower.contains("connection") {
            hdrs["Connection"] = p.keepAlive ? "keep-alive" : "close"
        } else if hdrs.contains(where: { $0.key.lowercased() == "connection" && $0.value.lowercased() == "close" }) {
            p.keepAlive = false // o JS pediu para fechar: a conexão sai de `connections` ao fim
        }
        if !lower.contains("date") {
            hdrs["Date"] = HttpParser.httpDate()
        }
        var head = "HTTP/1.1 \(status) \(HttpParser.reason(status))\r\n"
        for (k, v) in hdrs {
            head += "\(k): \(v)\r\n"
        }
        head += "\r\n"
        p.headersSent = true
        pendingBodies[reqId] = p
        p.conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    func write(_ reqId: Int, chunk: Data, end: Bool) {
        guard let p = pendingBodies[reqId] else { return }
        var out = Data()
        if p.chunked {
            if !chunk
                .isEmpty
            {
                out.append(Data(String(chunk.count, radix: 16).utf8)); out.append(Data("\r\n".utf8)); out
                    .append(chunk); out.append(Data("\r\n".utf8))
            }
            if end {
                out.append(Data("0\r\n\r\n".utf8))
            }
        } else {
            out.append(chunk)
        }
        p.conn.send(content: out, completion: .contentProcessed { [weak self] _ in
            guard let self, end else { return }
            // `keepAlive` pode ter mudado depois (cliente fechou o lado dele): vale o de agora.
            let atual = pendingBodies.removeValue(forKey: reqId)
            if !(atual?.keepAlive ?? p.keepAlive) {
                fechar(p.connId)
            }
        })
    }
}

enum HttpParser {
    struct Request {
        var method: String; var url: String; var version: String; var headers: [String: String]; var body: Data
    }

    static func parse(_ data: Data) -> (Request, Data)? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex ..< headEnd.lowerBound], as: UTF8.self)
        var lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { return nil }
        lines.removeFirst()
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[String(l[..<i]).lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard data.count - bodyStart >= len else { return nil }
        let body = data.subdata(in: bodyStart ..< bodyStart + len)
        let rest = data.subdata(in: bodyStart + len ..< data.count)
        return (
            Request(
                method: String(parts[0]),
                url: String(parts[1]),
                version: parts.count > 2 ? String(parts[2]) : "HTTP/1.1",
                headers: headers,
                body: body
            ),
            rest
        )
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: "OK"; case 201: "Created"; case 204: "No Content"; case 301: "Moved Permanently"; case 302: "Found"
        case 304: "Not Modified"; case 400: "Bad Request"; case 401: "Unauthorized"; case 403: "Forbidden"; case 404: "Not Found"
        case 500: "Internal Server Error"; default: "OK"
        }
    }

    private static let dias = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let meses = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Data HTTP (IMF-fixdate, RFC 9110): `Sun, 06 Nov 1994 08:49:37 GMT`.
    ///
    /// Montada à mão com `gmtime_r` em vez de um `DateFormatter` por resposta: não aloca
    /// formatador, não depende de locale e pode rodar em qualquer fila ao mesmo tempo — cada
    /// runtime tem a sua, e um formatador compartilhado precisaria de trava.
    static func httpDate(_ data: Date = .now) -> String {
        var t = time_t(data.timeIntervalSince1970)
        var g = tm()
        gmtime_r(&t, &g)
        func dois(_ n: Int32) -> String {
            n < 10 ? "0\(n)" : "\(n)"
        }
        return "\(dias[Int(g.tm_wday)]), \(dois(g.tm_mday)) \(meses[Int(g.tm_mon)]) \(g.tm_year + 1900) "
            + "\(dois(g.tm_hour)):\(dois(g.tm_min)):\(dois(g.tm_sec)) GMT"
    }
}

import CryptoKit
import OdeteI18n

enum SHA1Digest {
    static func digest(_ s: String) -> [UInt8] {
        Array(Insecure.SHA1.hash(data: Data(s.utf8)))
    }
}

enum HostHttp {
    /// Abre o listener, pulando para a porta seguinte quando a pedida está ocupada.
    ///
    /// Porta em uso só aparece quando o listener falha, nunca ao criá-lo: a tentativa em
    /// sequência que existia aqui (`try? HttpServer(...)`) não descobria nada, e o
    /// servidor morria com "NWError 48 - Address already in use" e uma pilha apontando
    /// para dentro do runtime. Deixar um servidor de pé e mandar subir outro virava um
    /// erro ilegível em vez de uma porta nova, que é o que o vite faz.
    /// Qual porta tentar e quantas ainda dá para tentar depois dela.
    struct Tentativa {
        var id: Int
        var porta: UInt16
        var restantes: Int
    }

    static func abrir(
        rt: JSRuntime,
        box: ServersBox,
        _ t: Tentativa,
        avisar: @escaping @Sendable (String) -> Void
    ) {
        let (id, porta, restantes) = (t.id, t.porta, t.restantes)
        guard let server = try? HttpServer(id: id, port: porta, rt: rt) else {
            avisar(tr("não consegui abrir a porta %1$@", "\(porta)"))
            return
        }
        // `rt` fraco: o listener guarda este closure, o servidor fica na caixa e a caixa no
        // runtime — forte, era um ciclo que prendia o runtime enquanto o servidor existisse.
        server.listener.stateUpdateHandler = { [weak server, weak rt] state in
            guard let server, let rt else { return }
            switch state {
            case .ready:
                rt.call("__odete_httpListening", [id, Int(server.actualPort)])
            case let .failed(erro):
                let ocupada = if case .posix(.EADDRINUSE) = erro {
                    true
                } else {
                    false
                }
                // O servidor que falhou sai da caixa: `httpClose` depois do erro não conta um
                // servidor a menos, e nada fica preso a ele.
                server.stop()
                box.servers.removeValue(forKey: id)
                if ocupada, porta != 0, restantes > 0 {
                    abrir(
                        rt: rt,
                        box: box,
                        Tentativa(id: id, porta: porta + 1, restantes: restantes - 1),
                        avisar: avisar
                    )
                } else if ocupada {
                    avisar(tr("porta %1$@ ocupada, e as %2$@ seguintes também", "\(porta)", "\(21 - restantes)"))
                } else {
                    avisar(erro.localizedDescription)
                }
            default: break
            }
        }
        box.servers[id] = server
        server.start()
    }

    static func install(_ rt: JSRuntime) {
        let h = rt.host
        var nextId = 1
        let box = ServersBox()
        let listen: @convention(block) (Int) -> Any = { [unowned rt] port in
            let id = nextId
            nextId += 1
            rt.keepAlive += 1
            abrir(rt: rt, box: box, Tentativa(id: id, porta: UInt16(clamping: port), restantes: 20)) { [weak rt] msg in
                guard let rt else { return }
                rt.keepAlive = max(rt.keepAlive - 1, 0)
                rt.call("__odete_httpError", [id, msg])
                rt.checkIdle()
            }
            return ["id": id]
        }
        h.setObject(listen, forKeyedSubscript: "httpListen" as NSString)

        let close: @convention(block) (Int) -> Void = { [unowned rt] id in
            // Só conta se o servidor ainda existia: um que falhou já descontou ao avisar.
            if let s = box.servers.removeValue(forKey: id) {
                s.stop()
                rt.keepAlive = max(rt.keepAlive - 1, 0)
            }
            rt.checkIdle()
        }
        h.setObject(close, forKeyedSubscript: "httpClose" as NSString)

        let writeHead: @convention(block) (Int, Int, Int, [String: String]) -> Void = { sid, rid, status, headers in
            box.servers[sid]?.writeHead(rid, status: status, headers: headers)
        }
        h.setObject(writeHead, forKeyedSubscript: "httpWriteHead" as NSString)

        // O corpo chega como typed array; string base64 (o formato antigo) ainda é aceita.
        let write: @convention(block) (Int, Int, JSValue?, Bool) -> Void = { sid, rid, corpo, end in
            box.servers[sid]?.write(rid, chunk: HostBytes.dados(corpo), end: end)
        }
        h.setObject(write, forKeyedSubscript: "httpWrite" as NSString)

        let wsSend: @convention(block) (Int, Int, String) -> Void = { sid, rid, text in
            box.servers[sid]?.wsSend(rid, text: text)
        }
        h.setObject(wsSend, forKeyedSubscript: "wsSend" as NSString)
        rt.serversBox = box
    }
}

final class ServersBox: @unchecked Sendable {
    var servers: [Int: HttpServer] = [:]
    func stopAll() {
        for (_, s) in servers {
            s.stop()
        }; servers.removeAll()
    }
}
