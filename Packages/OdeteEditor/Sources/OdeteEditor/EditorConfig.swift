import Foundation

/// O que o `.editorconfig` do projeto diz sobre um arquivo. `nil` em cada campo é "não diz
/// nada": aí vale o que o arquivo já usa e, por último, os Ajustes.
public struct ConfigDoArquivo: Equatable, Sendable {
    public enum Recuo: String, Equatable, Sendable {
        case espacos
        case tab
    }

    /// `indent_style`
    public var recuo: Recuo?
    /// `indent_size` (com `indent_size = tab`, vale o `tab_width`).
    public var tamanhoDoRecuo: Int?
    /// `tab_width`
    public var larguraDoTab: Int?
    /// `end_of_line`
    public var fimDeLinha: FimDeLinha?
    /// `insert_final_newline`
    public var quebraNoFim: Bool?
    /// `trim_trailing_whitespace`
    public var aparar: Bool?

    public init(
        recuo: Recuo? = nil,
        tamanhoDoRecuo: Int? = nil,
        larguraDoTab: Int? = nil,
        fimDeLinha: FimDeLinha? = nil,
        quebraNoFim: Bool? = nil,
        aparar: Bool? = nil
    ) {
        self.recuo = recuo
        self.tamanhoDoRecuo = tamanhoDoRecuo
        self.larguraDoTab = larguraDoTab
        self.fimDeLinha = fimDeLinha
        self.quebraNoFim = quebraNoFim
        self.aparar = aparar
    }

    public var vazia: Bool {
        self == ConfigDoArquivo()
    }
}

/// Leitura do `.editorconfig` (editorconfig.org): seções com padrões de caminho e as
/// propriedades que o editor sabe usar.
///
/// Projeto que declara "recuo de 4 espaços" ou "CRLF" num `.editorconfig` esperava ver
/// isso respeitado; a Odete forçava o recuo dos Ajustes em todo arquivo.
public enum EditorConfig {
    struct Secao {
        var padrao: String
        var props: [String: String]
    }

    struct Arquivo {
        var raiz = false
        var secoes: [Secao] = []
    }

