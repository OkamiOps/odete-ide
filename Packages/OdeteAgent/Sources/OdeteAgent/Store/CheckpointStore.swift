import Foundation
import OdeteCore
import OdeteI18n
import Synchronization

public struct Checkpoint: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var title: String
    public var at: Date
    public var paths: [String]
    public var saved: [String]
    /// Arquivos que o agente mexeu no turno, copiados antes da primeira escrita.
    public var capturados: [String] = []
    /// Arquivos que não existiam antes do turno: desfazer apaga.
    public var criados: [String] = []
    /// Pastas que nasceram junto com os criados: desfazer tira as que ficarem vazias.
    public var pastasCriadas: [String] = []
    /// Grandes demais para guardar (mais de `CheckpointStore.tetoPorArquivo`).
    public var grandes: [String] = []

    public init(id: String, title: String, at: Date, paths: [String], saved: [String]) {
        self.id = id
        self.title = title
        self.at = at
        self.paths = paths
        self.saved = saved
    }

    /// O manifesto é o mesmo de sempre; o que o turno escreveu mora ao lado, em
    /// `escritas.json`, e é regravado a cada arquivo novo — ver `CheckpointStore.capturar`.
    enum CodingKeys: String, CodingKey { case id, title, at, paths, saved }
}

/// O que o turno escreveu, em `.odete/checkpoints/<id>/escritas.json`.
///
/// Fora do manifesto porque o manifesto carrega a lista de todos os caminhos do projeto:
/// regravá-lo a cada arquivo que o agente toca seria reescrever milhares de linhas para
/// acrescentar uma.
struct Escritas: Codable {
    var capturados: [String] = []
    var criados: [String] = []
    var pastasCriadas: [String] = []
    var grandes: [String] = []
}

/// Snapshot dos arquivos antes de cada turno, em `.odete/checkpoints/<id>/`.
///
/// São duas redes, porque cada uma pega o que a outra deixa passar:
///
/// - **O retrato do começo** (`take`): os primeiros arquivos pequenos do projeto, copiados
///   antes de o turno começar. É o que cobre o que o shell muda por conta própria — um
///   `npm run` que reescreve um arquivo, um `git checkout` — sem ninguém avisar.
/// - **A cópia na escrita** (`capturar`): antes de uma ferramenta do agente escrever num
///   arquivo, o original dele é guardado, se ainda não foi. Sem limite de quantidade e
///   com teto folgado de tamanho. O retrato sozinho parava nos 220 primeiros arquivos
///   com menos de 200 kB: o agente editava o 221º, ou um arquivo grande, e o "desfazer
///   último turno" voltava tudo menos justamente o que ele tinha mudado.
public final class CheckpointStore: @unchecked Sendable {
    public let root: URL
    public let host: ToolHost
    private var dir: URL {
        root.appending(path: ".odete/checkpoints")
    }

    public var limit = 8
    /// Acima disso o arquivo não é copiado: fica anotado, e o desfazer avisa.
    public static let tetoPorArquivo = 10_000_000
    private static let counter = Mutex(0)

    private struct Estado {
        /// Os checkpoints do disco, do mais novo para o mais velho. `nil` até a primeira
        /// leitura: a lista era relida e decodificada a cada redesenho do botão de desfazer.
        var lista: [Checkpoint]?
        /// O checkpoint do turno em andamento, que recebe as cópias na escrita.
        var atual: String?
        /// Caminhos que já têm destino no turno atual: retratados, copiados, anotados como
        /// novos ou grandes. A segunda escrita no mesmo arquivo não copia de novo — a
        /// cópia que vale é a de antes da primeira.
        var conhecidos: Set<String> = []
        /// Os caminhos que existiam no começo do turno.
        var doComeco: Set<String> = []
    }

    private let estado = Mutex(Estado())

    public init(root: URL, host: ToolHost) {
        self.root = root; self.host = host
    }

    public func list() -> [Checkpoint] {
        estado.withLock { lista(&$0) }
    }

    private func lista(_ st: inout Estado) -> [Checkpoint] {
        if let l = st.lista {
            return l
        }
        let l = lerDoDisco()
        st.lista = l
        return l
    }

