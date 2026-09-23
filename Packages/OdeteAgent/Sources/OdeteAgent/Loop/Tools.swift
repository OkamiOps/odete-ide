import Foundation
import OdeteI18n

public enum AgentMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case chat, plan, build
    public var id: String {
        rawValue
    }

    public var label: String {
        switch self { case .chat: tr("Chat"); case .plan: tr("Plan"); case .build: tr("Build") }
    }
}

public enum PermitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case ask, auto, full
    public var id: String {
        rawValue
    }

    public var label: String {
        switch self { case .ask: tr("Ask"); case .auto: tr("Auto"); case .full: tr("Full") }
    }

    public var hint: String {
        switch self {
        case .ask: tr(
                "pergunta antes de tudo"
            ); case .auto: tr("só pergunta para escrever e rodar"); case .full: tr("não pergunta")
        }
    }

    public var symbol: String {
        switch self { case .ask: "hand.raised"; case .auto: "bolt.shield"; case .full: "bolt.fill" }
    }
}

/// As ferramentas, com os mesmos nomes e schemas do web — mais as duas que leem o que o
/// app já sabe (`read_problems` e `read_preview_console`).
public enum Tools {
    static let safe: Set<String> = [
        "read_file", "list_dir", "grep", "read_terminal", "read_problems", "read_preview_console",
    ]
    static let chatTools: Set<String> = [
        "read_file", "list_dir", "grep", "read_terminal", "run_shell", "github", "read_problems",
        "read_preview_console",
    ]
    static let planTools: Set<String> = chatTools.union(["write_file", "str_replace"])

    public static let all: [ToolSpec] = [
        ToolSpec(
            name: "read_file",
            description: "Lê um arquivo do projeto. Arquivo longo vem em partes: continue com offset.",
            // Como o `read` do opencode (`tool/read.ts`): `offset` é a linha inicial (1 é a
            // primeira) e `limit` quantas linhas; sem eles vêm as primeiras 2000.
            parameters: obj([
                "path": caminho,
                "offset": ["type": "number", "description": "linha inicial (1 = primeira)"],
                "limit": ["type": "number", "description": "quantas linhas (padrão 2000)"],
            ], required: ["path"])
        ),
        ToolSpec(
            name: "str_replace",
            description: "Substitui um trecho EXATO no arquivo. Prefira isto a write_file. old precisa aparecer uma vez.",
            parameters: obj([
                "path": caminho,
                "old": texto("O trecho como ele está hoje no arquivo, copiado do read_file, "
                    + "com a mesma indentação e as mesmas quebras de linha."),
                "new": texto("O trecho que entra no lugar, em texto puro e na linguagem do próprio arquivo."),
            ], required: ["path", "old", "new"])
        ),
        ToolSpec(
            name: "write_file",
            description: "Cria arquivo ou reescreve INTEIRO. No modo plan, grave o plano em .odete/plan.md.",
            parameters: obj([
                "path": caminho,
                "content": texto("O arquivo inteiro, em texto puro e na linguagem do próprio arquivo: "
                    + "CSS num .css, HTML num .html, JavaScript num .js. Nunca JSON, a não ser num .json."),
            ], required: ["path", "content"])
        ),
        ToolSpec(
            name: "list_dir",
            description: "Lista arquivos e pastas. path vazio = raiz.",
            parameters: obj(["path": texto("Pasta a listar, relativa à raiz. Vazio lista a raiz.")])
        ),
        ToolSpec(
            name: "grep",
            description: "Busca regex no projeto.",
            parameters: obj([
                "pattern": texto("Expressão regular a procurar."),
                "path": texto("Pasta ou arquivo onde procurar. Vazio procura no projeto todo."),
            ], required: ["pattern"])
        ),
        ToolSpec(
            name: "read_terminal",
            description: "Lê as últimas linhas do terminal (stdout/stderr).",
            parameters: obj(["n": ["type": "number", "description": "quantas linhas (default 80)"]])
        ),
        // Descrições curtas de propósito: entram também no modelo do aparelho, onde cada
        // caractere de schema sai do espaço da conversa — ver `AppleProvider.ferramentas`.
        ToolSpec(
            name: "read_problems",
            description: "Erros e avisos que a Odete já mostra (lint, sintaxe, build, preview), "
                + "um por linha: arquivo:linha:coluna gravidade mensagem (fonte).",
            parameters: obj(["path": texto("Arquivo ou pasta para filtrar. Vazio traz o projeto todo.")])
        ),
        ToolSpec(
            name: "read_preview_console",
            description: "Últimas linhas do console do app no Preview, com o nível (log, info, warn, error).",
            parameters: obj(["n": ["type": "number", "description": "quantas linhas (padrão 50, máximo 200)"]])
        ),
        ToolSpec(
            name: "run_shell",
            description: "Terminal do projeto no iPad: ls, cat, mkdir, git, npm install, "
                + "npm run dev/build, node arquivo.js. Vite, Next, Astro e Nest sobem no Preview. "
                + "Não tem substituição de comando ($(…), crase) nem heredoc (<<): para mensagem de "
                + "commit com corpo, use um -m por parágrafo. Chat só lê. Plan: mkdir/touch só em .odete/.",
            parameters: obj(["command": str], required: ["command"])
        ),
        ToolSpec(
            name: "github",
            description: "Pull requests do repositório no GitHub: list_pulls, create_pull (title, body, "
                + "head, base), comment (number, body), merge_pull (number, method: squash|merge|rebase) e "
                + "close_pull (number). O push é pelo run_shell; isto é só a parte que vive na API.",
            parameters: obj([
                "action": ["type": "string", "enum": GitHubPedido.Acao.allCases.map(\.rawValue)],
                "number": ["type": "number", "description": "número do PR"],
                "title": str,
                "body": str,
                "head": ["type": "string", "description": "branch de origem (default: a atual)"],
                "base": ["type": "string", "description": "branch de destino (default: a principal)"],
                "method": ["type": "string", "enum": ["squash", "merge", "rebase"]],
            ], required: ["action"])
        ),
    ]

