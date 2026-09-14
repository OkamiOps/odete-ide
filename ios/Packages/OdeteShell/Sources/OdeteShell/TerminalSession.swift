import Foundation
import Observation

public struct TermLine: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable { case input, out, err, ok, system }
    public var id: Int
    public var kind: Kind
    public var text: String
}

/// Uma aba de terminal: linhas na tela, prompt, entrada, histórico e o comando em execução.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public let id = UUID()
    public let shell: Shell
    public private(set) var lines: [TermLine] = []
    public var input = ""
    public private(set) var running: String?
    public private(set) var jobs: [Job] = []
    private var seq = 0
    private var histIndex: Int?
    public var title: String {
        running ?? shell.prompt
    }

    public init(shell: Shell, banner: Bool = true) {
        self.shell = shell
        shell.onJobsChanged = { [weak self] in Task { @MainActor in self?.jobs = shell.jobs } }
        if banner {
            append(.system, "Odete · shell no iPad. Digite help.")
        }
    }

    public func append(_ kind: TermLine.Kind, _ text: String) {
        if text == "\u{1B}[clear]" {
            lines.removeAll(); return
        }
        for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
            seq += 1
            lines.append(TermLine(id: seq, kind: kind, text: String(part)))
        }
        if lines.count > 5000 {
            lines.removeFirst(lines.count - 5000)
        }
    }

    public var prompt: String {
        "odete \(shell.prompt) %"
    }

    public func submit() {
        let line = input
        input = ""
        histIndex = nil
        append(.input, "\(prompt) \(line)")
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run(line)
    }

    public func run(_ line: String) {
        running = line
        Task { [shell] in
            let code = await shell.run(line) { kind, text in
                Task { @MainActor in self.append(kind == .out ? .out : .err, text) }
            }
            await MainActor.run {
                if code != 0, code != 130 {
                    self.append(.err, "exit \(code)")
                }
                self.running = nil
                self.jobs = shell.jobs
            }
        }
    }

    public func cancel() {
        shell.cancel()
        if running == nil, let j = shell.jobs.last {
            j.kill(); append(.system, "^C job \(j.id) parado")
        } else {
            append(
                .system,
                "^C"
            )
        }
    }

    public func historyUp() {
        let h = shell.history
        guard !h.isEmpty else { return }
        let i = (histIndex ?? h.count) - 1
        guard i >= 0 else { return }
        histIndex = i
        input = h[i]
    }

    public func historyDown() {
        let h = shell.history
        guard let i = histIndex else { return }
        if i + 1 < h.count {
            histIndex = i + 1; input = h[i + 1]
        } else {
            histIndex = nil; input = ""
        }
    }

    public func tab() {
        let parts = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { return }
        let opts = shell.complete(last)
        if opts.count == 1 {
            input = (parts.dropLast() + [opts[0]]).joined(separator: " ")
        } else if opts.count > 1 {
            let common = opts.reduce(opts[0]) { String(zip($0, $1).prefix { $0 == $1 }.map(\.0)) }
            if common.count > last.count {
                input = (parts.dropLast() + [common]).joined(separator: " ")
            } else {
                append(
                    .system,
                    opts.joined(separator: "  ")
                )
            }
        }
    }

    public func clear() {
        lines.removeAll()
    }
}
