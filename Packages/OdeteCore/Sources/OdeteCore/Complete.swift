import Foundation
import OdeteI18n

/// Uma sugestão do autocompletar.
public struct Completion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case word, path, snippet
        public var symbol: String {
            switch self {
            case .word: "textformat.abc"
            case .path: "folder"
            case .snippet: "chevron.left.forwardslash.chevron.right"
            }
        }
    }

    public var label: String
    /// Texto inserido no lugar do prefixo. `$0` marca onde o cursor fica.
    public var insert: String
    public var kind: Kind
    public var detail: String?
    public var id: String {
        "\(kind.rawValue):\(label)"
    }

    public init(label: String, insert: String, kind: Kind, detail: String? = nil) {
        self.label = label
        self.insert = insert
        self.kind = kind
        self.detail = detail
    }
}

/// O que o usuário está digitando: o prefixo antes do cursor e o contexto (palavra ou caminho).
public struct CompletionContext: Sendable, Hashable {
    public enum Mode: Sendable, Hashable { case word, path(String) }
    public var prefix: String
    /// Offset onde o prefixo começa. Em `Character`s quando veio de `context(text:cursor:)`;
    /// quando veio de `contexto(janela:inicioDaJanela:)` é o mesmo número de `inicioUTF16`,
    /// porque contar Characters desde o começo do arquivo é justamente o custo que o
    /// contexto por janela existe para evitar.
    public var start: Int
    public var mode: Mode
    /// Verdadeiro quando o trecho é um import de módulo (`from "…"`), e não um `src=`.
    public var modulo = false
    /// Onde o prefixo começa em unidades UTF-16 — a medida do editor e do `NSString`.
    public var inicioUTF16 = 0
}

public enum Complete {
    public struct Snippet: Sendable, Hashable {
        public var trigger: String
        public var detail: String
        public var body: String
    }

    static let jsSnippets: [Snippet] = [
        Snippet(trigger: "log", detail: "console.log(…)", body: "console.log($0)"),
        Snippet(trigger: "fn", detail: "function", body: "function $0() {\n  \n}"),
        Snippet(trigger: "afn", detail: "arrow function", body: "const $0 = () => {\n  \n}"),
        Snippet(trigger: "imp", detail: "import", body: "import $0 from \"\""),
        Snippet(trigger: "exp", detail: "export default", body: "export default $0"),
        Snippet(trigger: "useState", detail: "React state", body: "const [$0, set] = useState()"),
        Snippet(trigger: "useEffect", detail: "React effect", body: "useEffect(() => {\n  $0\n}, [])"),
        Snippet(trigger: "try", detail: "try/catch", body: "try {\n  $0\n} catch (e) {\n  console.error(e)\n}"),
        Snippet(trigger: "for", detail: "for…of", body: "for (const $0 of ) {\n  \n}"),
        Snippet(
            trigger: "fetch",
            detail: "fetch JSON",
            body: "const res = await fetch($0)\nconst data = await res.json()"
        ),
    ]

    static let swiftSnippets: [Snippet] = [
        Snippet(
            trigger: "struct",
            detail: "View",
            body: "struct $0: View {\n    var body: some View {\n        Text(\"\")\n    }\n}"
        ),
        Snippet(trigger: "state", detail: "@State", body: "@State private var $0 = "),
        Snippet(trigger: "vstack", detail: "VStack", body: "VStack {\n    $0\n}"),
        Snippet(trigger: "hstack", detail: "HStack", body: "HStack {\n    $0\n}"),
        Snippet(trigger: "button", detail: "Button", body: "Button(\"$0\") {\n    \n}"),
        Snippet(trigger: "foreach", detail: "ForEach", body: "ForEach($0) { item in\n    \n}"),
        Snippet(trigger: "func", detail: "func", body: "func $0() {\n    \n}"),
    ]

