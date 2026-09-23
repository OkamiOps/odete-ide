import Foundation

/// Compactação da conversa quando ela chega perto do fim da janela de contexto.
///
/// Não é invenção daqui: é o desenho do opencode (github.com/sst/opencode), trazido para o
/// formato de mensagens da Odete. Cada decisão abaixo diz de que arquivo dele veio:
///
/// - **Quando** (`session/overflow.ts`, `isOverflow`): pelo uso que o provedor reportou na
///   última rodada — entrada + cache + saída —, não por uma contagem nossa. A diferença é
///   o limite: o opencode compara com a janela menos a saída máxima; aqui o gatilho é 80%
///   da janela total, que deixa a mesma folga para a resposta sem precisar saber o teto de
///   saída de cada modelo.
/// - **Primeiro a poda** (`session/compaction.ts`, `prune`): de trás para frente, as saídas
///   de ferramenta mais recentes somando `podaProtege` tokens ficam; as mais antigas viram
///   uma marca curta — mas só se o que sai passar de `podaMinima`, para não mexer na
///   conversa por pouco.
/// - **Se não bastar, o resumo** (`session/compaction.ts`, `process` e `select`; o prompt é
///   o de `core/session/compaction.ts`, `buildPrompt`, e o sistema é
///   `agent/prompt/compaction.txt`): o começo da conversa vira texto (`serialize`, com cada
///   resultado de ferramenta cortado em `saidaNoResumo` caracteres), um pedido sem
///   ferramentas resume isso num modelo fixo de seções, e o resumo entra no lugar do começo.
///   As mensagens mais recentes que cabem em `orcamentoDaCauda` ficam como estão, e o pedido
///   do turno fica sempre.
/// - **Estouro mesmo assim** (`llm/src/provider-error.ts`, `isContextOverflow`): se o
///   provedor recusa por tamanho, o laço resume e tenta a rodada de novo — ver `ehEstouro`.
///
/// E uma regra que vem da Anthropic, não do opencode: os modelos com "raciocínio preservado"
/// (Claude Fable 5.1, Opus 5.5) amarram cada bloco de raciocínio à conversa exata que o
/// produziu; mexer numa mensagem antiga invalida todos os blocos depois dela, e em conta
/// nova isso é 400. O guia de migração (`model-migration.md`, "history-editing check") diz
/// que compactar resumindo o começo e mantendo as últimas mensagens só é aceito sem o
/// raciocínio das mensagens mantidas, e que descartar o raciocínio uma vez, na fronteira de
/// uma compactação, "tem pouco efeito". Por isso toda poda e todo resumo saem com
/// `semRaciocinio` — e depois deles a conversa volta a só crescer no fim.
public enum Compactacao {
    // MARK: limites

    /// A janela quando ninguém disse qual é a do modelo.
    public static let janelaPadrao = 200_000
    /// Fração da janela total a partir da qual a conversa é compactada.
    public static let gatilho = 0.8
    /// `PRUNE_MINIMUM` do opencode: podar menos que isto não vale mexer na conversa.
    static let podaMinima = 20_000
    /// `PRUNE_PROTECT` do opencode: as saídas de ferramenta mais recentes, até esta soma,
    /// nunca são podadas.
    static let podaProtege = 40_000
    /// `TOOL_OUTPUT_MAX_CHARS` do opencode: quanto de cada resultado entra no texto que vai
    /// ser resumido.
    static let saidaNoResumo = 2_000
    /// `MIN_PRESERVE_RECENT_TOKENS` e `MAX_PRESERVE_RECENT_TOKENS` do opencode: a cauda que
    /// fica como está é um quarto do que se pode usar, entre esses dois.
    static let caudaMinima = 2_000
    static let caudaMaxima = 15_000
    /// `SUMMARY_OUTPUT_TOKENS` do opencode: o espaço reservado para o próprio resumo.
    static let saidaDoResumo = 4_096

    /// O que fica no lugar de um resultado podado — o `[Old tool result content cleared]`
    /// do opencode.
    public static let marcaDePoda = "[resultado antigo de ferramenta apagado para caber na janela]"
    static let abreResumo = "<resumo_da_conversa>"
    static let fechaResumo = "</resumo_da_conversa>"

    // MARK: medida

    /// Tokens estimados: quatro caracteres por token, a conta de `util/token.ts` do
    /// opencode. É o plano B; o que manda é o uso reportado pelo provedor.
    public static func estimar(_ s: String) -> Int {
        Int((Double(s.utf16.count) / 4).rounded())
    }