    static var str: [String: Any] {
        ["type": "string"]
    }

    /// Campo de texto que diz o que se espera dentro dele.
    ///
    /// Parece detalhe e não é. Com geração guiada — que é como o modelo do sistema chama
    /// ferramenta — o modelo está emitindo JSON, e um campo `content` sem explicação faz
    /// um modelo pequeno continuar o padrão do JSON para dentro do valor: foi assim que
    /// um pedido de novo visual gravou `{"body": {"margin": "0"}}` dentro de um
    /// `style.css`. Dizer "o arquivo inteiro, na linguagem do próprio arquivo" corta isso
    /// na raiz, e não atrapalha ninguém.
    static func texto(_ oQueEh: String) -> [String: Any] {
        ["type": "string", "description": oQueEh]
    }

    static var caminho: [String: Any] {
        texto("Caminho relativo à raiz do projeto, como src/main.js.")
    }

    static func obj(_ props: [String: Any], required: [String] = []) -> [String: Any] {
        var o: [String: Any] = ["type": "object", "properties": props]
        if !required.isEmpty {
            o["required"] = required
        }
        return o
    }

    public static func forMode(_ mode: AgentMode) -> [ToolSpec] {
        switch mode {
        case .build: all
        case .plan: all.filter { planTools.contains($0.name) }
        case .chat: all.filter { chatTools.contains($0.name) }
        }
    }

    /// A ferramenta existe neste modo?
    public static func permitida(_ nome: String, no modo: AgentMode) -> Bool {
        switch modo {
        case .build: all.contains { $0.name == nome }
        case .plan: planTools.contains(nome)
        case .chat: chatTools.contains(nome)
        }
    }