    private func lerDoDisco() -> [Checkpoint] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return ids
            .compactMap { id -> Checkpoint? in
                guard let d = try? Data(contentsOf: dir.appending(path: "\(id)/manifest.json")),
                      var cp = try? dec.decode(Checkpoint.self, from: d) else { return nil }
                if let e = try? Data(contentsOf: dir.appending(path: "\(id)/escritas.json")),
                   let escritas = try? JSONDecoder().decode(Escritas.self, from: e)
                {
                    cp.capturados = escritas.capturados
                    cp.criados = escritas.criados
                    cp.pastasCriadas = escritas.pastasCriadas
                    cp.grandes = escritas.grandes
                }
                return cp
            }.sorted { $0.id > $1.id }
    }

    public var last: Checkpoint? {
        list().first
    }

    /// Copia os arquivos (sem ruído, < 200 kB, até 220), grava o manifesto e abre o turno
    /// para as cópias na escrita.
    @discardableResult
    public func take(title: String) -> Checkpoint {
        let id = String(
            format: "%013ld-%06ld",
            Int(Date().timeIntervalSince1970 * 1000),
            Self.counter.withLock { $0 += 1; return $0 }
        )
        let paths = host.allPaths()
        var saved: [String] = []
        let fm = FileManager.default
        for p in paths.prefix(220) {
            let src = root.appending(path: p)
            guard let size = (try? fm.attributesOfItem(atPath: src.path)[.size]) as? Int,
                  size < 200_000 else { continue }
            let dst = dir.appending(path: "\(id)/files/\(p)")
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil {
                saved.append(p)
            }
        }
        let cp = Checkpoint(id: id, title: title, at: .now, paths: paths, saved: saved)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? fm.createDirectory(at: dir.appending(path: id), withIntermediateDirectories: true)
        try? enc.encode(cp).write(to: dir.appending(path: "\(id)/manifest.json"), options: .atomic)
        estado.withLock { st in
            // A lista pode ter acabado de ser lida do disco, já com o manifesto novo.
            var l = lista(&st).filter { $0.id != id }
            l.insert(cp, at: 0)
            st.lista = l
            st.atual = id
            st.conhecidos = Set(saved)
            st.doComeco = Set(paths)
            limpar(&st)
        }
        return cp
    }

    /// Guarda o original de `caminho` no checkpoint do turno, antes de uma ferramenta
    /// escrever nele. Chamar de novo para o mesmo caminho não faz nada.
    ///
    /// Pasta entra inteira (o `rm -r` do shell), menos o ruído — `node_modules` volta
    /// com um `npm install`, e copiá-lo a cada turno seria pior que perdê-lo.
    public func capturar(_ caminho: String) {
        let p = Self.limpo(caminho)
        guard !p.isEmpty, !p.split(separator: "/").contains("..") else { return }
        estado.withLock { st in
            guard let id = st.atual, var l = st.lista, let i = l.firstIndex(where: { $0.id == id }) else { return }
            var cp = l[i]
            let antes = (cp.capturados.count, cp.criados.count, cp.grandes.count)
            for alvo in expandir(p) {
                capturar(alvo, em: &cp, estado: &st)
            }
            guard antes != (cp.capturados.count, cp.criados.count, cp.grandes.count) else { return }
            l[i] = cp
            st.lista = l
            let escritas = Escritas(
                capturados: cp.capturados,
                criados: cp.criados,
                pastasCriadas: cp.pastasCriadas,
                grandes: cp.grandes
            )
            try? JSONEncoder().encode(escritas).write(
                to: dir.appending(path: "\(id)/escritas.json"),
                options: .atomic
            )
        }
    }

    private func capturar(_ p: String, em cp: inout Checkpoint, estado st: inout Estado) {
        guard !st.conhecidos.contains(p) else { return }
        let fm = FileManager.default
        let src = root.appending(path: p)
        var pasta: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &pasta) else {
            st.conhecidos.insert(p)
            // Sumiu no meio do turno algo que existia no começo: não há o que copiar, e
            // apagar o que o agente puser no lugar perderia o pouco que sobrou.
            guard !st.doComeco.contains(p) else { return }
            cp.criados.append(p)
            // As pastas que a escrita vai criar. Anotadas agora, que ainda não existem:
            // depois não dá mais para saber quais já estavam lá.
            var pai = (p as NSString).deletingLastPathComponent
            while !pai.isEmpty, !fm.fileExists(atPath: root.appending(path: pai).path) {
                if !cp.pastasCriadas.contains(pai) {
                    cp.pastasCriadas.append(pai)
                }
                pai = (pai as NSString).deletingLastPathComponent
            }
            return
        }
        if pasta.boolValue {
            st.conhecidos.insert(p)
            guard !Ignore.isNoisePath(p),
                  let e = fm.enumerator(at: src, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
            let base = root.standardizedFileURL.path + "/"
            while let u = e.nextObject() as? URL {
                let rel = String(u.standardizedFileURL.path.dropFirst(base.count))
                if Ignore.isNoisePath(rel) {
                    e.skipDescendants(); continue
                }
                if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    capturar(rel, em: &cp, estado: &st)
                }
            }
            return
        }
        st.conhecidos.insert(p)
        let tamanho = ((try? fm.attributesOfItem(atPath: src.path)[.size]) as? Int) ?? 0
        guard tamanho <= Self.tetoPorArquivo else {
            cp.grandes.append(p)
            return
        }
        let dst = dir.appending(path: "\(cp.id)/files/\(p)")
        try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: dst)
        if (try? fm.copyItem(at: src, to: dst)) != nil {
            cp.capturados.append(p)
        }
    }

    /// Volta os arquivos ao começo do turno e tira o checkpoint da pilha.
    ///
    /// Na ordem: o que nasceu no turno sai; o retrato do começo volta; os arquivos
    /// copiados na escrita voltam byte a byte; as pastas que o turno criou e ficaram vazias
    /// saem. Depois o checkpoint some — o próximo desfazer volta o turno anterior, em vez
    /// de repetir este por cima do que a pessoa já tiver mexido.
    public func restore(_ id: String) -> String {
        estado.withLock { st in
            guard let cp = lista(&st).first(where: { $0.id == id }) else { return "checkpoint sumiu" }
            let fm = FileManager.default
            let doComeco = Set(cp.paths)
            for p in host.allPaths() where !doComeco.contains(p) {
                try? fm.removeItem(at: root.appending(path: p))
            }
            for p in cp.criados {
                try? fm.removeItem(at: root.appending(path: p))
            }
            for p in cp.saved + cp.capturados {
                let src = dir.appending(path: "\(cp.id)/files/\(p)"), dst = root.appending(path: p)
                guard fm.fileExists(atPath: src.path) else { continue }
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                try? fm.copyItem(at: src, to: dst)
            }
            // Das mais fundas para as mais rasas: `src/a/b` sai antes de `src/a`.
            for pasta in cp.pastasCriadas.sorted(by: { $0.count > $1.count }) {
                let u = root.appending(path: pasta)
                if (try? fm.contentsOfDirectory(atPath: u.path))?.isEmpty == true {
                    try? fm.removeItem(at: u)
                }
            }
            try? fm.removeItem(at: dir.appending(path: cp.id))
            st.lista = lista(&st).filter { $0.id != cp.id }
            if st.atual == cp.id {
                st.atual = nil
                st.conhecidos = []
                st.doComeco = []
            }
            var msg = "voltou: \(cp.title)"
            if !cp.grandes.isEmpty {
                msg += "\n" + tr(
                    "Não voltaram, por passarem de 10 MB: %1$@",
                    cp.grandes.joined(separator: ", ")
                )
            }
            return msg
        }
    }

    /// Mantém os `limit` checkpoints mais novos e apaga todo o resto da pasta.
    ///
    /// Antes só saíam os que tinham manifesto legível: um turno interrompido no meio da
    /// cópia deixava uma pasta sem manifesto, que nunca aparecia na lista e por isso
    /// nunca era apagada — e cada uma delas carrega até 220 arquivos.
    private func limpar(_ st: inout Estado) {
        let fm = FileManager.default
        let manter = Array(lista(&st).prefix(max(1, limit)))
        let ids = Set(manter.map(\.id))
        for nome in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !ids.contains(nome) {
            try? fm.removeItem(at: dir.appending(path: nome))
        }
        st.lista = manter
    }

    /// `src/*.js` vira os arquivos que casam, como o shell faria. Só o último pedaço do
    /// caminho pode ter curinga — é o caso de `rm *.log`, e o resto não vale a conta.
    private func expandir(_ p: String) -> [String] {
        let nome = (p as NSString).lastPathComponent
        guard nome.contains(where: { "*?[".contains($0) }) else { return [p] }
        let pai = (p as NSString).deletingLastPathComponent
        let pasta = pai.isEmpty ? root : root.appending(path: pai)
        let nomes = (try? FileManager.default.contentsOfDirectory(atPath: pasta.path)) ?? []
        return nomes.filter { fnmatch(nome, $0, 0) == 0 }.map { pai.isEmpty ? $0 : pai + "/" + $0 }
    }

    static func limpo(_ p: String) -> String {
        var s = p.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("/") {
            s.removeFirst()
        }
        while s.hasPrefix("./") {
            s.removeFirst(2)
        }
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
}
