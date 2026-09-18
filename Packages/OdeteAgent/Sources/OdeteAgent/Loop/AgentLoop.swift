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
    public init(mode: AgentMode, permit: PermitMode, model: String, effort: String = "", conversationId: String = "") {
        self.mode = mode; self.permit = permit; self.model = model; self.effort = effort; self
            .conversationId = conversationId
    }
}

public enum LoopEvent: Sendable {
    case item(ChatItem)
    case usage(TokenUse)
    case history([AgentMessage])
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

    public init(provider: Provider, host: ToolHost, patches: PatchStore, checkpoints: CheckpointStore? = nil) {
        self.provider = provider
        self.host = host
        runner = ToolRunner(host: host, patches: patches)
        self.checkpoints = checkpoints
    }

    /// A partir de quantas repetições idênticas o laço passa a orientar.
    ///
    /// Três é folgado para um agente que relê um arquivo depois de mexer nele. Da quarta
    /// em diante a chamada nem chega a rodar: no lugar do resultado volta um aviso de que
    /// aquilo já foi lido e não mudou. Orientar é o trabalho do harness; matar o turno
    /// seria transferir para a pessoa um problema que é nosso.
    static let tetoDeRepeticao = 3

    /// E quando nem a orientação pega, aí sim desiste.
    ///
    /// Um agente que insiste na mesma chamada doze vezes, já avisado, não vai sair do
    /// lugar sozinho — e quem está olhando merece saber disso em vez de ver o mesmo
    /// pedido rodar para sempre.
    static let tetoDeDesistencia = 12

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

    public func stop() {
        stopped.withLock { $0 = true }
        current.withLock { $0?.cancel() }
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

    private func loop(
        history: [AgentMessage],
        userText: String,
        images: [AgentImage],
        config: LoopConfig,
        emit: @escaping @Sendable (LoopEvent) -> Void
    ) async {
        var messages = history
        let expanded = Mentions.expand(userText, host: host)
        messages.append(.user(expanded, images: images))
        emit(.item(.user(id: UUID().uuidString, text: userText, images: images.isEmpty ? nil : images)))
        checkpoints?.take(title: ChatStore.title(of: [.user(id: "", text: userText, images: nil)]))
        let tools = Tools.forMode(config.mode)
        var round = 0
        var hitCap = false
        // Se o turno chegou a mexer em arquivo, e se a cutucada de "anunciar não é
        // fazer" já foi dada — ver o `toolCalls.isEmpty` mais abaixo.
        var fezPatch = false
        var cutucou = false
        // Quantas vezes cada chamada idêntica já aconteceu neste turno — ver `tetoDeRepeticao`.
        var repetidas: [String: Int] = [:]
        while round < config.maxRounds {
            if isStopped {
                break
            }
            let thinkId = UUID().uuidString, textId = UUID().uuidString
            let think = Mutex(""), text = Mutex(""), calls = Mutex<[ToolCall]>([]), use = Mutex(TokenUse()),
                err = Mutex<String?>(nil)
            let turn = TurnRequest(
                system: systemPrompt(mode: config.mode, userText: userText),
                messages: Array(messages.suffix(24)),
                tools: tools,
                model: config.model,
                effort: config.effort,
                conversationId: config.conversationId
            )
            let streamTask = Task { [provider] in
                do {
                    for try await e in provider.stream(turn) {
                        if Task.isCancelled {
                            break
                        }
                        switch e {
                        case let .think(s): let t = think.withLock { $0 += s; return $0 }; emit(.item(.think(
                                id: thinkId,
                                text: t,
                                live: true
                            )))
                        case let .text(s):
                            if let t = think.withLock({ $0.isEmpty ? nil : $0 }) {
                                emit(.item(.think(
                                    id: thinkId,
                                    text: t,
                                    live: false
                                )))
                            }
                            let t = text.withLock { $0 += s; return $0 }; emit(.item(.assistant(id: textId, text: t)))
                        case let .tools(c): calls.withLock { $0 = c }
                        case let .usage(u): use.withLock { $0 = $0.filled(with: u) }
                        case let .error(m): err.withLock { $0 = m }
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
                emit(.item(.error(id: UUID().uuidString, text: e)))
                break
            }
            messages.append(AgentMessage(
                role: .assistant,
                content: answer,
                thinking: thinkText.isEmpty ? nil : thinkText,
                toolCalls: toolCalls.isEmpty ? nil : toolCalls
            ))
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
                // A mesma chamada, com os mesmos argumentos, repetida sem parar.
                //
                // Foi o que aconteceu com o modelo local: cento e oitenta e seis
                // `read_file` do mesmo arquivo, um atrás do outro. Um agente que relê o
                // mesmo arquivo pela sexta vez não está trabalhando, está preso — e o
                // fusível de rodadas, lá em cima, é grande demais para servir de freio
                // aqui: até ele disparar já passou meia hora.
                let assinatura = "\(call.name)|\(call.arguments)"
                let vezes = (repetidas[assinatura] ?? 0) + 1
                repetidas[assinatura] = vezes
                if vezes > Self.tetoDeDesistencia {
                    emit(.item(.error(
                        id: UUID().uuidString,
                        text: tr(
                            "Parei: a mesma chamada de %1$@ se repetiu %2$@ vezes, mesmo avisada. Redirecione ou tente outro modelo.",
                            call.name,
                            "\(vezes)"
                        )
                    )))
                    return
                }
                if vezes > Self.tetoDeRepeticao {
                    // A chamada nem roda: no lugar do resultado volta a orientação, no
                    // formato de resultado de ferramenta, que é o que mantém a
                    // transcrição inteira — chamada feita, chamada respondida.
                    emit(.item(.tool(id: call.id, name: call.name, detail: tr("já lido, sem mudança"))))
                    messages.append(.tool(call.id, tr(
                        "Você já chamou %1$@ com estes mesmos argumentos nesta conversa e o resultado não mudou. Não repita: use o que já leu. Se a mudança já foi feita, diga o que mudou e encerre.",
                        call.name
                    )))
                    continue
                }
                let hint = Self.hint(call)
                if Tools.needsPermit(config.permit, call) {
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
                let out = await runner.run(call, mode: config.mode)
                if let p = out.patch {
                    fezPatch = true
                    emit(.item(.patch(id: UUID().uuidString, patchId: p.id, path: p.path)))
                } else if !Tools.needsPermit(config.permit, call) {
                    emit(.item(.tool(
                        id: call.id,
                        name: call.name,
                        detail: hint.isEmpty ? String(out.text.split(separator: "\n").first ?? "") : hint
                    )))
                }
                messages.append(.tool(call.id, out.text))
            }
            emit(.history(messages))
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
        emit(.history(messages))
        emit(.done)
    }

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
