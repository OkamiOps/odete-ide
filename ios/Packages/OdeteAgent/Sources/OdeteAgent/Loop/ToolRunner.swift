import Foundation

public struct ToolOutcome: Sendable {
    public var text: String
    public var patch: Patch?
}

/// Executa uma chamada de ferramenta respeitando o modo.
public struct ToolRunner: Sendable {
    public var host: ToolHost
    public var patches: PatchStore
    public init(host: ToolHost, patches: PatchStore) {
        self.host = host; self.patches = patches
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
            return .init(text: host.read(p).map { Self.clip($0) } ?? "não existe: \(p)")
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
            return await .init(text: Self.clip(host.runShell(cmd)))
        default:
            return .init(text: "tool desconhecida: \(call.name)")
        }
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
            after = (args["content"] as? String) ?? ""
        }
        if mode == .plan {
            guard path == ".odete/plan.md"
            else { return .init(text: "plan só escreve .odete/plan.md — mude pra Build pra editar o resto") }
            do { try host.write(path, after) } catch {
                return .init(text: "erro ao escrever: \(error.localizedDescription)")
            }
            return .init(text: "escrito \(path)")
        }
        let before = host.read(path) ?? ""
        do { try host.write(path, after) } catch {
            return .init(text: "erro ao escrever: \(error.localizedDescription)")
        }
        let patch = patches.queue(path: path, before: before, after: after)
        host.reveal(path)
        return .init(text: "escrito \(path)", patch: patch)
    }
}