    public static func needsPermit(_ mode: PermitMode, _ name: String) -> Bool {
        switch mode {
        case .full: false
        case .auto: !safe.contains(name)
        case .ask: true
        }
    }

    /// Abrir, comentar, mergear ou fechar um PR aparece no repositório de outras pessoas
    /// e não dá para desfazer com um toque, como um patch dá. Pergunta sempre, mesmo no
    /// modo que não pergunta nada.
    public static func needsPermit(_ mode: PermitMode, _ call: ToolCall) -> Bool {
        if call.name == "github" {
            let acao = (call.args["action"] as? String).flatMap(GitHubPedido.Acao.init(rawValue:))
            return acao?.escreve ?? true
        }
        return needsPermit(mode, call.name)
    }

    /// Comandos que só leem (liberados em chat e plan).
    ///
    /// Lido com o mesmo corte de linha que o resto do shell usa (`segmentosDoShell`), e
    /// não só no `|`: dividir só no cano deixava `ls && rm -rf src`, `echo x > f`,
    /// `git branch -D main` e `find . -delete` passarem como leitura — no Chat e no Plan
    /// eles rodavam, e no Build o desfazer do turno não tinha guardado nada antes.
    ///
    /// Na dúvida, não é leitura: o custo de errar para esse lado é pedir licença (ou
    /// abrir a janela do checkpoint) à toa; o do outro é um arquivo apagado sem volta.
    public static func isReadShell(_ command: String) -> Bool {
        // `$(…)` e crase o shell da Odete não faz, mas quem pede não sabe disso — e o que
        // está dentro não passa por esta leitura.
        if temSubstituicao(command) {
            return false
        }
        let segmentos = segmentosDoShell(command)
        return !segmentos.isEmpty && segmentos.allSatisfy(segmentoSoLe)
    }

