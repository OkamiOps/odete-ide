import Foundation

/// Item da conversa como a UI mostra.
public enum ChatItem: Codable, Sendable, Hashable, Identifiable {
    case user(id: String, text: String, images: [AgentImage]?)
    case assistant(id: String, text: String)
    case think(id: String, text: String, live: Bool)
    case tool(id: String, name: String, detail: String)
    case permit(id: String, name: String, detail: String, status: PermitStatus)
    case error(id: String, text: String)
    case patch(id: String, patchId: String, path: String)
    /// A conversa foi compactada: `resumo` é o texto que entrou no lugar do começo (vazio
    /// quando só as saídas antigas de ferramenta foram podadas), `antes` e `depois` os
    /// tokens na janela. Com `depois` zero e resumo vazio, a compactação está em andamento.
    case compactado(id: String, resumo: String, antes: Int, depois: Int)

    public enum PermitStatus: String, Codable, Sendable { case pending, ok, no }

    public var id: String {
        switch self {
        case let .user(id, _, _), let .assistant(id, _), let .think(id, _, _), let .tool(id, _, _), let .permit(
            id,
            _,
            _,
            _
        ), let .error(id, _), let .patch(id, _, _), let .compactado(id, _, _, _): id
        }
    }
}

public struct ChatThread: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var updated: Date
    public var items: [ChatItem]
    public var messages: [AgentMessage]
    public var usage: TokenUse
    public var lastInput: Int
    /// O prompt de sistema desta conversa, montado no primeiro turno e mantido igual até o
    /// fim — ver `Prompts.daConversa`. `nil` nas conversas de antes desta versão e nas que
    /// ainda não tiveram turno.
    public var sistema: String? = nil

    /// Conversa sem título ainda. Guardada vazia, e não com a frase pronta: o título
    /// fica no disco, e uma conversa criada em português não podia aparecer em
    /// português na lista de quem usa o app em alemão.
    public static let semTitulo = ""

    public static func blank() -> ChatThread {
        .init(
            id: UUID().uuidString,
            title: semTitulo,
            updated: .now,
            items: [],
            messages: [],
            usage: TokenUse(),
            lastInput: 0
        )
    }

    public var isEmpty: Bool {
        items.isEmpty && messages.isEmpty
    }
}

/// Conversas em `.odete/chats/<id>.json`.
public final class ChatStore: @unchecked Sendable {
    public let root: URL
    private var dir: URL {
        root.appending(path: ".odete/chats")
    }

    public init(root: URL) {
        self.root = root
    }

    static func title(of items: [ChatItem]) -> String {
        for case let .user(_, text, _) in items {
            let t = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                return t.count > 48 ? String(t.prefix(48)) + "…" : t
            }
        }
        return ChatThread.semTitulo
    }

    public func list() -> [ChatThread] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter { $0.hasSuffix(".json") }
            .compactMap { (try? Data(contentsOf: dir.appending(path: $0))).flatMap { try? dec.decode(
                ChatThread.self,
                from: $0
            ) } }.sorted { $0.updated > $1.updated }
    }

    /// Quantas conversas há, sem abrir nenhuma: a contagem do botão do histórico lia e
    /// decodificava todas as conversas do projeto a cada redesenho do painel.
    public func count() -> Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count { $0.hasSuffix(".json") }
    }

    /// Uma conversa, lida do arquivo dela — e não achada no meio de todas decodificadas.
    public func load(_ id: String) -> ChatThread? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if !id.contains("/"), let d = try? Data(contentsOf: dir.appending(path: "\(id).json")),
           let t = try? dec.decode(ChatThread.self, from: d), t.id == id
        {
            return t
        }
        return list().first { $0.id == id }
    }

    /// Grava e devolve o que ficou gravado — título calculado e hora da gravação —, para
    /// quem salvou não precisar ler o arquivo de volta.
    @discardableResult
    public func save(_ t: ChatThread) -> ChatThread {
        var s = t
        s.items = Self.slim(t.items)
        // Sem o corte fixo de 40: com a compactação a conversa já cabe na janela, e o
        // corte cego podia começar a conversa guardada num resultado de ferramenta sem a
        // chamada — o 400 de toda mensagem seguinte. O teto que sobra é folgado e corta
        // no começo de uma mensagem da pessoa.
        s.messages = Transcricao.consertar(Transcricao.aparar(t.messages, maximo: Self.mensagensGuardadas))
        if s.title == ChatThread.semTitulo {
            s.title = Self.title(of: s.items)
        }
        s.updated = .now
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? enc.encode(s).write(to: dir.appending(path: "\(s.id).json"), options: .atomic)
        return s
    }

    /// Quantas mensagens da conversa (do modelo) ficam no disco, no máximo.
    public static let mensagensGuardadas = 1500

    public func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir.appending(path: "\(id).json"))
    }

    static func slim(_ items: [ChatItem]) -> [ChatItem] {
        items.suffix(80).map { it in
            switch it {
            case let .user(id, text, images): .user(
                    id: id,
                    text: text,
                    images: images?.prefix(2).filter { $0.data.count < 180_000 }
                )
            case let .think(id, text, _): .think(id: id, text: String(text.suffix(8000)), live: false)
            case let .assistant(id, text): .assistant(id: id, text: String(text.prefix(20000)))
            case let .permit(id, n, d, s): s == .pending ? .permit(id: id, name: n, detail: d, status: .no) : it
            default: it
            }
        }
    }
}
