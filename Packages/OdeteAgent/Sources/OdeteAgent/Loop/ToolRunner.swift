import Foundation

public struct ToolOutcome: Sendable {
    public var text: String
    public var patch: Patch?
}

/// Executa uma chamada de ferramenta respeitando o modo.
public struct ToolRunner: Sendable {
    public var host: ToolHost
    public var patches: PatchStore
    /// Onde guardar o original de cada arquivo antes de a ferramenta escrever nele — é o
    /// que faz o "desfazer último turno" voltar tudo, e não só o retrato do começo.
    public var checkpoints: CheckpointStore?
    public init(host: ToolHost, patches: PatchStore, checkpoints: CheckpointStore? = nil) {
        self.host = host; self.patches = patches; self.checkpoints = checkpoints
    }

    static func clean(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("/") {
            s.removeFirst()
        }
        return s
    }

    static func clip(
        _ s: String,
        _ max: Int = 200_000
    ) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "\n… truncado"
    }

    public func run(_ call: ToolCall, mode: AgentMode) async -> ToolOutcome {
        guard let args = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]
        else { return .init(text: "argumentos JSON inválidos") }
        func str(_ k: String) -> String {
            (args[k] as? String) ?? ""
        }
        switch call.name {
        case "read_file":
            let p = Self.clean(str("path"))
            if let texto = host.read(p) {
                return .init(text: Self.clip(texto))
            }
            // Binário e latin-1 também devolvem nil aqui; dizer "não existe" fazia o
            // agente afirmar que um arquivo do projeto não estava lá.
            return .init(text: host.exists(p) ? "\(p) existe, mas não é texto em UTF-8" : "não existe: \(p)")
        case "list_dir":
            let l = host.list(Self.clean(str("path")))
            return .init(text: l.isEmpty ? "(vazio)" : l.joined(separator: "\n"))
        case "grep":
            return .init(text: Self.clip(host.grep(
                str("pattern"),
                in: str("path").isEmpty ? nil : Self.clean(str("path"))
            )))
        case "read_terminal":
            let n = (args["n"] as? Int) ?? Int((args["n"] as? Double) ?? 80)
            return .init(text: host.terminalTail(min(200, max(1, n))))
        case "read_problems":
            let filtro = Self.clean(str("path"))
            return .init(text: Self.clip(Diagnosticos.relatorio(
                host.problemas(),
                filtro: filtro.isEmpty ? nil : filtro
            )))
        case "read_preview_console":
            let pedidas = (args["n"] as? Int) ?? (args["n"] as? Double).map(Int.init) ?? Diagnosticos.consolePadrao
            let n = min(Diagnosticos.consoleMaximo, max(1, pedidas))
            return .init(text: Self.clip(Diagnosticos.console(host.consolePreview(n), n: n)))
        case "str_replace", "write_file":
            return await edit(call.name, args: args, mode: mode)
        case "run_shell":
            let cmd = str("command").trimmingCharacters(in: .whitespaces)
            if cmd.isEmpty {
                return .init(text: "comando vazio")
            }
            if let why = Tools.isForbiddenShell(cmd) {
                return .init(text: why)
            }
            if mode == .chat,
               !Tools
               .isReadShell(cmd)
            {
                return .init(text: "chat só lê o terminal. use Plan (escrever plano) ou Build (executar).")
            }
            if mode == .plan, !Tools.isReadShell(cmd) {
                guard cmd.range(of: #"^(mkdir|touch)\b"#, options: .regularExpression) != nil
                else {
                    return .init(
                        text: "plan não roda npm/git que muda algo. mkdir/touch em .odete/ e leitura ok. Build pra o resto."
                    )
                }
                let dest = Self
                    .clean(cmd.split(separator: " ").dropFirst().first { !$0.hasPrefix("-") }.map(String.init) ?? "")
                if dest != ".odete", !dest.hasPrefix(".odete/") {
                    return .init(text: "plan só cria coisas em .odete/")
                }
            }
            // O shell escreve por conta própria: antes de ele rodar, guarda o que dá para
            // saber que ele vai tocar, e anota quando ele rodou — o que mudar nessa janela é
            // do turno. Comando que só lê não mexe em nada.
            if let checkpoints, !Tools.isReadShell(cmd) {
                let alvos = Tools.alvosDoShell(cmd, pasta: host.pastaDoShell())
                let desde = checkpoints.antesDoShell(alvos)
                let saida = await host.runShell(cmd)
                checkpoints.depoisDoShell(desde: desde, alvos: alvos)
                return .init(text: Self.clip(saida))
            }
            return await .init(text: Self.clip(host.runShell(cmd)))
        case "github":
            return await .init(text: Self.clip(github(args, mode: mode)))
        default:
            return .init(text: "tool desconhecida: \(call.name)")
        }
    }

    func github(_ args: [String: Any], mode: AgentMode) async -> String {
        guard let bruta = args["action"] as? String,
              let acao = GitHubPedido.Acao(rawValue: bruta)
        else { return "action precisa ser uma de: " + GitHubPedido.Acao.allCases.map(\.rawValue)
            .joined(separator: ", ")
        }
        if acao.escreve, mode != .build {
            return "\(mode.label) só lê o GitHub. Mude para Build para abrir, comentar, mergear ou fechar PR."
        }
        let numero = (args["number"] as? Int) ?? (args["number"] as? Double).map(Int.init)
        if acao != .listPulls, acao != .createPull, numero == nil {
            return "\(acao.rawValue) precisa do number do PR"
        }
        func texto(_ k: String) -> String? {
            (args[k] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        return await host.github(GitHubPedido(
            acao: acao,
            numero: numero,
            titulo: texto("title"),
            corpo: texto("body"),
            base: texto("base"),
            head: texto("head"),
            metodo: texto("method")
        ))
    }

    func edit(_ name: String, args: [String: Any], mode: AgentMode) async -> ToolOutcome {
        if mode == .chat {
            return .init(text: "chat não edita. mude pra Plan ou Build.")
        }
        let path = Self.clean((args["path"] as? String) ?? "")
        guard !path.isEmpty, !path.contains("..") else { return .init(text: "caminho inválido") }
        let after: String
        if name == "str_replace" {
            let old = (args["old"] as? String) ?? ""
            let new = (args["new"] as? String) ?? ""
            guard !old.isEmpty else { return .init(text: "old vazio") }
            // Trocar um trecho por ele mesmo não muda nada, e o "escrito" que saía daqui
            // virava prova de serviço feito: o modelo anunciava o conserto e a tela
            // continuava quebrada. Quem pediu isso se enganou — e precisa saber.
            guard old != new else {
                return .init(text: "old e new são iguais — isso não mudaria nada. Escreva em new o texto corrigido.")
            }
            guard let before = host.read(path) else { return .init(text: "não existe: \(path)") }
            let hits = before.components(separatedBy: old).count - 1
            if hits == 0 {
                return .init(text: "trecho não encontrado — leia o arquivo de novo")
            }
            if hits > 1 {
                return .init(text: "trecho aparece \(hits) vezes — seja mais específico")
            }
            guard let r = before.range(of: old) else { return .init(text: "trecho não encontrado") }
            after = before.replacingCharacters(in: r, with: new)
        } else {
            // Sem `content` o arquivo virava vazio e a resposta dizia "escrito". Apagar um
            // arquivo por esquecimento de campo não é uma edição — é uma perda.
            guard let conteudo = args["content"] as? String else {
                return .init(text: "faltou content — mande o arquivo inteiro, ou use str_replace para trocar um trecho")
            }
            after = conteudo
        }
        if mode == .plan {
            guard path == ".odete/plan.md"
            else { return .init(text: "plan só escreve .odete/plan.md — mude pra Build pra editar o resto") }
            checkpoints?.capturar(path)
            do { try host.write(path, after) } catch {
                return .init(text: "erro ao escrever: \(error.localizedDescription)")
            }
            checkpoints?.anotarEscrita(path)
            return .init(text: "escrito \(path)")
        }
        let before = host.read(path) ?? ""
        // O original vai para o checkpoint antes da primeira escrita do turno — inclusive
        // num arquivo que o retrato do começo deixou de fora por ser grande ou por estar
        // depois dos primeiros 220.
        checkpoints?.capturar(path)
        do { try host.write(path, after) } catch {
            return .init(text: "erro ao escrever: \(error.localizedDescription)")
        }
        // E o que ficou, logo depois: se o turno não chegar a fechar, é por isto que o
        // desfazer sabe se o arquivo ainda está como o agente deixou.
        checkpoints?.anotarEscrita(path)
        let patch = patches.queue(path: path, before: before, after: after)
        host.reveal(path)
        // O tamanho vai junto porque é a consequência: um arquivo que dobrou de linhas
        // quando era para ser consertado é um erro que o próprio modelo enxerga na
        // resposta, em vez de anunciar conserto por cima de um estrago.
        let antes = before.isEmpty ? 0 : before.split(separator: "\n", omittingEmptySubsequences: false).count
        let depois = after.isEmpty ? 0 : after.split(separator: "\n", omittingEmptySubsequences: false).count
        return .init(text: "escrito \(path) (\(antes) → \(depois) linhas)", patch: patch)
    }
}
