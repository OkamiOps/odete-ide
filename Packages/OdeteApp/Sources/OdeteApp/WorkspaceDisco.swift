import Foundation
import OdeteGit

/// O que o observador de arquivos diz sobre um arquivo só: aba aberta reescrita por fora,
/// ou arquivo mudado no git que pode ter voltado ao original.
extension WorkspaceModel {
    /// Arquivo aberto reescrito por fora volta para a tela.
    ///
    /// Sem isto o editor seguia mostrando o texto velho depois de um `git checkout`, de um
    /// script no terminal ou do agente escrevendo, e o salvamento automático gravava o
    /// velho por cima do novo. Buffer com alteração não salva é deixado em paz: ali quem
    /// manda é o que a pessoa digitou.
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
        guard !t.isDirty else { return }
        if let disco = try? ops.read(t.path), disco != buffers[t.path] {
            buffers[t.path] = disco
            reloadTick += 1
            analyze(t.path)
            refreshGutter(t.path)
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
