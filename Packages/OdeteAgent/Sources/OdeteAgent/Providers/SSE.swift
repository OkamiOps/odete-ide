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
///
/// Tenta de novo quando a falha é do tipo que passa: limite de uso, erro de servidor e
/// conexão que caiu antes de a resposta começar. Num iPad em wifi de casa isso acontece
/// o tempo todo, e uma falha dessas matava o turno inteiro na primeira tentativa.
func openSSE(
    _ http: HTTPClient,
    url: URL,
    headers: [String: String],
    body: [String: Any],
    tentativas: Int = 3,
    espera: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
) async throws -> AsyncThrowingStream<String, Error> {
    var tentativa = 0
    while true {
        do {
            return try await abrirSSE(http, url: url, headers: headers, body: body)
        } catch {
            tentativa += 1
            guard tentativa < tentativas, let pausa = pausaAntesDeTentarDeNovo(error, tentativa) else { throw error }
            try await espera(pausa)
        }
    }
}

/// Quanto esperar antes da próxima tentativa, ou nada quando não vale insistir.
func pausaAntesDeTentarDeNovo(_ error: Error, _ tentativa: Int) -> Double? {
    // 1 s, 3 s, 7 s. Sem sorteio: em app de uma pessoa só não existe rebanho para dispersar.
    let escada = [1.0, 3.0, 7.0]
    let pausa = escada[min(tentativa - 1, escada.count - 1)]
    if let e = error as? AgentError {
        switch e {
        case let .http(code, _) where code == 429 || (500 ... 504).contains(code): return pausa
        case let .transport(texto) where texto.contains("cancel") == false: return pausa
        default: return nil
        }
    }
    if let u = error as? URLError {
        switch u.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed,
             .notConnectedToInternet, .cannotFindHost, .resourceUnavailable:
            return pausa
        default: return nil
        }
    }
    return nil
}

private func abrirSSE(
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
