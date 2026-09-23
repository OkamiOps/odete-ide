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

    /// Teto do resultado de uma ferramenta, em caracteres.
    ///
    /// Era 200 mil: um `npm install` barulhento ou um `cat` de bundle entrava inteiro, e
    /// três desses enchiam a janela de um modelo de 200 mil tokens. O número vem do
    /// opencode (`tool/truncate.ts`: `MAX_BYTES = 50 * 1024`), que também corta a saída de
    /// toda ferramenta antes de ela entrar na conversa.
    static let tetoDoResultado = 50000

    /// Corta o meio e fica com o começo e o fim.
    ///
    /// O começo diz o que rodou; o fim é onde moram o erro, o resumo do teste e o
    /// "exit 1". Cortar só o fim — como era — escondia justamente o que o agente
    /// precisava ler para decidir o próximo passo.
    static func clip(_ s: String, _ max: Int = tetoDoResultado) -> String {
        guard s.count > max else { return s }
        let metade = max / 2
        let fora = s.count - 2 * metade
        let linhasFora = s.dropFirst(metade).dropLast(metade).count { $0 == "\n" }
        return String(s.prefix(metade))
            + "\n\n… (\(fora) caracteres e \(linhasFora) linhas omitidos do meio; "
            + "leia por partes ou filtre a saída) …\n\n"
            + String(s.suffix(metade))
    }

    /// Quantas linhas o `read_file` devolve sem `limit`, o tamanho máximo de uma linha e
    /// o teto em bytes da resposta — os mesmos números do `read` do opencode
    /// (`tool/read.ts`: `DEFAULT_READ_LIMIT`, `MAX_LINE_LENGTH`, `MAX_BYTES`).
    static let linhasPorLeitura = 2000
    static let tetoDaLinha = 2000
    static let bytesPorLeitura = 50 * 1024
    /// Acima disto o arquivo nem é lido: carregar um arquivo de 100 MB inteiro para a
    /// memória só para devolver 2000 linhas dele não vale.
    static let tetoDoArquivo = 8_000_000

    /// Um pedaço do arquivo: de `offset` (linha, 1 é a primeira) até `limit` linhas.
    ///
    /// Arquivo que cabe inteiro e sem pedido de pedaço volta como está, byte a byte — é
    /// dele que o `str_replace` copia o trecho. Só o pedaço ganha o rodapé que diz onde
    /// continuar.
    static func trecho(_ texto: String, offset: Int?, limit: Int?) -> String {
        let linhas = texto.split(separator: "\n", omittingEmptySubsequences: false)
        let inicio = max(1, offset ?? 1)
        let quantas = max(1, limit ?? linhasPorLeitura)
        let longa = linhas.contains { $0.count > tetoDaLinha }
        if inicio == 1, linhas.count <= quantas, texto.utf8.count <= bytesPorLeitura, !longa {
            return texto
        }
        guard inicio <= linhas.count else {
            return "o arquivo tem \(linhas.count) linhas; offset \(inicio) passa do fim"
        }
        var out: [String] = []
        var bytes = 0
        var ultima = inicio - 1
        for i in (inicio - 1) ..< min(linhas.count, inicio - 1 + quantas) {
            var l = String(linhas[i])
            if l.count > tetoDaLinha {
                l = String(l.prefix(tetoDaLinha)) + "… (linha cortada em \(tetoDaLinha) caracteres)"
            }
            let n = l.utf8.count + 1
            if bytes + n > bytesPorLeitura, !out.isEmpty {
                break
            }
            bytes += n
            out.append(l)
            ultima = i + 1
        }
        let rodape = ultima < linhas.count
            ? "(linhas \(inicio)–\(ultima) de \(linhas.count). Para continuar: read_file com offset=\(ultima + 1))"
            : "(linhas \(inicio)–\(ultima) de \(linhas.count), fim do arquivo)"
        return out.joined(separator: "\n") + "\n\n" + rodape
    }

    public func run(_ call: ToolCall, mode: AgentMode) async -> ToolOutcome {
        // Chamada cortada no limite de saída ou com argumentos quebrados: quem leu o
        // stream já explicou o que houve, e é isso que o modelo precisa ler.
        if let problema = call.problema {
            return .init(text: problema)
        }
        guard let args = try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8)) as? [String: Any]
        else { return .init(text: "argumentos JSON inválidos") }
        func str(_ k: String) -> String {
            (args[k] as? String) ?? ""
        }
        switch call.name {
        case "read_file":
            let p = Self.clean(str("path"))
            if let n = host.tamanho(p), n > Self.tetoDoArquivo {
                return .init(text: "\(p) tem \(n / 1_000_000) MB — grande demais para ler inteiro. "
                    + "Use grep, ou run_shell com head/tail.")
            }
            if let texto = host.read(p) {
                func numero(_ k: String) -> Int? {
                    (args[k] as? Int) ?? (args[k] as? Double).map(Int.init)
                }
                return .init(text: Self.trecho(texto, offset: numero("offset"), limit: numero("limit")))
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
                guard Tools.planPodeRodar(cmd, pasta: host.pastaDoShell()) else {
                    return .init(
                        text: "plan não roda npm/git que muda algo. mkdir/touch em .odete/ e leitura ok. Build pra o resto."
                    )
                }
            }
            // O shell escreve por conta própria: antes de ele rodar, guarda o que dá para
            // saber que ele vai tocar, e anota quando ele rodou — o que mudar nessa janela é
            // do turno.
            //
            // No Build a janela abre sempre, até para o que parece só ler: a leitura do
            // comando é de boa-fé, e o que ela deixar passar como leitura sem a janela
            // aberta fica fora do desfazer. Abrir a janela à toa custa um `stat`.
            if let checkpoints, mode == .build || !Tools.isReadShell(cmd) {
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
            guard let before = host.read(path) else {
                return .init(text: host
                    .exists(path) ? "\(path) existe, mas não é texto em UTF-8" : "não existe: \(path)")
            }
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
        // Arquivo que existe mas não é texto em UTF-8 (binário, latin-1) lê como `nil`.
        // Tratado como vazio, o patch nascia com "antes" vazio — e rejeitar esse patch
        // apagava o arquivo da pessoa.
        let existia = host.exists(path)
        guard let before = existia ? host.read(path) : "" else {
            return .init(text: "\(path) existe, mas não é texto em UTF-8 — não dá para editar com segurança por aqui.")
        }
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
        let patch = patches.queue(path: path, before: before, after: after, criado: !existia)
        host.reveal(path)
        // O tamanho vai junto porque é a consequência: um arquivo que dobrou de linhas
        // quando era para ser consertado é um erro que o próprio modelo enxerga na
        // resposta, em vez de anunciar conserto por cima de um estrago.
        let antes = before.isEmpty ? 0 : before.split(separator: "\n", omittingEmptySubsequences: false).count
        let depois = after.isEmpty ? 0 : after.split(separator: "\n", omittingEmptySubsequences: false).count
        return .init(text: "escrito \(path) (\(antes) → \(depois) linhas)", patch: patch)
    }
}
