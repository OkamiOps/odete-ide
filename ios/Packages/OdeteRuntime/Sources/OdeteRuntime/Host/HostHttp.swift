import Foundation
import JavaScriptCore
import Network

/// Servidor HTTP/1.1 real em 127.0.0.1 com Network.framework. Cada requisição vira uma chamada JS
/// `__odete_httpRequest(serverId, reqId, method, url, headers, bodyB64)`; o JS responde com
/// `__odete.httpRespond(reqId, status, headers, bodyB64, done)`.
final class HttpServer: @unchecked Sendable {
    let id: Int
    let port: UInt16
    let listener: NWListener
    unowned let rt: JSRuntime
    var connections: [Int: NWConnection] = [:]
    var nextReq = 1
    var pendingBodies: [Int: (conn: NWConnection, keepAlive: Bool, chunked: Bool, headersSent: Bool)] = [:]
    var wsClients: [Int: NWConnection] = [:]

    init(id: Int, port: UInt16, rt: JSRuntime) throws {
        self.id = id
        self.rt = rt
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port) ?? .any
        )
        listener = try NWListener(using: params)
        self.port = port
    }

    var actualPort: UInt16 {
        listener.port?.rawValue ?? port
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: rt.queue)
    }

    func stop() {
        listener.cancel()
        for (_, c) in connections {
            c.cancel()
        }
        connections.removeAll()
        wsClients.removeAll()
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: rt.queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data {
                buf.append(data)
            }
            if error != nil || (isComplete && buf.isEmpty) {
                conn.cancel(); return
            }
            if let (req, rest) = HttpParser.parse(buf) {
                handle(req, conn: conn)
                readRequest(conn, buffer: rest)
            } else if isComplete {
                conn.cancel()
            } else {
                readRequest(conn, buffer: buf)
            }
        }
    }

    private func handle(_ req: HttpParser.Request, conn: NWConnection) {
        let reqId = nextReq
        nextReq += 1
        connections[reqId] = conn
        let keepAlive = (req.headers["connection"] ?? (req.version == "HTTP/1.1" ? "keep-alive" : "close"))
            .lowercased() != "close"
        pendingBodies[reqId] = (conn, keepAlive, false, false)
        if req.headers["upgrade"]?.lowercased() == "websocket", let key = req.headers["sec-websocket-key"] {
            // handshake WebSocket (só para o reload do dev server)
            let accept = Data(SHA1Digest.digest(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            wsClients[reqId] = conn
            pendingBodies[reqId] = nil
            rt.call("__odete_wsOpen", [id, reqId, req.url])
            readWs(conn, reqId: reqId)
            return
        }
        rt.call("__odete_httpRequest", [id, reqId, req.method, req.url, req.headers, req.body.base64EncodedString()])
    }

    private func readWs(_ conn: NWConnection, reqId: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                wsClients[reqId] = nil
                rt.call("__odete_wsClose", [id, reqId])
                return
            }
            readWs(conn, reqId: reqId)
        }
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
            pendingBodies[reqId] = nil
            connections[reqId] = nil
            if !p.keepAlive {
                p.conn.cancel()
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

    static func httpDate() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: .now)
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
        server.listener.stateUpdateHandler = { [weak server] state in
            guard let server else { return }
            switch state {
            case .ready:
                rt.call("__odete_httpListening", [id, Int(server.actualPort)])
            case let .failed(erro):
                let ocupada = if case .posix(.EADDRINUSE) = erro {
                    true
                } else {
                    false
                }
                if ocupada, porta != 0, restantes > 0 {
                    server.stop()
                    box.servers.removeValue(forKey: id)
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
            abrir(rt: rt, box: box, Tentativa(id: id, porta: UInt16(clamping: port), restantes: 20)) { msg in
                rt.keepAlive = max(rt.keepAlive - 1, 0)
                rt.call("__odete_httpError", [id, msg])
            }
            return ["id": id]
        }
        h.setObject(listen, forKeyedSubscript: "httpListen" as NSString)

        let close: @convention(block) (Int) -> Void = { [unowned rt] id in
            box.servers.removeValue(forKey: id)?.stop()
            rt.keepAlive = max(rt.keepAlive - 1, 0)
            rt.checkIdle()
        }
        h.setObject(close, forKeyedSubscript: "httpClose" as NSString)

        let writeHead: @convention(block) (Int, Int, Int, [String: String]) -> Void = { sid, rid, status, headers in
            box.servers[sid]?.writeHead(rid, status: status, headers: headers)
        }
        h.setObject(writeHead, forKeyedSubscript: "httpWriteHead" as NSString)

        let write: @convention(block) (Int, Int, String, Bool) -> Void = { sid, rid, b64, end in
            box.servers[sid]?.write(rid, chunk: Data(base64Encoded: b64) ?? Data(), end: end)
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
