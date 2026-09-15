import Foundation
import OdeteAccounts
import OdeteAgent
import OdeteI18n
import OdeteShell

/// Ferramentas do agente sobre o workspace: arquivos no disco, terminal e shell reais.
final class AppToolHost: FileToolHost, @unchecked Sendable {
    private let reloadBox: SendBox<String, Void>
    private let tailBox: SendBox<Int, String>
    private let revealBox: SendBox<String, Void>
    private let runBox: SendBox<Void, TerminalSession>
    /// Slug, token e branch atual só existem no ator principal; o agente roda fora dele.
    private let ghBox: SendBox<Void, (slug: String?, token: String?, branch: String?)>

    @MainActor
    init(ws: WorkspaceModel) {
        reloadBox = SendBox { [weak ws] (p: String) in ws?.reloadBuffer(p) }
        tailBox = SendBox { [weak ws] (n: Int) in
            guard let s = ws?.run.active else { return "(terminal vazio)" }
            let lines = s.lines.suffix(n).map { ($0.kind == .err ? "! " : "") + $0.text }
            return lines.isEmpty ? "(terminal vazio)" : lines.joined(separator: "\n")
        }
        revealBox = SendBox { [weak ws] (p: String) in ws?.openFile(p) }
        runBox = SendBox { [weak ws] in ws!.run.agentSession() }
        ghBox = SendBox { [weak ws] in
            (ws?.git.githubSlug, ws?.git.githubToken, ws?.git.current?.name ?? ws?.git.headName)
        }
        super.init(root: ws.root)
    }

    override func write(_ path: String, _ text: String) throws {
        try super.write(path, text)
        reloadBox.value(path)
    }

    override func terminalTail(_ n: Int) -> String {
        tailBox.value(n)
    }

    override func reveal(_ path: String) {
        revealBox.value(path)
    }

    override func runShell(_ command: String) async -> String {
        let session = runBox.value()
        let start = await MainActor.run { session.lines.count }
        await MainActor.run { session.append(.input, "\(session.prompt) \(command)"); session.run(command) }
        var waited = 0
        while await MainActor.run(body: { session.running != nil }) {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
            if waited >
                3000
            {
                return await MainActor
                    .run { session.lines[start...].map(\.text).joined(
                        separator: "\n"
                    ) } + tr("\n… (ainda rodando após 5 min)")
            }
        }
        return await MainActor.run {
            let out = session.lines[min(start, session.lines.count)...].filter { $0.kind != .input }
                .map { ($0.kind == .err ? "! " : "") + $0.text }.joined(separator: "\n")
            return out.isEmpty ? tr("(sem saída)") : out
        }
    }

    /// Pull requests do repositório, com a conta que está nos Ajustes.
    ///
    /// A resposta é texto curto de propósito: o agente lê melhor uma linha por PR do que
    /// um JSON, e o que ele precisa saber é número, título e estado.
    override func github(_ pedido: GitHubPedido) async -> String {
        let ctx = ghBox.value()
        guard let slug = ctx.slug else {
            return tr("este projeto não tem remoto no GitHub; publique primeiro pelo painel Git")
        }
        guard let token = ctx.token else {
            return tr("sem conta do GitHub conectada; entre em Ajustes → Git e GitHub")
        }
        let api = GitHubAPI(token: token)
        do {
            switch pedido.acao {
            case .listPulls:
                let pulls = try await api.pulls(slug)
                if pulls.isEmpty {
                    return tr("nenhum PR aberto em %1$@", "\(slug)")
                }
                return pulls.map { p in
                    "#\(p.number) \(p.title) · \(p.head.ref) → \(p.base.ref) · \(p.user?.login ?? "")"
                }.joined(separator: "\n")
            case .createPull:
                guard let titulo = pedido.titulo else { return tr("create_pull precisa de title") }
                guard let head = pedido.head ?? ctx.branch else { return tr("create_pull precisa de head") }
                let base = pedido.base ?? "main"
                let p = try await api.createPull(
                    slug,
                    title: titulo,
                    body: pedido.corpo ?? "",
                    head: head,
                    base: base
                )
                return "PR #\(p.number) aberto: \(p.htmlUrl)"
            case .comment:
                try await api.comment(slug, number: pedido.numero!, body: pedido.corpo ?? "")
                return tr("comentário publicado no #%1$@", "\(pedido.numero!)")
            case .mergePull:
                try await api.mergePull(slug, number: pedido.numero!, method: pedido.metodo ?? "squash")
                return "PR #\(pedido.numero!) mergeado (\(pedido.metodo ?? "squash"))"
            case .closePull:
                try await api.closePull(slug, number: pedido.numero!)
                return tr("PR #%1$@ fechado sem merge", "\(pedido.numero!)")
            }
        } catch {
            return "GitHub: \(error.localizedDescription)"
        }
    }
}
