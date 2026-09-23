import Foundation
import OdeteI18n

/// Provedor concreto: conta + sessão + formato.
public struct HTTPProvider: Provider {
    public let kind: ProviderKind
    let account: AIAccount
    let session: Session
    let http: HTTPClient
    let registro: RegistroDeCapacidades
    let catalogo: CatalogoDeModelos?
    /// Espera entre tentativas. Nos testes é zero.
    let espera: @Sendable (Double) async throws -> Void
    public static let grokClientVersion = "0.2.91"

    /// Quantas vezes um 400 pode ensinar algo no mesmo pedido antes de o erro subir.
    static let ajustesPorPedido = 4
    /// Sobrecarga (`overloaded_error`) no começo do stream: quantas vezes tentar de novo.
    static let tentativasDeSobrecarga = 2
    /// `pause_turn` seguidos que ainda valem continuar.
    static let pausasPorTurno = 3
    /// Por quanto tempo o que a API do provedor disse de um modelo vale sem perguntar de novo.
    static let validadeDaConsulta: TimeInterval = 86400

    public init(account: AIAccount, session: Session, http: HTTPClient = URLSessionClient()) {
        self.init(account: account, session: session, http: http, registro: .compartilhado, catalogo: .compartilhado)
    }

    init(
        account: AIAccount,
        session: Session,
        http: HTTPClient,
        registro: RegistroDeCapacidades,
        catalogo: CatalogoDeModelos?,
        espera: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        kind = account.kind
        self.account = account
        self.session = session
        self.http = http
        self.registro = registro
        self.catalogo = catalogo
        self.espera = espera
    }

    var base: String {
        account.baseURL.hasSuffix("/") ? String(account.baseURL.dropLast()) : account.baseURL
    }

    var host: String {
        URL(string: base)?.host()?.lowercased() ?? ""
    }

    func headers(token: String, conversationId: String = "", betas: [String] = []) -> [String: String] {
        switch kind {
        // Nunca chega aqui: conta da Apple é atendida pelo AppleProvider.
        case .apple: return [:]
        case .claude: return [
                "Authorization": "Bearer \(token)",
                "anthropic-version": "2023-06-01",
                "anthropic-beta": (["oauth-2025-04-20", "claude-code-20250219"] + betas).joined(separator: ","),
            ]
        case .anthropicCompat:
            var h = ["x-api-key": token, "anthropic-version": "2023-06-01"]
            if !betas.isEmpty {
                h["anthropic-beta"] = betas.joined(separator: ",")
            }
            return h
        case .codex:
            var h = ["Authorization": "Bearer \(token)", "originator": "codex_cli_rs", "OpenAI-Beta": "responses=v1"]
            if let id = account.accountId {
                h["ChatGPT-Account-ID"] = id
            }
            return h
        case .grok:
            var h = [
                "Authorization": "Bearer \(token)",
                "User-Agent": "grok-pager/\(Self.grokClientVersion) grok-shell/\(Self.grokClientVersion) (ipados; aarch64)",
                "x-grok-client-identifier": "grok-pager",
                "x-grok-client-version": Self.grokClientVersion,
            ]
            if !conversationId.isEmpty {
                h["x-grok-conv-id"] = conversationId
            }
            return h
        case .openaiCompat: return ["Authorization": "Bearer \(token)"]
        }
    }

    public func stream(_ turn: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let t = Task {
                do {
                    try await conduzir(turn, cont)
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel() }
        }
    }