    /// Um comando do meio da linha só lê?
    static func segmentoSoLe(_ segmento: String) -> Bool {
        if escreveComSeta(segmento) {
            return false
        }
        let words = palavrasDoShell(segmento)
        guard let cmd = words.first else { return false }
        let args = Array(words.dropFirst())
        switch cmd {
        case "ls", "cat", "head", "tail", "grep", "pwd", "wc", "echo", "which", "date", "history", "jobs",
             "help", "true", "tree", "cd":
            return true
        case "env":
            // `env` sozinho lista; com argumento roda outro programa com eles.
            return args.allSatisfy { $0.hasPrefix("-") }
        case "find":
            // Estes apagam, rodam comando ou escrevem arquivo.
            let escreve: Set = ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf",
                                "-fls"]
            return !args.contains { escreve.contains($0) }
        case "git":
            return gitSoLe(args)
        case "npm":
            guard let sub = args.first else { return false }
            if ["ls", "list", "-v", "--version"].contains(sub) {
                return true
            }
            // `npm run` sozinho lista os scripts; com nome, roda um.
            return sub == "run" && args.count == 1
        case "node":
            return args.contains("-v") || args.contains("--version")
        default:
            return false
        }
    }

    /// `git` que só lê. Cada subcomando tem o seu jeito de escrever, então vai um a um.
    static func gitSoLe(_ bruto: [String]) -> Bool {
        var args = bruto
        // `--no-pager` não muda o que o comando faz.
        while args.first == "--no-pager" {
            args.removeFirst()
        }
        guard let sub = args.first else { return false }
        let resto = Array(args.dropFirst())
        switch sub {
        case "--version":
            return true
        case "status", "log", "diff", "show", "rev-parse", "blame", "shortlog", "ls-files", "describe":
            // `--output` grava o resultado num arquivo.
            return !resto.contains { $0 == "--output" || $0.hasPrefix("--output=") }
        case "branch":
            // Listar é sem nome e só com estas opções; nome cria, -d/-D apaga, -m move.
            let listar: Set = ["-a", "-r", "-v", "-vv", "-l", "--list", "--all", "--remotes", "--show-current",
                               "--merged", "--no-merged", "--contains", "--no-contains", "--color", "--no-color"]
            return resto.allSatisfy { listar.contains($0) }
        case "remote":
            guard let acao = resto.first else { return true }
            if acao == "-v" || acao == "--verbose" {
                return resto.count == 1
            }
            return ["show", "get-url"].contains(acao)
        case "stash":
            return resto.first == "list" || resto.first == "show"
        case "tag":
            return resto.isEmpty || resto.allSatisfy { ["-l", "--list", "-n"].contains($0) }
        case "config":
            return resto.contains("--get") || resto.contains("--list") || resto.contains("-l")
                || resto.contains("--get-all")
        default:
            return false
        }
    }

    /// `>` ou `>>` fora de aspas mandando para arquivo. `2>&1` só junta as saídas, e
    /// `/dev/null` não guarda nada.
    static func escreveComSeta(_ segmento: String) -> Bool {
        let chars = Array(segmento)
        var aspa: Character?
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if let a = aspa {
                if c == a {
                    aspa = nil
                }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                aspa = c
                i += 1
                continue
            }
            guard c == ">" else {
                i += 1
                continue
            }
            var j = i + 1
            if j < chars.count, chars[j] == ">" {
                j += 1
            }
            while j < chars.count, chars[j] == " " {
                j += 1
            }
            if j < chars.count, chars[j] == "&" {
                i = j + 1
                continue
            }
            var alvo = ""
            while j < chars.count, !" ;|&".contains(chars[j]) {
                alvo.append(chars[j])
                j += 1
            }
            if alvo.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) != "/dev/null" {
                return true
            }
            i = j
        }
        return false
    }

    /// `$(…)` ou crase fora de aspas simples.
    static func temSubstituicao(_ command: String) -> Bool {
        var simples = false
        var anterior: Character = " "
        for c in command {
            if c == "'" {
                simples.toggle()
            } else if !simples, c == "`" || (anterior == "$" && c == "(") {
                return true
            }
            anterior = c
        }
        return false
    }

    /// O que o Plan deixa o shell fazer: ler, e `mkdir`/`touch` só dentro de `.odete/`.
    ///
    /// Olha cada comando da linha. Antes bastava a linha começar com `mkdir` e o
    /// primeiro argumento ser `.odete` — e `mkdir .odete && rm -rf src` passava inteiro.
    /// `pasta` é onde o shell do agente está, como em `alvosDoShell`.
    static func planPodeRodar(_ command: String, pasta: String = "") -> Bool {
        if temSubstituicao(command) {
            return false
        }
        let segmentos = segmentosDoShell(command)
        return !segmentos.isEmpty && segmentos.allSatisfy { seg in
            if segmentoSoLe(seg) {
                return true
            }
            guard !escreveComSeta(seg) else { return false }
            let palavras = palavrasDoShell(seg)
            guard let cmd = palavras.first, cmd == "mkdir" || cmd == "touch" else { return false }
            let alvos = palavras.dropFirst().filter { !$0.hasPrefix("-") }
            return !alvos.isEmpty && alvos.allSatisfy { alvo in
                let p = caminhoNoShell(alvo, cwd: pasta)
                return p == ".odete" || p.hasPrefix(".odete/")
            }
        }
    }

    /// Onde um comando do shell vai escrever, para o checkpoint guardar o original antes.
    ///
    /// Leitura de boa-fé, não um parser de shell: pega `rm`, `mv`, `cp`, `touch`, `>` e
    /// `>>`, o `cd` no meio da linha e o `npm` que reescreve o `package.json` e o lock. O
    /// que escapa daqui ainda tem o retrato do começo do turno. Anotar a mais não estraga
    /// nada: guardar o original de um arquivo que não mudou só devolve o mesmo conteúdo.
    ///
    /// `pasta` é onde o shell do agente está, relativa à raiz. No shell da Odete, `/` e
    /// `~` são a raiz do projeto.
    public static func alvosDoShell(_ command: String, pasta: String = "") -> [String] {
        var alvos: [String] = []
        var cwd = pasta
        for segmento in segmentosDoShell(command) {
            var palavras: [String] = []
            let todas = palavrasDoShell(segmento)
            var i = 0
            while i < todas.count {
                let w = todas[i]
                if [">", ">>", "2>", "&>"].contains(w) {
                    if i + 1 < todas.count {
                        alvos.append(caminhoNoShell(todas[i + 1], cwd: cwd))
                    }
                    i += 2
                    continue
                }
                if let seta = ["2>", ">>", ">"].first(where: { w.hasPrefix($0) && w.count > $0.count }) {
                    // `2>&1` aponta para outra saída, não para um arquivo.
                    let alvo = String(w.dropFirst(seta.count))
                    if !alvo.hasPrefix("&") {
                        alvos.append(caminhoNoShell(alvo, cwd: cwd))
                    }
                    i += 1
                    continue
                }
                palavras.append(w)
                i += 1
            }
            guard let cmd = palavras.first else { continue }
            let args = palavras.dropFirst().filter { !$0.hasPrefix("-") }
            switch cmd {
            case "cd":
                cwd = args.first.map { caminhoNoShell($0, cwd: cwd) } ?? ""
            case "rm", "touch":
                alvos += args.map { caminhoNoShell($0, cwd: cwd) }
            case "mv", "cp":
                guard args.count >= 2, let destino = args.last else { continue }
                let d = caminhoNoShell(destino, cwd: cwd)
                alvos.append(d)
                for origem in args.dropLast() {
                    // `mv` tira da origem; e os dois podem cair dentro de uma pasta de destino.
                    if cmd == "mv" {
                        alvos.append(caminhoNoShell(origem, cwd: cwd))
                    }
                    let nome = (origem as NSString).lastPathComponent
                    alvos.append(d.isEmpty ? nome : d + "/" + nome)
                }
            case "npm", "pnpm", "yarn", "bun":
                let mexe: Set = ["install", "i", "add", "remove", "rm", "uninstall", "un", "update", "up", "ci"]
                if args.contains(where: { mexe.contains($0) }) {
                    let base = cwd.isEmpty ? "" : cwd + "/"
                    alvos += [base + "package.json", base + "package-lock.json"]
                }
            case "git":
                let mexe: Set = ["checkout", "restore", "rm", "mv"]
                if let sub = args.first, mexe.contains(sub) {
                    alvos += args.dropFirst().map { caminhoNoShell($0, cwd: cwd) }
                }
            default:
                break
            }
        }
        var vistos = Set<String>()
        return alvos.filter { !$0.isEmpty && $0 != ".." && !$0.hasPrefix("../") && vistos.insert($0).inserted }
    }

    /// Os comandos de uma linha, separados por `&&`, `||`, `;`, `|` e quebra de linha.
    static func segmentosDoShell(_ command: String) -> [String] {
        var out: [String] = []
        var atual = ""
        var aspa: Character?
        for c in command {
            if let a = aspa {
                atual.append(c)
                if c == a {
                    aspa = nil
                }
            } else if c == "\"" || c == "'" {
                aspa = c
                atual.append(c)
            } else if c == ";" || c == "\n" || c == "|" || c == "&" {
                // `&&` e `||` viram dois cortes seguidos; o segmento vazio do meio some
                // no filtro. `&>` não chega aqui como corte porque vem colado à seta.
                if c == "&", atual.hasSuffix(">") {
                    atual.append(c)
                    continue
                }
                out.append(atual)
                atual = ""
            } else {
                atual.append(c)
            }
        }
        out.append(atual)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// As palavras de um comando, sem as aspas.
    static func palavrasDoShell(_ segmento: String) -> [String] {
        var out: [String] = []
        var atual = ""
        var aspa: Character?
        var temPalavra = false
        for c in segmento {
            if let a = aspa {
                if c == a {
                    aspa = nil
                } else {
                    atual.append(c)
                }
            } else if c == "\"" || c == "'" {
                aspa = c
                temPalavra = true
            } else if c == " " || c == "\t" {
                if temPalavra {
                    out.append(atual)
                }
                atual = ""
                temPalavra = false
            } else {
                atual.append(c)
                temPalavra = true
            }
        }
        if temPalavra {
            out.append(atual)
        }
        return out
    }

    /// Caminho do shell — relativo à `cwd`, ou a partir de `/` e `~`, que são a raiz —
    /// em caminho relativo à raiz do projeto. Quem sai do projeto com `..` volta como
    /// `..`, e quem chama descarta.
    static func caminhoNoShell(_ p: String, cwd: String) -> String {
        var base: [String]
        var resto = p
        if resto == "~" || resto == "/" {
            return ""
        }
        if resto.hasPrefix("~/") {
            resto.removeFirst(2)
            base = []
        } else if resto.hasPrefix("/") {
            resto.removeFirst()
            base = []
        } else {
            base = cwd.split(separator: "/").map(String.init)
        }
        for parte in resto.split(separator: "/").map(String.init) {
            switch parte {
            case ".": continue
            case "..":
                if base.isEmpty {
                    return ".."
                }
                base.removeLast()
            default: base.append(parte)
            }
        }
        return base.joined(separator: "/")
    }

    /// Comandos que o agente nunca roda.
    public static func isForbiddenShell(_ command: String) -> String? {
        let c = command.trimmingCharacters(in: .whitespaces)
        if c.range(of: #"^rm\s+(-\w*r\w*\s+)?(/|~|\.|\*)\s*$"#, options: .regularExpression) != nil || c.range(
            of: #"^rm\s+-\w*r\w*f?\s+(/|~/?|\.)$"#,
            options: .regularExpression
        ) != nil {
            return "rm da raiz do projeto não é permitido ao agente"
        }
        if c
            .range(of: #"git\s+push\s+.*(-f\b|--force)"#, options: .regularExpression) !=
            nil
        {
            return "git push --force não é permitido ao agente"
        }
        if c.hasPrefix("kill all") || c == "kill" {
            return "kill all só pelo usuário"
        }
        return nil
    }
}

public enum Prompts {
    /// Calculado, e não guardado: a linha do idioma muda quando a pessoa muda de
    /// idioma, e um `static let` prenderia o agente ao idioma da primeira conversa.
    public static var system: String {
        """
        Você é o agente da Odete, uma IDE que roda 100% no iPad.
        O projeto é uma pasta real no dispositivo. A lista de caminhos vem no sistema; o conteúdo só entra se VOCÊ chamar read_file.
        Você escolhe quando abrir e qual arquivo. Em todos os modos a leitura está liberada.
        O terminal é o shell da Odete: npm install e npm run dev funcionam de verdade e o Preview mostra o app.
        Responda em \(Texto.idioma.paraOModelo).

        Formato (obrigatório, o usuário tem TDAH):
        - Nunca um bloco de texto corrido.
        - Use ## título curto e listas.
        - 1 ideia por bullet.
        - No máximo 1 frase solta. O resto vira lista.
        - Arquivos sempre em `backticks`.
        """
    }

    static let read = "Você decide se precisa abrir arquivo, qual, e quando. Use read_file / list_dir / grep / "
        + "read_terminal só se o conteúdo for necessário. Os erros que a tela já mostra vêm de read_problems. "
        + "Não invente conteúdo."

    public static func mode(_ m: AgentMode) -> String {
        switch m {
        case .chat: """
            Modo CHAT: conversa. \(read)
            Pode LER o terminal (read_terminal ou run_shell com ls/cat/git status).
            Não edite arquivos. Não rode npm install, git push, rm, mkdir.
            """
        case .plan: """
            Modo PLAN: investigue e GRAVE o plano em `.odete/plan.md` (crie a pasta se precisar).
            \(read)
            Só escreve `.odete/plan.md`. mkdir/touch só dentro de `.odete/`.
            Não rode git push / npm install / rm em massa. Shell de leitura ok.

            O arquivo `.odete/plan.md` deve ter:

            ## Objetivo
            uma linha

            ## O que vi
            - arquivo — o que importa

            ## Passos
            1. arquivo — mudança

            ## Riscos
            - …

            ## Fora de escopo
            - o que não vamos fazer agora
            """
        case .build: "Modo BUILD: pode editar. \(read) Prefira str_replace. write_file só pra arquivo novo ou reescrita total. Depois dos patches, 1–3 linhas do que mudou."
        }
    }

    /// O prompt de sistema de uma conversa inteira: sem o modo e sem as skills do turno.
    ///
    /// Ele é montado no primeiro turno e fica igual até a conversa acabar
    /// (`ChatThread.sistema`). Refazer o sistema a cada rodada — a lista de arquivos muda
    /// assim que o agente cria um — invalida o cache de prompt do provedor e, nos modelos
    /// da Anthropic com raciocínio preservado, todo bloco de raciocínio já devolvido: o
    /// bloco é amarrado ao sistema, às ferramentas e às mensagens exatas que vieram antes
    /// dele. O que muda de um turno para outro (o modo, as skills pedidas com `/nome`) vai
    /// junto da mensagem da pessoa — ver `contextoDoTurno` —, que é sempre acréscimo.
    public static func daConversa(fileList: [String], extras: [String]) -> String {
        let list = fileList
            .isEmpty ? "(vazio)" :
            (fileList.count <= 400 ? fileList.joined(separator: "\n") : fileList.prefix(400)
                .joined(separator: "\n") + "\n… e \(fileList.count - 400) mais")
        let modos = """
        A mensagem da pessoa traz, em <contexto_do_turno>, o modo em que ela está (Chat, Plan ou Build) e as skills que ela chamou. Siga o modo da mensagem mais recente: ele pode mudar de um turno para o outro, e as ferramentas que ele não permite são recusadas.
        """
        return ([
            system,
            modos,
            "Arquivos no projeto quando esta conversa começou (use list_dir para ver como está agora):\n\(list)",
        ] + extras.filter { !$0.isEmpty }).joined(separator: "\n\n")
    }

    /// O que muda a cada turno e por isso não mora no sistema: o modo e as skills.
    public static func contextoDoTurno(mode: AgentMode, skills: String) -> String {
        let partes = [Prompts.mode(mode), skills].filter { !$0.isEmpty }
        return "<contexto_do_turno>\n" + partes.joined(separator: "\n\n") + "\n</contexto_do_turno>"
    }

    /// Tira o `<contexto_do_turno>` de uma mensagem, para mostrar ou repetir o que a pessoa
    /// escreveu.
    public static func semContextoDoTurno(_ texto: String) -> String {
        guard let inicio = texto.range(of: "\n\n<contexto_do_turno>\n"),
              let fim = texto.range(of: "\n</contexto_do_turno>", range: inicio.upperBound ..< texto.endIndex)
        else { return texto }
        return String(texto[..<inicio.lowerBound]) + String(texto[fim.upperBound...])
    }

    public static func build(mode: AgentMode, fileList: [String], extras: [String]) -> String {
        let list = fileList
            .isEmpty ? "(vazio)" :
            (fileList.count <= 400 ? fileList.joined(separator: "\n") : fileList.prefix(400)
                .joined(separator: "\n") + "\n… e \(fileList.count - 400) mais")
        return ([system, Prompts.mode(mode), "Arquivos no projeto:\n\(list)"] + extras.filter { !$0.isEmpty })
            .joined(separator: "\n\n")
    }
}
