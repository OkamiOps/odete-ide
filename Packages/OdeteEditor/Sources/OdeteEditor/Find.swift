import Foundation
import Synchronization

/// O que procurar dentro do arquivo aberto.
///
/// Até aqui a lupa do teclado abria a busca do projeto inteiro: não havia como achar
/// a terceira ocorrência de uma variável no arquivo que está na tela.
public struct EditorFind: Equatable, Sendable {
    public var texto: String
    public var caseSensitive: Bool
    public var regex: Bool
    /// Qual das ocorrências está em foco. Muda a cada próximo/anterior.
    public var indice: Int

    public init(texto: String, caseSensitive: Bool = false, regex: Bool = false, indice: Int = 0) {
        self.texto = texto
        self.caseSensitive = caseSensitive
        self.regex = regex
        self.indice = indice
    }
}

/// Pedido de substituição. O `token` é o que dispara: mudar só o texto não refaz nada.
///
/// É de uso único: quem pediu entrega o pedido só ao editor do documento certo e o
/// esquece quando o editor avisa que atendeu (`aoConsumirTroca`). Sem isso o pedido velho
/// ficava no modelo, e todo editor que nascia depois — trocar de modo, o lado direito do
/// modo Dois — substituía de novo.
public struct EditorReplace: Equatable, Sendable {
    public var por: String
    public var todos: Bool
    public var token: Int

    public init(por: String, todos: Bool, token: Int) {
        self.por = por
        self.todos = todos
        self.token = token
    }
}

/// Números dos pedidos de uso único ao editor: substituir e ir para uma linha.
///
/// O editor de cada documento anota o último pedido que atendeu (ver
/// `SessoesDoEditor.Sessao`), e um pedido já atendido não roda de novo quando outro host
/// monta o mesmo editor. Um contador só para o app inteiro porque os editores guardados
/// sobrevivem ao fechar e reabrir o projeto: se cada workspace contasse do zero, o editor
/// guardado ignoraria o pedido novo que repetisse um número velho.
public enum TokensDoEditor {
    private static let contador = Mutex(0)

    public static func proximo() -> Int {
        contador.withLock { n in
            n += 1
            return n
        }
    }
}
