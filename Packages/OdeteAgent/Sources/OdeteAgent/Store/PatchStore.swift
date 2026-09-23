import Foundation
import OdeteCore
import Synchronization

public struct Patch: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable { case pending, accepted, rejected, undone }
    public var id: String
    public var path: String
    /// Texto de antes. Trocar refaz o diff — uma vez, aqui.
    public var before: String {
        get { antes }
        set { antes = newValue; recalcular() }
    }

    /// Texto de depois. Idem.
    public var after: String {
        get { depois }
        set { depois = newValue; recalcular() }
    }

    public var orig: String
    public var status: Status
    public var at: Date
    /// O arquivo não existia antes do patch: rejeitar apaga. `nil` nos patches de antes
    /// desta versão, que decidem pelo texto vazio — ver `PatchStore.restaurar`.
    public var criado: Bool?
    /// O diff, guardado junto com o texto de que ele saiu.
    ///
    /// Eram propriedades calculadas: cada leitura rodava o LCS inteiro. O cartão do patch
    /// lia `additions`, `deletions` e `hunks` — mais uma vez por hunk — a cada redesenho,
    /// e o centro mais duas; com a tabela antiga isso chegava a dezenas de megabytes
    /// alocados por quadro. Agora o diff nasce quando o texto muda e as leituras só leem.
    public private(set) var hunks: [Hunk] = []
    public private(set) var additions = 0
    public private(set) var deletions = 0

    private var antes: String
    private var depois: String

    public init(
        id: String,
        path: String,
        before: String,
        after: String,
        orig: String,
        status: Status,
        at: Date,
        criado: Bool? = nil
    ) {
        self.id = id
        self.path = path
        antes = before
        depois = after
        self.orig = orig
        self.status = status
        self.at = at
        self.criado = criado
        recalcular()
    }

    /// Troca os dois textos com um diff só, em vez de um por atribuição.
    public mutating func trocar(before: String, after: String) {
        antes = before
        depois = after
        recalcular()
    }

    private mutating func recalcular() {
        hunks = LineDiff.hunks(antes, depois)
        var mais = 0, menos = 0
        for h in hunks {
            for l in h.lines {
                switch l {
                case .added: mais += 1
                case .removed: menos += 1
                case .context: break
                }
            }
        }
        additions = mais
        deletions = menos
    }

    enum CodingKeys: String, CodingKey { case id, path, before, after, orig, status, at, criado }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            id: c.decode(String.self, forKey: .id),
            path: c.decode(String.self, forKey: .path),
            before: c.decode(String.self, forKey: .before),
            after: c.decode(String.self, forKey: .after),
            orig: c.decode(String.self, forKey: .orig),
            status: c.decode(Status.self, forKey: .status),
            at: c.decode(Date.self, forKey: .at),
            criado: c.decodeIfPresent(Bool.self, forKey: .criado)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(path, forKey: .path)
        try c.encode(antes, forKey: .before)
        try c.encode(depois, forKey: .after)
        try c.encode(orig, forKey: .orig)
        try c.encode(status, forKey: .status)
        try c.encode(at, forKey: .at)
        try c.encodeIfPresent(criado, forKey: .criado)
    }

    /// Igualdade pelo que o patch é, não pelo diff: o diff sai do texto, e comparar os
    /// hunks de novo seria pagar duas vezes pela mesma resposta.
    public static func == (l: Patch, r: Patch) -> Bool {
        l.id == r.id && l.path == r.path && l.status == r.status && l.at == r.at && l.antes == r.antes
            && l.depois == r.depois && l.orig == r.orig && l.criado == r.criado
    }

    public func hash(into h: inout Hasher) {
        h.combine(id)
        h.combine(path)
        h.combine(status)
        h.combine(antes)
        h.combine(depois)
    }
}