    static let htmlSnippets: [Snippet] = [
        Snippet(
            trigger: "html",
            detail: "documento",
            body: "<!doctype html>\n<html lang=\"pt-BR\">\n<head>\n  <meta charset=\"utf-8\">\n  <title>$0</title>\n</head>\n<body>\n</body>\n</html>"
        ),
        Snippet(trigger: "div", detail: "<div>", body: "<div>$0</div>"),
        Snippet(trigger: "a", detail: "<a href>", body: "<a href=\"$0\"></a>"),
        Snippet(trigger: "script", detail: "<script>", body: "<script type=\"module\" src=\"$0\"></script>"),
    ]

    static let cssSnippets: [Snippet] = [
        Snippet(
            trigger: "flex",
            detail: "flex center",
            body: "display: flex;\nalign-items: center;\njustify-content: center;$0"
        ),
        Snippet(trigger: "media", detail: "@media", body: "@media (max-width: $0px) {\n  \n}"),
    ]

    public static func snippets(for language: Language) -> [Snippet] {
        switch language {
        case .javascript, .jsx, .typescript, .tsx: jsSnippets
        case .swift: swiftSnippets
        case .html: htmlSnippets
        case .css: cssSnippets
        default: []
        }
    }

    /// Descobre o prefixo antes do cursor (offset em Characters).
    ///
    /// Copia o documento inteiro para um array de Characters. Serve para teste e para quem
    /// só tem uma `String` na mão; o editor usa `contexto(janela:inicioDaJanela:)`, que
    /// olha só a linha do cursor.
    public static func context(text: String, cursor: Int) -> CompletionContext? {
        let chars = Array(text)
        let end = min(max(cursor, 0), chars.count)
        guard var ctx = contexto(chars: chars, fim: end, paraAntesDaLinha: false) else { return nil }
        ctx.inicioUTF16 = chars[..<ctx.start].reduce(0) { $0 + $1.utf16.count }
        return ctx
    }

    /// A regra do contexto, sobre Characters que terminam no cursor.
    ///
    /// `paraAntesDaLinha` decide o que vale como fim de linha na volta até as aspas. A
    /// versão antiga só parava em `"\n"`, e num arquivo CRLF o `"\r\n"` é um Character só,
    /// diferente de `"\n"` — a volta atravessava a linha de cima. A janela para em qualquer
    /// quebra.
    static func contexto(chars: [Character], fim end: Int, paraAntesDaLinha: Bool) -> CompletionContext? {
        func quebra(_ c: Character) -> Bool {
            c == "\n" || (paraAntesDaLinha && c.isNewline)
        }
        // Caminho: dentro de aspas depois de from / import( / require( / src= / href=, ou começando com ./ ../ @/
        var q = end - 1
        var pathStart: Int?
        var moduloAqui = false
        while q >= 0, !quebra(chars[q]) {
            if chars[q] == "\"" || chars[q] == "'" || chars[q] == "`" {
                let inside = String(chars[(q + 1) ..< end])
                let before = String(chars[max(0, q - 12) ..< q])
                let ehModulo = before.contains("from ") || before.contains("import(") || before
                    .contains("require(") || before.contains("import ")
                let looksImport = ehModulo || before.contains("src=") || before.contains("href=")
                moduloAqui = ehModulo
                if looksImport || inside.hasPrefix("./") || inside.hasPrefix("../") || inside.hasPrefix("@/") || inside
                    .hasPrefix("/")
                {
                    pathStart = q + 1
                }
                break
            }
            q -= 1
        }
        if let ps = pathStart {
            let inside = String(chars[ps ..< end])
            guard !inside.contains(" ") else { return nil }
            let slash = inside.lastIndex(of: "/").map { inside.distance(from: inside.startIndex, to: $0) + 1 } ?? 0
            let prefix = String(inside.dropFirst(slash))
            return CompletionContext(
                prefix: prefix,
                start: ps + slash,
                mode: .path(String(inside.prefix(slash))),
                modulo: moduloAqui
            )
        }
        var s = end
        while s > 0, isWord(chars[s - 1]) {
            s -= 1
        }
        guard s < end else { return nil }
        return CompletionContext(prefix: String(chars[s ..< end]), start: s, mode: .word)
    }