    public static func estimar(_ m: AgentMessage) -> Int {
        // O que volta ao provedor é o raciocínio bruto (com a assinatura), quando há; o
        // `thinking` é o que a tela mostrou dele — contar os dois seria contar duas vezes.
        var n = estimar(m.content) + estimar(m.raciocinio?.json ?? m.thinking ?? "") + 4
        for c in m.toolCalls ?? [] {
            n += estimar(c.name) + estimar(c.arguments)
        }
        // Uma imagem de 1600 px fica na casa de mil e poucos tokens nos provedores.
        return n + (m.images?.count ?? 0) * 1600
    }

    public static func estimar(_ ms: some Sequence<AgentMessage>) -> Int {
        ms.reduce(0) { $0 + estimar($1) }
    }

    /// Os tokens que a última rodada ocupou na janela, pelo que o provedor reportou.
    ///
    /// Na Anthropic a entrada não inclui o cache: soma-se. Nos formatos da OpenAI os
    /// tokens em cache já estão dentro de `prompt_tokens`: somar contaria duas vezes.
    public static func tokensDaRodada(_ u: TokenUse, kind: ProviderKind) -> Int? {
        guard !u.isEmpty else { return nil }
        switch kind {
        case .claude, .anthropicCompat: return u.input + u.cache + u.output
        case .apple, .codex, .grok, .openaiCompat: return max(u.input, u.cache) + u.output
        }
    }

    /// Passou do ponto de compactar?
    public static func passou(_ uso: Int, janela: Int) -> Bool {
        janela > 0 && Double(uso) >= Double(janela) * gatilho
    }

    /// A mensagem de erro do provedor diz que o pedido não coube na janela?
    ///
    /// A lista é a de `isContextOverflow` do opencode (`llm/src/provider-error.ts`), que
    /// junta como cada provedor diz isso — e as mesmas exceções: limite de uso e
    /// "throttling" não são estouro de janela.
    public static func ehEstouro(_ mensagem: String) -> Bool {
        let m = mensagem.lowercased()
        let excecoes = ["rate limit", "too many requests", "throttling error", "service unavailable"]
        if excecoes.contains(where: { m.contains($0) }) {
            return false
        }
        let padroes = [
            #"prompt is too long"#, #"request_too_large"#, #"input is too long for requested model"#,
            #"exceeds the context window"#, #"exceeds (the )?(model'?s )?maximum context length"#,
            #"input token count.*exceeds the maximum"#, #"tokens in request more than max tokens allowed"#,
            #"maximum prompt length is \d+"#, #"reduce the length of the messages"#,
            #"maximum context length is \d+ tokens"#, #"exceeds (the )?maximum allowed input length"#,
            #"is longer than the model'?s context length"#, #"exceeds the limit of \d+"#,
            #"exceeds the available context size"#, #"greater than the context length"#,
            #"context window exceeds limit"#, #"exceeded model token limit"#, #"context[_ ]length[_ ]exceeded"#,
            #"request entity too large"#, #"context length is only \d+ tokens"#,
            #"input length.*exceeds.*context length"#, #"prompt too long; exceeded (max )?context length"#,
            #"too large for model with \d+ maximum context length"#,
            #"but the configured context size is"#, #"model_context_window_exceeded"#, #"too many tokens"#,
            #"token limit exceeded"#, #"http 413"#,
        ]
        return padroes.contains { m.range(of: $0, options: .regularExpression) != nil }
    }

    // MARK: poda

    /// A poda do opencode (`prune`): das saídas de ferramenta, as mais recentes até
    /// `podaProtege` ficam, e as de antes viram `marcaDePoda` — se o que sai passar de
    /// `podaMinima`. Para no resumo de uma compactação anterior e em resultado já podado,
    /// como o opencode para em `time.compacted`.
    ///
    /// Adaptação: o opencode não poda os dois últimos turnos da pessoa, porque poda entre
    /// turnos. Aqui um turno sozinho chega a mil rodadas e a poda roda no meio dele, então
    /// quem protege o trabalho recente é só a soma de `podaProtege`.
    public static func podar(_ ms: [AgentMessage]) -> (mensagens: [AgentMessage], liberados: Int)? {
        var total = 0
        var liberados = 0
        var alvos: [Int] = []
        for i in ms.indices.reversed() {
            let m = ms[i]
            if ehResumo(m) {
                break
            }
            guard m.role == .tool else { continue }
            if m.content == marcaDePoda {
                break
            }
            let n = estimar(m.content)
            total += n
            if total <= podaProtege {
                continue
            }
            liberados += n
            alvos.append(i)
        }
        guard liberados > podaMinima else { return nil }
        var out = ms
        for i in alvos {
            out[i] = .tool(ms[i].toolCallId ?? "", marcaDePoda)
        }
        return (semRaciocinio(out), liberados - alvos.count * estimar(marcaDePoda))
    }

