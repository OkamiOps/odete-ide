import Foundation
import OdeteAgent
import OdeteGit

/// Chamadas de uma vez só ao modelo ativo (sem ferramentas): mensagem de commit, título de PR…
extension AgentModel {
    struct NoAccount: LocalizedError {
        var errorDescription: String? {
            "Conecte uma conta de IA em Ajustes → Contas de IA."
        }
    }

    func oneShot(system: String, user: String) async throws -> String {
        guard let acc = account, !acc.needsReconnect else { throw NoAccount() }
        let provider = HTTPProvider(account: acc, session: accounts.session(for: acc))
        let turn = TurnRequest(
            system: system,
            messages: [.user(user)],
            tools: [],
            model: model,
            effort: effort,
            conversationId: UUID().uuidString
        )
        var out = ""
        for try await e in provider.stream(turn) {
            switch e {
            case let .text(t): out += t
            case let .error(m): throw AgentError.transport(m)
            default: break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Mensagem de commit a partir do diff staged (até 12 kB).
    func suggestCommitMessage() async throws -> String {
        guard let repo = ws.git.repo else { throw NoAccount() }
        let diff = try await repo.diff(.index)
        let text = String(Self.unified(diff).prefix(12000))
        guard !text.isEmpty else { return "" }
        let skill = Skills.builtin.first { $0.id == "commit" }?.body ?? ""
        let msg = try await oneShot(
            system: "Você escreve mensagens de commit. Responda só com a mensagem, sem aspas nem explicação.\n\(skill)",
            user: "Diff staged:\n\n\(text)"
        )
        return msg.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: CharacterSet(charactersIn: "`\"' ")) ?? msg
    }

    /// Título e descrição de PR a partir dos commits da branch atual.
    func suggestPullRequest(base: String) async throws -> (title: String, body: String) {
        let commits = ws.git.log.prefix(30)
        let lines = commits
            .map {
                "- \($0.summary)\($0.body.isEmpty ? "" : "\n  \($0.body.replacingOccurrences(of: "\n", with: "\n  "))")"
            }
        let branch = ws.git.current?.name ?? "branch"
        let raw = try await oneShot(
            system: "Você escreve pull requests em PT-BR. Responda exatamente neste formato:\nTÍTULO: <uma linha>\nDESCRIÇÃO:\n<markdown curto: o que mudou, por quê, como testar>",
            user: "Branch `\(branch)` para `\(base)`. Commits mais recentes primeiro:\n\(lines.joined(separator: "\n"))"
        )
        var title = ""
        var body = ""
        if let r = raw.range(of: "TÍTULO:") {
            let rest = raw[r.upperBound...]
            if let d = rest.range(of: "DESCRIÇÃO:") {
                title = rest[..<d.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                body = rest[d.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                title = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            title = raw.split(separator: "\n").first.map(String.init) ?? raw
            body = raw
        }
        return (title, body)
    }

    /// Diff em texto unificado, para prompts.
    static func unified(_ diff: Diff) -> String {
        var s = ""
        for f in diff.files {
            s += "--- \(f.oldPath ?? f.path)\n+++ \(f.path)\n"
            for h in f.hunks {
                s += h.header + "\n"
                for l in h.lines {
                    let p = switch l.kind {
                    case .addition: "+"
                    case .deletion: "-"
                    case .context: " "
                    }
                    s += p + l.text + "\n"
                }
            }
        }
        return s
    }
}