    static func isWord(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_" || c == "$"
    }

    // MARK: - Contexto por janela

    /// Quantas unidades UTF-16 antes do cursor o contexto aceita olhar.
    ///
    /// Nenhum prefixo de palavra ou de caminho passa disso; o teto só existe para a linha
    /// de um arquivo minificado, que pode ter um megabyte, não ser lida inteira a cada tecla.
    public static let tetoDaJanela = 2000

    /// Folga antes do começo da linha. A regra das aspas olha doze Characters antes delas
    /// (`from `, `import(`), e as aspas podem abrir a linha.
    public static let folgaAntesDaLinha = 32

    /// Onde a janela do contexto começa, dado o começo da linha do cursor.
    ///
    /// O editor sabe o começo da linha sem varrer nada (o Runestone guarda as linhas numa
    /// árvore), então quem chama passa o número e recebe de volta a faixa a pedir.
    public static func inicioDaJanela(cursor: Int, inicioDaLinha: Int) -> Int {
        max(0, max(inicioDaLinha - folgaAntesDaLinha, cursor - tetoDaJanela))
    }

    /// O mesmo que `context(text:cursor:)`, olhando só o trecho que termina no cursor.
    ///
    /// Antes o contexto copiava o documento inteiro para um array de Characters, duas vezes
    /// por tecla — três com a lista aberta. Num arquivo de 2000 linhas era a maior parte do
    /// que o autocompletar custava no ator principal. A regra só olha para trás até o
    /// começo da linha, então a linha é tudo que ela precisa.
    ///
    /// - `janela`: o texto que termina exatamente no cursor.
    /// - `inicioDaJanela`: onde a janela começa no documento, em UTF-16.
    public static func contexto(janela: String, inicioDaJanela: Int) -> CompletionContext? {
        let chars = Array(janela)
        guard var ctx = contexto(chars: chars, fim: chars.count, paraAntesDaLinha: true) else { return nil }
        ctx.inicioUTF16 = inicioDaJanela + chars[..<ctx.start].reduce(0) { $0 + $1.utf16.count }
        ctx.start = ctx.inicioUTF16
        return ctx
    }

    /// Recorta a janela de um `NSString` e chama `contexto(janela:inicioDaJanela:)`.
    ///
    /// Para quem tem o documento como `NSString`; o editor recorta direto do Runestone.
    public static func contexto(em ns: NSString, cursor: Int) -> CompletionContext? {
        let fim = min(max(cursor, 0), ns.length)
        let inicio = inicioDaJanela(cursor: fim, inicioDaLinha: inicioDaLinha(em: ns, antesDe: fim))
        let janela = ns.substring(with: NSRange(location: inicio, length: fim - inicio))
        return contexto(janela: janela, inicioDaJanela: inicio)
    }

    /// Começo da linha que contém `fim`, procurando para trás até o teto da janela.
    static func inicioDaLinha(em ns: NSString, antesDe fim: Int) -> Int {
        var i = fim
        let limite = max(0, fim - tetoDaJanela)
        while i > limite {
            let c = ns.character(at: i - 1)
            if c == 10 || c == 13 {
                break
            }
            i -= 1
        }
        return i
    }

    /// Sugestões para um contexto já calculado, com as palavras vindas do índice e a linha
    /// do cursor lida agora.
    public static func sugestoes(
        para ctx: CompletionContext,
        indice: IndiceDePalavras,
        linha: LinhaDoCursor,
        language: Language,
        files: [String] = [],
        currentPath: String = "",
        packages: [String] = [],
        limit: Int = 8
    ) -> [Completion] {
        switch ctx.mode {
        case let .path(dir):
            return paths(
                dir: dir,
                prefix: ctx.prefix,
                files: files,
                currentPath: currentPath,
                packages: ctx.modulo && !dir.hasPrefix(".") && !dir.hasPrefix("/") && !dir.hasPrefix("@/")
                    ? packages : [],
                dir: dir,
                limit: limit
            )
        case .word:
            guard ctx.prefix.count >= 2 else { return [] }
            return palavras(indice: indice, linha: linha, prefix: ctx.prefix, language: language, limit: limit)
        }
    }