    /// Um turno inteiro: pedido, as correções que um 400 ensina, a sobrecarga no começo
    /// do stream e a continuação de uma resposta pausada.
    func conduzir(_ turn: TurnRequest, _ cont: AsyncThrowingStream<StreamEvent, Error>.Continuation) async throws {
        var token = try await session.accessToken()
        var cap = await capacidades(turn.model, token: token)
        var semRaciocinio = false
        var tentados: Set<Pensamento> = []
        var ajustes = 0, sobrecargas = 0, pausas = 0
        var renovou = false
        var continuacao: String?
        // Teto de saída só deste pedido, quando a conversa quase enche a janela.
        var tetoDoPedido: Int?
        while true {
            let fim = FimDoFluxo()
            var capDoPedido = cap
            if let t = tetoDoPedido {
                capDoPedido.saida = min(cap.saida ?? t, t)
            }
            var pedido = montar(turn, capDoPedido, semRaciocinio: semRaciocinio, continuacao: continuacao)
            pedido.mandado.pensamentosTentados = tentados
            let lines: AsyncThrowingStream<String, Error>
            do {
                lines = try await openSSE(
                    http,
                    url: pedido.url,
                    headers: pedido.headers(headers(token: token, conversationId: turn.conversationId, betas: pedido.betas)),
                    body: pedido.corpo,
                    espera: espera
                )
            } catch AgentError.auth where !renovou {
                // 401: renova uma vez e tenta de novo
                renovou = true
                token = try await session.refreshNow().access
                continue
            } catch let AgentError.http(400, texto) where ajustes < Self.ajustesPorPedido {
                ajustes += 1
                if let cabe = Aprendizado.saidaQueCabe(texto), cabe < (pedido.mandado.saida ?? .max) {
                    tetoDoPedido = cabe
                    continue
                }
                if !semRaciocinio, Aprendizado.pedeTirarRaciocinio(texto),
                   turn.messages.contains(where: { $0.raciocinio != nil })
                {
                    // Bloco assinado que o servidor não aceita mais (histórico mexido,
                    // outra conta): vai sem o raciocínio antigo, uma vez.
                    semRaciocinio = true
                    continue
                }
                guard let novo = Aprendizado.aprender(
                    texto,
                    familia: Familia(kind),
                    cap: cap,
                    mandado: pedido.mandado
                ) else { throw AgentError.http(400, texto) }
                if let p = pedido.mandado.pensamento {
                    tentados.insert(p)
                }
                cap = novo
                registro.substituir(kind, turn.model, por: novo)
                continue
            }
            let ctx = ContextoDoFluxo(
                origem: "\(kind.rawValue)@\(host)",
                modelo: turn.model,
                ferramentas: turn.tools,
                prefixoJSON: continuacao,
                fim: fim
            )
            var emitiu = false
            var sobrecarregado = false
            do {
                for try await e in eventos(lines, ctx) {
                    if Task.isCancelled {
                        return
                    }
                    switch e {
                    case .error where !emitiu && sobrecargas < Self.tentativasDeSobrecarga &&
                        ["overloaded_error", "api_error"].contains(fim.atual.tipoDoErro ?? ""):
                        // Sobrecarga antes de qualquer texto: nada foi mostrado, dá para pedir
                        // de novo sem a pessoa ver duas respostas.
                        sobrecarregado = true
                    case .text, .think, .tools:
                        emitiu = true
                        cont.yield(e)
                    default:
                        cont.yield(e)
                    }
                    if sobrecarregado {
                        break
                    }
                }
            } catch let falha where !emitiu && sobrecargas < Self.tentativasDeSobrecarga &&
                pausaAntesDeTentarDeNovo(falha, 1) != nil
            {
                // A conexão caiu depois de aberta mas antes de chegar texto: mesmo caso.
                sobrecarregado = true
            }
            if sobrecarregado {
                sobrecargas += 1
                try await espera(pausaAntesDeTentarDeNovo(AgentError.http(529, ""), sobrecargas) ?? 1)
                continue
            }
            if let pausado = fim.atual.pausado {
                pausas += 1
                guard pausas <= Self.pausasPorTurno else {
                    cont.yield(.error(tr(
                        "O modelo pausou o turno %1$@ vezes seguidas. Mande de novo para continuar.",
                        "\(pausas - 1)"
                    )))
                    return
                }
                // `pause_turn`: a resposta volta como está e o modelo continua dela.
                continuacao = pausado
                continue
            }
            return
        }
    }

    struct Pedido {
        var url: URL
        var corpo: [String: Any]
        var mandado: PedidoMandado
        var betas: [String]
        var extras: [String: String] = [:]

        func headers(_ base: [String: String]) -> [String: String] {
            base.merging(extras) { _, novo in novo }
        }
    }

