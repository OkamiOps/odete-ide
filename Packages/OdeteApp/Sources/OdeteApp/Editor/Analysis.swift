import Foundation
import OdeteAgent
import OdeteBundler
import OdeteCore
import OdeteEditor
import OdeteGit
import OdeteI18n

/// Esboço, lint e gutter do git para os arquivos abertos.
extension WorkspaceModel {
    /// Reanalisa depois de uma pausa na digitação.
    func scheduleAnalysis(_ path: String) {
        analysisTasks[path]?.cancel()
        analysisTasks[path] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.analyze(path, porEdicao: true)
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
        analyze(path, porEdicao: false)
    }

    /// `porEdicao`: veio de digitação (e não de abrir, restaurar ou recarregar do disco).
    func analyze(_ path: String, porEdicao: Bool) {
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
        let indice = indiceDeNomes(para: lang)
        Task.detached(priority: .utility) { [weak self] in
            let esboco = Outline.items(text: text, language: lang)
            // Quando a linguagem tem gramática, quem confere a sintaxe é o parser dela.
            var doParser = ParserErros.problemas(text: text, language: lang)
            // Nome usado e nunca declarado: a parte do interpretador que não é sintaxe.
            // O índice diz o que os outros arquivos do projeto declaram — sem ele, uma
            // função do arquivo vizinho apareceria como não declarada.
            if Resolvedor.temResolvedor(lang) {
                doParser += Resolvedor.problemas(text: text, language: lang, path: path, indice: indice)
            }
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
        if Self.lintaComEsbuild(lang) {
            lintarSintaxe(path, text: text, porEdicao: porEdicao)
        } else {
            syntax[path] = nil
        }
    }

    // MARK: - Sintaxe pelo esbuild

    /// Quanto o workspace espera, depois de aparecer, antes de subir o esbuild só para
    /// conferir as abas restauradas.
    static let janelaDeAbertura: Duration = .seconds(3)

    /// Espera a mais, só para o esbuild, depois da pausa que já dispara a análise: 350 +
    /// 250 ≈ 600 ms. Esboço e regras são nativos e baratos; a sintaxe é wasm interpretado.
    static let esperaDoEsbuild: Duration = .milliseconds(250)

    /// Chave da tarefa que roda os lints adiados da abertura. `analysisTasks` é por
    /// caminho, e caminho nenhum tem byte nulo.
    static let chaveDosAdiados = "\u{0}lint-adiado"

    static func lintaComEsbuild(_ lang: Language) -> Bool {
        switch lang {
        case .javascript, .jsx, .typescript, .tsx: true
        default: false
        }
    }

    /// Sintaxe de JS/TS vem do esbuild do projeto — o mesmo do terminal e do dev server.
    ///
    /// O caro aqui é o esbuild: no iPad, wasm e JS rodam interpretados, e subir o motor
    /// compila um módulo de 14 MB. Então:
    /// - na abertura, uma aba `.tsx` restaurada não sobe o motor: o lint dela espera a
    ///   pessoa editar o arquivo ou o workspace ter aparecido há `janelaDeAbertura`;
    /// - digitando, o esbuild só entra depois de `esperaDoEsbuild` a mais;
    /// - texto igual ao último lintado não volta ao esbuild (`Esbuild.lint` guarda).
    func lintarSintaxe(_ path: String, text: String, porEdicao: Bool) {
        let chave = path + "\u{0}lint"
        analysisTasks[chave]?.cancel()
        guard let motor = motorDoLint(porEdicao: porEdicao) else {
            agendarLintsAdiados()
            return
        }
        let espera = porEdicao ? Self.esperaDoEsbuild : .zero
        analysisTasks[chave] = Task { [weak self] in
            if espera > .zero {
                try? await Task.sleep(for: espera)
                guard !Task.isCancelled else { return }
            }
            let diags = await (try? motor.lint(text, file: path)) ?? []
            guard let self, !Task.isCancelled, buffers[path] == text else { return }
            syntax[path] = diags.filter { $0.kind == .error }
        }
    }

    /// O esbuild para lintar agora, ou `nil` se é cedo demais para subir um.
    ///
    /// Se alguém já subiu o do projeto (o terminal, o dev server), ele é usado na hora: o
    /// custo de criar já foi pago. Senão, só edição ou o fim da janela de abertura criam.
    func motorDoLint(porEdicao: Bool) -> Esbuild? {
        if let motor = lintEngine ?? Esbuild.existente(root) {
            lintEngine = motor
            return motor
        }
        guard porEdicao || ContinuousClock.now - run.criadoEm >= Self.janelaDeAbertura else { return nil }
        let motor = Esbuild.doProjeto(root)
        lintEngine = motor
        return motor
    }

    /// No fim da janela de abertura, linta as abas de JS/TS que ficaram sem resposta.
    private func agendarLintsAdiados() {
        guard analysisTasks[Self.chaveDosAdiados] == nil else { return }
        let falta = max(.zero, Self.janelaDeAbertura - (ContinuousClock.now - run.criadoEm))
        analysisTasks[Self.chaveDosAdiados] = Task { [weak self] in
            try? await Task.sleep(for: falta)
            guard let self, !Task.isCancelled else { return }
            analysisTasks[Self.chaveDosAdiados] = nil
            for t in tabs where syntax[t.path] == nil && Self.lintaComEsbuild(Language.detect(path: t.path)) {
                guard let texto = buffers[t.path], texto.utf8.count <= Limites.arquivoGrande else { continue }
                lintarSintaxe(t.path, text: texto, porEdicao: false)
            }
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
    ///
    /// Descarta só aquele trecho. O git trabalha no disco; com a aba suja, o disco não é o
    /// que está na tela, e recarregar depois do descarte trocava o buffer inteiro pelo
    /// disco — ia embora junto tudo o que estava digitado e não salvo, em qualquer lugar
    /// do arquivo. Por isso a aba suja é gravada antes, e o trecho é achado de novo na
    /// linha tocada, no disco já gravado. Se não dá para gravar (conflito com o disco),
    /// nada é descartado.
    func discardHunk(at line: Int, in path: String) {
        guard let repo = git.repo else { return }
        let suja = tabs.first { $0.path == path }?.isDirty == true
        if suja, !save(path) {
            error = tr("Não descartei o trecho: as alterações de %1$@ não puderam ser salvas.", path)
            return
        }
        let guardado = suja ? nil : hunk(at: line, in: path)
        guard suja || guardado != nil else { return }
        Task { [weak self] in
            do {
                var alvo = guardado
                if alvo == nil {
                    let r = try await repo.gutterMarks(path: path)
                    if let f = r.file, let m = r.marks.first(where: { $0.line == line }),
                       f.hunks.indices.contains(m.hunk)
                    {
                        alvo = (f, f.hunks[m.hunk])
                    }
                }
                guard let (f, h) = alvo else { return }
                try await repo.discardHunk(h, in: f)
                self?.reloadBuffer(path)
                self?.git.agendarMarcas()
                self?.refreshGutter(path)
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }
}

/// O índice de nomes do projeto, para o resolvedor saber o que os outros arquivos
/// declaram.
extension WorkspaceModel {
    /// O disco é lido uma vez e guardado; o que está aberto entra por cima, toda vez.
    ///
    /// Ler e analisar o projeto inteiro a cada pausa na digitação seria engasgo garantido,
    /// e é por isso que a parte cara fica em cache. Mas o cache sozinho mente: quem acabou
    /// de escrever uma função no arquivo ao lado e ainda não salvou veria o nome acusado
    /// aqui. Por isso os arquivos abertos — que são poucos e já estão na memória — são
    /// somados a cada chamada.
    func indiceDeNomes(para language: Language) -> Resolvedor.Indice {
        guard Resolvedor.usaIndice(language) else { return Resolvedor.Indice() }
        let exts = Set(Language.extensoes[language] ?? [])
        let alvos = filePaths.filter { exts.contains(($0 as NSString).pathExtension.lowercased()) }
        let abertos: [(caminho: String, texto: String)] = alvos.compactMap { caminho in
            buffers[caminho].map { (caminho, $0) }
        }
        let assinatura = "\(language.rawValue):\(filePaths.count):\(filePaths.last ?? "")"
        if let guardado = indiceCache, assinaturaDoIndice == assinatura {
            return guardado.somando(arquivos: abertos)
        }
        let doDisco: [(caminho: String, texto: String)] = alvos.prefix(600).compactMap { caminho in
            guard buffers[caminho] == nil,
                  let dados = try? String(contentsOf: root.appending(path: caminho), encoding: .utf8),
                  dados.utf8.count <= Limites.arquivoGrande
            else { return nil }
            return (caminho, dados)
        }
        let indice = Resolvedor.Indice(arquivos: doDisco)
        indiceCache = indice
        assinaturaDoIndice = assinatura
        return indice.somando(arquivos: abertos)
    }
}