    /// `words(text:cursor:…)` sem varrer o documento: o documento vem contado no índice e
    /// só a linha do cursor é lida agora.
    ///
    /// A conta é `índice − linha do cursor quando o índice foi montado + linha do cursor
    /// agora`. Enquanto a pessoa digita numa linha só — que é quase sempre —, o resto do
    /// documento não muda, e a conta dá exatamente o que a varredura inteira daria, mesmo
    /// com o índice uma tecla atrasado. Quando o índice é de outra linha, ele está em dia
    /// (o editor remonta ao trocar de linha) e basta tirar a palavra do cursor.
    static func palavras(
        indice: IndiceDePalavras,
        linha: LinhaDoCursor,
        prefix: String,
        language: Language,
        limit: Int
    ) -> [Completion] {
        let lower = prefix.lowercased()
        var out: [Completion] = []
        for s in snippets(for: language) where s.trigger.lowercased().hasPrefix(lower) && s.trigger != prefix {
            out.append(Completion(label: s.trigger, insert: s.body, kind: .snippet, detail: s.detail))
        }
        // A linha como está agora, sem a palavra que o cursor está escrevendo.
        var aoVivo: [String: Int] = [:]
        var doCursor: String?
        IndiceDePalavras.cada(em: linha.texto) { palavra, inicio, fim in
            if inicio < linha.cursor, linha.cursor <= fim {
                doCursor = palavra
            } else {
                aoVivo[palavra, default: 0] += 1
            }
        }
        let mesmaLinha = indice.linha?.inicio == linha.inicio
        func contagem(_ w: String) -> Int {
            let total = indice.contagem(w)
            if mesmaLinha {
                return total - (indice.linha?.palavras[w] ?? 0) + (aoVivo[w] ?? 0)
            }
            return total - (w == doCursor ? 1 : 0)
        }
        var candidatas = Set(indice.comecandoCom(lower))
        for w in aoVivo.keys where w.lowercased().hasPrefix(lower) {
            candidatas.insert(w)
        }
        var contadas: [(palavra: String, n: Int)] = []
        for w in candidatas where w != prefix {
            let n = contagem(w)
            if n > 0 {
                contadas.append((w, n))
            }
        }
        contadas.sort { a, b in
            if a.n != b.n {
                return a.n > b.n
            }
            let ca = a.palavra.count, cb = b.palavra.count
            return ca != cb ? ca < cb : a.palavra < b.palavra
        }
        for (w, _) in contadas where !out.contains(where: { $0.label == w }) {
            out.append(Completion(label: w, insert: w, kind: .word))
            if out.count >= limit {
                break
            }
        }
        return Array(out.prefix(limit))
    }

    /// Sugestões para o texto e o cursor dados.
    /// - `files`: caminhos relativos ao projeto (para completar caminhos).
    /// - `currentPath`: caminho do arquivo aberto (para resolver `./`).
    public static func suggestions(
        text: String,
        cursor: Int,
        language: Language,
        files: [String] = [],
        currentPath: String = "",
        packages: [String] = [],
        limit: Int = 8
    ) -> [Completion] {
        guard let ctx = context(text: text, cursor: cursor) else { return [] }
        switch ctx.mode {
        case let .path(dir):
            return paths(
                dir: dir,
                prefix: ctx.prefix,
                files: files,
                currentPath: currentPath,
                // Pacote instalado só faz sentido num import sem caminho: `from "re…"`.
                // Com `./`, `/` ou `@/` a pessoa está apontando para dentro do projeto.
                packages: ctx.modulo && !dir.hasPrefix(".") && !dir.hasPrefix("/") && !dir.hasPrefix("@/")
                    ? packages : [],
                dir: dir,
                limit: limit
            )
        case .word:
            guard ctx.prefix.count >= 2 else { return [] }
            return words(text: text, cursor: cursor, prefix: ctx.prefix, language: language, limit: limit)
        }
    }

