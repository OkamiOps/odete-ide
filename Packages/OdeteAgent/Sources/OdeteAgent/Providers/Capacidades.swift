import Foundation
import Synchronization

/// Como o modelo pensa, do ponto de vista do pedido.
public enum Pensamento: String, Codable, Sendable {
    /// `thinking: {type: "adaptive"}`, com a profundidade em `output_config.effort`.
    case adaptativo
    /// `thinking: {type: "enabled", budget_tokens}` — modelos que ainda pedem orçamento.
    case orcamento
    /// O modelo não pensa, ou o endpoint não aceita o campo.
    case nenhum
}

/// O que se sabe de um modelo para montar o pedido certo.
///
/// Sai de três lugares, do mais confiável para o menos: a API do próprio provedor (a
/// Models API da Anthropic diz janela, teto de saída, tipos de thinking e níveis de
/// esforço; a lista do Codex diz janela e níveis), o catálogo público do models.dev e o
/// que um 400 ensinou. O que ninguém disse fica nulo e vale o formato mais novo da
/// família: um modelo que saiu ontem se parece mais com o de hoje do que com o de dois
/// anos atrás. Lista de nomes de modelo decidindo parâmetro envelhece na semana seguinte.
public struct Capacidades: Codable, Sendable, Equatable {
    public var contexto: Int?
    public var saida: Int?
    /// Níveis de esforço aceitos. Nulo: não se sabe. Vazio: o modelo não tem esforço.
    public var esforcos: [String]?
    public var pensamento: Pensamento?
    /// Campo em que um provedor compatível com a OpenAI quer o raciocínio de volta nas
    /// mensagens do assistente (o `reasoning_content` da DeepSeek, por exemplo).
    public var campoDoRaciocinio: String?
    /// Campos opcionais que o endpoint recusou com 400. Não vão mais.
    public var recusados: [String]?
    /// Quando a API do provedor foi consultada por último, dando certo ou não.
    public var consultaDaAPI: Date?

    public init(
        contexto: Int? = nil,
        saida: Int? = nil,
        esforcos: [String]? = nil,
        pensamento: Pensamento? = nil,
        campoDoRaciocinio: String? = nil,
        recusados: [String]? = nil,
        consultaDaAPI: Date? = nil
    ) {
        self.contexto = contexto; self.saida = saida; self.esforcos = esforcos; self.pensamento = pensamento
        self.campoDoRaciocinio = campoDoRaciocinio; self.recusados = recusados; self.consultaDaAPI = consultaDaAPI
    }

    /// Preenche o que falta com o que `outra` sabe.
    func completada(com outra: Capacidades?) -> Capacidades {
        guard let o = outra else { return self }
        var c = self
        c.contexto = contexto ?? o.contexto
        c.saida = saida ?? o.saida
        c.esforcos = esforcos ?? o.esforcos
        c.pensamento = pensamento ?? o.pensamento
        c.campoDoRaciocinio = campoDoRaciocinio ?? o.campoDoRaciocinio
        c.recusados = Self.unir(recusados, o.recusados)
        c.consultaDaAPI = consultaDaAPI ?? o.consultaDaAPI
        return c
    }

    /// O que `nova` sabe passa por cima; o que ela não sabe fica. Recusas se somam.
    func atualizada(com nova: Capacidades) -> Capacidades {
        var c = nova.completada(com: self)
        c.recusados = Self.unir(recusados, nova.recusados)
        return c
    }

    func recusou(_ campo: String) -> Bool {
        recusados?.contains(campo) == true
    }

    mutating func recusar(_ campo: String) {
        recusados = Self.unir(recusados, [campo])
    }

    private static func unir(_ a: [String]?, _ b: [String]?) -> [String]? {
        let u = Set((a ?? []) + (b ?? []))
        return u.isEmpty ? nil : u.sorted()
    }

    /// Pasta de cache: `Caches` não vai para o iCloud nem para o backup, e o sistema pode
    /// limpar quando faltar espaço — o que só custa baixar de novo.
    static var pastaDoCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "Odete/modelos")
    }
}

/// A família de API de cada tipo de conta: qual formato é o mais novo e onde procurar o
/// modelo no catálogo.
enum Familia {
    case anthropic, openai, xai, apple

