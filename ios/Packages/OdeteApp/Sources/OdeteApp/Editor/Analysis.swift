import Foundation
import OdeteBundler
import OdeteCore
import OdeteGit

/// Esboço, lint e gutter do git para os arquivos abertos.
extension WorkspaceModel {
    /// Reanalisa depois de uma pausa na digitação.
    func scheduleAnalysis(_ path: String) {
        analysisTasks[path]?.cancel()
        analysisTasks[path] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.analyze(path)
        }
    }

    /// Esboço e regras são síncronos e baratos; a sintaxe (esbuild) roda em segundo plano.
    func analyze(_ path: String) {
        guard let text = buffers[path] else { return }
        let lang = Language.detect(path: path)
        outlines[path] = Outline.items(text: text, language: lang)
        lint[path] = Lint.rules(text: text, language: lang)
        switch lang {
        case .javascript, .jsx, .typescript, .tsx:
            let engine = run.active?.shell.bundler ?? lintEngine ?? {
                let e = Esbuild(root: root)
                lintEngine = e
                return e
            }()
            Task { [weak self] in
                let diags = await (try? engine.lint(text, file: path)) ?? []
                guard let self, buffers[path] == text else { return }
                syntax[path] = diags.filter { $0.kind == .error }
            }
        default:
            syntax[path] = nil
        }
    }

    func refreshGutters() {
        for t in tabs {
            refreshGutter(t.path)
        }
    }

    func refreshGutter(_ path: String) {
        guard let repo = git.repo else {
            gutter[path] = nil
            gutterFiles[path] = nil
            return
        }
        Task { [weak self] in
            let r = try? await repo.gutterMarks(path: path)
            guard let self, tabs.contains(where: { $0.path == path }) else { return }
            gutter[path] = r?.marks ?? []
            gutterFiles[path] = r?.file
        }
    }

    /// Problemas do arquivo (regras + sintaxe) prontos para o editor.
    func issues(for path: String) -> [LintIssue] {
        let rules = lint[path] ?? []
        let syn = (syntax[path] ?? []).map {
            LintIssue(
                rule: "syntax",
                message: $0.text,
                severity: .error,
                line: $0.line ?? 1,
                column: $0.column ?? 1,
                length: 1
            )
        }
        return syn + rules
    }

    /// Todos os problemas de lint dos arquivos abertos, para o painel Problemas.
    var allLint: [(path: String, issue: LintIssue)] {
        tabs.flatMap { t in issues(for: t.path).map { (t.path, $0) } }
    }

    /// Hunk do git que contém a linha (para o popover do gutter).
    func hunk(at line: Int, in path: String) -> (FileDiff, Hunk)? {
        guard let f = gutterFiles[path], let m = gutter[path]?.first(where: { $0.line == line }),
              f.hunks.indices.contains(m.hunk)
        else {
            return nil
        }
        return (f, f.hunks[m.hunk])
    }

    /// Descarta o hunk no workdir e recarrega o buffer.
    func discardHunk(at line: Int, in path: String) {
        guard let (f, h) = hunk(at: line, in: path), let repo = git.repo else { return }
        Task { [weak self] in
            do {
                try await repo.discardHunk(h, in: f)
                self?.reloadBuffer(path)
                self?.git.scheduleRefresh()
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }
}
