import Foundation

/// Um problema que o app já conhece: lint, sintaxe, build, Swift ou erro do preview.
///
/// O agente só enxergava o que abria com `read_file` ou lia do terminal. A barra de
/// status mostrando "3 ⊗" e o agente respondendo "não vejo erro nenhum" era a mesma tela
/// falando duas coisas — e o erro que a pessoa quer consertar é justamente esse.
public struct Problema: Sendable, Hashable {
    public enum Gravidade: String, Sendable, Comparable {
        case error, warning, info

        var ordem: Int {
            switch self { case .error: 0; case .warning: 1; case .info: 2 }
        }

        public static func < (l: Gravidade, r: Gravidade) -> Bool {
            l.ordem < r.ordem
        }
    }

    /// Caminho relativo à raiz do projeto, ou nada quando o erro não tem arquivo aqui.
    public var arquivo: String?
    public var linha: Int?
    public var coluna: Int?
    public var gravidade: Gravidade
    public var mensagem: String
    /// De onde veio: `lint`, `syntax`, `esbuild`, `swift`, `preview`.
    public var fonte: String

    public init(
        arquivo: String?,
        linha: Int?,
        coluna: Int?,
        gravidade: Gravidade,
        mensagem: String,
        fonte: String
    ) {
        self.arquivo = arquivo
        self.linha = linha
        self.coluna = coluna
        self.gravidade = gravidade
        self.mensagem = mensagem
        self.fonte = fonte
    }

    /// `arquivo:linha:coluna gravidade mensagem (fonte)` — o formato que compilador e
    /// linter usam, e que qualquer modelo já sabe ler.
    public var linhaDeTexto: String {
        var local = arquivo ?? ""
        if !local.isEmpty, let linha {
            local += ":\(linha)"
            if let coluna {
                local += ":\(coluna)"
            }
        }
        // Mensagem de várias linhas (pilha do esbuild, stack do navegador) vira uma: o
        // formato é uma entrada por linha, e a primeira linha é a que diz o que houve.
        let texto = mensagem.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let corpo = "\(gravidade.rawValue) \(texto.prefix(400)) (\(fonte))"
        return local.isEmpty ? corpo : "\(local) \(corpo)"
    }
}

/// Uma linha do console do preview.
public struct LinhaDoConsole: Sendable, Hashable {
    /// `log`, `info`, `warn` ou `error`.
    public var nivel: String
    public var texto: String
    public var arquivo: String?
    public var linha: Int?

    public init(nivel: String, texto: String, arquivo: String? = nil, linha: Int? = nil) {
        self.nivel = nivel
        self.texto = texto
        self.arquivo = arquivo
        self.linha = linha
    }
}

/// O texto que `read_problems` e `read_preview_console` devolvem ao modelo.
///
/// Fica aqui, e não no app, para ser o mesmo em qualquer host e para dar para testar o
/// formato e os tetos sem montar um workspace.
public enum Diagnosticos {
    /// Mais que isso não ajuda a consertar nada: é a mesma causa repetida em cem lugares,
    /// e cada linha é contexto que sai da conversa.
    public static let tetoDeProblemas = 100
    public static let consolePadrao = 50
    public static let consoleMaximo = 200

    /// Erros primeiro, depois avisos; dentro de cada um, por arquivo e linha.
    public static func relatorio(_ problemas: [Problema], filtro: String? = nil) -> String {
        var lista = problemas
        if let filtro, !filtro.isEmpty {
            lista = lista.filter { p in
                guard let a = p.arquivo else { return false }
                return a == filtro || a.hasPrefix(filtro.hasSuffix("/") ? filtro : filtro + "/")
            }
        }
        // O mesmo erro visto por duas fontes (o lint do editor e o esbuild do servidor)
        // conta uma vez.
        var vistos = Set<String>()
        lista = lista.filter { vistos.insert($0.linhaDeTexto).inserted }
        guard !lista.isEmpty else {
            if let filtro, !filtro.isEmpty {
                return "(nenhum problema em \(filtro))"
            }
            return "(nenhum problema)"
        }
        lista.sort { l, r in
            if l.gravidade != r.gravidade {
                return l.gravidade < r.gravidade
            }
            if (l.arquivo ?? "") != (r.arquivo ?? "") {
                return (l.arquivo ?? "\u{10FFFF}") < (r.arquivo ?? "\u{10FFFF}")
            }
            return (l.linha ?? 0, l.coluna ?? 0) < (r.linha ?? 0, r.coluna ?? 0)
        }
        let erros = lista.count { $0.gravidade == .error }
        let avisos = lista.count { $0.gravidade == .warning }
        let infos = lista.count - erros - avisos
        var resumo = [plural(erros, "erro", "erros"), plural(avisos, "aviso", "avisos")]
        if infos > 0 {
            resumo.append(plural(infos, "nota", "notas"))
        }
        var linhas = [resumo.joined(separator: ", ")]
        linhas += lista.prefix(tetoDeProblemas).map(\.linhaDeTexto)
        if lista.count > tetoDeProblemas {
            linhas.append("… e mais \(lista.count - tetoDeProblemas) omitidos")
        }
        return linhas.joined(separator: "\n")
    }

    /// As últimas `n` linhas, a mais nova embaixo, como no painel.
    public static func console(_ linhas: [LinhaDoConsole], n: Int) -> String {
        let pedidas = min(consoleMaximo, max(1, n))
        let fim = linhas.suffix(pedidas)
        guard !fim.isEmpty else { return "(console do preview vazio)" }
        var out: [String] = []
        if linhas.count > fim.count {
            out.append("… \(linhas.count - fim.count) linhas mais antigas omitidas")
        }
        for l in fim {
            var s = "[\(l.nivel)] \(l.texto.prefix(500))"
            if let a = l.arquivo, !a.isEmpty {
                s += " (\(a)\(l.linha.map { ":\($0)" } ?? ""))"
            }
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    static func plural(_ n: Int, _ um: String, _ varios: String) -> String {
        "\(n) \(n == 1 ? um : varios)"
    }
}