    static func paths(
        dir: String,
        prefix: String,
        files: [String],
        currentPath: String,
        packages: [String] = [],
        dir base0: String = "",
        limit: Int
    ) -> [Completion] {
        let base: String
        if dir.hasPrefix("@/") {
            base = "src/" + dir.dropFirst(2)
        } else if dir.hasPrefix("/") {
            base = String(dir.dropFirst())
        } else {
            var parts = currentPath.split(separator: "/").dropLast().map(String.init)
            for seg in dir.split(separator: "/") {
                if seg == ".." {
                    _ = parts.popLast()
                } else if seg != "." {
                    parts.append(String(seg))
                }
            }
            base = parts.joined(separator: "/")
        }
        var seen = Set<String>()
        var out: [Completion] = []
        // Pacotes instalados primeiro: é o que se procura quando se escreve `from "`.
        // Sem isto, ver node_modules na árvore não ajudava a escrever o import.
        for nome in packages {
            let alvo = base0.isEmpty ? nome : String(nome.dropFirst(min(base0.count, nome.count)))
            guard nome.hasPrefix(base0), !alvo.isEmpty,
                  prefix.isEmpty || alvo.lowercased().hasPrefix(prefix.lowercased()),
                  seen.insert(alvo).inserted else { continue }
            out.append(Completion(label: alvo, insert: alvo, kind: .path, detail: "pacote"))
        }
        for f in files where f != currentPath {
            let rel: Substring
            if base.isEmpty {
                rel = f[...]
            } else if f.hasPrefix(base + "/") {
                rel = f.dropFirst(base.count + 1)
            } else {
                continue
            }
            let first = rel.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard let head = first.first.map(String.init), !head.isEmpty else { continue }
            let isDir = first.count > 1
            let name = isDir ? head + "/" : head
            guard prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased()),
                  seen.insert(name).inserted else { continue }
            let insert = isDir ? name : stripExt(name)
            out.append(Completion(label: name, insert: insert, kind: .path, detail: isDir ? "pasta" : nil))
        }
        return Array(out.sorted { ($0.detail == nil) == ($1.detail == nil) ? $0.label < $1.label : $0.detail != nil }
            .prefix(limit))
    }

    static func stripExt(_ name: String) -> String {
        for ext in [".ts", ".tsx", ".js", ".jsx"] where name.hasSuffix(ext) && !name.hasSuffix(".d.ts") {
            return String(name.dropLast(ext.count))
        }
        return name
    }

    static func words(text: String, cursor: Int, prefix: String, language: Language, limit: Int) -> [Completion] {
        let lower = prefix.lowercased()
        var out: [Completion] = []
        for s in snippets(for: language) where s.trigger.lowercased().hasPrefix(lower) && s.trigger != prefix {
            out.append(Completion(label: s.trigger, insert: s.body, kind: .snippet, detail: s.detail))
        }
        // Palavras do documento, mais próximas do cursor primeiro; a própria palavra sendo digitada fica de fora.
        var counts: [String: Int] = [:] // palavra → ocorrências
        var word = ""
        var idx = 0
        var wordStart = 0
        func flush() {
            if word.count >= 3, word.lowercased().hasPrefix(lower), word != prefix,
               !(wordStart < cursor && cursor <= wordStart + word.count)
            {
                counts[word, default: 0] += 1
            }
            word = ""
        }
        for c in text {
            if isWord(c) {
                if word.isEmpty {
                    wordStart = idx
                }
                word.append(c)
            } else {
                flush()
            }
            idx += 1
        }
        flush()
        let ranked = counts.sorted { a, b in
            if a.value != b.value {
                return a.value > b.value
            }
            return a.key.count != b.key.count ? a.key.count < b.key.count : a.key < b.key
        }
        for (w, _) in ranked where !out.contains(where: { $0.label == w }) {
            out.append(Completion(label: w, insert: w, kind: .word))
        }
        return Array(out.prefix(limit))
    }
}