    static func ler(_ texto: String) -> Arquivo {
        var arq = Arquivo()
        var atual: Secao?
        for bruta in texto.components(separatedBy: .newlines) {
            let linha = bruta.trimmingCharacters(in: .whitespaces)
            if linha.isEmpty || linha.hasPrefix("#") || linha.hasPrefix(";") {
                continue
            }
            if linha.hasPrefix("["), linha.hasSuffix("]") {
                if let atual {
                    arq.secoes.append(atual)
                }
                atual = Secao(padrao: String(linha.dropFirst().dropLast()), props: [:])
                continue
            }
            guard let igual = linha.firstIndex(where: { $0 == "=" || $0 == ":" }) else { continue }
            let chave = linha[..<igual].trimmingCharacters(in: .whitespaces).lowercased()
            var valor = linha[linha.index(after: igual)...].trimmingCharacters(in: .whitespaces)
            // Comentário no fim da linha (`indent_size = 2 # dois`).
            if let c = valor.range(of: " #") ?? valor.range(of: " ;") {
                valor = valor[..<c.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            valor = valor.lowercased()
            if atual == nil {
                if chave == "root" {
                    arq.raiz = valor == "true"
                }
            } else {
                atual?.props[chave] = valor
            }
        }
        if let atual {
            arq.secoes.append(atual)
        }
        return arq
    }

    /// A configuração de `caminho` (relativo à raiz do projeto).
    ///
    /// `arquivos` são os `.editorconfig` encontrados subindo da pasta do arquivo até a raiz
    /// do projeto — o mais próximo primeiro —, cada um com a pasta onde mora (relativa à
    /// raiz, `""` para a própria raiz). A busca para no primeiro com `root = true`; o mais
    /// próximo manda sobre o mais distante, e dentro de um arquivo a última seção que casa
    /// manda sobre as de cima.
    public static func config(para caminho: String, arquivos: [(pasta: String, texto: String)]) -> ConfigDoArquivo {
        var valendo: [(pasta: String, arquivo: Arquivo)] = []
        for a in arquivos {
            let lido = ler(a.texto)
            valendo.append((a.pasta, lido))
            if lido.raiz {
                break
            }
        }
        var props: [String: String] = [:]
        for (pasta, arq) in valendo.reversed() {
            let relativo: String
            if pasta.isEmpty {
                relativo = caminho
            } else if caminho.hasPrefix(pasta + "/") {
                relativo = String(caminho.dropFirst(pasta.count + 1))
            } else {
                continue
            }
            for s in arq.secoes where casa(s.padrao, relativo) {
                for (k, v) in s.props {
                    props[k] = v
                }
            }
        }
        return config(de: props)
    }

    static func config(de props: [String: String]) -> ConfigDoArquivo {
        func valor(_ k: String) -> String? {
            guard let v = props[k], v != "unset" else { return nil }
            return v
        }
        func booleano(_ k: String) -> Bool? {
            switch valor(k) {
            case "true": true
            case "false": false
            default: nil
            }
        }
        var c = ConfigDoArquivo()
        switch valor("indent_style") {
        case "space": c.recuo = .espacos
        case "tab": c.recuo = .tab
        default: break
        }
        c.larguraDoTab = valor("tab_width").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        if valor("indent_size") == "tab" {
            c.tamanhoDoRecuo = c.larguraDoTab
        } else {
            c.tamanhoDoRecuo = valor("indent_size").flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        }
        // Pela especificação, `tab_width` sem valor herda o `indent_size`.
        if c.larguraDoTab == nil, valor("indent_size") != "tab" {
            c.larguraDoTab = c.tamanhoDoRecuo
        }
        c.fimDeLinha = valor("end_of_line").flatMap(FimDeLinha.init(rawValue:))
        c.quebraNoFim = booleano("insert_final_newline")
        c.aparar = booleano("trim_trailing_whitespace")
        return c
    }

    /// O padrão de uma seção casa com o caminho (relativo à pasta do `.editorconfig`)?
    ///
    /// Padrão sem `/` vale para o nome do arquivo em qualquer pasta; com `/`, é relativo à
    /// pasta do `.editorconfig`.
    static func casa(_ padrao: String, _ caminho: String) -> Bool {
        var p = padrao
        let ancorado = p.contains("/")
        if p.hasPrefix("/") {
            p.removeFirst()
        }
        let corpo = regex(p)
        let completo = "^" + (ancorado ? "" : "(?:.*/)?") + corpo + "$"
        guard let re = try? NSRegularExpression(pattern: completo) else { return false }
        let ns = caminho as NSString
        return re.firstMatch(in: caminho, range: NSRange(location: 0, length: ns.length)) != nil
    }

    /// Traduz o glob do EditorConfig para expressão regular: `*`, `**`, `?`, `[abc]`,
    /// `[!abc]`, `{a,b}` e `{1..3}`.
    static func regex(_ glob: String) -> String {
        let c = Array(glob)
        var out = ""
        var i = 0
        while i < c.count {
            let ch = c[i]
            switch ch {
            case "*":
                if i + 1 < c.count, c[i + 1] == "*" {
                    out += ".*"
                    i += 1
                } else {
                    out += "[^/]*"
                }
            case "?":
                out += "[^/]"
            case "[":
                if let fim = c[(i + 1)...].firstIndex(of: "]") {
                    var dentro = String(c[(i + 1) ..< fim])
                    if dentro.hasPrefix("!") {
                        dentro = "^" + dentro.dropFirst()
                    }
                    out += "[" + dentro.replacingOccurrences(of: "\\", with: "\\\\") + "]"
                    i = fim
                } else {
                    out += "\\["
                }
            case "{":
                if let fim = fechamento(c, de: i) {
                    let dentro = String(c[(i + 1) ..< fim])
                    let partes = separar(dentro)
                    if let faixa = numeros(dentro) {
                        out += "(?:" + faixa.map(String.init).joined(separator: "|") + ")"
                    } else if partes.count > 1 {
                        out += "(?:" + partes.map(regex).joined(separator: "|") + ")"
                    } else {
                        out += "\\{" + regex(dentro) + "\\}"
                    }
                    i = fim
                } else {
                    out += "\\{"
                }
            case "\\":
                if i + 1 < c.count {
                    out += NSRegularExpression.escapedPattern(for: String(c[i + 1]))
                    i += 1
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(ch))
            }
            i += 1
        }
        return out
    }

    private static func fechamento(_ c: [Character], de inicio: Int) -> Int? {
        var nivel = 0
        for j in inicio ..< c.count {
            if c[j] == "{" {
                nivel += 1
            } else if c[j] == "}" {
                nivel -= 1
                if nivel == 0 {
                    return j
                }
            }
        }
        return nil
    }

    /// Separa `a,b,{c,d}` nas vírgulas de fora das chaves.
    private static func separar(_ s: String) -> [String] {
        var partes: [String] = []
        var atual = ""
        var nivel = 0
        for ch in s {
            if ch == "{" {
                nivel += 1
            } else if ch == "}" {
                nivel -= 1
            }
            if ch == ",", nivel == 0 {
                partes.append(atual)
                atual = ""
            } else {
                atual.append(ch)
            }
        }
        partes.append(atual)
        return partes
    }

    /// `{3..7}`: a faixa de números, se for isso. Faixa enorme não vira alternativa.
    private static func numeros(_ s: String) -> ClosedRange<Int>? {
        let partes = s.components(separatedBy: "..")
        guard partes.count == 2, let a = Int(partes[0]), let b = Int(partes[1]), a <= b, b - a <= 1000
        else { return nil }
        return a ... b
    }
}