    func montar(_ turn: TurnRequest, _ cap: Capacidades, semRaciocinio: Bool, continuacao: String?) -> Pedido {
        switch kind {
        case .apple, .claude, .anthropicCompat:
            var o = MessagesStream.Opcoes(cap, kind: kind, host: host)
            o.semRaciocinio = semRaciocinio
            o.continuacao = ContextoDoFluxo(prefixoJSON: continuacao).prefixo
            let m = MessagesStream.body(turn, o)
            return Pedido(url: URL(string: base + "/v1/messages")!, corpo: m.corpo, mandado: m.mandado, betas: m.betas)
        case .grok, .codex:
            // O backend do Codex só atende a API de Responses. Em /chat/completions ele
            // devolve 404 com {"detail":"Not Found"}, que era o erro que aparecia.
            var o = ResponsesStream.Opcoes(cap, kind: kind, host: host)
            o.semRaciocinio = semRaciocinio
            let m = ResponsesStream.body(turn, o)
            var p = Pedido(url: URL(string: base + "/responses")!, corpo: m.corpo, mandado: m.mandado, betas: [])
            if kind == .grok {
                p.extras["x-grok-model-override"] = turn.model
            }
            return p
        case .openaiCompat:
            let m = ChatCompletionsStream.body(turn, ChatCompletionsStream.Opcoes(cap, kind: kind))
            return Pedido(url: URL(string: base + "/chat/completions")!, corpo: m.corpo, mandado: m.mandado, betas: [])
        }
    }

    func eventos(_ lines: AsyncThrowingStream<String, Error>, _ ctx: ContextoDoFluxo)
        -> AsyncThrowingStream<StreamEvent, Error>
    {
        switch kind {
        case .apple, .claude, .anthropicCompat: MessagesStream.events(lines, ctx)
        case .grok, .codex: ResponsesStream.events(lines, ctx)
        case .openaiCompat: ChatCompletionsStream.events(lines, ctx)
        }
    }

    /// O que se sabe do modelo antes do pedido: o guardado, a Models API da Anthropic
    /// (uma vez por dia por modelo) e, para o que faltar, o catálogo do models.dev.
    func capacidades(_ model: String, token: String) async -> Capacidades {
        var c = registro.ler(kind, model) ?? Capacidades()
        if Familia(kind) == .anthropic,
           c.consultaDaAPI.map({ Date().timeIntervalSince($0) > Self.validadeDaConsulta }) ?? true
        {
            let resposta = await consultarModelo(model, token: token)
            var nova = resposta ?? Capacidades()
            // Anota a consulta mesmo quando ela falha: um compatível sem a rota não é
            // perguntado a cada turno. A falha vale por uma hora, não por um dia — pode
            // ter sido só a rede.
            nova.consultaDaAPI = resposta == nil ? Date(timeIntervalSinceNow: 3600 - Self.validadeDaConsulta) : Date()
            registro.atualizar(kind, model, com: nova)
            c = registro.ler(kind, model) ?? c
        }
        let falta = switch Familia(kind) {
        case .anthropic: c.saida == nil || c.pensamento == nil || c.esforcos == nil
        default: c.esforcos == nil
        }
        // Na primeira vez o catálogo ainda não está no aparelho; o pedido não fica
        // esperando a descida inteira por ele — vai no formato mais novo.
        if falta, let e = await catalogo?.entrada(kind: kind, model: model, esperaMaxima: 3) {
            c = c.completada(com: e.capacidades)
        }
        return c
    }

    /// `GET /v1/models/{id}`: janela, teto de saída, tipos de thinking e níveis de esforço.
    func consultarModelo(_ model: String, token: String) async -> Capacidades? {
        guard let id = model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: base + "/v1/models/" + id) else { return nil }
        var req = URLRequest(url: url)
        for (k, v) in headers(token: token) {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 8
        guard let (d, r) = try? await http.data(for: req), (200 ..< 300).contains(r.statusCode) else { return nil }
        let j = jsonObject(d)
        guard j["id"] != nil || j["max_tokens"] != nil else { return nil }
        return Capacidades.daAnthropic(j)
    }

