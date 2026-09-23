import Foundation
import OdeteI18n
import OdeteRuntime

/// O `vite build`: o index.html e o que ele carrega viram `dist/`, pronto para servir.
///
/// Um bundle de produção só, feito pelo esbuild do projeto, e o resto como o Vite entrega:
///   - o JS e o CSS saem em `assets/index-<hash>.js` e `.css`, e o index.html aponta para
///     eles no `<head>`. O hash muda com o conteúdo: o navegador pode guardar para sempre,
///     e um deploy novo nunca serve o bundle velho de cache;
///   - todos os `<script type="module">` da página e as folhas do projeto que ela liga
///     (`<link rel="stylesheet" href="/src/…">`) entram no mesmo bundle. Antes o link
///     ficava apontando para `/src/index.css`, que não existe em dist/, e cada script
///     ganhava um `<link>` para um CSS que só um deles tinha;
///   - o arquivo importado que passa de 4 KB (o `assetsInlineLimit` do Vite) sai em
///     `assets/<nome>-<hash>.<ext>`; o menor vai embutido;
///   - `import.meta.env` e `%VITE_X%` no HTML com o modo (`--mode`) e os `.env` dele, e o
///     `base` do vite.config (ou `--base`) na frente de cada endereço;
///   - o `default` de um pacote CommonJS é o mesmo do dev server (bundler.js, `fachada`);
///   - `public/` copiada como está.
public enum ViteBuild {
    public struct Opcoes: Sendable {
        public var modo: String
        /// `nil`: o do vite.config, ou `/`.
        public var base: String?
        /// `nil`: o `build.outDir` do vite.config, ou `dist`.
        public var saida: String?

        public init(modo: String = "production", base: String? = nil, saida: String? = nil) {
            self.modo = modo
            self.base = base
            self.saida = saida
        }
    }

    public struct Gravado: Sendable, Equatable {
        /// Relativo à raiz do projeto: `dist/assets/index-AB12CD34.js`.
        public var caminho: String
        public var bytes: Int
    }

    public struct Resultado: Sendable {
        public var ok: Bool
        public var diagnosticos: [Diagnostic]
        public var gravados: [Gravado]
        public var saida: String
    }

    /// O embutido no JS vai até aqui; o maior sai como arquivo.
    static let limiteDeInline = 4096
    /// A entrada que junta os scripts e as folhas da página. Só existe em memória.
    static let entradaVirtual = "__odete_vite_build.js"

