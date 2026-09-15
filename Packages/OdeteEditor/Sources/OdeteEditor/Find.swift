import Foundation

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