    init(_ kind: ProviderKind) {
        switch kind {
        case .apple: self = .apple
        case .claude, .anthropicCompat: self = .anthropic
        case .codex, .openaiCompat: self = .openai
        case .grok: self = .xai
        }
    }

    /// Os níveis de esforço da geração mais nova, para o modelo que ninguém descreveu.
    var esforcosMaisNovos: [String] {
        switch self {
        case .anthropic: ["low", "medium", "high", "xhigh", "max"]
        case .openai: ["low", "medium", "high", "xhigh", "max"]
        case .xai: ["low", "medium", "high", "xhigh"]
        case .apple: []
        }
    }

    /// Teto de saída a pedir quando ninguém disse o do modelo. Só a Anthropic exige
    /// `max_tokens`; vai o maior da geração atual, e um 400 ensina o certo.
    var saidaPadrao: Int {
        128_000
    }

    /// Onde o models.dev guarda os modelos desta família.
    var noCatalogo: [String] {
        switch self {
        case .anthropic: ["anthropic"]
        case .openai: ["openai"]
        case .xai: ["xai"]
        case .apple: []
        }
    }
}

// MARK: - Leitura das respostas das APIs

extension Capacidades {
    /// Um modelo da Models API da Anthropic (`GET /v1/models/{id}` ou um item da lista).
    static func daAnthropic(_ m: [String: Any]) -> Capacidades {
        var c = Capacidades()
        c.contexto = inteiro(m["max_input_tokens"])
        c.saida = inteiro(m["max_tokens"])
        guard let cap = m["capabilities"] as? [String: Any] else { return c }
        func suportado(_ x: Any?) -> Bool? {
            (x as? [String: Any])?["supported"] as? Bool
        }
        if let th = cap["thinking"] as? [String: Any] {
            let tipos = th["types"] as? [String: Any]
            if suportado(tipos?["adaptive"]) == true {
                c.pensamento = .adaptativo
            } else if suportado(tipos?["enabled"]) == true {
                c.pensamento = .orcamento
            } else if th["supported"] as? Bool == false || tipos != nil {
                c.pensamento = .nenhum
            }
        }
        if let ef = cap["effort"] as? [String: Any] {
            if ef["supported"] as? Bool == false {
                c.esforcos = []
            } else {
                // Os níveis são as chaves com `supported: true`: um nível novo aparece
                // sozinho, sem ninguém mexer aqui.
                c.esforcos = Effort.ordenar(ef.compactMap { k, v in suportado(v) == true ? k : nil })
            }
        }
        return c
    }

    /// Um item de lista de modelos em formato livre (Codex, xAI, compatíveis).
    static func daLista(_ m: [String: Any]) -> Capacidades {
        var c = Capacidades()
        let cap = (m["capabilities"] as? [String: Any]) ?? [:]
        c.contexto = inteiro(m["context_window"] ?? m["context_length"] ?? m["max_input_tokens"] ??
            m["input_token_limit"] ?? cap["context_window"] ?? cap["context_length"])
        c.saida = inteiro(m["max_output_tokens"] ?? m["output_token_limit"] ?? m["max_completion_tokens"] ??
            (m["top_provider"] as? [String: Any])?["max_completion_tokens"])
        var niveis: [String]?
        for chave in ["supported_reasoning_levels", "supported_reasoning_efforts", "reasoning_efforts", "efforts"] {
            guard let l = m[chave] as? [Any] else { continue }
            niveis = l.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["effort"] as? String) }
            break
        }
        if let n = niveis {
            c.esforcos = Effort.ordenar(n)
        }
        return c
    }

    static func inteiro(_ v: Any?) -> Int? {
        if let i = v as? Int {
            return i > 0 ? i : nil
        }
        if let d = v as? Double {
            return d > 0 ? Int(d) : nil
        }
        if let s = v as? String, let i = Int(s) {
            return i > 0 ? i : nil
        }
        return nil
    }
}

// MARK: - O que fica guardado

/// O que se aprendeu de cada modelo, em memória e num arquivo no cache.
///
/// Leitura síncrona de propósito: o seletor de esforço da tela pergunta daqui a cada
/// desenho e não pode esperar rede.
final class RegistroDeCapacidades: Sendable {
    static let compartilhado = RegistroDeCapacidades(
        arquivo: Capacidades.pastaDoCache.appending(path: "capacidades.json")
    )

