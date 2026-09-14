import Foundation

public enum AgentMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case chat, plan, build
    public var id: String {
        rawValue
    }

    public var label: String {
        switch self { case .chat: "Chat"; case .plan: "Plan"; case .build: "Build" }
    }
}

public enum PermitMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case ask, auto, full
    public var id: String {
        rawValue
    }

    public var label: String {
        switch self { case .ask: "Ask"; case .auto: "Auto"; case .full: "Full" }
    }

    public var hint: String {
        switch self {
        case .ask: "pergunta antes de tudo"; case .auto: "só pergunta para escrever e rodar"; case .full: "não pergunta"
        }
    }

    public var symbol: String {
        switch self { case .ask: "hand.raised"; case .auto: "bolt.shield"; case .full: "bolt.fill" }
    }
}

/// As sete ferramentas, com os mesmos nomes e schemas do web.
public enum Tools {
    static let safe: Set<String> = ["read_file", "list_dir", "grep", "read_terminal"]
    static let chatTools: Set<String> = ["read_file", "list_dir", "grep", "read_terminal", "run_shell"]
    static let planTools: Set<String> = chatTools.union(["write_file", "str_replace"])

    public static let all: [ToolSpec] = [
        ToolSpec(
            name: "read_file",
            description: "Lê um arquivo do projeto.",
            parameters: obj(["path": str], required: ["path"])
        ),
        ToolSpec(
            name: "str_replace",
            description: "Substitui um trecho EXATO no arquivo. Prefira isto a write_file. old precisa aparecer uma vez.",
            parameters: obj(["path": str, "old": str, "new": str], required: ["path", "old", "new"])
        ),
        ToolSpec(
            name: "write_file",
            description: "Cria arquivo ou reescreve INTEIRO. No modo plan, grave o plano em .odete/plan.md.",
            parameters: obj(["path": str, "content": str], required: ["path", "content"])
        ),
        ToolSpec(
            name: "list_dir",
            description: "Lista arquivos e pastas. path vazio = raiz.",
            parameters: obj(["path": str])
        ),
        ToolSpec(
            name: "grep",
            description: "Busca regex no projeto.",
            parameters: obj(["pattern": str, "path": str], required: ["pattern"])
        ),
        ToolSpec(
            name: "read_terminal",
            description: "Lê as últimas linhas do terminal (stdout/stderr).",
            parameters: obj(["n": ["type": "number", "description": "quantas linhas (default 80)"]])
        ),
        ToolSpec(
            name: "run_shell",
            description: "Terminal do projeto no iPad: ls, cat, mkdir, git, npm install, npm run dev/build, node arquivo.js. Vite, Next, Astro e Nest sobem no Preview. Chat só lê. Plan: mkdir/touch só em .odete/.",
            parameters: obj(["command": str], required: ["command"])
        ),
    ]

    static var str: [String: Any] {
        ["type": "string"]
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

    public static func needsPermit(_ mode: PermitMode, _ name: String) -> Bool {
        switch mode {
        case .full: false
        case .auto: !safe.contains(name)
        case .ask: true
        }
    }

    /// Comandos que só leem (liberados em chat e plan).
    public static func isReadShell(_ command: String) -> Bool {
        let parts = command.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return !parts.isEmpty && parts.allSatisfy { seg in
            let words = seg.split(separator: " ").map(String.init)
            guard let cmd = words.first else { return false }
            if [
                "ls",
                "cat",
                "head",
                "tail",
                "grep",
                "find",
                "pwd",
                "wc",
                "echo",
                "which",
                "env",
                "date",
                "history",
                "jobs",
                "help",
                "true",
                "tree",
            ].contains(cmd) {
                return true
            }
            if cmd == "git", words.count > 1 {
                return [
                    "status",
                    "log",
                    "diff",
                    "branch",
                    "remote",
                    "show",
                    "rev-parse",
                    "stash",
                ].contains(words[1]) && !(words[1] == "stash" && words.count > 2 && words[2] != "list")
            }
            if cmd == "npm",
               words
               .count >
               1
            {
                return ["ls", "list", "-v", "--version", "run"]
                    .contains(words[1]) && !(words[1] == "run" && words.count > 2)
            }
            if cmd == "node", words.contains("-v") || words.contains("--version") {
                return true
            }
            return false
        }
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
    public static let system = """
    Você é o agente da Odete, uma IDE que roda 100% no iPad.
    O projeto é uma pasta real no dispositivo. A lista de caminhos vem no sistema; o conteúdo só entra se VOCÊ chamar read_file.
    Você escolhe quando abrir e qual arquivo. Em todos os modos a leitura está liberada.
    O terminal é o shell da Odete: npm install e npm run dev funcionam de verdade e o Preview mostra o app.
    Responda em português brasileiro.

    Formato (obrigatório, o usuário tem TDAH):
    - Nunca um bloco de texto corrido.
    - Use ## título curto e listas.
    - 1 ideia por bullet.
    - No máximo 1 frase solta. O resto vira lista.
    - Arquivos sempre em `backticks`.
    """

    static let read = "Você decide se precisa abrir arquivo, qual, e quando. Use read_file / list_dir / grep / read_terminal só se o conteúdo for necessário. Não invente conteúdo."

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

    public static func build(mode: AgentMode, fileList: [String], extras: [String]) -> String {
        let list = fileList
            .isEmpty ? "(vazio)" :
            (fileList.count <= 400 ? fileList.joined(separator: "\n") : fileList.prefix(400)
                .joined(separator: "\n") + "\n… e \(fileList.count - 400) mais")
        return ([system, Prompts.mode(mode), "Arquivos no projeto:\n\(list)"] + extras.filter { !$0.isEmpty })
            .joined(separator: "\n\n")
    }
}