/// O que rejeitar um patch fez.
public enum Rejeicao: Sendable, Equatable {
    /// O arquivo voltou ao que era antes do patch (ou já estava assim).
    case voltou
    /// O arquivo mudou depois do patch: nada foi mexido e o patch continua pendente —
    /// voltar agora levaria junto o que foi feito depois. Quem decide é a pessoa, com
    /// `reject(_:forcar:)` ou `manter(_:)`.
    case conflito
}

/// Patches do agente: pendentes em `.odete/patches.json`, aceitar/rejeitar/desfazer.
///
/// O texto de cada patch mora em arquivo próprio, em `.odete/patches/<id>/`, e o
/// `patches.json` guarda só quem é quem. Antes ia tudo no JSON, e para ele não crescer
/// sem fim só os doze pendentes mais novos e com menos de 80 mil caracteres sobreviviam:
/// o décimo terceiro patch sumia da barra, e "Rejeitar tudo" deixava no disco a mudança
/// que ninguém mais via.
public final class PatchStore: @unchecked Sendable {
    public let root: URL
    private struct Estado {
        var lista: [Patch] = []
        /// Patches cujo texto mudou desde a última gravação.
        var sujos: Set<String> = []
    }

    private let estado = Mutex(Estado())
    public var onChange: (@Sendable () -> Void)?
    private var file: URL {
        root.appending(path: ".odete/patches.json")
    }

    private var pastaDosTextos: URL {
        root.appending(path: ".odete/patches")
    }

    /// Resolvidos que ficam na memória para o cartão da conversa mostrar o estado.
    static let resolvidosNaMemoria = 24

    /// O que vai no `patches.json` desde que os textos saíram de lá.
    private struct Indice: Codable {
        var versao = 2
        var patches: [Entrada]
    }

    private struct Entrada: Codable {
        var id: String
        var path: String
        var status: Patch.Status
        var at: Date
        var criado: Bool?
    }

    public init(root: URL) {
        self.root = root
        let lidos = ler()
        estado.withLock { $0.lista = lidos }
    }