    /// Tira o raciocínio de todas as mensagens — ver a regra da Anthropic no topo.
    ///
    /// Monta cada mensagem de novo com o que ela tem de conversa, em vez de só zerar
    /// `thinking`: se o formato ganhar outro campo amarrado ao raciocínio (a assinatura do
    /// bloco, por exemplo), ele também fica para trás.
    public static func semRaciocinio(_ ms: [AgentMessage]) -> [AgentMessage] {
        ms.map {
            AgentMessage(
                role: $0.role,
                content: $0.content,
                images: $0.images,
                toolCalls: $0.toolCalls,
                toolCallId: $0.toolCallId
            )
        }
    }

    // MARK: resumo

    /// O sistema do pedido de resumo: `agent/prompt/compaction.txt` do opencode.
    static let sistema = """
    Você é um agente de resumo de contexto. Recebe uma conversa entre uma pessoa e um agente de código e produz um resumo estruturado, no formato pedido, para que outro agente de código continue o trabalho.

    Siga exatamente a estrutura pedida. Mantenha todas as seções, preserve caminhos de arquivo e identificadores exatamente como estão, e prefira bullets curtos a parágrafos.

    Não continue a conversa. Não responda a perguntas que estão na conversa. Escreva só o resumo, no formato pedido. Responda no mesmo idioma da conversa.
    """

    /// O modelo de seções: `SUMMARY_TEMPLATE` de `core/session/compaction.ts`.
    ///
    /// As três regras depois de "Bullets curtos" vêm do prompt de compactação que a
    /// Anthropic recomenda para os modelos com raciocínio preservado: o raciocínio de antes
    /// do resumo não segue adiante, então o resumo é tudo o que sobra daquele trabalho — e
    /// o que a pessoa disse vale mais que o que o agente explicou.
    static let modelo = """
    Escreva exatamente a estrutura em Markdown dentro de <modelo>, com as seções nesta ordem. Não inclua as tags <modelo> na resposta.
    <modelo>
    ## Objetivo
    - [uma ou duas frases curtas sobre o que a pessoa quer conseguir]

    ## Detalhes importantes
    - [restrições e preferências, decisões e por quê, fatos e suposições importantes, o contexto exato para continuar; ou "(nenhum)"]

    ## Estado do trabalho
    ### Feito
    - [trabalho terminado, fatos conferidos ou mudanças feitas; senão "(nenhum)"]

    ### Em andamento
    - [o que está sendo feito, mudanças pela metade ou investigação em curso; senão "(nenhum)"]

    ### Bloqueado
    - [bloqueios, comandos que falham ou incógnitas; senão "(nenhum)"]

    ## Próximo passo
    1. [a próxima ação concreta, ou "(nenhum)"]
    2. [a seguinte, se já se sabe, ou "(nenhum)"]

    ## Arquivos relevantes
    - [arquivo ou pasta: por que importa; ou "(nenhum)"]
    </modelo>

    Regras:
    - Mantenha todas as seções, mesmo vazias.
    - Bullets curtos, não parágrafos.
    - Preserve exatamente caminhos de arquivo, símbolos, comandos, mensagens de erro, URLs e identificadores.
    - O que a pessoa pediu, decidiu, recusou ou estabeleceu como preferência ou limite fica com cuidado, perto das palavras dela; as explicações do agente podem encolher até o que concluíram ou produziram.
    - Registre os problemas que apareceram e como foram resolvidos, e as abordagens tentadas ou deixadas de lado, com o porquê.
    - Não mencione o processo de resumo nem que o contexto foi compactado.
    - Não chame ferramentas: responda só com texto.
    """

