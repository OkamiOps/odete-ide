import Foundation
import OdeteI18n
import Synchronization

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
        /// Chamadas que o provedor disse que terminaram (bloco fechado, item pronto).
        var fechadas: Set<Int> = []
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

        mutating func fechar(_ i: Int) {
            fechadas.insert(i)
        }

        var calls: [ToolCall] {
            calls(ferramentas: [], cortado: false, sabeQuemFechou: false)
        }

        /// As chamadas, cada uma já dizendo se pode rodar.
        ///
        /// Com a saída cortada no limite, a chamada que estava sendo escrita chega pela
        /// metade: ela volta marcada, e o modelo lê que foi cortada — não um "JSON
        /// inválido" que ele não tem como entender. JSON quebrado sem corte e argumento
        /// obrigatório faltando também voltam explicados: com o streaming de entrada
        /// ansioso ligado, o servidor não valida mais os argumentos, então valida-se aqui.
        func calls(ferramentas: [ToolSpec], cortado: Bool, sabeQuemFechou: Bool = true) -> [ToolCall] {
            items.sorted { $0.key < $1.key }.map { i, v in
                let args = v.args.isEmpty ? "{}" : v.args
                let objeto = try? JSONSerialization.jsonObject(with: Data(args.utf8)) as? [String: Any]
                var problema: String?
                if cortado, objeto == nil || (sabeQuemFechou && !fechadas.contains(i)) {
                    problema = Cortes.chamadaCortada(v.name)
                } else if objeto == nil {
                    problema = Cortes.jsonInvalido(v.name, args)
                } else if let objeto, let spec = ferramentas.first(where: { $0.name == v.name }) {
                    let obrigatorios = (spec.parameters["required"] as? [String]) ?? []
                    if let falta = obrigatorios.first(where: { objeto[$0] == nil }) {
                        problema = Cortes.faltaArgumento(falta, v.name)
                    }
                }
                return ToolCall(
                    id: v.id.isEmpty ? UUID().uuidString : v.id,
                    name: v.name,
                    arguments: args,
                    problema: problema
                )
            }
        }
    }
}

/// As frases de quando a resposta não chega inteira. Nenhum corte passa calado: ou vira
/// erro na tela, ou volta ao modelo como resultado da chamada que ele tentou fazer.
enum Cortes {
    static func chamadaCortada(_ nome: String) -> String {
        tr(
            "A chamada de %1$@ foi cortada: a resposta do modelo chegou ao limite de saída enquanto os argumentos eram escritos, então eles chegaram incompletos e nada foi executado. Divida o trabalho em partes menores (arquivos menores ou várias edições) e chame de novo.",
            nome
        )
    }

    static func jsonInvalido(_ nome: String, _ recebido: String) -> String {
        tr(
            "Os argumentos desta chamada de %1$@ não são um JSON válido, então nada foi executado. Mande a chamada de novo com um objeto JSON válido. Recebido: %2$@",
            nome,
            String(recebido.prefix(2000))
        )
    }

    static func faltaArgumento(_ argumento: String, _ nome: String) -> String {
        tr(
            "Faltou o argumento obrigatório \"%1$@\" nesta chamada de %2$@, então nada foi executado. Mande a chamada de novo com todos os argumentos.",
            argumento,
            nome
        )
    }

    static var respostaCortada: String {
        tr(
            "A resposta foi cortada: o modelo chegou ao limite de saída dele antes de terminar. Peça para continuar ou divida o pedido em partes menores."
        )
    }

    static var conexaoCaiu: String {
        tr("A resposta chegou incompleta: a conexão fechou antes do fim. Tente de novo.")
    }

    static var filtro: String {
        tr("O filtro de conteúdo do provedor interrompeu a resposta. Reescreva o pedido ou escolha outro modelo.")
    }