/// A linha do cursor como está agora, em UTF-16: o texto inteiro dela, onde ela começa no
/// documento e onde o cursor está dentro dela. `inicio` negativo quer dizer "linha longa
/// demais para ler" (arquivo minificado) — a conta por linha fica de fora.
public struct LinhaDoCursor: Sendable, Hashable {
    public var texto: String
    public var inicio: Int
    public var cursor: Int

    public init(texto: String, inicio: Int, cursor: Int) {
        self.texto = texto
        self.inicio = inicio
        self.cursor = cursor
    }
}

/// As palavras de um documento, contadas uma vez por versão do texto.
///
/// O autocompletar varria o arquivo inteiro a cada tecla: percorria Character por
/// Character, montava cada palavra e passava cada uma para minúscula. Num arquivo de 2000
/// linhas, isso e as cópias do contexto eram 9% do tempo do ator principal ao digitar.
/// Aqui a varredura acontece fora do ator principal, quando o texto muda de um jeito que
/// a linha do cursor não cobre, e cada palavra vai para minúscula uma vez só.
public struct IndiceDePalavras: Sendable {
    struct Entrada: Sendable {
        let palavra: String
        let minuscula: String
    }

    /// A linha onde estava o cursor quando o índice foi montado, com as palavras dela.
    public struct Linha: Sendable, Hashable {
        public var inicio: Int
        public var palavras: [String: Int]
    }

    /// As palavras agrupadas pela primeira letra em minúscula: a busca por prefixo só olha
    /// o grupo da letra digitada.
    private let grupos: [Character: [Entrada]]
    private let contagens: [String: Int]
    public let linha: Linha?

    public static let vazio = IndiceDePalavras(texto: "", linhaDoCursor: nil)

    /// - `linhaDoCursor`: a faixa UTF-16 da linha do cursor, para a conta de
    ///   `Complete.palavras` poder trocá-la pela versão de agora.
    public init(texto: String, linhaDoCursor: NSRange?) {
        var contagens: [String: Int] = [:]
        var daLinha: [String: Int] = [:]
        Self.cada(em: texto) { palavra, inicio, _ in
            contagens[palavra, default: 0] += 1
            if let l = linhaDoCursor, inicio >= l.location, inicio < NSMaxRange(l) {
                daLinha[palavra, default: 0] += 1
            }
        }
        var grupos: [Character: [Entrada]] = [:]
        for palavra in contagens.keys {
            let m = palavra.lowercased()
            guard let primeira = m.first else { continue }
            grupos[primeira, default: []].append(Entrada(palavra: palavra, minuscula: m))
        }
        self.grupos = grupos
        self.contagens = contagens
        linha = linhaDoCursor.map { Linha(inicio: $0.location, palavras: daLinha) }
    }

    /// Quantas vezes a palavra aparece no documento indexado.
    public func contagem(_ palavra: String) -> Int {
        contagens[palavra] ?? 0
    }

    /// As palavras cuja minúscula começa com `prefixo` (já em minúscula).
    public func comecandoCom(_ prefixo: String) -> [String] {
        guard let primeira = prefixo.first else { return Array(contagens.keys) }
        return (grupos[primeira] ?? []).filter { $0.minuscula.hasPrefix(prefixo) }.map(\.palavra)
    }

    /// Cada palavra de três Characters ou mais, com início e fim em UTF-16.
    ///
    /// A mesma regra de palavra do autocompletar (`Complete.isWord`) e o mesmo mínimo de
    /// três letras: palavra menor que isso não vale a sugestão.
    static func cada(em texto: String, _ achou: (String, Int, Int) -> Void) {
        var palavra = ""
        var tamanho = 0
        var inicio = 0
        var i = 0
        for c in texto {
            if Complete.isWord(c) {
                if palavra.isEmpty {
                    inicio = i
                }
                palavra.append(c)
                tamanho += 1
            } else if !palavra.isEmpty {
                if tamanho >= 3 {
                    achou(palavra, inicio, i)
                }
                palavra = ""
                tamanho = 0
            }
            i += c.utf16.count
        }
        if tamanho >= 3 {
            achou(palavra, inicio, i)
        }
    }
}
