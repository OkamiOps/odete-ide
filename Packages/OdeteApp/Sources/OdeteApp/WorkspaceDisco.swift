import Foundation
import OdeteGit

/// O que o observador de arquivos diz sobre um arquivo só: aba aberta reescrita por fora,
/// ou arquivo mudado no git que pode ter voltado ao original.
extension WorkspaceModel {
    /// Arquivo aberto reescrito por fora volta para a tela.
    ///
    /// Sem isto o editor seguia mostrando o texto velho depois de um `git checkout`, de um
    /// script no terminal ou do agente escrevendo, e o salvamento automático gravava o
    /// velho por cima do novo. Buffer com alteração não salva não recebe o disco — ali
    /// quem manda é o que a pessoa digitou —, mas entra em conflito: antes o aviso era
    /// ignorado, e o salvamento seguinte gravava por cima do que chegou de fora.
    ///
    /// E o git olha de novo. Escrever no lugar — o `cp`, o `>` do shell — não mexe na
    /// pasta, e este aviso é o único que chega. Ele relia o buffer e parava ali: um arquivo
    /// devolvido byte a byte ao que está no HEAD continuava com "M" na árvore e no número
    /// do ícone, com `git status` limpo no disco, até alguma outra mudança acordar o git.
    func conferirDisco(_ absoluto: String) {
        // O observador fala em caminho absoluto, o resto do app em caminho relativo à
        // raiz. Comparar os absolutos evita montar a conversão de volta e errar nela.
        guard let t = tabs.first(where: { (try? ops.url($0.path))?.path == absoluto }) else {
            // Sem aba, só se vigia o arquivo que o git dá como mudado (`acompanharAbas`):
            // o que importa aqui é se ele voltou ao original.
            git.agendarMarcas()
            return
        }
        guard let data = ops.modifiedAt(t.path) else { return }
        let antes = marcaDisco[t.path]
        marcaDisco[t.path] = data
        // Data igual à anotada é a gravação do próprio app, e `save` já chamou o git.
        guard antes != data else { return }
        git.agendarMarcas()
        guard let disco = try? ops.read(t.path) else { return }
        guardarBuffer(t.path, antesDe: disco, origem: .externo)
        if absorverDisco(t.path, disco: disco) {
            reloadTick += 1
        }
    }

    /// O disco de uma aba aberta mudou (ou pode ter mudado): decide o que fazer com ele.
    ///
    /// - aba limpa: o disco vai para a tela;
    /// - aba suja, com o disco igual ao que ela tem: fica limpa;
    /// - aba suja, com o disco igual ao que ela conheceu: nada mudou de verdade;
    /// - aba suja, com o disco diferente do que ela conheceu: conflito. Nada é gravado nem
    ///   descartado até a pessoa escolher na faixa do editor.
    ///
    /// Devolve se o buffer mudou.
    @discardableResult
    func absorverDisco(_ path: String, disco: String) -> Bool {
        guard buffers[path] != nil else { return false }
        let impressao = EscritasProprias.impressao(disco)
        let suja = tabs.first { $0.path == path }?.isDirty == true
        if suja {
            if disco == buffers[path] {
                baseDisco[path] = impressao
                conflitos.remove(path)
                markDirty(path, false)
            } else if baseDisco[path] != impressao {
                conflitos.insert(path)
            }
            return false
        }
        baseDisco[path] = impressao
        conflitos.remove(path)
        guard disco != buffers[path] else { return false }
        buffers[path] = disco
        analyze(path)
        refreshGutter(path)
        return true
    }

    /// O disco mudou por fora desde que a aba o leu ou gravou?
    ///
    /// A data é o atalho: igual à anotada, ninguém mexeu. Diferente, o conteúdo decide —
    /// um `touch` ou um `git checkout` do mesmo conteúdo não é conflito, e o disco que já
    /// tem o que se vai gravar (`gravando`) também não.
    func discoMudouPorFora(_ path: String, gravando: [String]) -> Bool {
        guard let base = baseDisco[path], ops.exists(path) else { return false }
        let data = ops.modifiedAt(path)
        if let data, data == marcaDisco[path] {
            return false
        }
        guard let disco = try? ops.read(path) else { return false }
        let impressao = EscritasProprias.impressao(disco)
        if impressao == base || gravando.contains(disco) {
            baseDisco[path] = impressao
            marcaDisco[path] = data
            return false
        }
        return true
    }

    // MARK: - Faixa de conflito

    /// "Manter o meu": o texto da aba vai para o disco, por cima do que mudou lá. Devolve
    /// se gravou.
    @discardableResult
    func manterOMeu(_ path: String) -> Bool {
        conflitos.remove(path)
        // O disco de agora passa a ser a base: é por cima dele, de propósito, que se grava.
        if let disco = try? ops.read(path) {
            baseDisco[path] = EscritasProprias.impressao(disco)
            marcaDisco[path] = ops.modifiedAt(path)
        }
        return save(path)
    }

    /// "Recarregar do disco": o que está no disco volta para a aba. O texto que estava
    /// nela não some de vez — o editor recebe a troca como um passo do desfazer, e o ⌘Z o
    /// traz de volta.
    func recarregarDoDisco(_ path: String) {
        conflitos.remove(path)
        saveTasks[path]?.cancel()
        saveTasks[path] = nil
        guard let disco = try? ops.read(path) else { return }
        marcaDisco[path] = ops.modifiedAt(path)
        markDirty(path, false)
        absorverDisco(path, disco: disco)
        reloadTick += 1
    }

    /// Carrega o estado do disco de um caminho para outro (renomear, mover).
    func moverEstadoDoDisco(de antigo: String, para novo: String) {
        baseDisco[novo] = baseDisco.removeValue(forKey: antigo)
        marcaDisco[novo] = marcaDisco.removeValue(forKey: antigo)
        cursores[novo] = cursores.removeValue(forKey: antigo)
        if conflitos.remove(antigo) != nil {
            conflitos.insert(novo)
        }
    }

    /// Diz ao observador quais arquivos merecem vigilância própria: os abertos e os que o
    /// git dá como mudados.
    ///
    /// Os mudados porque são os únicos que podem voltar ao original, e a volta costuma vir
    /// escrita no lugar (`cp`, `git show HEAD:… >`), que a pasta não acusa. Sem vigiar o
    /// arquivo, o "M" dele ficava até outra coisa acordar o git. Arquivo novo ou apagado
    /// não entra: esses só mudam de estado criando ou apagando, e a pasta vê. O teto
    /// guarda descritores para o resto do app num repositório com tudo mudado.
    func acompanharAbas() {
        let abas = tabs.map(\.path)
        let mudados = git.status.lazy
            .filter { Self.podeVoltarAoOriginal($0) && !abas.contains($0.path) }
            .map(\.path)
            .prefix(Self.tetoDeMudadosVigiados)
        observador?.acompanhar((abas + mudados).compactMap { (try? ops.url($0))?.path })
    }

    /// Quantos arquivos mudados no git ganham observador próprio, além das abas.
    static let tetoDeMudadosVigiados = 100

    /// Arquivo que existe no disco e difere do HEAD só no conteúdo.
    static func podeVoltarAoOriginal(_ e: StatusEntry) -> Bool {
        let conteudo: Set<Change?> = [.modified, .typeChange]
        return conteudo.contains(e.unstaged) || conteudo.contains(e.staged)
    }
}