    private let arquivo: URL?
    private let estado: Mutex<[String: Capacidades]>

    /// `arquivo` nulo: só memória (testes).
    init(arquivo: URL?) {
        self.arquivo = arquivo
        var inicial: [String: Capacidades] = [:]
        if let arquivo, let d = try? Data(contentsOf: arquivo) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            inicial = (try? dec.decode([String: Capacidades].self, from: d)) ?? [:]
        }
        estado = Mutex(inicial)
    }

    static func chave(_ kind: ProviderKind, _ model: String) -> String {
        "\(kind.rawValue)|\(model.lowercased())"
    }

    func ler(_ kind: ProviderKind, _ model: String) -> Capacidades? {
        estado.withLock { $0[Self.chave(kind, model)] }
    }

    /// Junta o que se aprendeu agora ao que já se sabia.
    func atualizar(_ kind: ProviderKind, _ model: String, com nova: Capacidades) {
        atualizar(kind, [(model, nova)])
    }

    /// Vários de uma vez (a lista de modelos inteira), numa gravação só.
    func atualizar(_ kind: ProviderKind, _ novos: [(String, Capacidades)]) {
        estado.withLock { e in
            for (model, nova) in novos {
                let k = Self.chave(kind, model)
                e[k] = (e[k] ?? Capacidades()).atualizada(com: nova)
            }
            // Grava dentro da trava: duas gravações seguidas não chegam ao disco trocadas.
            gravar(e)
        }
    }

    /// Troca pelo que veio, sem juntar — para quando um 400 corrige o que se achava.
    func substituir(_ kind: ProviderKind, _ model: String, por c: Capacidades) {
        estado.withLock { e in
            e[Self.chave(kind, model)] = c
            gravar(e)
        }
    }

    private func gravar(_ tudo: [String: Capacidades]) {
        guard let arquivo else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        guard let d = try? enc.encode(tudo) else { return }
        try? FileManager.default.createDirectory(
            at: arquivo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? d.write(to: arquivo, options: .atomic)
    }
}

// MARK: - Catálogo do models.dev

/// O catálogo público do models.dev — o mesmo que o opencode usa: janela, teto de saída,
/// se o modelo raciocina e com quais níveis, para centenas de modelos de dezenas de
/// provedores. Baixado uma vez por dia, guardado enxuto no cache.
final class CatalogoDeModelos: Sendable {
    static let endereco = URL(string: "https://models.dev/api.json")!
    static let compartilhado = CatalogoDeModelos(pasta: Capacidades.pastaDoCache, http: URLSessionClient())

    struct Entrada: Codable, Sendable, Equatable {
        var contexto: Int?
        var saida: Int?
        var raciocina: Bool?
        var esforcos: [String]?
        var orcamento: Bool?
        var campoDoRaciocinio: String?

        var capacidades: Capacidades {
            var c = Capacidades(contexto: contexto, saida: saida, campoDoRaciocinio: campoDoRaciocinio)
            if raciocina == false {
                c.esforcos = []; c.pensamento = .nenhum
            } else if let e = esforcos {
                c.esforcos = Effort.ordenar(e); c.pensamento = .adaptativo
            } else if orcamento == true {
                c.esforcos = []; c.pensamento = .orcamento
            }
            return c
        }
    }

    struct Indice: Codable, Sendable {
        var em: Date
        /// provedor → id do modelo (minúsculo) → entrada.
        var provedores: [String: [String: Entrada]]
    }

    private let pasta: URL?
    private let http: HTTPClient
    let validade: TimeInterval
    private let indice = Mutex<Indice?>(nil)
    private let leuODisco = Mutex(false)
    private let baixando = Mutex<Task<Indice?, Never>?>(nil)
    private let ultimaFalha = Mutex<Date?>(nil)

    init(pasta: URL?, http: HTTPClient, validade: TimeInterval = 86400) {
        self.pasta = pasta
        self.http = http
        self.validade = validade
    }

    private var arquivo: URL? {
        pasta?.appending(path: "catalogo.json")
    }