    /// `SUMMARY_UPDATE_INSTRUCTIONS` de `core/session/compaction.ts`: quando já existe um
    /// resumo, o novo junta os dois.
    static let atualizacao = """
    O <resumo_anterior> resume tudo o que aconteceu antes da <conversa>. Construa um resumo novo que junte os dois. O <resumo_anterior> é descartado depois disto: o que você não levar para o resumo novo se perde.

    Ao juntar:
    - Leve adiante objetivos, restrições, orientações da pessoa, decisões e frentes de trabalho paralelas do <resumo_anterior>, mesmo que a <conversa> não fale deles. Deixe de fora só o que terminou e não é mais preciso.
    - A <conversa> é mais recente que o <resumo_anterior>. Onde eles discordam, vale a conversa: registre o fato corrigido e tire o antigo.
    - Acrescente o progresso, as decisões, as restrições e o contexto novos da conversa.
    - Passe o que terminou de "Em andamento" para "Feito".
    - Se um bloqueio foi resolvido, atualize o resumo mantendo os detalhes ainda necessários para continuar.
    - Atualize "Objetivo" e "Próximo passo" para o estado atual do trabalho.
    """

    /// O pedido de resumo: `buildPrompt` de `core/session/compaction.ts`.
    static func prompt(conversa: String, resumoAnterior: String?) -> String {
        let bloco = "Esta é a conversa até aqui:\n\n<conversa>\n\(conversa)\n</conversa>"
        guard let resumoAnterior else {
            return [
                bloco,
                "Crie um resumo novo, ancorado no histórico da conversa dentro das tags <conversa> acima, para que outro agente de código continue o trabalho.",
                modelo,
            ].joined(separator: "\n\n")
        }
        return [
            bloco,
            "Este é o resumo da conversa de antes da <conversa> acima:\n\n<resumo_anterior>\n\(resumoAnterior)\n</resumo_anterior>",
            atualizacao,
            modelo,
        ].joined(separator: "\n\n")
    }

    /// Uma mensagem como texto para o resumo: `serialize` do opencode.
    static func serializar(_ m: AgentMessage, teto: Int) -> String {
        func cortar(_ s: String) -> String {
            s.count <= teto ? s : String(s.prefix(teto)) + "\n[cortado]"
        }
        switch m.role {
        case .user:
            let anexos = (m.images ?? []).map { "[Anexo \($0.mime)]" }
            return (["[Pessoa]: \(m.content)"] + anexos).joined(separator: "\n")
        case .assistant:
            var linhas: [String] = []
            if let t = m.thinking, !t.isEmpty {
                linhas.append("[Raciocínio do agente]: \(cortar(t))")
            }
            if !m.content.isEmpty {
                linhas.append("[Agente]: \(m.content)")
            }
            for c in m.toolCalls ?? [] {
                if let problema = c.problema {
                    linhas.append("[Chamada de ferramenta que não rodou]: \(c.name) — \(cortar(problema))")
                } else {
                    linhas.append("[Chamada de ferramenta]: \(c.name)(\(cortar(c.arguments)))")
                }
            }
            return linhas.joined(separator: "\n")
        case .tool:
            return "[Resultado da ferramenta]: \(cortar(m.content))"
        case .system:
            return "[Sistema]: \(m.content)"
        }
    }