    public static func rodar(raiz: URL, esbuild: Esbuild, opcoes: Opcoes = .init()) async throws -> Resultado {
        let fm = FileManager.default
        guard var html = try? String(contentsOf: raiz.appending(path: "index.html"), encoding: .utf8)
        else { throw RuntimeError(message: tr("vite build: sem index.html")) }
        let config = configDoVite(raiz)
        let base = normalizaBase(opcoes.base ?? config.base ?? "/")
        let saida = opcoes.saida ?? config.saida ?? "dist"
        let relativa = base == "./"

        let pagina = entradasDaPagina(html, raiz: raiz)
        guard pagina.contains(where: \.ehScript)
        else { throw RuntimeError(message: tr("vite build: nenhum <script type=module src> no index.html")) }
        // Dito aqui, pelo nome que está no HTML: pelo esbuild, o erro citaria a entrada
        // virtual que junta a página.
        if let falta = pagina.first(where: { !FileManager.default.fileExists(atPath: $0.arquivo.path) }) {
            throw RuntimeError(message: tr("vite build: o index.html carrega %1$@, que não existe", falta.ref))
        }
        // Na ordem do documento: a folha ligada no <head> vem antes do CSS que o script importa.
        let fonte = pagina.map { "import \(Self.literalJS($0.arquivo.path));" }.joined(separator: "\n") + "\n"

        // Com `base: "./"` não há endereço absoluto para um arquivo à parte: do JS ele seria
        // relativo à página, do CSS relativo à folha. Tudo embutido funciona dos dois lados.
        let r = try await esbuild.build(
            entries: [entradaVirtual],
            dev: false,
            minify: true,
            mode: opcoes.modo,
            base: base,
            entryNames: "assets/index-[hash]",
            assetNames: "assets/[name]-[hash]",
            publicPath: relativa ? nil : base,
            limiteDeInline: relativa ? nil : limiteDeInline,
            virtuais: [entradaVirtual: fonte],
            fachadas: true
        )
        guard r.ok else { return Resultado(ok: false, diagnosticos: r.diagnostics, gravados: [], saida: saida) }

        let destino = raiz.appending(path: saida)
        try? fm.removeItem(at: destino)
        try fm.createDirectory(at: destino.appending(path: "assets"), withIntermediateDirectories: true)
        // public/ primeiro: o que o build gera ganha de um arquivo de mesmo nome lá.
        let publica = raiz.appending(path: "public")
        if let itens = try? fm.contentsOfDirectory(at: publica, includingPropertiesForKeys: nil) {
            for item in itens {
                try? fm.copyItem(at: item, to: destino.appending(path: item.lastPathComponent))
            }
        }

        var gravados: [Gravado] = []
        var js: String?
        var css: String?
        for f in r.files {
            // O esbuild escreve (em memória) sob `dist/`; o destino pode ser outro.
            let rel = f.path.hasPrefix("dist/") ? String(f.path.dropFirst(5)) : f.path
            let alvo = destino.appending(path: rel)
            try fm.createDirectory(at: alvo.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: alvo)
            try f.data.write(to: alvo)
            gravados.append(Gravado(caminho: saida + "/" + rel, bytes: f.data.count))
            if rel.hasPrefix("assets/index-") {
                if rel.hasSuffix(".js") {
                    js = rel
                } else if rel.hasSuffix(".css") {
                    css = rel
                }
            }
        }

        // O index.html: sem os scripts e folhas que viraram bundle, com os do bundle no
        // <head> (módulo roda depois do documento lido, como antes), como o Vite escreve.
        for trecho in pagina.map(\.tag) {
            html = html.replacingOccurrences(of: trecho, with: "")
        }
        var cabeca = ""
        if let js {
            cabeca += "<script type=\"module\" crossorigin src=\"\(base)\(js)\"></script>\n"
        }
        if let css {
            cabeca += "<link rel=\"stylesheet\" crossorigin href=\"\(base)\(css)\">\n"
        }
        if let fim = html.range(of: "</head>") {
            html.insert(contentsOf: cabeca, at: fim.lowerBound)
        } else {
            html = cabeca + html
        }
        html = substituiEnv(html, r.env)
        html = prefixaPublicos(html, base: base, publica: publica)
        let indice = Data(html.utf8)
        try indice.write(to: destino.appending(path: "index.html"))
        gravados.insert(Gravado(caminho: saida + "/index.html", bytes: indice.count), at: 0)
        return Resultado(ok: true, diagnosticos: r.diagnostics, gravados: gravados, saida: saida)
    }

    // MARK: - Página

    struct DaPagina {
        var tag: String
        /// Como está no HTML (`/src/main.tsx`).
        var ref: String
        var arquivo: URL
        var ehScript: Bool
    }

