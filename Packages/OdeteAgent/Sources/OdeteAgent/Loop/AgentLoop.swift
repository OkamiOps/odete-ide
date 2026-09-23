import Foundation
import OdeteCore
import OdeteI18n
import Synchronization

public struct LoopConfig: Sendable {
    public var mode: AgentMode
    public var permit: PermitMode
    public var model: String
    public var effort: String
    public var conversationId: String
    /// Teto de rodadas de ferramenta.
    ///
    /// Sessão de desenvolvimento de verdade passa de mil rodadas. Vinte era absurdo, e
    /// duzentas ainda parariam no meio de um trabalho grande — e parar no meio obriga a
    /// pessoa a ficar mandando "continua", que é exatamente o que uma ferramenta assim
    /// não pode fazer.
    ///
    /// O que sobra aqui não é um limite de trabalho, é um fusível: o modelo entrando em
    /// laço não pode virar conta alta na chave de quem está usando. Quem interrompe
    /// trabalho legítimo é o botão de parar, que está sempre à mão.
    public var maxRounds = 5000
    /// A janela total de contexto do modelo, em tokens. Quem sabe é quem conhece o modelo
    /// (o `AgentModel`); sem ela vale `Compactacao.janelaPadrao`. É daqui que sai o ponto
    /// de compactar a conversa — ver `Compactacao`.
    public var janelaDeContexto: Int?
    /// O prompt de sistema da conversa, se ela já tem um (`ChatThread.sistema`). Sem ele, o
    /// laço monta e devolve no evento `.sistema`, para quem guarda a conversa guardar junto.
    public var sistema: String?
    public init(mode: AgentMode, permit: PermitMode, model: String, effort: String = "", conversationId: String = "") {
        self.mode = mode; self.permit = permit; self.model = model; self.effort = effort; self
            .conversationId = conversationId
    }
}

public enum LoopEvent: Sendable {
    case item(ChatItem)
    case usage(TokenUse)
    case history([AgentMessage])
    /// Quanto da janela a conversa ocupa agora, em tokens: o que o provedor reportou na
    /// última rodada mais o que entrou depois dela, ou a estimativa quando não há relato.
    case contexto(usados: Int, janela: Int)
    /// O prompt de sistema que esta conversa passa a usar — ver `LoopConfig.sistema`.
    case sistema(String)
    case done
}

/// O loop do agente: turnos de modelo → ferramentas → repetição, com permissões, parada e redirecionamento.
public final class AgentLoop: @unchecked Sendable {
    public let provider: Provider
    public let host: ToolHost
    public let runner: ToolRunner
    public let checkpoints: CheckpointStore?
    private let permits = Mutex<[String: CheckedContinuation<Bool, Never>]>([:])
    private let steerQueue = Mutex<[String]>([])
    private let stopped = Mutex(false)
    private let current = Mutex<Task<Void, Never>?>(nil)
    /// A ferramenta rodando agora. Separada de `current` porque só o parar a interrompe:
    /// redirecionar no meio de um `npm install` não pode matar o `npm install`.
    private let ferramenta = Mutex<Task<ToolOutcome, Never>?>(nil)
    /// O pedido de resumo em andamento. Também só o parar interrompe: redirecionar no meio
    /// do resumo deixaria um resumo pela metade no lugar da conversa.
    private let resumindo = Mutex<Task<Void, Never>?>(nil)

    public init(provider: Provider, host: ToolHost, patches: PatchStore, checkpoints: CheckpointStore? = nil) {
        self.provider = provider
        self.host = host
        runner = ToolRunner(host: host, patches: patches, checkpoints: checkpoints)
        self.checkpoints = checkpoints
    }

    /// A partir de quantas repetições idênticas o laço passa a orientar.
    ///
    /// Idêntica quer dizer a mesma chamada, com os mesmos argumentos, devolvendo o mesmo
    /// resultado. Três é folgado para um agente que confere o que acabou de ler. Da quarta
    /// em diante, no lugar do resultado volta um aviso de que aquilo já foi lido e não
    /// mudou. Orientar é o trabalho do harness; matar o turno seria transferir para a
    /// pessoa um problema que é nosso.
    static let tetoDeRepeticao = 3

    /// E quando nem a orientação pega, aí sim desiste.
    ///
    /// Um agente que insiste na mesma chamada doze vezes, já avisado, não vai sair do
    /// lugar sozinho — e quem está olhando merece saber disso em vez de ver o mesmo
    /// pedido rodar para sempre.
    static let tetoDeDesistencia = 12