    /// A entrada do modelo, baixando o catálogo se ainda não houver nenhum. Espera a
    /// descida no máximo `esperaMaxima` segundos; ela continua depois disso, e a próxima
    /// pergunta já acha.
    func entrada(kind: ProviderKind, model: String, esperaMaxima: Double = 20) async -> Entrada? {
        carregarDoDisco()
        if let i = indice.withLock({ $0 }) {
            if Date().timeIntervalSince(i.em) > validade {
                _ = atualizar()
            }
            return Self.procurar(i, kind: kind, model: model)
        }
        let descida = atualizar()
        let i = await withTaskGroup(of: Indice?.self) { g -> Indice? in
            g.addTask { await descida.value }
            g.addTask {
                try? await Task.sleep(for: .seconds(esperaMaxima))
                return nil
            }
            let primeiro = await g.next() ?? nil
            g.cancelAll()
            return primeiro
        }
        return i.flatMap { Self.procurar($0, kind: kind, model: model) }
    }

    /// Só o que já está no aparelho, sem esperar e sem rede: para a tela. Desenhar o
    /// seletor não é pedir nada à internet — o catálogo desce quando a pessoa manda uma
    /// mensagem a um modelo na nuvem (ver `HTTPProvider.capacidades`).
    func entradaSemEsperar(kind: ProviderKind, model: String) -> Entrada? {
        let lido = leuODisco.withLock { $0 }
        if !lido {
            Task.detached(priority: .utility) { self.carregarDoDisco() }
        }
        return indice.withLock { $0 }.flatMap { Self.procurar($0, kind: kind, model: model) }
    }

    private func carregarDoDisco() {
        let primeira = leuODisco.withLock { lido in
            defer { lido = true }
            return !lido
        }
        guard primeira, let arquivo, let d = try? Data(contentsOf: arquivo) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let i = try? dec.decode(Indice.self, from: d) {
            indice.withLock { atual in
                if atual == nil {
                    atual = i
                }
            }
        }
    }

    /// Baixa de novo. Uma descida por vez: quem chega no meio espera a mesma. Sem rede,
    /// não tenta de novo a cada pergunta da tela — espera uns minutos.
    private func atualizar() -> Task<Indice?, Never> {
        baixando.withLock { t in
            if let t {
                return t
            }
            if let f = ultimaFalha.withLock({ $0 }), Date().timeIntervalSince(f) < 300 {
                let atual = indice.withLock { $0 }
                return Task { atual }
            }
            let nova = Task<Indice?, Never> { [self] in
                defer { baixando.withLock { $0 = nil } }
                var req = URLRequest(url: Self.endereco)
                req.timeoutInterval = 15
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                guard let (d, r) = try? await http.data(for: req), (200 ..< 300).contains(r.statusCode),
                      let i = Self.indice(de: d)
                else {
                    ultimaFalha.withLock { $0 = Date() }
                    return indice.withLock { $0 }
                }
                ultimaFalha.withLock { $0 = nil }
                indice.withLock { $0 = i }
                gravar(i)
                return i
            }
            t = nova
            return nova
        }
    }

