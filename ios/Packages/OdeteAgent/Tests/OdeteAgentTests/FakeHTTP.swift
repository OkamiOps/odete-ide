import Foundation
@testable import OdeteAgent
import Synchronization

/// HTTP falso: uma fila de respostas por URL (prefixo), e registra os pedidos.
final class FakeHTTP: HTTPClient, @unchecked Sendable {
    struct Call {
        let request: URLRequest; var bodyJSON: [String: Any] {
            jsonObject(request.httpBody ?? Data())
        }; var bodyForm: [String: String] {
            var out: [String: String] = [:]
            for pair in String(decoding: request.httpBody ?? Data(), as: UTF8.self).split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                    .map { String($0).removingPercentEncoding ?? String($0) }
                if kv.count == 2 {
                    out[kv[0]] = kv[1]
                }
            }
            return out
        }
    }

    let calls = Mutex<[Call]>([])
    private let queue = Mutex<[(String, Int, String)]>([])

    func enqueue(_ prefix: String, _ status: Int, _ body: String) {
        queue.withLock { $0.append((prefix, status, body)) }
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls.withLock { $0.append(Call(request: request)) }
        let url = request.url!.absoluteString
        let hit = queue.withLock { q -> (Int, String)? in
            guard let i = q.firstIndex(where: { url.hasPrefix($0.0) }) else { return nil }
            let e = q.remove(at: i); return (e.1, e.2)
        }
        guard let hit else { throw AgentError.transport("sem resposta enfileirada para \(url)") }
        return (
            Data(hit.1.utf8),
            HTTPURLResponse(
                url: request.url!,
                statusCode: hit.0,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        throw AgentError.transport("bytes não suportado no fake")
    }

    var count: Int {
        calls.withLock { $0.count }
    }

    func call(_ i: Int) -> Call {
        calls.withLock { $0[i] }
    }
}

func jwt(_ claims: [String: Any]) -> String {
    let h = Data(#"{"alg":"none"}"#.utf8).base64EncodedString()
    let p = (try! JSONSerialization.data(withJSONObject: claims)).base64EncodedString().replacingOccurrences(
        of: "=",
        with: ""
    )
    return "\(h).\(p).sig"
}
