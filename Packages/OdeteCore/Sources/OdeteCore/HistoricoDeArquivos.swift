import Foundation

/// O que ia sobrescrever ou apagar o arquivo quando a versão foi guardada.
///
/// A versão é sempre o conteúdo de *antes*: "agente" quer dizer "como o arquivo estava
/// logo antes de o agente escrever nele". É isso que a folha do histórico mostra.
public enum OrigemDaVersao: String, Codable, Sendable, CaseIterable {
    /// O salvamento do editor. É o único que se agrupa: com o salvamento automático, uma
    /// versão por pausa na digitação encheria o histórico de passos de um minuto só.
    case voce
    case agente
    /// Rejeitar ou desfazer o que o agente propôs, inclusive desfazer o turno inteiro.
    case patchRejeitado
    case git
    /// Restaurar uma versão do próprio histórico (ou de um checkpoint).
    case restauracao
    case apagar
    /// Mudança que o app só percebeu depois, pelo observador de arquivos.
    case externo
    case trocarTudo
    /// O editor jogou fora o texto não salvo da aba para reler o disco.
    case recarregar
    /// Comando do shell da Odete: `rm`, `mv`, `cp`, `>`, `npm install` no package.json.
    case terminal
}

/// Quem sabe guardar versões. A implementação mora em OdeteFiles (`HistoricoLocal`); o
/// agente, o git e o shell não dependem de OdeteFiles, então falam com ela por aqui.
public protocol GuardaDeVersoes: AnyObject, Sendable {
    /// Guarda o conteúdo atual de cada arquivo (pasta entra arquivo por arquivo). `raiz`
    /// é a raiz do projeto; sem ela, a guarda procura sozinha.
    func guardar(_ urls: [URL], raiz: URL?, origem: OrigemDaVersao)
    /// Guarda um texto que não está no disco — o buffer de uma aba, por exemplo.
    func guardar(texto: String, de url: URL, raiz: URL?, origem: OrigemDaVersao)
}

/// Porta de entrada do histórico local para quem não enxerga OdeteFiles.
///
/// Cada caminho de escrita que não passa por `FileOps.write` chama isto uma linha antes
/// de sobrescrever ou apagar. Sem guarda instalada (testes de pacote, por exemplo) é um
/// nada: melhor não guardar que travar quem escreve.
public enum HistoricoDeArquivos {
    private final class Caixa: @unchecked Sendable {
        let trava = NSLock()
        var guarda: (any GuardaDeVersoes)?
    }

    private static let caixa = Caixa()

    public static func instalar(_ guarda: (any GuardaDeVersoes)?) {
        caixa.trava.withLock { caixa.guarda = guarda }
    }

    public static var instalada: (any GuardaDeVersoes)? {
        caixa.trava.withLock { caixa.guarda }
    }

    public static func guardar(_ url: URL, raiz: URL? = nil, origem: OrigemDaVersao) {
        instalada?.guardar([url], raiz: raiz, origem: origem)
    }

    public static func guardar(_ urls: [URL], raiz: URL? = nil, origem: OrigemDaVersao) {
        guard !urls.isEmpty else { return }
        instalada?.guardar(urls, raiz: raiz, origem: origem)
    }

    public static func guardar(texto: String, de url: URL, raiz: URL? = nil, origem: OrigemDaVersao) {
        instalada?.guardar(texto: texto, de: url, raiz: raiz, origem: origem)
    }
}
