import Foundation
import OdeteAgent
import OdeteBundler
import OdeteCore
import OdeteEditor
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

    /// Esboço, regras e sintaxe, todos fora do ator principal.
    ///
    /// Esboço e lint leem o arquivo inteiro e rodavam aqui mesmo, no ator principal, a
    /// cada pausa na digitação. Em arquivo grande isso é engasgo na tecla seguinte.
    /// Quais caminhos de import deste arquivo apontam para outro arquivo do projeto.
    /// Fora do ator principal, como o resto da análise: é uma varredura por regex no
    /// arquivo inteiro a cada pausa na digitação.
    nonisolated static func elos(
        text: String,
        language: Language,
        path: String,
        model: WorkspaceModel?
    ) async -> [EditorLink] {
        let links = ImportLinks.find(text: text, language: language)
        guard !links.isEmpty else { return [] }
        let (arquivos, apelidos) = await MainActor.run { [weak model] in
            (Set(model?.filePaths ?? []), model?.tsAliases ?? [:])
        }
        return links.compactMap { l in
            guard let destino = ImportLinks.resolve(l.spec, de: path, arquivos: arquivos, aliases: apelidos)
            else { return nil }
            return EditorLink(range: l.range, destino: destino)
        }
    }

    func analyze(_ path: String) {
        guard let text = buffers[path] else { return }
        let lang = Language.detect(path: path)
        // Bundle e minificado: o esboço vira uma lista de mil entradas inúteis, o lint
        // vira uma enxurrada sobre código de terceiro e o esbuild engole um megabyte a
        // cada pausa na digitação. Nada disso ajuda quem só abriu o arquivo para ler.
        guard text.utf8.count <= Limites.arquivoGrande else {
            outlines[path] = []
            lint[path] = []
            links[path] = []
            syntax[path] = nil
            refreshPatchMarks(path)
            return
        }
        Task.detached(priority: .utility) { [weak self] in
            let esboco = Outline.items(text: text, language: lang)
            // Quando a linguagem tem gramática, quem confere a sintaxe é o parser dela.
            let doParser = ParserErros.problemas(text: text, language: lang)
            let regras = doParser + Lint.rules(
                text: text,
                language: lang,
                path: path,
                sintaxeDeFora: ParserErros.temParser(lang)
            )
            let elos = await Self.elos(text: text, language: lang, path: path, model: self)
            await MainActor.run {
                guard let self, self.buffers[path] == text else { return }
                self.outlines[path] = esboco
                self.lint[path] = regras
                self.links[path] = elos
                self.refreshPatchMarks(path)
            }
        }
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

    /// Linhas do patch pendente deste arquivo, em cima do texto que está na tela agora.
    ///
    /// A comparação é com o texto de antes do agente, não com o que ele escreveu: assim a
    /// marcação continua certa depois de a pessoa editar por cima da alteração, que é o
    /// que ela faz na prática quando quer ajustar uma linha que o agente escreveu.
    func refreshPatchMarks(_ path: String) {
        guard let p = agent.pendingPatches.first(where: { $0.path == path }), let texto = buffers[path] else {
            if patchChanges[path] != nil {
                patchChanges[path] = nil
            }
            return
        }
        let novas = PatchMarks.linhas(antes: p.before, agora: texto)
        if patchChanges[path] != novas {
            patchChanges[path] = novas
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
    func hunk(at line: Int, in path: String) -> (FileDiff, OdeteGit.Hunk)? {
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
