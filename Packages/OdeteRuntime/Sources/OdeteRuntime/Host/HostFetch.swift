import Foundation
import JavaScriptCore
import OdeteI18n

/// `fetch` e `http.request` cliente via URLSession. O corpo vai e volta como `Uint8Array`
/// (string base64 ainda é aceita no pedido, para quem chamava assim).
enum HostFetch {
    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let fetch: @convention(block) (Int, String, String, [String: String], JSValue?)
            -> Void = { [unowned rt] id, url, method, headers, bodyValue in
                guard let u = URL(string: url) else {
                    rt.call("__odete_fetchFail", [id, tr("URL inválida: %1$@", "\(url)")])
                    return
                }
                var req = URLRequest(url: u)
                req.httpMethod = method
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if let bodyValue, !bodyValue.isNull, !bodyValue.isUndefined {
                    req.httpBody = HostBytes.dados(bodyValue)
                }
                // A resposta chega depois que este bloco voltou: o runtime vai junto, forte, até
                // ela ser entregue. Com `unowned` um processo morto (Ctrl+C) antes da resposta
                // derrubava o app ao chegar a resposta.
                let alvo: JSRuntime = rt
                alvo.beginWork()
                let task = URLSession.shared.dataTask(with: req) { data, resp, error in
                    alvo.queue.async {
                        defer { alvo.endWork() }
                        guard !alvo.exited else { return }
                        if let error {
                            alvo.call("__odete_fetchFail", [id, error.localizedDescription])
                            return
                        }
                        let http = resp as? HTTPURLResponse
                        var hdrs: [String: String] = [:]
                        for (k, v) in http?
                            .allHeaderFields ?? [:]
                        {
                            hdrs[String(describing: k).lowercased()] = String(describing: v)
                        }
                        alvo.call(
                            "__odete_fetchDone",
                            [
                                id,
                                http?.statusCode ?? 200,
                                hdrs,
                                alvo.bytes(data ?? Data()),
                                http?.url?.absoluteString ?? url,
                            ]
                        )
                    }
                }
                task.resume()
            }
        h.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }
}