    /// Lê o índice e os textos. Entende também o formato de antes, com os textos dentro do
    /// JSON — e, na primeira gravação, passa esses para arquivos.
    private func ler() -> [Patch] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: file) else { return [] }
        if let indice = try? dec.decode(Indice.self, from: d) {
            return indice.patches.compactMap { e in
                let pasta = pastaDosTextos.appending(path: e.id)
                func texto(_ nome: String) -> String? {
                    try? String(contentsOf: pasta.appending(path: nome), encoding: .utf8)
                }
                guard let antes = texto("before"), let depois = texto("after"), let orig = texto("orig")
                else { return nil }
                return Patch(
                    id: e.id,
                    path: e.path,
                    before: antes,
                    after: depois,
                    orig: orig,
                    status: e.status,
                    at: e.at,
                    criado: e.criado
                )
            }
        }
        let antigos = (try? dec.decode([Patch].self, from: d)) ?? []
        estado.withLock { $0.sujos = Set(antigos.map(\.id)) }
        return antigos
    }

    public var all: [Patch] {
        estado.withLock { $0.lista }
    }

    public var pending: [Patch] {
        all.filter { $0.status == .pending }
    }

    public func get(_ id: String) -> Patch? {
        all.first { $0.id == id }
    }

    public func pending(for path: String) -> Patch? {
        pending.first { $0.path == path }
    }

    /// Grava o índice dos pendentes, os textos que mudaram e apaga a pasta de quem saiu.
    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let fm = FileManager.default
        let (pendentes, sujos): ([Patch], Set<String>) = estado.withLock { st in
            let p = st.lista.filter { $0.status == .pending }
            let s = st.sujos
            st.sujos = []
            return (p, s)
        }
        try? fm.createDirectory(at: pastaDosTextos, withIntermediateDirectories: true)
        for p in pendentes {
            let pasta = pastaDosTextos.appending(path: p.id)
            guard sujos.contains(p.id) || !fm.fileExists(atPath: pasta.appending(path: "orig").path) else { continue }
            try? fm.createDirectory(at: pasta, withIntermediateDirectories: true)
            try? p.before.write(to: pasta.appending(path: "before"), atomically: true, encoding: .utf8)
            try? p.after.write(to: pasta.appending(path: "after"), atomically: true, encoding: .utf8)
            try? p.orig.write(to: pasta.appending(path: "orig"), atomically: true, encoding: .utf8)
        }
        let vivos = Set(pendentes.map(\.id))
        for nome in (try? fm.contentsOfDirectory(atPath: pastaDosTextos.path)) ?? [] where !vivos.contains(nome) {
            try? fm.removeItem(at: pastaDosTextos.appending(path: nome))
        }
        let indice = Indice(patches: pendentes.map {
            Entrada(id: $0.id, path: $0.path, status: $0.status, at: $0.at, criado: $0.criado)
        })
        try? enc.encode(indice).write(to: file, options: .atomic)
        onChange?()
    }

    private func update(_ id: String, textoMudou: Bool = false, _ f: (inout Patch) -> Void) {
        estado.withLock { st in
            if let i = st.lista.firstIndex(where: { $0.id == id }) {
                f(&st.lista[i])
                if textoMudou {
                    st.sujos.insert(id)
                }
            }
        }
        save()
    }

    /// Enfileira (ou funde com o pendente do mesmo caminho). O arquivo já foi escrito com
    /// `after`. `criado`: o arquivo não existia antes desta escrita; sem dizer, vale a
    /// leitura de antes — `antes` vazio é arquivo novo.
    @discardableResult
    public func queue(path: String, before: String, after: String, criado: Bool? = nil) -> Patch {
        let result: Patch = estado.withLock { st in
            if let i = st.lista.firstIndex(where: { $0.status == .pending && $0.path == path }) {
                // Fundir não muda de onde o arquivo partiu: o `antes` que vale é o do
                // primeiro patch, e com ele quem sabe se o arquivo foi criado.
                st.lista[i].trocar(before: st.lista[i].before, after: after)
                st.sujos.insert(st.lista[i].id)
                return st.lista[i]
            }
            let p = Patch(
                id: UUID().uuidString,
                path: path,
                before: before,
                after: after,
                orig: before,
                status: .pending,
                at: .now,
                criado: criado
            )
            // Pendente não sai por idade: sem teto. Só os resolvidos, que já não mexem
            // em nada, ficam limitados na memória.
            let resolvidos = st.lista.filter { $0.status != .pending }.suffix(Self.resolvidosNaMemoria)
            let pendentes = st.lista.filter { $0.status == .pending }
            st.lista = Array(resolvidos) + pendentes + [p]
            st.sujos.insert(p.id)
            return p
        }
        save()
        return result
    }

    /// Como o arquivo está no disco agora.
    enum NoDisco: Equatable {
        case ausente
        case texto(String)
        /// Existe, mas não lê como UTF-8.
        case outro
    }

    func noDisco(_ path: String) -> NoDisco {
        let u = root.appending(path: path)
        guard FileManager.default.fileExists(atPath: u.path) else { return .ausente }
        return (try? String(contentsOf: u, encoding: .utf8)).map(NoDisco.texto) ?? .outro
    }

    private func write(_ path: String, _ text: String) {
        let u = root.appending(path: path)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        HistoricoDeArquivos.guardar(u, raiz: root, origem: .agente)
        try? text.write(to: u, atomically: true, encoding: .utf8)
    }

    /// Aceitar só marca: o disco já tem o `depois`, porque o agente escreveu antes de
    /// perguntar.
    ///
    /// Gravar o `depois` de novo por cima do que estivesse lá perdia o que a pessoa
    /// editou no arquivo entre o patch e o aceite. A única vez em que aceitar escreve é
    /// quando o disco está exatamente no `antes` — a mudança não chegou lá (um desfazer
    /// de turno voltou o arquivo) e não há edição de ninguém para perder.
    public func accept(_ id: String) {
        guard let p = get(id), p.status == .pending else { return }
        if p.before != p.after, noDisco(p.path) == .texto(p.before) {
            write(p.path, p.after)
        }
        update(id) { $0.status = .accepted }
    }

    /// Aceita um hunk: ele passa a fazer parte do `antes`, e o patch fica com o resto.
    ///
    /// O disco não é tocado. Antes gravava `antes + este hunk` no arquivo — o que tirava
    /// do disco os outros hunks, ainda pendentes, e qualquer coisa que a pessoa tivesse
    /// escrito no arquivo depois do patch.
    public func acceptHunk(_ id: String, index: Int) {
        guard let p = get(id), p.status == .pending else { return }
        if p.hunks.count <= 1 {
            accept(id); return
        }
        let next = LineDiff.applyOnly(hunk: index, before: p.before, after: p.after)
        // Disco no `antes`: a mudança não está lá, então este hunk entra agora.
        if noDisco(p.path) == .texto(p.before) {
            write(p.path, next)
        }
        // Trocar `before` já refaz o diff; o que sobrou é o que ele diz.
        update(id, textoMudou: true) {
            $0.before = next
            if $0.hunks.isEmpty {
                $0.status = .accepted
            }
        }
    }

    /// Rejeita: o arquivo volta ao `antes` do patch.
    ///
    /// Só volta sozinho quando o disco ainda está como o agente deixou. Se a pessoa
    /// mexeu depois, antes marcava "rejeitado" e deixava o arquivo como estava — o patch
    /// sumia da tela com a mudança ainda no disco, sem aviso. Agora devolve `.conflito` e
    /// não mexe em nada; `forcar` volta assim mesmo.
    @discardableResult
    public func reject(_ id: String, forcar: Bool = false) -> Rejeicao {
        guard let p = get(id), p.status == .pending else { return .voltou }
        let disco = noDisco(p.path)
        // "Voltar" de um arquivo criado pelo patch é ele não existir.
        let jaVoltou = ehCriacao(p) && p.before.isEmpty ? disco == .ausente : disco == .texto(p.before)
        if !jaVoltou {
            let comoOAgenteDeixou = disco == .texto(p.after)
            guard comoOAgenteDeixou || forcar else { return .conflito }
            restaurar(p, para: p.before)
        }
        update(id) { $0.status = .rejected }
        return .voltou
    }

    /// Deixa o arquivo como está e tira o patch da fila: a saída para quem, no conflito,
    /// prefere o que está no disco.
    public func manter(_ id: String) {
        guard let p = get(id), p.status == .pending else { return }
        update(id) { $0.status = .rejected }
    }

    public func undo(_ id: String) {
        guard let p = get(id) else { return }
        restaurar(p, para: p.orig)
        update(id) { $0.status = .undone }
    }

    /// O arquivo nasceu com o patch?
    private func ehCriacao(_ p: Patch) -> Bool {
        p.criado ?? (p.orig.isEmpty && p.before.isEmpty)
    }

    /// Volta `p.path` para `texto` — ou apaga, se o arquivo nasceu com o patch e o texto
    /// de volta é o vazio de antes dele.
    private func restaurar(_ p: Patch, para texto: String) {
        let u = root.appending(path: p.path)
        HistoricoDeArquivos.guardar(u, raiz: root, origem: .patchRejeitado)
        if ehCriacao(p), texto.isEmpty {
            // Arquivo que não é texto não foi o agente que deixou: não se apaga.
            if noDisco(p.path) != .outro {
                try? FileManager.default.removeItem(at: u)
            }
            return
        }
        write(p.path, texto)
    }

    public func acceptAll() {
        for p in pending {
            accept(p.id)
        }
    }

    /// Rejeita todos; devolve os que ficaram em conflito (pendentes, sem mexer).
    @discardableResult
    public func rejectAll(forcar: Bool = false) -> [Patch] {
        var conflitos: [Patch] = []
        for p in pending.reversed() where reject(p.id, forcar: forcar) == .conflito {
            conflitos.append(p)
        }
        return conflitos.reversed()
    }
}
