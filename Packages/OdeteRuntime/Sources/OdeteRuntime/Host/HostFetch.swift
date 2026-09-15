import Foundation
import JavaScriptCore
import OdeteI18n

/// `fetch` e `http.request` cliente via URLSession. Resposta volta como base64.
enum HostFetch {
    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let fetch: @convention(block) (Int, String, String, [String: String], JSValue?)
            -> Void = { [unowned rt] id, url, method, headers, bodyValue in
                let bodyB64: String? = (bodyValue?.isString == true) ? bodyValue?.toString() : nil
                guard let u = URL(string: url) else {
                    rt.call("__odete_fetchFail", [id, tr("URL inválida: %1$@", "\(url)")])
                    return
                }
                var req = URLRequest(url: u)
                req.httpMethod = method
                for (k, v) in headers {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if let bodyB64, let d = Data(base64Encoded: bodyB64) {
                    req.httpBody = d
                }
                rt.beginWork()
                let task = URLSession.shared.dataTask(with: req) { data, resp, error in
                    rt.queue.async {
                        defer { rt.endWork() }
                        guard !rt.exited else { return }
                        if let error {
                            rt.call("__odete_fetchFail", [id, error.localizedDescription])
                            return
                        }
                        let http = resp as? HTTPURLResponse
                        var hdrs: [String: String] = [:]
                        for (k, v) in http?
                            .allHeaderFields ?? [:]
                        {
                            hdrs[String(describing: k).lowercased()] = String(describing: v)
                        }
                        rt.call(
                            "__odete_fetchDone",
                            [
                                id,
                                http?.statusCode ?? 200,
                                hdrs,
                                (data ?? Data()).base64EncodedString(),
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
