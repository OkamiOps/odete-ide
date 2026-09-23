import Foundation
import OdeteI18n

/// HTTP mínimo que os provedores usam; nos testes vira um fake.
public protocol HTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse)
}

public struct URLSessionClient: HTTPClient {
    public var session: URLSession
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await session.data(for: request)
        guard let h = r as? HTTPURLResponse else { throw AgentError.transport(tr("resposta sem HTTP")) }
        return (d, h)
    }

    public func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        let (b, r) = try await session.bytes(for: request)
        guard let h = r as? HTTPURLResponse else { throw AgentError.transport(tr("resposta sem HTTP")) }
        return (b, h)
    }
}

public enum AgentError: LocalizedError, Sendable, Equatable {
    case transport(String)
    case http(Int, String)
    case auth(String)
    case noAccount
    case invalidGrant
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .transport(s): s
        case let .http(code, body): "HTTP \(code)" + (body.isEmpty ? "" : ": \(body.prefix(240))")
        case let .auth(s): s
        case .noAccount: tr("Conecte uma conta em Ajustes → Contas.")
        case .invalidGrant: tr("A sessão expirou. Reconecte a conta em Ajustes.")
        case .cancelled: "parado"
        }
    }
}

extension URLRequest {
    static func json(
        _ url: URL,
        method: String = "POST",
        body: [String: Any],
        headers: [String: String] = [:]
    ) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers {
            r.setValue(v, forHTTPHeaderField: k)
        }
        // Chaves em ordem fixa: o dicionário do Swift sai cada vez numa ordem, e o
        // provedor renderiza o JSON (schemas das ferramentas, argumentos devolvidos) na
        // ordem em que chegou. Ordem trocando a cada pedido é prefixo diferente a cada
        // pedido — cache de prompt perdido e raciocínio assinado invalidado.
        r.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return r
    }

    static func form(_ url: URL, body: [String: String], headers: [String: String] = [:]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers {
            r.setValue(v, forHTTPHeaderField: k)
        }
        var cs = CharacterSet.alphanumerics
        cs.insert(charactersIn: "-._~")
        r
            .httpBody = Data(body.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: cs) ?? "")" }
                .joined(separator: "&").utf8)
        return r
    }
}

func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}
