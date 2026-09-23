import Foundation
import OdeteAccounts
@testable import OdeteAgent
import Synchronization

/// Servidor falso no nível do `URLSession`: o provedor roda inteiro (cabeçalhos, SSE em
/// bytes, novas tentativas) e nada sai para a rede. A sessão só conhece este protocolo,
/// então até `api.anthropic.com` cai aqui.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Resposta: Sendable {
        var status = 200
        var corpo = ""
        var headers: [String: String] = [:]
        /// Derruba a conexão em vez de responder.
        var cair = false
    }

    struct Pedido: Sendable {
        let url: URL
        let metodo: String
        let headers: [String: String]
        let corpo: Data
        var json: [String: Any] {
            jsonObject(corpo)
        }
    }

    typealias Roteiro = @Sendable (Pedido) -> Resposta

    private static let roteiro = Mutex<Roteiro?>(nil)
    private static let feitos = Mutex<[Pedido]>([])

    /// Troca o roteiro e zera os pedidos registrados.
    static func servir(_ r: @escaping Roteiro) {
        roteiro.withLock { $0 = r }
        feitos.withLock { $0 = [] }
    }

    static var pedidos: [Pedido] {
        feitos.withLock { $0 }
    }

    static func pedidos(_ caminho: String) -> [Pedido] {
        pedidos.filter { $0.url.path().hasSuffix(caminho) }
    }

    static var cliente: URLSessionClient {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return URLSessionClient(session: URLSession(configuration: c))
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        var h: [String: String] = [:]
        for (k, v) in request.allHTTPHeaderFields ?? [:] {
            h[k.lowercased()] = v
        }
        let p = Pedido(url: request.url!, metodo: request.httpMethod ?? "GET", headers: h, corpo: Self.corpo(request))
        Self.feitos.withLock { $0.append(p) }
        guard let r = Self.roteiro.withLock({ $0 })?(p), !r.cair else {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let resp = HTTPURLResponse(
            url: request.url!,
            statusCode: r.status,
            httpVersion: "HTTP/1.1",
            headerFields: r.headers
        )!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(r.corpo.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func corpo(_ r: URLRequest) -> Data {
        if let b = r.httpBody {
            return b
        }
        guard let s = r.httpBodyStream else { return Data() }
        s.open()
        defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 {
                break
            }
            d.append(buf, count: n)
        }
        return d
    }
}

// MARK: - Respostas prontas

/// SSE a partir de eventos JSON.
func sse(_ eventos: [[String: Any]]) -> String {
    eventos.map { e in
        let d = try! JSONSerialization.data(withJSONObject: e, options: [.sortedKeys])
        return "event: \(e["type"] as? String ?? "message")\ndata: \(String(decoding: d, as: UTF8.self))\n\n"
    }.joined()
}

/// Um stream da Messages API com os blocos dados e a parada dada.
func sseAnthropic(
    _ blocos: [[String: Any]],
    parada: String = "end_turn",
    detalhes: [String: Any]? = nil,
    termina: Bool = true,
    modelo: String = "claude-sonnet-5"
) -> String {
    var ev: [[String: Any]] = [[
        "type": "message_start",
        "message": ["id": "msg_1", "model": modelo, "usage": ["input_tokens": 10, "output_tokens": 1]],
    ]]
    for (i, b) in blocos.enumerated() {
        let tipo = b["type"] as? String ?? ""
        switch tipo {
        case "thinking":
            ev.append([
                "type": "content_block_start",
                "index": i,
                "content_block": ["type": "thinking", "thinking": ""],
            ])
            ev.append(["type": "content_block_delta", "index": i,
                       "delta": ["type": "thinking_delta", "thinking": b["thinking"] as? String ?? ""]])
            ev.append(["type": "content_block_delta", "index": i,
                       "delta": ["type": "signature_delta", "signature": b["signature"] as? String ?? ""]])
        case "text":
            ev.append(["type": "content_block_start", "index": i, "content_block": ["type": "text", "text": ""]])
            ev.append(["type": "content_block_delta", "index": i,
                       "delta": ["type": "text_delta", "text": b["text"] as? String ?? ""]])
        case "tool_use":
            ev.append(["type": "content_block_start", "index": i, "content_block": [
                "type": "tool_use", "id": b["id"] ?? "", "name": b["name"] ?? "", "input": [String: Any](),
            ]])
            ev.append(["type": "content_block_delta", "index": i,
                       "delta": ["type": "input_json_delta", "partial_json": b["json"] as? String ?? "{}"]])
        default: break
        }
        // Bloco sem fim: foi cortado no meio.
        if b["aberto"] as? Bool != true {
            ev.append(["type": "content_block_stop", "index": i])
        }
    }
    var delta: [String: Any] = ["stop_reason": parada]
    if let detalhes {
        delta["stop_details"] = detalhes
    }
    ev.append(["type": "message_delta", "delta": delta, "usage": ["output_tokens": 5]])
    if termina {
        ev.append(["type": "message_stop"])
    }
    return sse(ev)
}

/// O que a Models API da Anthropic devolve para um modelo.
func modeloDaAnthropic(
    _ id: String,
    contexto: Int,
    saida: Int,
    adaptativo: Bool,
    orcamento: Bool,
    esforcos: [String]?
) -> String {
    var effort: [String: Any] = ["supported": esforcos != nil]
    for n in ["low", "medium", "high", "xhigh", "max"] {
        effort[n] = ["supported": esforcos?.contains(n) == true]
    }
    let m: [String: Any] = [
        "id": id,
        "type": "model",
        "display_name": id,
        "max_input_tokens": contexto,
        "max_tokens": saida,
        "capabilities": [
            "thinking": [
                "supported": adaptativo || orcamento,
                "types": ["adaptive": ["supported": adaptativo], "enabled": ["supported": orcamento]],
            ],
            "effort": effort,
            "image_input": ["supported": true],
        ],
    ]
    return String(decoding: try! JSONSerialization.data(withJSONObject: m), as: UTF8.self)
}

/// Uma conta pronta para usar, com os segredos em memória.
func contaDeTeste(_ kind: ProviderKind, base: String? = nil) -> (AIAccount, MemorySecrets) {
    let a = AIAccount(kind: kind, baseURL: base, expiresAt: Date(timeIntervalSinceNow: 3600))
    let s = MemorySecrets()
    try? s.set("chave-de-teste", for: a.keychainPrefix + ":key")
    try? s.set("acesso-de-teste", for: a.keychainPrefix + ":access")
    try? s.set("refresh-de-teste", for: a.keychainPrefix + ":refresh")
    return (a, s)
}

/// Provedor HTTP apontado para o servidor falso, sem esperar entre tentativas.
func provedorDeTeste(
    _ kind: ProviderKind,
    base: String? = nil,
    registro: RegistroDeCapacidades = RegistroDeCapacidades(arquivo: nil),
    catalogo: CatalogoDeModelos? = nil,
    esperas: Esperas? = nil
) -> HTTPProvider {
    let (a, s) = contaDeTeste(kind, base: base)
    let http = StubURLProtocol.cliente
    return HTTPProvider(
        account: a,
        session: Session(account: a, secrets: s, http: http) { _, _ in },
        http: http,
        registro: registro,
        catalogo: catalogo,
        espera: { s in esperas?.anotar(s) }
    )
}

/// As esperas entre tentativas que o provedor pediu.
final class Esperas: Sendable {
    private let m = Mutex<[Double]>([])
    func anotar(_ s: Double) {
        m.withLock { $0.append(s) }
    }

    var todas: [Double] {
        m.withLock { $0 }
    }
}

/// Tudo o que o stream entregou, na ordem.
func eventos(_ s: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var out: [StreamEvent] = []
    for try await e in s {
        out.append(e)
    }
    return out
}

extension [StreamEvent] {
    var texto: String {
        compactMap {
            if case let .text(t) = $0 {
                t
            } else {
                nil
            }
        }.joined()
    }

    var erros: [String] {
        compactMap {
            if case let .error(m) = $0 {
                m
            } else {
                nil
            }
        }
    }

    var chamadas: [ToolCall] {
        compactMap {
            if case let .tools(c) = $0 {
                c
            } else {
                nil
            }
        }.last ?? []
    }

    var raciocinio: RaciocinioBruto? {
        compactMap {
            if case let .raciocinio(r) = $0 {
                r
            } else {
                nil
            }
        }.last
    }

    var terminou: Bool {
        contains(.done)
    }
}