    public func models() async throws -> [ModelInfo] {
        let token = try await session.accessToken()
        let h = headers(token: token)
        let urls: [String] = switch kind {
        case .apple, .claude, .anthropicCompat: [base + "/v1/models?limit=100"]
        case .codex: [
                "https://chatgpt.com/backend-api/codex/models?client_version=0.145.0",
                "https://chatgpt.com/backend-api/codex/models",
            ]
        case .grok: [base + "/models"]
        case .openaiCompat: [base + "/models"]
        }
        var lastStatus = 0
        for u in urls {
            var req = URLRequest(url: URL(string: u)!)
            for (k, v) in h {
                req.setValue(v, forHTTPHeaderField: k)
            }
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await http.data(for: req) else { continue }
            lastStatus = resp.statusCode
            guard (200 ..< 300).contains(resp.statusCode) else { continue }
            let lista = ModelList.parse(data, familia: Familia(kind))
            if !lista.isEmpty {
                // O que a lista diz de cada modelo fica guardado: o seletor de esforço e
                // o tamanho da janela saem daqui sem outra ida à rede.
                registro.atualizar(kind, lista.compactMap { info, cap in
                    guard cap != Capacidades() else { return nil }
                    var c = cap
                    if Familia(kind) == .anthropic {
                        c.consultaDaAPI = Date()
                    }
                    return (info.id, c)
                })
                return lista.map(\.0)
            }
        }
        if kind == .grok {
            return ModelList.grokCatalog
        }
        throw AgentError.http(lastStatus, tr("não devolveu modelos"))
    }
}

enum ModelList {
    static let grokCatalog: [ModelInfo] = [
        ModelInfo(id: "grok-4.6", label: "Grok 4.6", ctx: 1_000_000), ModelInfo(
            id: "grok-4.5",
            label: "Grok 4.5",
            ctx: 1_000_000
        ),
        ModelInfo(id: "grok-4.3", label: "Grok 4.3", ctx: 1_000_000), ModelInfo(
            id: "grok-build",
            label: "Grok Build",
            ctx: 500_000
        ),
        ModelInfo(id: "grok-composer-2.5-fast", label: "Grok Composer 2.5 Fast", ctx: 200_000),
    ]

    static func parse(_ data: Data) -> [ModelInfo] {
        parse(data, familia: .openai).map(\.0)
    }

    /// Aceita `data`, `models`, `items` ou `model_slugs` (lista ou dicionário), e tira de
    /// cada item o que ele diz do modelo.
    static func parse(_ data: Data, familia: Familia) -> [(ModelInfo, Capacidades)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var raw: Any? = (root as? [String: Any])
            .flatMap { $0["data"] ?? $0["models"] ?? $0["items"] ?? $0["model_slugs"] } ?? (root as? [Any])
        if let dict = raw as? [String: Any] {
            raw = dict.map { k, v in
                var d = (v as? [String: Any]) ?? [:]; d["slug"] = k; return d
            }
        }
        var out: [(ModelInfo, Capacidades)] = []
        var seen: Set<String> = []
        for item in (raw as? [Any]) ?? [] {
            if let s = item as? String {
                if seen.insert(s).inserted {
                    out.append((ModelInfo(id: s), Capacidades()))
                }; continue
            }
            guard let m = item as? [String: Any] else { continue }
            let vis = "\(m["visibility"] ?? m["hidden"] ?? "")"
            if vis == "hidden" || vis == "1" || vis == "true" {
                continue
            }
            guard let id = ((m["slug"] ?? m["id"] ?? m["model"] ?? m["name"]) as? String)?
                .trimmingCharacters(in: .whitespaces), !id.isEmpty, seen.insert(id).inserted else { continue }
            let label = ((m["display_name"] ?? m["displayName"] ?? m["title"] ?? m["name"]) as? String) ?? id
            let cap = familia == .anthropic ? Capacidades.daAnthropic(m) : Capacidades.daLista(m)
            // Só vira lista de níveis o que o item disse; o silêncio fica para o registro
            // e o catálogo resolverem depois.
            let efforts = cap.esforcos != nil || cap.pensamento != nil ? Effort.opcoes(cap, familia: familia) : []
            out.append((
                ModelInfo(
                    id: id,
                    label: label,
                    efforts: efforts.isEmpty ? nil : efforts,
                    ctx: (cap.contexto ?? 0) > 1000 ? cap.contexto : nil
                ),
                cap
            ))
        }
        return out.sorted { $0.0.label.localizedCaseInsensitiveCompare($1.0.label) == .orderedAscending }
    }
}
