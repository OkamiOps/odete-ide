import Foundation

/// Leitor de Server-Sent Events: entrega o `data:` de cada evento.
enum SSE {
    /// Linhas de `data:` a partir de bytes HTTP.
    static func data(from bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    for try await line in bytes.lines {
                        if Task.isCancelled {
                            break
                        }
                        if let d = payload(line) {
                            cont.yield(d)
                        }
                    }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Mesmo, a partir de texto (fixtures nos testes).
    static func data(fromText text: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            for line in text
                .split(separator: "\n", omittingEmptySubsequences: true)
            {
                if let d = payload(String(line)) {
                    cont.yield(d)
                }
            }
            cont.finish()
        }
    }

    static func payload(_ raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("data:") else { return nil }
        let d = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return d.isEmpty ? nil : d
    }

    /// Acumula chamadas de ferramenta por índice/bloco.
    struct ToolAcc {
        var items: [Int: (id: String, name: String, args: String)] = [:]
        mutating func add(_ i: Int, id: String? = nil, name: String? = nil, args: String? = nil) {
            var cur = items[i] ?? ("", "", "")
            if let id, !id.isEmpty {
                cur.id = id
            }
            if let name {
                cur.name += name
            }
            if let args {
                cur.args += args
            }
            items[i] = cur
        }

        var calls: [ToolCall] {
            items.sorted { $0.key < $1.key }.map { ToolCall(
                id: $0.value.id.isEmpty ? UUID().uuidString : $0.value.id,
                name: $0.value.name,
                arguments: $0.value.args.isEmpty ? "{}" : $0.value.args
            ) }
        }
    }
}

/// POST com corpo JSON e leitura do SSE, com erro HTTP legível.
func openSSE(
    _ http: HTTPClient,
    url: URL,
    headers: [String: String],
    body: [String: Any]
) async throws -> AsyncThrowingStream<String, Error> {
    var req = URLRequest.json(url, body: body, headers: headers)
    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 600
    let (bytes, resp) = try await http.bytes(for: req)
    guard (200 ..< 300).contains(resp.statusCode) else {
        var text = ""
        for try await line in bytes.lines {
            text += line; if text.count > 2000 {
                break
            }
        }
        if resp.statusCode == 401 {
            throw AgentError.auth("401: " + text.prefix(200))
        }
        throw AgentError.http(resp.statusCode, "\(url.host() ?? "") \(text)")
    }
    return SSE.data(from: bytes)
}
