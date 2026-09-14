import Foundation
import OdeteAgent
import OdeteShell

/// Ferramentas do agente sobre o workspace: arquivos no disco, terminal e shell reais.
final class AppToolHost: FileToolHost, @unchecked Sendable {
    private let reloadBox: SendBox<String, Void>
    private let tailBox: SendBox<Int, String>
    private let revealBox: SendBox<String, Void>
    private let runBox: SendBox<Void, TerminalSession>

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
                    ) } + "\n… (ainda rodando após 5 min)"
            }
        }
        return await MainActor.run {
            let out = session.lines[min(start, session.lines.count)...].filter { $0.kind != .input }
                .map { ($0.kind == .err ? "! " : "") + $0.text }.joined(separator: "\n")
            return out.isEmpty ? "(sem saída)" : out
        }
    }
}