    /// O pedido de resumo, encolhido até caber: primeiro corta mais cada resultado de
    /// ferramenta; se nem assim, fica com o fim da conversa, que é o que o próximo passo
    /// precisa. (O opencode desiste nesse ponto — "Conversation history too large to
    /// compact"; desistir aqui deixaria o turno preso num 400 atrás do outro.)
    static func promptQueCabe(_ cabeca: [AgentMessage], resumoAnterior: String?, janela: Int) -> String {
        let limite = max(8_000, Int(Double(janela) * gatilho) - saidaDoResumo)
        var conversa = ""
        for teto in [saidaNoResumo, 500, 120] {
            conversa = cabeca.map { serializar($0, teto: teto) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
            let p = prompt(conversa: conversa, resumoAnterior: resumoAnterior)
            if estimar(p) <= limite {
                return p
            }
        }
        let fixo = estimar(prompt(conversa: "", resumoAnterior: resumoAnterior))
        let cabe = max(1_000, (limite - fixo) * 4)
        return prompt(
            conversa: "(o começo da conversa não coube e ficou de fora)\n\n" + String(conversa.suffix(cabe)),
            resumoAnterior: resumoAnterior
        )
    }

    /// O resumo como mensagem da conversa. Vai como mensagem da pessoa, que é o formato
    /// que todo provedor aceita no começo da conversa — e é o que a Anthropic chama de
    /// compactação simples: o resumo numa mensagem só.
    ///
    /// `continuar`: o turno segue sozinho depois do resumo. O convite é o texto que o
    /// opencode põe depois de uma compactação automática.
    static func mensagemDoResumo(_ resumo: String, continuar: Bool) -> AgentMessage {
        var texto = abreResumo + "\n" + resumo + "\n" + fechaResumo + "\n\n"
            + "O começo desta conversa foi resumido acima para caber na janela de contexto. "
            + "O que não está no resumo não está mais aqui: releia os arquivos se precisar de detalhes."
        if continuar {
            texto += " Continue se houver próximos passos, ou pare e pergunte se não tiver certeza de como seguir."
        }
        return .user(texto)
    }

    /// É o resumo de uma compactação?
    public static func ehResumo(_ m: AgentMessage) -> Bool {
        m.role == .user && m.content.hasPrefix(abreResumo)
    }

    /// O texto do resumo, sem as tags nem o aviso.
    public static func textoDoResumo(_ m: AgentMessage) -> String? {
        guard ehResumo(m), let fim = m.content.range(of: fechaResumo) else { return nil }
        let inicio = m.content.index(m.content.startIndex, offsetBy: abreResumo.count)
        return String(m.content[inicio ..< fim.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Quanto fica como está no fim: um quarto do utilizável, entre `caudaMinima` e
    /// `caudaMaxima` — `preserveRecentBudget` do opencode.
    static func orcamentoDaCauda(janela: Int) -> Int {
        min(caudaMaxima, max(caudaMinima, Int(Double(janela) * gatilho * 0.25)))
    }

    /// O plano de um resumo: o que vai para ele, e o que fica.
    struct Plano {
        /// As mensagens que o resumo substitui.
        var cabeca: [AgentMessage]
        var resumoAnterior: String?
        /// Daqui até o fim, a conversa continua igual.
        var inicioDaCauda: Int
        /// O pedido do turno, se ele ficou antes da cauda (e por isso vai explícito).
        var pedidoForaDaCauda: Int?
    }

    /// Onde cortar: `select` e `splitTurn` do opencode, no formato daqui.
    ///
    /// A cauda é o maior fim da conversa que cabe no orçamento e começa numa mensagem que
    /// não é resultado de ferramenta — um resultado sem a chamada antes é o 400 de sempre.
    /// Não passa para trás do resumo anterior. `nil` quando não há o que resumir.
    static func planejar(_ ms: [AgentMessage], pedido: Int?, janela: Int) -> Plano? {
        let piso = ms.lastIndex(where: ehResumo) ?? -1
        let orcamento = orcamentoDaCauda(janela: janela)
        var inicio = ms.count
        var soma = 0
        var i = ms.count - 1
        while i > piso {
            soma += estimar(ms[i])
            if soma > orcamento {
                break
            }
            if ms[i].role != .tool {
                inicio = i
            }
            i -= 1
        }
        let fora = pedido.flatMap { $0 > piso && $0 < inicio ? $0 : nil }
        let cabeca = ((piso + 1) ..< inicio).filter { $0 != fora }.map { ms[$0] }
        guard !cabeca.isEmpty else { return nil }
        return Plano(
            cabeca: cabeca,
            resumoAnterior: piso >= 0 ? textoDoResumo(ms[piso]) : nil,
            inicioDaCauda: inicio,
            pedidoForaDaCauda: fora
        )
    }

    /// A conversa depois do resumo: o resumo, o pedido do turno e a cauda — sem o
    /// raciocínio de nenhuma delas. Devolve também onde o pedido foi parar.
    static func montar(
        _ ms: [AgentMessage],
        plano: Plano,
        resumo: String,
        pedido: Int?,
        continuar: Bool
    ) -> (mensagens: [AgentMessage], pedido: Int?) {
        var out = [mensagemDoResumo(resumo, continuar: continuar)]
        var novoPedido: Int?
        if let p = plano.pedidoForaDaCauda {
            novoPedido = out.count
            out.append(ms[p])
        }
        let base = out.count
        out += ms[plano.inicioDaCauda...]
        if novoPedido == nil, let p = pedido, p >= plano.inicioDaCauda {
            novoPedido = base + (p - plano.inicioDaCauda)
        }
        return (semRaciocinio(out), novoPedido)
    }

    /// O texto que o modelo devolveu, sem as tags que ele às vezes põe em volta.
    static func limparResumo(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (a, b) in [("<summary>", "</summary>"), ("<resumo>", "</resumo>"), ("<modelo>", "</modelo>")] {
            if t.hasPrefix(a), t.hasSuffix(b) {
                t = String(t.dropFirst(a.count).dropLast(b.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }
}
