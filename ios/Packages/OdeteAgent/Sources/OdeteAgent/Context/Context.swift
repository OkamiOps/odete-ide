import Foundation

/// Regras do projeto que entram no sistema.
public enum Rules {
    public static let files = ["AGENTS.md", "CLAUDE.md", ".odete.md", ".cursorrules", ".odete/rules.md"]
    public static func prompt(host: ToolHost) -> String {
        var chunks: [String] = []
        for f in files {
            guard let body = host.read(f)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !body.isEmpty else { continue }
            chunks.append("## \(f)\n\(body.prefix(6000))")
        }
        return chunks.isEmpty ? "" : "Regras do projeto (siga):\n" + chunks.joined(separator: "\n\n")
    }
}

public struct Skill: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    public var body: String
    public var path: String?
}

/// Skills: `.odete/skills/*.md` com front matter, mais as embutidas; ativadas por `/nome`.
public enum Skills {
    public static let builtin: [Skill] = [
        Skill(
            id: "commit",
            name: "Commit",
            description: "Mensagens curtas no padrão convencional, em PT-BR.",
            body: "Mensagens: tipo(escopo): o que mudou\nTipos: feat, fix, chore, docs, refactor, style, test.\nUma linha, sem ponto final, verbo no infinitivo. Ex: feat(editor): destacar seleção pelo tema."
        ),
        Skill(
            id: "swiftui",
            name: "SwiftUI",
            description: "Estilo SwiftUI para o pacote do Swift Playgrounds.",
            body: "Views pequenas, nomes claros, sem Combine. Compatível com Swift Playgrounds no iPad."
        ),
        Skill(
            id: "review",
            name: "Review",
            description: "Revisão curta: risco, bug, o que está ok.",
            body: "Revise em 3 blocos: (1) o que está ok, (2) bugs/risco, (3) patch sugerido.\nNão reescreva arquivo inteiro se um hunk resolve. Cite path:linha."
        ),
        Skill(
            id: "html",
            name: "HTML",
            description: "index.html e CSS do preview, sem framework.",
            body: "index.html é a página do Preview. CSS em src/style.css. JS em src/main.js.\nAcessível, contraste ok, sem dependência nova."
        ),
    ]

    static func parse(path: String, text: String) -> Skill? {
        var meta: [String: String] = [:]
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("---\n"), let end = body.range(
            of: "\n---",
            range: body.index(body.startIndex, offsetBy: 4) ..< body.endIndex
        ) {
            let front = body[body.index(body.startIndex, offsetBy: 4) ..< end.lowerBound]
            for line in front.split(separator: "\n") {
                guard let i = line.firstIndex(of: ":") else { continue }
                meta[line[..<i].trimmingCharacters(in: .whitespaces)] = line[line.index(after: i)...]
                    .trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            body = String(body[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty else { return nil }
        let base = (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        let id = (meta["id"] ?? meta["name"] ?? base).lowercased().replacingOccurrences(
            of: #"[^a-z0-9-]+"#,
            with: "-",
            options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return Skill(
            id: id,
            name: meta["name"] ?? id,
            description: meta["description"] ?? String(body.split(separator: "\n").first ?? "").prefix(80).description,
            body: body,
            path: path
        )
    }

    public static func all(host: ToolHost) -> [Skill] {
        let files = host.list(".odete/skills").filter { $0.hasSuffix(".md") }
        let mine = files.compactMap { f in host.read(".odete/skills/\(f)").flatMap { parse(
            path: ".odete/skills/\(f)",
            text: $0
        ) } }
        let ids = Set(mine.map(\.id))
        return mine + builtin.filter { !ids.contains($0.id) }
    }

    public static func slashes(in text: String) -> [String] {
        captures(#"(?:^|\s)/([a-zA-Z][\w-]*)"#, in: text).map { $0.lowercased() }
    }

    public static func prompt(all: [Skill], userText: String) -> String {
        let ids = Set(slashes(in: userText))
        let active = all.filter { ids.contains($0.id) || ids.contains($0.name.lowercased().replacingOccurrences(
            of: " ",
            with: ""
        )) }
        if active.isEmpty {
            let names = all.map { "/\($0.id)" }.joined(separator: ", ")
            return names.isEmpty ? "" : "Skills via /nome no chat: \(names)"
        }
        return "Skills aplicadas neste turno (o usuário chamou com /nome):\n" + active
            .map { "### /\($0.id) — \($0.name)\n\($0.body)" }.joined(separator: "\n\n")
    }
}

/// `@caminho` no texto do usuário vira o conteúdo do arquivo.
public enum Mentions {
    public static func paths(in text: String) -> [String] {
        captures(#"(?:^|\s)@([\w./-]+)"#, in: text).filter { !$0.hasSuffix(".") }
    }

    public static func expand(_ text: String, host: ToolHost) -> String {
        var blocks: [String] = []
        for p in paths(in: text) {
            guard let body = host.read(p) else { continue }
            blocks.append("Arquivo `\(p)`:\n```\n\(body.prefix(40000))\n```")
        }
        return blocks.isEmpty ? text : text + "\n\n" + blocks.joined(separator: "\n\n")
    }
}

/// Primeiro grupo de cada ocorrência.
func captures(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
        Range(m.range(at: 1), in: text).map { String(text[$0]) }
    }
}