    /// `stop_reason: "refusal"`, com a categoria e a explicação de `stop_details` quando
    /// vierem (as duas podem faltar).
    static func recusa(_ detalhes: [String: Any]?) -> String {
        if let e = detalhes?["explanation"] as? String, !e.isEmpty {
            return tr("O modelo recusou este pedido: %1$@", e)
        }
        if let c = detalhes?["category"] as? String, !c.isEmpty {
            return tr(
                "O modelo recusou este pedido (categoria: %1$@). Reescreva o pedido ou escolha outro modelo.",
                c
            )
        }
        return tr("O modelo recusou este pedido. Reescreva o pedido ou escolha outro modelo.")
    }
}

/// Uma resposta HTTP de erro, com o que o servidor disse sobre quando tentar de novo.
struct FalhaHTTP: Error {
    let erro: AgentError
    /// `Retry-After`, em segundos.
    let esperar: Double?
}

/// POST com corpo JSON e leitura do SSE, com erro HTTP legível.
///
/// Tenta de novo quando a falha é do tipo que passa: limite de uso, servidor
/// sobrecarregado ou fora do ar e conexão que caiu antes de a resposta começar. Num iPad
/// em wifi de casa isso acontece o tempo todo, e uma falha dessas matava o turno inteiro
/// na primeira tentativa.
func openSSE(
    _ http: HTTPClient,
    url: URL,
    headers: [String: String],
    body: [String: Any],
    tentativas: Int = 4,
    espera: @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
) async throws -> AsyncThrowingStream<String, Error> {
    var tentativa = 0
    while true {
        do {
            return try await abrirSSE(http, url: url, headers: headers, body: body)
        } catch let f as FalhaHTTP {
            tentativa += 1
            guard tentativa < tentativas,
                  let pausa = pausaAntesDeTentarDeNovo(f.erro, tentativa, pedida: f.esperar)
            else { throw f.erro }
            try await espera(pausa)
        } catch {
            tentativa += 1
            guard tentativa < tentativas, let pausa = pausaAntesDeTentarDeNovo(error, tentativa) else { throw error }
            try await espera(pausa)
        }
    }
}

/// A espera mais longa que vale fazer por um `Retry-After`. Acima disso a pessoa lê o
/// erro na hora em vez de olhar para uma tela parada.
let esperaMaximaPedida = 20.0

/// Quanto esperar antes da próxima tentativa, ou nada quando não vale insistir.
func pausaAntesDeTentarDeNovo(_ error: Error, _ tentativa: Int, pedida: Double? = nil) -> Double? {
    // 1 s, 2 s, 4 s. Sem sorteio: em app de uma pessoa só não existe rebanho para dispersar.
    let escada = [1.0, 2.0, 4.0]
    let pausa = escada[min(tentativa - 1, escada.count - 1)]
    if let e = error as? AgentError {
        switch e {
        case let .http(code, texto) where code == 429 || code == 408 || code == 529 || (500 ... 504).contains(code):
            // Teto de gasto do mês não passa esperando: o 429 dele nem traz `Retry-After`.
            let t = texto.lowercased()
            if t.contains("enforced_spend_limit") || t.contains("insufficient_quota") || t.contains("usage limit") {
                return nil
            }
            if let p = pedida {
                return p <= esperaMaximaPedida ? max(0, p) : nil
            }
            return pausa
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

/// `Retry-After` em segundos (ou `retry-after-ms`, que a OpenAI manda).
func esperaPedida(_ resp: HTTPURLResponse) -> Double? {
    if let ms = resp.value(forHTTPHeaderField: "retry-after-ms").flatMap(Double.init) {
        return ms / 1000
    }
    guard let v = resp.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
        return nil
    }
    if let s = Double(v) {
        return s
    }
    // Também pode vir como data HTTP.
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: v).map { max(0, $0.timeIntervalSinceNow) }
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
        throw FalhaHTTP(erro: .http(resp.statusCode, "\(url.host() ?? "") \(text)"), esperar: esperaPedida(resp))
    }
    return SSE.data(from: bytes)
}
