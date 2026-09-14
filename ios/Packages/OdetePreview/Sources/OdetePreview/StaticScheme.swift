import Foundation
import UniformTypeIdentifiers
import WebKit

/// `odete://static/<caminho>` serve os arquivos do projeto direto do disco (HTML puro, sem build).
public final class StaticScheme: NSObject, WKURLSchemeHandler {
    public static let scheme = "odete"
    public static let host = "static"
    let root: URL

    public init(root: URL) {
        self.root = root
    }

    public func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var rel = url.path.isEmpty || url.path == "/" ? "/index.html" : url.path
        if rel.hasSuffix("/") {
            rel += "index.html"
        }
        let file = root.appending(path: String(rel.dropFirst())).standardizedFileURL
        guard file.path.hasPrefix(root.standardizedFileURL.path) else { fail(task, 403, "fora do projeto"); return }
        var isDir: ObjCBool = false
        var target = file
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir),
           isDir.boolValue
        {
            target = file.appending(path: "index.html")
        }
        guard let data = FileManager.default.contents(atPath: target.path) else { fail(
            task,
            404,
            "não encontrado: \(rel)"
        ); return }
        let type = UTType(filenameExtension: target.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let mime = type.hasPrefix("text/") || type.contains("javascript") || type
            .contains("json") ? type + "; charset=utf-8" : type
        let resp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store"]
        )!
        task.didReceive(resp)
        task.didReceive(data)
        task.didFinish()
    }

    public func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    private func fail(_ task: WKURLSchemeTask, _ status: Int, _ msg: String) {
        let body = Data(
            "<!doctype html><meta charset=utf-8><body style=\"font-family:system-ui;padding:24px;color:#888\"><h2>\(status)</h2><p>\(msg)</p>"
                .utf8
        )
        let resp = HTTPURLResponse(
            url: task.request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/html; charset=utf-8"]
        )!
        task.didReceive(resp); task.didReceive(body); task.didFinish()
    }
}