    private func gravar(_ i: Indice) {
        guard let arquivo else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(i) else { return }
        try? FileManager.default.createDirectory(
            at: arquivo.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? d.write(to: arquivo, options: .atomic)
    }

    /// Do `api.json` inteiro (megabytes) só fica o que o pedido usa.
    static func indice(de data: Data, em: Date = Date()) -> Indice? {
        guard let raiz = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var provedores: [String: [String: Entrada]] = [:]
        for (pid, p) in raiz {
            guard let modelos = (p as? [String: Any])?["models"] as? [String: Any] else { continue }
            var saida: [String: Entrada] = [:]
            for (mid, m) in modelos {
                guard let m = m as? [String: Any] else { continue }
                saida[mid.lowercased()] = entrada(m)
            }
            if !saida.isEmpty {
                provedores[pid.lowercased()] = saida
            }
        }
        return provedores.isEmpty ? nil : Indice(em: em, provedores: provedores)
    }

    static func entrada(_ m: [String: Any]) -> Entrada {
        let lim = m["limit"] as? [String: Any]
        let opcoes = (m["reasoning_options"] as? [[String: Any]]) ?? []
        let esforco = opcoes.first { $0["type"] as? String == "effort" }
        let inter = m["interleaved"]
        return Entrada(
            contexto: Capacidades.inteiro(lim?["context"]),
            saida: Capacidades.inteiro(lim?["output"]),
            raciocina: m["reasoning"] as? Bool,
            esforcos: esforco?["values"] as? [String],
            orcamento: opcoes.contains { $0["type"] as? String == "budget_tokens" } ? true : nil,
            campoDoRaciocinio: (inter as? [String: Any])?["field"] as? String
        )
    }

    /// Primeiro no provedor da família (com e sem prefixo `fornecedor/`), depois em
    /// qualquer um — quem usa um compatível (OpenRouter, um proxy) manda o id de lá.
    static func procurar(_ i: Indice, kind: ProviderKind, model: String) -> Entrada? {
        let id = model.lowercased().trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return nil }
        let curto = id.split(separator: "/").last.map(String.init) ?? id
        for p in Familia(kind).noCatalogo {
            if let e = i.provedores[p]?[id] ?? i.provedores[p]?[curto] {
                return e
            }
        }
        let ordem = i.provedores.keys.sorted()
        for p in ordem {
            if let e = i.provedores[p]?[id] {
                return e
            }
        }
        for p in ordem {
            for (k, e) in i.provedores[p] ?? [:] where k.hasSuffix("/" + curto) || k == curto {
                return e
            }
        }
        return nil
    }
}

// MARK: - O que um 400 ensina

/// O que foi mandado, para saber o que o 400 recusou.
struct PedidoMandado: Sendable, Equatable {
    var saida: Int?
    var pensamento: Pensamento?
    var nivel: String?
    /// Campos opcionais que foram no pedido (ver `Aprendizado.sinais`).
    var campos: Set<String> = []
    /// Formatos de thinking já recusados neste mesmo pedido: não se volta a eles.
    var pensamentosTentados: Set<Pensamento> = []
}

enum Aprendizado {
    /// O 400 reclama da assinatura ou do vínculo de um bloco de raciocínio devolvido: a
    /// saída é tirar o raciocínio antigo e tentar de novo, não mexer em capacidade.
    static func pedeTirarRaciocinio(_ texto: String) -> Bool {
        let t = texto.lowercased()
        if t.contains("signature") || t.contains("bound to a different conversation") ||
            t.contains("encrypted_content") || t.contains("encrypted content")
        {
            return true
        }
        // Item de raciocínio que o servidor não reconhece (`store: false`).
        return t.contains("rs_") && t.contains("not found")
    }

    /// Como cada campo opcional aparece nas mensagens de erro. O nome do campo no pedido
    /// nem sempre é o que o servidor cita: o vínculo do thinking vem num cabeçalho beta.
    static let sinais: [String: [String]] = [
        "block_binding": ["block_binding", "thinking-binding-controls"],
        "display": ["display"],
        "eager_input_streaming": ["eager_input_streaming"],
        // Só o nome do parâmetro citado: "supported values include …" não é recusa.
        "include": ["'include'", "`include`", "\"include\"", "include:", "include["],
        "stream_options": ["stream_options"],
        "summary": ["summary"],
        "reasoning_content": ["reasoning_content"],
    ]