    /// As ferramentas que o freio vigia: as que só leem.
    ///
    /// O `run_shell` fica de fora de propósito. Editar → rodar o teste → editar → rodar o
    /// teste é o ciclo normal de trabalho, e o freio contava cada `npm test` como a mesma
    /// chamada: na quarta vez o teste nem rodava, e no lugar dele voltava "As mudanças já
    /// foram feitas… Pare de ler".
    static let vigiadas: Set<String> = [
        "read_file", "list_dir", "grep", "read_terminal", "read_problems", "read_preview_console",
    ]

    /// Contagem das repetições do turno — ver `tetoDeRepeticao`.
    struct Freio {
        private var vezes: [String: Int] = [:]
        private var ultimo: [String: Int] = [:]

        /// Uma chamada com este resultado. Devolve quantas vezes seguidas ela deu o
        /// mesmo resultado.
        ///
        /// Comparar o resultado é o que separa estar preso de estar trabalhando: reler o
        /// arquivo depois de editar devolve outro conteúdo, e isso não é repetição — era
        /// bloqueado antes, porque só a chamada era comparada.
        mutating func registrar(_ assinatura: String, resultado: String) -> Int {
            let marca = resultado.hashValue
            if ultimo[assinatura] == marca {
                vezes[assinatura, default: 1] += 1
            } else {
                ultimo[assinatura] = marca
                vezes[assinatura] = 1
            }
            return vezes[assinatura] ?? 1
        }

        /// Depois de uma escrita tudo pode ter mudado: a contagem recomeça.
        mutating func zerar() {
            vezes = [:]
            ultimo = [:]
        }
    }

    public func approve(_ id: String, _ ok: Bool) {
        permits.withLock { $0.removeValue(forKey: id) }?.resume(returning: ok)
    }

    /// Cancela a rodada atual e injeta a mensagem.
    public func steer(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        steerQueue.withLock { $0.append(t) }
        current.withLock { $0?.cancel() }
        let waiting = permits.withLock { let all = $0; $0.removeAll(); return all }
        for (_, c) in waiting {
            c.resume(returning: false)
        }
    }

    /// Para tudo: o modelo, a licença pendente e a ferramenta que estiver rodando.
    ///
    /// A ferramenta não parava: um `run_shell` esperava até cinco minutos pelo comando,
    /// com a pessoa já tendo apertado parar.
    public func stop() {
        stopped.withLock { $0 = true }
        current.withLock { $0?.cancel() }
        ferramenta.withLock { $0?.cancel() }
        resumindo.withLock { $0?.cancel() }
        let waiting = permits.withLock { let all = $0; $0.removeAll(); return all }
        for (_, c) in waiting {
            c.resume(returning: false)
        }
    }

    var hasSteer: Bool {
        steerQueue.withLock { !$0.isEmpty }
    }

    func takeSteer() -> String {
        steerQueue.withLock { let s = $0.joined(separator: "\n\n"); $0.removeAll(); return s }
    }

    var isStopped: Bool {
        stopped.withLock { $0 }
    }

