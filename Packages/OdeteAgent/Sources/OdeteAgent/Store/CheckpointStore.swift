import Foundation
import OdeteCore
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
    /// O que cada caminho escrito pelo turno tinha logo depois da escrita: o resumo do
    /// conteúdo, ou vazio se ficou apagado. `nil` nos turnos de antes desta versão.
    ///
    /// É o que deixa desfazer com segurança um turno que não chegou ao fim — o app fechou
    /// no meio e o fim do turno nunca foi anotado: só volta o que ainda está como o agente
    /// deixou.
    public var depois: [String: String]?

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
    /// Opcional para os `escritas.json` de antes continuarem legíveis — ver `Checkpoint.depois`.
    var depois: [String: String]?

    init(_ cp: Checkpoint) {
        capturados = cp.capturados
        criados = cp.criados
        pastasCriadas = cp.pastasCriadas
        grandes = cp.grandes
        depois = cp.depois
    }
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
///
/// E um retrato do fim (`encerrar`): como cada arquivo ficou quando o turno terminou, e
/// quais o turno mexeu. É ele que separa o turno do que a pessoa fez depois. Desfazer
/// apagava tudo o que não existia no começo do turno — inclusive o arquivo que a pessoa
/// criou depois — e sobrescrevia com o conteúdo de antes o arquivo que ela editou depois.
/// Agora só sai o que o turno criou, só volta o que o turno mudou, e o que a pessoa mexeu
/// depois fica como ela deixou, com o aviso na conversa.
public final class CheckpointStore: @unchecked Sendable {
    public let root: URL
    public let host: ToolHost
    var dir: URL {
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
        /// Tamanho e hora de cada arquivo no começo do turno. É comparando com isto, no fim,
        /// que se sabe o que o shell mudou sem ninguém avisar.
        var inicio: [String: Assinatura] = [:]
        /// Quando o shell do agente rodou comandos que escrevem, em nanossegundos, já com a
        /// folga. Mudança fora dessas janelas não é do turno — ver `FimDoTurno.medir`.
        var janelas: [ClosedRange<Int64>] = []
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
                    cp.depois = escritas.depois
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
        // Um `stat` por arquivo, sem ler conteúdo: é o que diz, no fim, o que mudou.
        var inicio: [String: Assinatura] = [:]
        for p in paths {
            inicio[p] = Assinatura.de(root.appending(path: p))
        }
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
        var cp = Checkpoint(id: id, title: title, at: .now, paths: paths, saved: saved)
        cp.depois = [:]
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
            st.inicio = inicio
            st.janelas = []
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
            gravarEscritas(cp)
        }
    }

    private func gravarEscritas(_ cp: Checkpoint) {
        try? JSONEncoder().encode(Escritas(cp)).write(
            to: dir.appending(path: "\(cp.id)/escritas.json"),
            options: .atomic
        )
    }

    /// Mexe no checkpoint do turno em andamento, se houver um, e regrava `escritas.json`.
    private func noTurno(_ mudar: (inout Checkpoint, inout Estado) -> Void) {
        estado.withLock { st in
            guard let id = st.atual, var l = st.lista, let i = l.firstIndex(where: { $0.id == id }) else { return }
            var cp = l[i]
            mudar(&cp, &st)
            l[i] = cp
            st.lista = l
            gravarEscritas(cp)
        }
    }

    /// Anota o que uma ferramenta do agente acabou de deixar em `caminho` — ver
    /// `Checkpoint.depois`.
    public func anotarEscrita(_ caminho: String) {
        let p = Self.limpo(caminho)
        guard !p.isEmpty else { return }
        noTurno { cp, _ in
            var d = cp.depois ?? [:]
            d[p] = Assinatura.resumir(root.appending(path: p)) ?? ""
            cp.depois = d
        }
    }

    /// Antes de o shell do agente rodar um comando que escreve: guarda o original do que dá
    /// para saber que ele vai tocar e devolve a hora em que a janela do comando abre.
    public func antesDoShell(_ alvos: [String]) -> Int64 {
        for alvo in alvos {
            capturar(alvo)
        }
        return Assinatura.agora()
    }

    /// O comando terminou: fecha a janela aberta em `desde` e anota o que ficou nos
    /// caminhos que ele tocou.
    ///
    /// A janela é o que faz o arquivo que o shell criou sem ninguém saber — um gerador de
    /// código, um `npm init` — sair no desfazer, e o arquivo que a pessoa criou no editor
    /// enquanto o agente trabalhava ficar. (`dist/`, `build/` e afins são ruído: o projeto
    /// não os vê, e o desfazer também não.)
    public func depoisDoShell(desde: Int64, alvos: [String]) {
        let limpos = alvos.map(Self.limpo).filter { !$0.isEmpty }
        noTurno { cp, st in
            st.janelas.append((desde - FimDoTurno.folga) ... (Assinatura.agora() + FimDoTurno.folga))
            var d = cp.depois ?? [:]
            for p in Set(cp.capturados + cp.criados) where limpos.contains(where: { Self.casa(p, $0) }) {
                let u = root.appending(path: p)
                d[p] = FileManager.default.fileExists(atPath: u.path) ? Assinatura.resumir(u) ?? "" : ""
            }
            cp.depois = d
        }
    }

    /// `p` é `alvo`, está dentro dele, ou casa com o curinga dele.
    static func casa(_ p: String, _ alvo: String) -> Bool {
        if p == alvo || p.hasPrefix(alvo + "/") {
            return true
        }
        return alvo.contains { "*?[".contains($0) } && fnmatch(alvo, p, 0) == 0
    }

    /// Fecha o turno: anota como cada arquivo ficou e quais o turno mexeu.
    ///
    /// Vale para todo fim — resposta, erro, parada no meio. Depois disto o checkpoint não
    /// recebe mais cópia nenhuma: o que mudar dali em diante é da pessoa.
    public func encerrar() {
        estado.withLock { st in
            defer {
                st.atual = nil
                st.conhecidos = []
                st.doComeco = []
                st.inicio = [:]
                st.janelas = []
            }
            guard let id = st.atual, let cp = st.lista?.first(where: { $0.id == id }) else { return }
            let fim = FimDoTurno.medir(
                cp,
                raiz: root,
                caminhos: host.allPaths(),
                inicio: st.inicio,
                janelas: st.janelas
            )
            try? JSONEncoder().encode(fim).write(to: dir.appending(path: "\(id)/fim.json"), options: .atomic)
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

    /// Volta o turno e tira o checkpoint da pilha; devolve a mensagem para a conversa.
    public func restore(_ id: String) -> String {
        desfazer(id)?.mensagem ?? "checkpoint sumiu"
    }

    /// O que desfazer o turno `id` faria agora, sem mexer em nada. É o que a tela usa para
    /// perguntar antes, quando a pessoa mexeu depois do turno em algo que ele tocou.
    /// `manter`: ver `planejar`.
    public func previa(_ id: String, manter: Set<String> = []) -> VoltaDoTurno? {
        estado.withLock { st in
            lista(&st).first(where: { $0.id == id }).map { planejar($0, manter: manter) }
        }
    }

    /// Volta o turno e tira o checkpoint da pilha.
    ///
    /// Só o que o turno mexeu: o que ele criou sai, o que ele mudou volta, e as pastas que
    /// ele criou e ficaram vazias saem. O que a pessoa mexeu depois fica como ela deixou e
    /// vai listado no resultado — ver `planejar`. A varredura de antes (apagar tudo o que
    /// não existia no começo do turno, voltar todo o retrato do começo) não existe mais: era
    /// ela que levava junto o arquivo que a pessoa criou e a edição que ela fez depois.
    ///
    /// Depois o checkpoint some: o próximo desfazer volta o turno anterior, em vez de
    /// repetir este por cima do que a pessoa já tiver mexido.
    public func desfazer(_ id: String, manter: Set<String> = []) -> VoltaDoTurno? {
        estado.withLock { st in
            guard let cp = lista(&st).first(where: { $0.id == id }) else { return nil }
            let volta = planejar(cp, manter: manter)
            aplicar(volta, de: cp)
            try? FileManager.default.removeItem(at: dir.appending(path: cp.id))
            st.lista = lista(&st).filter { $0.id != cp.id }
            if st.atual == cp.id {
                st.atual = nil
                st.conhecidos = []
                st.doComeco = []
                st.inicio = [:]
                st.janelas = []
            }
            return volta
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