    /// Capacidades corrigidas a partir da mensagem de um 400, ou nulo se não há o que
    /// aprender (e o erro sobe para a tela).
    static func aprender(
        _ texto: String,
        familia: Familia,
        cap: Capacidades,
        mandado: PedidoMandado
    ) -> Capacidades? {
        let t = texto.lowercased()
        var c = cap
        for campo in mandado.campos.sorted() where (sinais[campo] ?? [campo]).contains(where: { t.contains($0) }) {
            // Campo opcional que o endpoint não conhece: sai e não volta.
            c.recusar(campo)
            return c
        }
        if familia == .anthropic {
            if t.contains("max_tokens"), saidaQueCabe(t) == nil, let limite = limiteDeSaida(t),
               limite < (mandado.saida ?? .max)
            {
                c.saida = limite
                return c
            }
            if let p = mandado.pensamento, p != .nenhum, t.contains("thinking") || t.contains("budget_tokens") {
                // "thinking.type.enabled is not supported … use thinking.type.adaptive" num
                // modelo novo; "should be 'enabled' or 'disabled'" num endpoint antigo.
                var outro: Pensamento = .nenhum
                if p == .orcamento,
                   t.contains("adaptive") || t.contains("budget_tokens") || t.contains("type.enabled")
                {
                    outro = .adaptativo
                } else if p == .adaptativo, t.contains("enabled") || t.contains("adaptive") {
                    outro = .orcamento
                }
                if mandado.pensamentosTentados.contains(outro) {
                    outro = .nenhum
                }
                c.pensamento = outro
                return c
            }
        }
        if let nivel = mandado.nivel, t.contains("effort") || t.contains("output_config") || t.contains("reasoning") {
            let aceitos = niveisCitados(t)
            // A mensagem cita o nível mandado, ou fala de valor: é este nível, não o campo.
            let doValor = ["unsupported value", "invalid value", "supported values", "should be", "must be one of",
                           "'\(nivel)'", "\"\(nivel)\"", "`\(nivel)`"].contains { t.contains($0) }
            let doCampo = ["unrecognized", "unknown parameter", "unknown field", "unsupported parameter",
                           "not permitted", "does not support", "not supported"].contains { t.contains($0) }
            if !aceitos.isEmpty, !aceitos.contains(nivel) {
                c.esforcos = aceitos
            } else if doCampo, !doValor {
                // O modelo não tem esforço nenhum, não só este nível.
                c.esforcos = []
            } else {
                // Sem a lista na mensagem: sai o nível recusado e fica o resto.
                c.esforcos = (cap.esforcos ?? familia.esforcosMaisNovos).filter { $0 != nivel }
            }
            return c
        }
        if let p = mandado.pensamento, p != .nenhum, t.contains("thinking") {
            c.pensamento = .nenhum
            return c
        }
        return nil
    }

    /// "input length and `max_tokens` exceed context limit: 150000 + 64000 > 200000": a
    /// conversa ocupa quase a janela e o teto de saída não cabe no que sobra. Vale só para
    /// este pedido — o teto do modelo continua o mesmo.
    static func saidaQueCabe(_ texto: String) -> Int? {
        let t = texto.lowercased()
        guard t.contains("max_tokens") || t.contains("context"),
              let r = t.range(of: #"(\d+)\s*\+\s*(\d+)\s*>\s*(\d+)"#, options: .regularExpression)
        else { return nil }
        let numeros = t[r].split { !$0.isNumber }.compactMap { Int($0) }
        guard numeros.count == 3 else { return nil }
        let sobra = numeros[2] - numeros[0]
        return sobra >= 1024 ? sobra : nil
    }

    /// "max_tokens: 128000 > 64000, which is the maximum allowed number of output tokens
    /// for …" — e variações.
    static func limiteDeSaida(_ t: String) -> Int? {
        let padroes = [
            #"(\d{3,})\s*,?\s*which is the maximum"#,
            #"maximum[^0-9]{0,60}?(\d{3,})"#,
            #">\s*(\d{3,})"#,
        ]
        for p in padroes {
            guard let r = t.range(of: p, options: .regularExpression) else { continue }
            let trecho = String(t[r])
            if let n = trecho.range(of: #"\d{3,}"#, options: .regularExpression).flatMap({ Int(trecho[$0]) }) {
                return n
            }
        }
        return nil
    }

    /// Os níveis de esforço entre aspas numa mensagem como "Supported values are: 'low',
    /// 'medium' and 'high'".
    static func niveisCitados(_ t: String) -> [String] {
        let ancoras = [
            "supported values",
            "allowed values",
            "valid values",
            "should be",
            "must be",
            "expected",
            "one of",
        ]
        guard let r = ancoras.lazy.compactMap({ t.range(of: $0) }).first else { return [] }
        let resto = String(t[r.upperBound...])
        var achados: [String] = []
        var i = resto.startIndex
        while let a = resto[i...].firstIndex(where: { $0 == "'" || $0 == "\"" }) {
            let depois = resto.index(after: a)
            guard let f = resto[depois...].firstIndex(of: resto[a]) else { break }
            let palavra = String(resto[depois ..< f])
            if Effort.order.contains(palavra) {
                achados.append(palavra)
            }
            i = resto.index(after: f)
        }
        return Effort.ordenar(achados)
    }
}
