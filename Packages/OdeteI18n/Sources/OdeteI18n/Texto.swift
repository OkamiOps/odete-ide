import Foundation
import Observation
import Synchronization

/// Traduz. A chave é o próprio texto em português: o código continua legível ao lado
/// da tela que ele desenha, e o português não precisa de tabela — ele já é a chave.
///
/// Serve dentro e fora do SwiftUI. Dentro de um `body`, a chamada também registra a
/// dependência do idioma, e é por isso que a tela se refaz sozinha quando a pessoa
/// troca de idioma nos Ajustes, sem reabrir o app.
public func tr(_ chave: String) -> String {
    Texto.observar()
    return Texto.chave(chave)
}

/// Com argumentos: a chave carrega os `%@` e `%d`, e o resto entra por `String(format:)`.
/// Interpolação normal (`"\(n) arquivos"`) não dá para traduzir — a frase chega pronta
/// e cada idioma põe o número num lugar.
public func tr(_ chave: String, _ args: any CVarArg...) -> String {
    Texto.observar()
    return String(format: Texto.chave(chave), locale: Texto.idioma.locale, arguments: args)
}

/// A tabela e o idioma em vigor. Fica fora de qualquer ator: o shell, o git e o agente
/// escrevem texto para a pessoa de dentro dos atores deles, e um `await` em cada frase
/// não é uma opção.
public enum Texto {
    public static let chaveDosAjustes = "odete.idioma"

    private struct Estado: Sendable {
        /// `nil` = ainda não li os Ajustes. Adiar isso até a primeira frase evita
        /// depender da ordem em que os singletons nascem.
        var idioma: Idioma?
        var tabela: [String: String] = [:]
    }

    private static let estado = Mutex(Estado())

    public static var idioma: Idioma {
        estado.withLock { st in
            garantir(&st)
            return st.idioma ?? .sistema
        }
    }

    /// Troca o idioma. Quem chama é `Idiomas`, que depois avisa o SwiftUI.
    public static func escolher(_ novo: Idioma) {
        UserDefaults.standard.set(novo.rawValue, forKey: chaveDosAjustes)
        estado.withLock { st in carregar(novo, &st) }
    }

    public static func chave(_ k: String) -> String {
        estado.withLock { st in
            garantir(&st)
            return st.tabela[k] ?? k
        }
    }

    /// Dentro de um `body` do SwiftUI, lê a versão do idioma para que a observação
    /// do SwiftUI ligue esta tela à troca de idioma. Fora da thread principal não há
    /// tela nenhuma esperando, e a leitura é pulada.
    static func observar() {
        guard Thread.isMainThread else { return }
        MainActor.assumeIsolated { _ = Idiomas.shared.versao }
    }

    private static func garantir(_ st: inout Estado) {
        guard st.idioma == nil else { return }
        let salvo = UserDefaults.standard.string(forKey: chaveDosAjustes) ?? ""
        carregar(Idioma(rawValue: salvo) ?? .sistema, &st)
    }

    private static func carregar(_ i: Idioma, _ st: inout Estado) {
        st.idioma = i
        st.tabela = tabela(i.codigo)
    }

    private static func tabela(_ codigo: String) -> [String: String] {
        // Português não tem tabela: a chave é a frase. Uma tabela de identidade só
        // dobraria o catálogo para devolver o que já está escrito no código.
        guard codigo != Idioma.ptBR.rawValue else { return [:] }
        guard let caminho = Bundle.module.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: nil,
            forLocalization: codigo
        ), let dict = NSDictionary(contentsOfFile: caminho) as? [String: String]
        else { return [:] }
        return dict
    }
}

/// A ponta do idioma que o SwiftUI enxerga. `versao` sobe a cada troca; quem chama
/// `tr()` dentro de um `body` lê isso sem saber, e a tela se refaz.
@MainActor
@Observable
public final class Idiomas {
    public static let shared = Idiomas()
    /// Guardada, e não calculada em cima de `Texto`: só uma propriedade de verdade
    /// entra na observação do SwiftUI, e é ela que move a marca de seleção na lista.
    public private(set) var atual: Idioma
    /// Sobe a cada troca. `tr()` lê isto de dentro do `body`, e é o que faz a tela
    /// inteira se refazer sem ninguém ter escrito `onChange`.
    public private(set) var versao = 0

    private init() {
        atual = Texto.idioma
    }

    public func escolher(_ novo: Idioma) {
        guard novo != atual else { return }
        Texto.escolher(novo)
        atual = novo
        versao &+= 1
    }
}