    /// Os `<script type="module" src>` (a mesma forma que o dev server reconhece) e os
    /// `<link rel="stylesheet">` que apontam para um arquivo do projeto, na ordem do
    /// documento. Folha de fora (`https://…`) ou de `public/` fica como está.
    static func entradasDaPagina(_ html: String, raiz: URL) -> [DaPagina] {
        var achados: [(String.Index, DaPagina)] = []
        for m in html.matches(of: /<script\s+type="module"\s+src="([^"]+)"\s*>\s*<\/script>/) {
            // O script que falta entra (e o build diz que falta); a folha que falta, não —
            // ela pode ser de um servidor que não é este.
            guard let u = arquivoDoProjeto(String(m.1), raiz: raiz, mesmoQueFalte: true) else { continue }
            achados.append((
                m.range.lowerBound,
                DaPagina(tag: String(m.0), ref: String(m.1), arquivo: u, ehScript: true)
            ))
        }
        for m in html.matches(of: /<link\b[^>]*>/) {
            let tag = String(m.0)
            guard tag.contains(/rel\s*=\s*["']?stylesheet/),
                  let href = tag.firstMatch(of: /href\s*=\s*["']([^"']+)["']/)?.1,
                  let u = arquivoDoProjeto(String(href), raiz: raiz),
                  !u.path.hasPrefix(raiz.appending(path: "public").path + "/") else { continue }
            achados.append((m.range.lowerBound, DaPagina(tag: tag, ref: String(href), arquivo: u, ehScript: false)))
        }
        return achados.sorted { $0.0 < $1.0 }.map(\.1)
    }

    /// `/src/main.tsx`, `./src/main.tsx` e `src/main.tsx` são o mesmo arquivo da raiz.
    /// Endereço de fora não é do projeto; arquivo que não existe só é se `mesmoQueFalte`.
    static func arquivoDoProjeto(_ ref: String, raiz: URL, mesmoQueFalte: Bool = false) -> URL? {
        if ref.hasPrefix("//") || ref.contains(":") {
            return nil
        }
        let limpo = String(ref.split(separator: "?", maxSplits: 1).first ?? "")
        let rel = limpo.replacingOccurrences(of: "^(\\./|/)+", with: "", options: .regularExpression)
        guard !rel.isEmpty else { return nil }
        let u = raiz.appending(path: rel).standardizedFileURL
        var pasta: ObjCBool = false
        let existe = FileManager.default.fileExists(atPath: u.path, isDirectory: &pasta)
        if pasta.boolValue {
            return nil
        }
        return existe || mesmoQueFalte ? u : nil
    }

    /// `%VITE_TITULO%`, `%MODE%`: o valor, como no Vite. O que não é do `import.meta.env`
    /// (um `100%` solto) fica como está.
    static func substituiEnv(_ html: String, _ env: [String: String]) -> String {
        html.replacing(/%(\S+?)%/) { m in env[String(m.1)] ?? String(m.0) }
    }

    /// Com `base` diferente de `/`, `src="/logo.svg"` que mora em public/ passa a apontar
    /// para o endereço de onde o site vai ser servido, como o Vite faz.
    static func prefixaPublicos(_ html: String, base: String, publica: URL) -> String {
        guard base != "/" else { return html }
        return html.replacing(/(src|href)="\/([^"\/][^"]*)"/) { m in
            let rel = String(m.2.split(separator: "?", maxSplits: 1).first ?? "")
            guard FileManager.default.fileExists(atPath: publica.appending(path: rel).path) else { return String(m.0) }
            return "\(m.1)=\"\(base)\(m.2)\""
        }
    }

    // MARK: - Configuração

    /// `base` e `build.outDir` do vite.config, quando são texto literal. A config não roda:
    /// ela importa o próprio Vite, que não sobe aqui. Uma expressão (`base:
    /// process.env.BASE`) não é lida, e vale o padrão.
    public static func configDoVite(_ raiz: URL) -> (base: String?, saida: String?) {
        for nome in [
            "vite.config.ts",
            "vite.config.mts",
            "vite.config.js",
            "vite.config.mjs",
            "vite.config.cts",
            "vite.config.cjs",
        ] {
            guard let texto = try? String(contentsOf: raiz.appending(path: nome), encoding: .utf8) else { continue }
            // Linha comentada não vale. `//` no meio da linha pode ser de uma URL.
            let util = texto.split(separator: "\n", omittingEmptySubsequences: false)
                .filter {
                    let t = $0.drop { $0 == " " || $0 == "\t" }
                    return !t.hasPrefix("//") && !t.hasPrefix("*") && !t.hasPrefix("/*")
                }
                .joined(separator: "\n")
            let base = util.firstMatch(of: /(?:^|[\s{,])base\s*:\s*(["'`])([^"'`]*)\1/)?.2
            let saida = util.firstMatch(of: /(?:^|[\s{,])outDir\s*:\s*(["'`])([^"'`]+)\1/)?.2
            return (base.map(String.init), saida.map(String.init))
        }
        return (nil, nil)
    }

    /// Como o Vite: `./` (ou vazio) é relativo; o resto termina em `/` e, se não for URL,
    /// começa com `/`.
    public static func normalizaBase(_ base: String) -> String {
        let b = base.trimmingCharacters(in: .whitespaces)
        if b.isEmpty || b == "." || b == "./" {
            return "./"
        }
        var r = b
        if !r.hasSuffix("/") {
            r += "/"
        }
        if !r.hasPrefix("/"), !r.contains("://"), !r.hasPrefix("./") {
            r = "/" + r
        }
        return r
    }

    static func literalJS(_ s: String) -> String {
        let dados = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let json = dados.map { String(decoding: $0, as: UTF8.self) } ?? "[\"\"]"
        return String(json.dropFirst().dropLast())
    }
}