    public func run(
        history: [AgentMessage],
        userText: String,
        images: [AgentImage] = [],
        config: LoopConfig
    ) -> AsyncStream<LoopEvent> {
        stopped.withLock { $0 = false }
        steerQueue.withLock { $0.removeAll() }
        return AsyncStream { cont in
            let task = Task { [self] in
                await loop(
                    history: history,
                    userText: userText,
                    images: images,
                    config: config,
                    emit: { cont.yield($0) }
                )
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Compacta a conversa agora, fora de um turno: o `/compact`.
    ///
    /// Vai direto ao resumo, como o `/compact` do opencode — a poda sozinha não é o que
    /// quem pediu para compactar espera.
    public func compactar(history: [AgentMessage], config: LoopConfig) -> AsyncStream<LoopEvent> {
        stopped.withLock { $0 = false }
        return AsyncStream { cont in
            let task = Task { [self] in
                let emit: @Sendable (LoopEvent) -> Void = { cont.yield($0) }
                // O modelo do aparelho cuida da própria janela, de poucos milhares de
                // tokens — ver o `compacta` do laço.
                guard provider.kind != .apple else {
                    emit(.item(.error(
                        id: Self.prefixoDeAviso + UUID().uuidString,
                        text: tr("O modelo do aparelho cuida da própria janela: não há o que compactar aqui.")
                    )))
                    emit(.done)
                    cont.finish()
                    return
                }
                let mensagens = Transcricao.consertar(history)
                let janela = config.janelaDeContexto ?? Compactacao.janelaPadrao
                let fixo = Self.fixo(config.sistema ?? sistemaDaConversa(), Tools.all)
                let uso = fixo + Compactacao.estimar(mensagens)
                if let c = await resumir(
                    mensagens,
                    pedido: nil,
                    uso: uso,
                    janela: janela,
                    fixo: fixo,
                    continuar: false,
                    config: config,
                    emit: emit
                ) {
                    emit(.history(c.mensagens))
                    emit(.contexto(usados: c.uso, janela: janela))
                }
                emit(.done)
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// O sistema de uma conversa nova — ver `Prompts.daConversa`.
    func sistemaDaConversa() -> String {
        let caminhos = host.allPaths()
        let pilha = Stack.detect(paths: caminhos, packageJSON: host.read("package.json").map { Data($0.utf8) })
        return Prompts.daConversa(fileList: caminhos, extras: [pilha.regrasParaOAgente, Rules.prompt(host: host)])
    }

    /// O sistema do modelo do aparelho, que continua recebendo tudo nele, modo inclusive:
    /// ele não guarda raciocínio entre pedidos, e as instruções dele são recortadas para
    /// caber na janela (`AppleInstrucoes`), que conta com o modo lá dentro.
    func systemPrompt(mode: AgentMode, userText: String) -> String {
        let skills = Skills.prompt(all: Skills.all(host: host), userText: userText)
        // A pilha entra sempre, sem a pessoa pedir: as skills são opt-in (`/nome`), e
        // esperar que alguém digite "isto é Astro" num projeto que o próprio Hub criou
        // a partir do modelo Astro não faz sentido.
        let caminhos = host.allPaths()
        let pilha = Stack.detect(paths: caminhos, packageJSON: host.read("package.json").map { Data($0.utf8) })
        return Prompts.build(
            mode: mode,
            fileList: caminhos,
            extras: [pilha.regrasParaOAgente, skills, Rules.prompt(host: host)]
        )
    }

    /// O que vai em todo pedido além da conversa: o sistema e o schema das ferramentas.
    static func fixo(_ sistema: String, _ ferramentas: [ToolSpec]) -> Int {
        Compactacao.estimar(sistema) + ferramentas.reduce(0) {
            $0 + Compactacao.estimar($1.name + $1.description + $1.parametersJSON)
        }
    }

    /// Quanto da janela a conversa ocupa antes do próximo envio.
    ///
    /// O que o provedor reportou na última rodada é a medida (é o que o opencode usa em
    /// `isOverflow`); o que entrou depois dela — os resultados de ferramenta — ainda não
    /// foi medido por ninguém e entra estimado. Sem relato, tudo é estimativa.
    static func uso(medido: (tokens: Int, ate: Int)?, mensagens: [AgentMessage], fixo: Int) -> Int {
        if let medido, medido.ate <= mensagens.count {
            return medido.tokens + Compactacao.estimar(mensagens[medido.ate...])
        }
        return fixo + Compactacao.estimar(mensagens)
    }

    private func loop(
        history: [AgentMessage],
        userText: String,
        images: [AgentImage],
        config: LoopConfig,
        emit: @escaping @Sendable (LoopEvent) -> Void
    ) async {
        var messages = Transcricao.consertar(history)
        // Sistema e ferramentas ficam iguais a conversa inteira — ver `Prompts.daConversa`.
        // O modelo do aparelho é a exceção: ele recebe o sistema do modo, montado uma vez
        // por turno, e só as ferramentas do modo.
        let congelado = provider.kind != .apple
        let sistema: String
        let tools: [ToolSpec]
        var expanded = Mentions.expand(userText, host: host)
        if congelado {
            if let s = config.sistema {
                sistema = s
            } else {
                sistema = sistemaDaConversa()
                emit(.sistema(sistema))
            }
            tools = Tools.all
            let skills = Skills.prompt(all: Skills.all(host: host), userText: userText)
            expanded += "\n\n" + Prompts.contextoDoTurno(mode: config.mode, skills: skills)
        } else {
            sistema = systemPrompt(mode: config.mode, userText: userText)
            tools = Tools.forMode(config.mode)
        }
        var pedido = AgentMessage.user(expanded, images: images)
        // A conversa terminou numa mensagem da pessoa que ninguém respondeu — a nota do
        // desfazer, ou um pedido que morreu num erro. Vai junto com o pedido novo, numa
        // mensagem só: duas seguidas da pessoa nem todo provedor aceita.
        if let ultima = messages.last, ultima.role == .user, !Compactacao.ehResumo(ultima) {
            messages.removeLast()
            pedido = .user(ultima.content + "\n\n" + expanded, images: (ultima.images ?? []) + images)
        }
        // O pedido deste turno, e não o primeiro da conversa: é ele que a compactação
        // guarda. (O `comOPedido` de antes pegava o primeiro pedido da conversa inteira e
        // o reinjetava em todo turno — num segundo pedido, o modelo recebia o primeiro de
        // novo, como se fosse o atual.)
        var indiceDoPedido: Int? = messages.count
        messages.append(pedido)
        emit(.item(.user(id: UUID().uuidString, text: userText, images: images.isEmpty ? nil : images)))
        checkpoints?.take(title: ChatStore.title(of: [.user(id: "", text: userText, images: nil)]))
        // O fim do turno fica anotado seja qual for a saída — resposta, erro, parada, o freio
        // de repetição. Sem ele, o desfazer não separa o que o turno fez do que a pessoa
        // fizer depois.
        defer { checkpoints?.encerrar() }
        let fixo = Self.fixo(sistema, tools)
        var round = 0
        var hitCap = false
        // Se o turno chegou a mexer em arquivo, e se a cutucada de "anunciar não é
        // fazer" já foi dada — ver o `toolCalls.isEmpty` mais abaixo.
        var fezPatch = false
        var cutucou = false
        var freio = Freio()
        var desistiu = false
        // O uso reportado pelo provedor na última rodada, e até onde ia a conversa medida.
        var medido: (tokens: Int, ate: Int)?
        // Já compactou por estouro nesta rodada: se estourar de novo, é erro de verdade.
        var estourou = false
        let janela = config.janelaDeContexto ?? Compactacao.janelaPadrao
        // O modelo do aparelho cuida da própria janela (`AppleTranscricao`), que é de
        // poucos milhares de tokens: compactar em cima disso resumiria a cada rodada.
        let compacta = provider.kind != .apple
        while round < config.maxRounds {
            if isStopped {
                break
            }
            // Antes de cada envio, a conversa fecha: toda chamada com resultado.
            messages = Transcricao.consertar(messages)
            let uso = Self.uso(medido: medido, mensagens: messages, fixo: fixo)
            emit(.contexto(usados: uso, janela: janela))
            if compacta {
                if Compactacao.passou(uso, janela: janela), let c = await compactar(
                    messages,
                    pedido: indiceDoPedido,
                    uso: uso,
                    janela: janela,
                    fixo: fixo,
                    config: config,
                    emit: emit
                ) {
                    messages = c.mensagens
                    indiceDoPedido = c.pedido
                    medido = nil
                    emit(.history(messages))
                    emit(.contexto(usados: c.uso, janela: janela))
                }
                if isStopped {
                    break
                }
            }
            let thinkId = UUID().uuidString, textId = UUID().uuidString
            let think = Mutex(""), text = Mutex(""), calls = Mutex<[ToolCall]>([]), use = Mutex(TokenUse()),
                err = Mutex<String?>(nil), bruto = Mutex<RaciocinioBruto?>(nil)
            // A conversa inteira. A janela deslizante de 24 mensagens que havia aqui jogava
            // fora trabalho no meio de um turno longo; quem cuida do tamanho agora é a
            // compactação, lá em cima.
            let turn = TurnRequest(
                system: sistema,
                messages: messages,
                tools: tools,
                model: config.model,
                effort: config.effort,
                conversationId: config.conversationId
            )
            // O texto vai para a tela em lotes, não token a token — ver `Vazao`. O que se
            // entrega é sempre o acumulado inteiro do item, então pular lotes não perde nada.
            let vazao = Vazao(emitir: emit)
            // O raciocínio aberto fecha quando a resposta começa. Uma vez só: fechar a cada
            // token de texto reenviava o raciocínio inteiro junto com cada pedaço.
            let pensando = Mutex(false)
            let relogio = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: vazao.intervalo)
                    if Task.isCancelled {
                        break
                    }
                    vazao.tique()
                }
            }
            let streamTask = Task { [provider] in
                do {
                    for try await e in provider.stream(turn) {
                        if Task.isCancelled {
                            break
                        }
                        switch e {
                        case let .think(s):
                            think.withLock { $0 += s }
                            pensando.withLock { $0 = true }
                            vazao.marcar(thinkId) { .think(id: thinkId, text: think.withLock { $0 }, live: true) }
                        case let .text(s):
                            if pensando.withLock({ let aberto = $0; $0 = false; return aberto }) {
                                vazao.marcar(thinkId) { .think(id: thinkId, text: think.withLock { $0 }, live: false) }
                            }
                            text.withLock { $0 += s }
                            vazao.marcar(textId) { .assistant(id: textId, text: text.withLock { $0 }) }
                        case let .tools(c): calls.withLock { $0 = c }
                        case let .usage(u): use.withLock { $0 = $0.filled(with: u) }
                        case let .error(m): err.withLock { $0 = m }
                        // O raciocínio assinado/criptografado volta intacto na próxima rodada.
                        case let .raciocinio(r): bruto.withLock { $0 = r }
                        case .done: break
                        }
                    }
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled {
                        err.withLock { $0 = error.localizedDescription }
                    }
                }
            }
            current.withLock { $0 = streamTask }
            await streamTask.value
            current.withLock { $0 = nil }
            // O relógio para antes do último lote: nada dele pode chegar depois do que o
            // laço emite daqui em diante — um raciocínio "ao vivo" atrasado reabriria o
            // cartão que já fechou.
            relogio.cancel()
            await relogio.value
            vazao.esvaziar()
            let thinkText = think.withLock { $0 }, answer = text.withLock { $0 }, toolCalls = calls.withLock { $0 }
            if !thinkText.isEmpty {
                emit(.item(.think(id: thinkId, text: thinkText, live: false)))
            }
            let u = use.withLock { $0 }
            if !u.isEmpty {
                emit(.usage(u))
            }
            if isStopped, !hasSteer {
                if !answer.isEmpty {
                    messages.append(AgentMessage(
                        role: .assistant,
                        content: answer,
                        thinking: thinkText.isEmpty ? nil : thinkText
                    ))
                }
                emit(.item(.error(id: UUID().uuidString, text: "parado")))
                break
            }
            if hasSteer {
                if !answer.isEmpty {
                    messages.append(AgentMessage(role: .assistant, content: answer))
                }
                let note = takeSteer()
                messages
                    .append(.user(tr(
                        "Redireciona a execução agora. Interrompe o plano anterior e segue isto:\n\n%1$@",
                        "\(note)"
                    )))
                emit(.item(.user(id: UUID().uuidString, text: note, images: nil)))
                round = 0
                continue
            }
            if let e = err.withLock({ $0 }) {
                // Não coube na janela, mesmo com a medida: resume e tenta a rodada de novo,
                // uma vez — o `ContextOverflowError` do opencode, que vira compactação.
                if compacta, !estourou, Compactacao.ehEstouro(e) {
                    estourou = true
                    if let c = await resumir(
                        messages,
                        pedido: indiceDoPedido,
                        uso: Self.uso(medido: nil, mensagens: messages, fixo: fixo),
                        janela: janela,
                        fixo: fixo,
                        continuar: true,
                        config: config,
                        emit: emit
                    ) {
                        messages = c.mensagens
                        indiceDoPedido = c.pedido
                        medido = nil
                        emit(.history(messages))
                        emit(.contexto(usados: c.uso, janela: janela))
                        continue
                    }
                }
                emit(.item(.error(id: UUID().uuidString, text: e)))
                break
            }
            estourou = false
            messages.append(AgentMessage(
                role: .assistant,
                content: answer,
                thinking: thinkText.isEmpty ? nil : thinkText,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls,
                raciocinio: bruto.withLock { $0 }
            ))
            medido = Compactacao.tokensDaRodada(u, kind: provider.kind).map { ($0, messages.count) }
            if let medido {
                emit(.contexto(usados: medido.tokens, janela: janela))
            }
            emit(.history(messages))
            if toolCalls.isEmpty {
                // Anunciar não é fazer.
                //
                // No Build já aconteceu do modelo devolver quinze linhas de "Fixed
                // color-scheme", "Set font-family", "Updated padding" — sem ter chamado
                // uma ferramenta sequer. O turno terminava ali: arquivo intacto, erro na
                // tela e a pessoa achando que tinha sido resolvido. Escrever isso nas
                // instruções não resolveu, então resolve aqui: uma cutucada, uma vez por
                // turno, e ela mesma abre a porta para "não havia o que fazer" — que é a
                // resposta certa quando a pergunta era só uma pergunta.
                if config.mode == .build, !fezPatch, !cutucou {
                    cutucou = true
                    messages.append(.user(tr(
                        "Nada mudou no projeto: você não chamou ferramenta nenhuma, e descrever a mudança não a aplica. Chame a ferramenta agora e faça. Só responda em texto se não existir nenhuma mudança a fazer."
                    )))
                    round += 1
                    continue
                }
                break
            }
            var redirected = false
            for (i, call) in toolCalls.enumerated() {
                if isStopped || hasSteer {
                    for c in toolCalls[i...] {
                        messages.append(.tool(
                            c.id,
                            tr("cancelado: o usuário redirecionou a execução")
                        ))
                    }
                    redirected = hasSteer
                    break
                }
                let hint = Self.hint(call)
                // As ferramentas vão todas em todo modo (a lista não pode mudar no meio da
                // conversa); a que o modo não tem é recusada aqui, antes de pedir licença
                // para uma ação que não ia acontecer.
                //
                // E a chamada cortada no limite de saída (`ToolCall.problema`) não roda: o
                // executor devolve a explicação. Pedir licença, ou dizer que o modo não
                // permite, seria falar de uma ação que também não vai acontecer.
                let cortada = call.problema != nil
                guard cortada || Tools.permitida(call.name, no: config.mode) else {
                    emit(.item(.tool(id: call.id, name: call.name, detail: hint)))
                    messages.append(.tool(call.id, "\(call.name) não está disponível no modo \(config.mode.label). "
                        + "Siga o modo do <contexto_do_turno>; para editar, a pessoa precisa mudar para Build."))
                    continue
                }
                if !cortada, Tools.needsPermit(config.permit, call) {
                    emit(.item(.permit(id: call.id, name: call.name, detail: hint, status: .pending)))
                    let ok = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                        permits.withLock { $0[call.id] = c }
                    }
                    if !ok {
                        emit(.item(.permit(id: call.id, name: call.name, detail: hint, status: .no)))
                        messages.append(.tool(call.id, "usuário recusou esta ação"))
                        continue
                    }
                    emit(.item(.permit(id: call.id, name: call.name, detail: hint, status: .ok)))
                }
                let out = await rodarFerramenta(call, mode: config.mode)
                let resultado = out.text
                if Self.vigiadas.contains(call.name) {
                    // A mesma chamada, com os mesmos argumentos e o mesmo resultado,
                    // repetida sem parar.
                    //
                    // Foi o que aconteceu com o modelo local: cento e oitenta e seis
                    // `read_file` do mesmo arquivo, um atrás do outro. Um agente que relê o
                    // mesmo arquivo sem mudança pela sexta vez não está trabalhando, está
                    // preso — e o fusível de rodadas, lá em cima, é grande demais para
                    // servir de freio aqui: até ele disparar já passou meia hora.
                    let vezes = freio.registrar("\(call.name)|\(call.arguments)", resultado: out.text)
                    if vezes > Self.tetoDeDesistencia {
                        // Quando o trabalho já foi feito, isto não é falha: é um agente que
                        // não sabe parar de conferir. Terminar em vermelho, com o patch
                        // pronto esperando na tela, faz parecer que deu errado o que deu
                        // certo.
                        if fezPatch {
                            emit(.item(.assistant(
                                id: UUID().uuidString,
                                text: tr("Fiz as mudanças e parei de reler o projeto. O patch está aí para você revisar.")
                            )))
                        } else {
                            emit(.item(.error(
                                id: UUID().uuidString,
                                text: tr(
                                    "Parei: a mesma chamada de %1$@ se repetiu %2$@ vezes, mesmo avisada. Redirecione ou tente outro modelo.",
                                    call.name,
                                    "\(vezes)"
                                )
                            )))
                        }
                        // Desistir também fecha a conversa: esta chamada e as que vinham
                        // depois dela na mesma rodada ganham resultado. Antes era um
                        // `return` aqui — sem resultado, sem histórico gravado, sem `.done`
                        // — e a conversa guardada terminava numa chamada sem resposta: dali
                        // em diante, toda mensagem recebia 400 do provedor.
                        let cancelado = tr("cancelado: o turno parou por repetição")
                        for c in toolCalls[i...] {
                            messages.append(.tool(c.id, cancelado))
                        }
                        desistiu = true
                        break
                    }
                    if vezes > Self.tetoDeRepeticao {
                        // No lugar do resultado volta a orientação, no formato de resultado
                        // de ferramenta, que é o que mantém a transcrição inteira — chamada
                        // feita, chamada respondida.
                        emit(.item(.tool(id: call.id, name: call.name, detail: tr("já lido, sem mudança"))))
                        // Com patch já feito o aviso é outro: não é "não releia", é "acabou".
                        // Quem está relendo, sem nada ter mudado, depois de editar não
                        // precisa de dado, precisa de alguém dizendo que o trabalho terminou.
                        messages.append(.tool(
                            call.id,
                            fezPatch
                                ? tr(
                                    "As mudanças já foram feitas e estão na tela para revisão. Pare de ler: responda em uma frase o que mudou."
                                )
                                : tr(
                                    "Você já chamou %1$@ com estes mesmos argumentos nesta conversa e o resultado não mudou. Não repita: use o que já leu. Se a mudança já foi feita, diga o que mudou e encerre.",
                                    call.name
                                )
                        ))
                        continue
                    }
                } else if Self.podeEscrever(call) {
                    freio.zerar()
                }
                if let p = out.patch {
                    fezPatch = true
                    emit(.item(.patch(id: UUID().uuidString, patchId: p.id, path: p.path)))
                } else if cortada || !Tools.needsPermit(config.permit, call) {
                    emit(.item(.tool(
                        id: call.id,
                        name: call.name,
                        detail: hint.isEmpty ? String(resultado.split(separator: "\n").first ?? "") : hint
                    )))
                }
                messages.append(.tool(call.id, resultado))
            }
            emit(.history(messages))
            if desistiu {
                break
            }
            if redirected {
                let note = takeSteer()
                messages
                    .append(.user(tr(
                        "Redireciona a execução agora. Interrompe o plano anterior e segue isto:\n\n%1$@",
                        "\(note)"
                    )))
                emit(.item(.user(id: UUID().uuidString, text: note, images: nil)))
                round = 0
                continue
            }
            if isStopped {
                emit(.item(.error(id: UUID().uuidString, text: "parado"))); break
            }
            round += 1
            if round == config.maxRounds {
                hitCap = true
            }
        }
        if hitCap, !isStopped {
            emit(.item(.error(
                id: UUID().uuidString,
                text: tr("parei em %1$@ rodadas de ferramenta — manda de novo pra continuar", "\(config.maxRounds)")
            )))
        }
        emit(.history(Transcricao.consertar(messages)))
        emit(.done)
    }

    /// Roda a ferramenta numa tarefa que o parar consegue cancelar.
    private func rodarFerramenta(_ call: ToolCall, mode: AgentMode) async -> ToolOutcome {
        let t = Task { [runner] in await runner.run(call, mode: mode) }
        ferramenta.withLock { $0 = t }
        // O parar pode ter chegado entre a última olhada e agora.
        if isStopped {
            t.cancel()
        }
        let out = await t.value
        ferramenta.withLock { $0 = nil }
        return out
    }

    /// A chamada pode ter mudado o projeto? Depois dela, o freio recomeça a contar.
    static func podeEscrever(_ call: ToolCall) -> Bool {
        // Cortada não rodou.
        if call.problema != nil {
            return false
        }
        if call.name == "run_shell" {
            return !Tools.isReadShell((call.args["command"] as? String) ?? "")
        }
        return !vigiadas.contains(call.name)
    }

    /// Compacta: primeiro a poda das saídas antigas de ferramenta; se ela não trouxer o uso
    /// para baixo do gatilho, o resumo — a ordem do opencode (`prune`, depois `process`).
    private func compactar(
        _ mensagens: [AgentMessage],
        pedido: Int?,
        uso: Int,
        janela: Int,
        fixo: Int,
        config: LoopConfig,
        emit: @escaping @Sendable (LoopEvent) -> Void
    ) async -> (mensagens: [AgentMessage], pedido: Int?, uso: Int)? {
        guard let podado = Compactacao.podar(mensagens) else {
            return await resumir(
                mensagens,
                pedido: pedido,
                uso: uso,
                janela: janela,
                fixo: fixo,
                continuar: true,
                config: config,
                emit: emit
            )
        }
        let depois = max(0, uso - podado.liberados)
        if !Compactacao.passou(depois, janela: janela) {
            emit(.item(.compactado(id: UUID().uuidString, resumo: "", antes: uso, depois: depois)))
            return (podado.mensagens, pedido, depois)
        }
        let resumido = await resumir(
            podado.mensagens,
            pedido: pedido,
            uso: uso,
            janela: janela,
            fixo: fixo,
            continuar: true,
            config: config,
            emit: emit
        )
        // Se o resumo falhar, a poda já ajudou: vale ficar com ela.
        return resumido ?? (podado.mensagens, pedido, depois)
    }

    /// O resumo: o começo da conversa vira um texto só, pedido ao mesmo modelo, sem
    /// ferramentas; o pedido do turno e as últimas mensagens ficam como estão.
    private func resumir(
        _ mensagens: [AgentMessage],
        pedido: Int?,
        uso: Int,
        janela: Int,
        fixo: Int,
        continuar: Bool,
        config: LoopConfig,
        emit: @escaping @Sendable (LoopEvent) -> Void
    ) async -> (mensagens: [AgentMessage], pedido: Int?, uso: Int)? {
        // Aviso, não erro: se o resumo falhar, o cartão vira um aviso neutro no mesmo
        // lugar, sem "Tentar de novo" — que repetiria a última pergunta, e não a compactação.
        let id = Self.prefixoDeAviso + UUID().uuidString
        guard let plano = Compactacao.planejar(mensagens, pedido: pedido, janela: janela) else {
            if !continuar {
                emit(.item(.error(
                    id: id,
                    text: tr("A conversa ainda é curta: não há o que compactar.")
                )))
            }
            return nil
        }
        emit(.item(.compactado(id: id, resumo: "", antes: uso, depois: 0)))
        let turno = TurnRequest(
            system: Compactacao.sistema,
            messages: [.user(Compactacao.promptQueCabe(
                plano.cabeca,
                resumoAnterior: plano.resumoAnterior,
                janela: janela
            ))],
            tools: [],
            model: config.model,
            effort: config.effort,
            conversationId: config.conversationId
        )
        let texto = Mutex(""), erro = Mutex<String?>(nil)
        let t = Task { [provider] in
            do {
                for try await e in provider.stream(turno) {
                    if Task.isCancelled {
                        break
                    }
                    switch e {
                    case let .text(s): texto.withLock { $0 += s }
                    case let .error(m): erro.withLock { $0 = m }
                    default: break
                    }
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled {
                    erro.withLock { $0 = error.localizedDescription }
                }
            }
        }
        resumindo.withLock { $0 = t }
        if isStopped {
            t.cancel()
        }
        await t.value
        resumindo.withLock { $0 = nil }
        if isStopped || t.isCancelled {
            emit(.item(.error(id: id, text: "parado")))
            return nil
        }
        let resumo = Compactacao.limparResumo(texto.withLock { $0 })
        guard erro.withLock({ $0 }) == nil, !resumo.isEmpty else {
            emit(.item(.error(id: id, text: tr(
                "Não deu para compactar a conversa: %1$@",
                erro.withLock { $0 } ?? tr("o modelo não devolveu o resumo")
            ))))
            return nil
        }
        let novo = Compactacao.montar(mensagens, plano: plano, resumo: resumo, pedido: pedido, continuar: continuar)
        let depois = fixo + Compactacao.estimar(novo.mensagens)
        emit(.item(.compactado(id: id, resumo: resumo, antes: uso, depois: depois)))
        return (novo.mensagens, novo.pedido, depois)
    }

    /// Começo do id de um aviso neutro na conversa — nem erro, nem resposta. O cartão sai
    /// cinza, sem "Tentar de novo".
    public static let prefixoDeAviso = "aviso-"

    static func hint(_ call: ToolCall) -> String {
        let a = call.args
        // No GitHub o que importa é a ação e o PR: "github" sozinho não diz o que se
        // está autorizando, e é justamente aí que a pessoa decide.
        if call.name == "github", let acao = a["action"] as? String {
            let n = (a["number"] as? Int) ?? (a["number"] as? Double).map(Int.init)
            let alvo = n.map { " #\($0)" } ?? (a["title"] as? String).map { ": \($0)" } ?? ""
            return acao + alvo
        }
        for k in ["path", "pattern", "command"] {
            if let v = a[k] as? String, !v.isEmpty {
                return v
            }
        }
        return call.name
    }
}
