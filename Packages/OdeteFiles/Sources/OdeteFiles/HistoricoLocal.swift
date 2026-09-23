import CryptoKit
import Foundation
import OdeteCore
import OdeteI18n

/// Histórico local por arquivo, como o Local History do VS Code e do JetBrains: antes de
/// qualquer coisa sobrescrever ou apagar um arquivo do projeto, o conteúdo de então é
/// guardado aqui.
///
/// Mora em `Application Support/Odete/Historico`, fora do projeto e fora do iCloud: não
/// sincroniza, não entra no git nem no zip, e não suja a árvore. Cada projeto tem a sua
/// pasta, e cada arquivo a sua dentro dela:
///
///     Historico/<projeto>/<sha256 do caminho>/indice.json   caminho e versões
///     Historico/<projeto>/<sha256 do caminho>/<sha256>.lzfse   conteúdo, comprimido
///
/// O conteúdo tem o nome do próprio hash, então a mesma versão guardada duas vezes (o
/// A → B → A de quem desfaz e refaz) ocupa o disco uma vez só. A deduplicação é por
/// arquivo, e não por projeto, de propósito: assim podar um arquivo nunca precisa ler o
/// índice dos outros para saber se um conteúdo ainda está em uso.
///
/// Tudo passa por uma trava só. É curto — ler o arquivo, um hash, gravar dois arquivos
/// pequenos — e acontece no máximo uma vez por gravação, que já é uma escrita em disco.
public final class HistoricoLocal: GuardaDeVersoes, @unchecked Sendable {
    public typealias Origem = OrigemDaVersao

    /// Quanto se guarda. Os números são os do VS Code, com teto de espaço porque aqui o
    /// disco é de um iPad.
    public struct Politica: Sendable {
        public var versoesPorArquivo = 50
        public var diasPorVersao = 30
        /// Somando todos os projetos. Passou, as versões mais velhas saem primeiro. Em MB
        /// de mil, que é como a tela mostra tamanho: 1024 × 1024 aparecia como "314,6 MB".
        public var tetoTotal = 300_000_000
        /// Arquivo maior que isto não entra: é gerado, é mídia, ou é um banco — e cinquenta
        /// cópias dele comeriam o teto de uma vez.
        public var maiorArquivo = 5_000_000
        /// Com o salvamento automático o editor grava a cada pausa na digitação. Guardar
        /// uma versão por pausa enche o histórico de passos que ninguém quer de volta, então
        /// a edição contínua vira no máximo uma versão por este intervalo.
        public var intervaloDeEdicao: TimeInterval = 60
        /// Uma pasta apagada com milhares de arquivos não pode travar quem apagou. O que
        /// passar disto numa chamada fica de fora (a lixeira do projeto ainda tem a pasta).
        public var arquivosPorChamada = 2000
        /// Pastas que não entram: o que o npm ou o build refazem, e o que já tem histórico
        /// próprio (`.git`) ou é do app (`.odete`).
        public var pastasIgnoradas: Set<String> = Ignore.noiseDirs.union([
            "node_modules", Ignore.modulosForaDaNuvem, "dist", "build", ".git", ".odete", ".next", ".astro",
        ])

        public init() {}

        public static let padrao = Politica()
    }

    /// Uma versão guardada: o conteúdo de antes de `origem` mexer no arquivo.
    public struct Versao: Codable, Sendable, Hashable, Identifiable {
        public var id: String
        public var hash: String
        public var data: Date
        public var origem: Origem
        /// Bytes do conteúdo original, sem a compressão.
        public var tamanho: Int
    }

    /// Arquivo que não existe mais no projeto e tem versões guardadas.
    public struct ArquivoApagado: Sendable, Hashable, Identifiable {
        public var caminho: String
        /// A mais nova — em geral a de logo antes de apagar.
        public var ultima: Versao
        public var versoes: Int
        public var id: String {
            caminho
        }
    }

    struct Indice: Codable {
        var caminho: String
        /// Da mais velha para a mais nova.
        var versoes: [Versao]
    }

    // MARK: estado

    public let pasta: URL
    private var politica: Politica
    private let agora: @Sendable () -> Date
    private let defaults: UserDefaults?
    private let trava = NSLock()
    private let fila = DispatchQueue(label: "odete.historico-local", qos: .utility)
    /// Raiz do projeto → id da pasta do projeto aqui dentro.
    private var ids: [String: String] = [:]
    /// Raízes vistas nesta sessão, para achar o projeto de uma URL que chega sem raiz.
    private var raizes: [URL] = []
    /// O que o editor gravou por último em cada arquivo — ver `anotarEscrita`.
    private var escritoPeloEditor: [String: String] = [:]
    /// Soma do que está guardado, quando já se sabe. Guardar só soma; podar recalcula.
    private var total: Int?
    private var podaAgendada = false

    static let chaveDoTeto = "odete.historicoLocal.teto"

    public static var pastaPadrao: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Odete/Historico", directoryHint: .isDirectory)
    }

    /// O do app. Nascer já instala a porta de entrada de OdeteCore, para o agente, o git
    /// e o shell guardarem também — e `FileOps` usa este por padrão, então basta abrir um
    /// projeto para tudo estar ligado.
    public static let compartilhado: HistoricoLocal = {
        let h = HistoricoLocal(pasta: pastaPadrao, defaults: .standard)
        HistoricoDeArquivos.instalar(h)
        h.manutencaoSePreciso()
        return h
    }()

    /// `defaults` guarda o teto escolhido nos Ajustes; sem ele (testes), vale a política.
    public init(
        pasta: URL,
        politica: Politica = .padrao,
        defaults: UserDefaults? = nil,
        agora: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pasta = pasta
        var p = politica
        if let teto = defaults?.object(forKey: Self.chaveDoTeto) as? Int, teto > 0 {
            p.tetoTotal = teto
        }
        self.politica = p
        self.agora = agora
        self.defaults = defaults
    }

    /// Teto de espaço de todos os projetos juntos. Baixar poda na hora.
    public var teto: Int {
        get { trava.withLock { politica.tetoTotal } }
        set {
            trava.withLock { politica.tetoTotal = newValue }
            defaults?.set(newValue, forKey: Self.chaveDoTeto)
            podarSePassou()
        }
    }

    /// Anota a raiz de um projeto aberto. Quem guarda sem dizer a raiz (o `npm install`
    /// reescrevendo o package.json) é achado por ela.
    public func conhecer(_ raiz: URL) {
        trava.withLock { conhecerSemTrava(raiz) }
    }

    private func conhecerSemTrava(_ raiz: URL) {
        let p = raiz.standardizedFileURL.path
        if !raizes.contains(where: { $0.standardizedFileURL.path == p }) {
            raizes.append(raiz)
        }
    }

    // MARK: guardar

    public func guardar(_ urls: [URL], raiz: URL?, origem: Origem) {
        trava.withLock {
            var restantes = politica.arquivosPorChamada
            for u in urls {
                guard restantes > 0, let r = raiz ?? acharRaiz(u) else { continue }
                conhecerSemTrava(r)
                guardarCaminho(u, raiz: r, origem: origem, restantes: &restantes)
            }
        }
        podarSePassou()
    }

    public func guardar(texto: String, de url: URL, raiz: URL?, origem: Origem) {
        trava.withLock {
            guard let r = raiz ?? acharRaiz(url), let rel = relativo(url, raiz: r), !ignorado(rel) else { return }
            conhecerSemTrava(r)
            let dados = Data(texto.utf8)
            guard dados.count <= politica.maiorArquivo else { return }
            registrar(dados, caminho: rel, projeto: projeto(r), origem: origem)
        }
        podarSePassou()
    }

    /// O que o editor acabou de gravar. É o que permite agrupar o salvamento automático
    /// sem perder nada: a versão do minuto só é pulada se o disco ainda tem exatamente o
    /// que o próprio editor escreveu. Se o agente, o git ou o terminal mexeram no meio, o
    /// conteúdo é outro e é guardado.
    public func anotarEscrita(_ url: URL, raiz: URL, dados: Data) {
        let hash = Self.hash(dados)
        trava.withLock {
            guard let rel = relativo(url, raiz: raiz) else { return }
            escritoPeloEditor[chave(projeto(raiz), rel)] = hash
        }
    }

    private func guardarCaminho(_ u: URL, raiz: URL, origem: Origem, restantes: inout Int) {
        let fm = FileManager.default
        var ehPasta: ObjCBool = false
        // Link quebrado ou arquivo que ainda não existe: não há o que guardar.
        guard fm.fileExists(atPath: u.path, isDirectory: &ehPasta) else { return }
        guard ehPasta.boolValue else {
            restantes -= 1
            guardarArquivo(u, raiz: raiz, origem: origem)
            return
        }
        // Link para pasta não é seguido: o destino pode estar fora do projeto. E a pasta
        // ignorada (apagar `node_modules`) não é percorrida.
        let ehRaiz = u.standardizedFileURL.path == raiz.standardizedFileURL.path
        guard (try? fm.destinationOfSymbolicLink(atPath: u.path)) == nil,
              ehRaiz || relativo(u, raiz: raiz).map({ !pastaIgnorada($0) }) == true,
              let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey])
        else { return }
        while restantes > 0, let f = e.nextObject() as? URL {
            let valores = try? f.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if valores?.isDirectory == true {
                if politica.pastasIgnoradas.contains(f.lastPathComponent) {
                    e.skipDescendants()
                }
                continue
            }
            guard valores?.isRegularFile == true else { continue }
            restantes -= 1
            guardarArquivo(f, raiz: raiz, origem: origem)
        }
    }

    private func guardarArquivo(_ u: URL, raiz: URL, origem: Origem) {
        guard let rel = relativo(u, raiz: raiz), !ignorado(rel) else { return }
        let destino = FileOps.destinoReal(u)
        let tamanho = ((try? FileManager.default.attributesOfItem(atPath: destino.path))?[.size] as? Int) ?? 0
        guard tamanho <= politica.maiorArquivo, let dados = try? Data(contentsOf: destino) else { return }
        registrar(dados, caminho: rel, projeto: projeto(raiz), origem: origem)
    }

    /// Onde a decisão acontece: igual à última não entra, e o salvamento do editor dentro
    /// do mesmo minuto de edição também não.
    private func registrar(_ dados: Data, caminho: String, projeto: String, origem: Origem) {
        let hash = Self.hash(dados)
        let dir = pastaDoArquivo(projeto, caminho)
        let momento = agora()
        var indice = lerIndice(dir) ?? Indice(caminho: caminho, versoes: [])
        if let ultima = indice.versoes.last {
            if ultima.hash == hash {
                return
            }
            if origem == .voce, ultima.origem == .voce,
               momento.timeIntervalSince(ultima.data) < politica.intervaloDeEdicao,
               escritoPeloEditor[chave(projeto, caminho)] == hash
            {
                return
            }
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if blob(hash, em: dir) == nil {
                let gravado = try gravarBlob(dados, hash: hash, em: dir)
                total = total.map { $0 + gravado }
            }
            indice.caminho = caminho
            indice.versoes.append(Versao(
                id: UUID().uuidString,
                hash: hash,
                data: momento,
                origem: origem,
                tamanho: dados.count
            ))
            podar(&indice, em: dir, agora: momento)
            try gravarIndice(indice, em: dir)
        } catch {
            // Melhor esforço: o histórico não pode impedir ninguém de salvar.
        }
    }

    // MARK: ler

    /// Da mais nova para a mais velha.
    public func versoes(de caminho: String, raiz: URL) -> [Versao] {
        trava.withLock {
            (lerIndice(pastaDoArquivo(projeto(raiz), caminho))?.versoes ?? []).reversed()
        }
    }

    public func dados(_ versao: Versao, de caminho: String, raiz: URL) -> Data? {
        trava.withLock {
            lerBlob(versao.hash, em: pastaDoArquivo(projeto(raiz), caminho))
        }
    }

    /// Arquivos do projeto que não existem mais e têm versões guardadas, o apagado mais
    /// recente primeiro. `pasta` filtra pelo que estava dentro dela ("" é o projeto todo).
    public func apagados(raiz: URL, em pasta: String = "") -> [ArquivoApagado] {
        let itens = trava.withLock { indices(projeto: projeto(raiz)) }
        let fm = FileManager.default
        return itens.compactMap { _, indice -> ArquivoApagado? in
            guard let ultima = indice.versoes.last,
                  pasta.isEmpty || indice.caminho.hasPrefix(pasta + "/"),
                  !fm.fileExists(atPath: raiz.appending(path: indice.caminho).path)
            else { return nil }
            return ArquivoApagado(caminho: indice.caminho, ultima: ultima, versoes: indice.versoes.count)
        }
        .sorted { $0.ultima.data > $1.ultima.data }
    }

    // MARK: restaurar

    public enum Falha: LocalizedError, Equatable {
        /// O conteúdo da versão não está mais no disco (poda, ou "Limpar histórico").
        case versaoSumiu

        public var errorDescription: String? {
            tr("Esta versão não está mais guardada.")
        }
    }

    /// Põe a versão de volta no arquivo. Antes, o que está lá agora vira uma versão
    /// (`restauracao`): restaurar também se desfaz.
    public func restaurar(_ versao: Versao, caminho: String, raiz: URL) throws {
        guard let dados = dados(versao, de: caminho, raiz: raiz) else { throw Falha.versaoSumiu }
        let u = raiz.appending(path: caminho)
        guardar([u], raiz: raiz, origem: .restauracao)
        let destino = FileOps.destinoReal(u)
        try FileManager.default.createDirectory(
            at: destino.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try dados.write(to: destino, options: .atomic)
    }

    // MARK: mover

    /// Arquivo ou pasta renomeado pela árvore: o histórico vai junto, e o caminho antigo
    /// não aparece como apagado. Roda fora de quem chamou — nada depende disto na hora, e
    /// renomear uma pasta pede para ler o índice de todos os arquivos do projeto.
    public func mover(de: URL, para: URL, raiz: URL) {
        fila.async { [self] in
            trava.withLock {
                guard let a = relativo(de, raiz: raiz), let b = relativo(para, raiz: raiz), a != b else { return }
                let proj = projeto(raiz)
                for (dir, indice) in indices(projeto: proj) {
                    let c = indice.caminho
                    guard c == a || c.hasPrefix(a + "/") else { continue }
                    juntar(dir, em: b + c.dropFirst(a.count), projeto: proj)
                }
            }
        }
    }

    /// Leva as versões da pasta `origem` para o caminho `novo`, somando com as que já
    /// estiverem lá.
    private func juntar(_ origem: URL, em novo: String, projeto: String) {
        let fm = FileManager.default
        guard var vindo = lerIndice(origem) else { return }
        let destino = pastaDoArquivo(projeto, novo)
        var indice = lerIndice(destino) ?? Indice(caminho: novo, versoes: [])
        try? fm.createDirectory(at: destino, withIntermediateDirectories: true)
        for v in vindo.versoes where blob(v.hash, em: destino) == nil {
            if let b = blob(v.hash, em: origem) {
                try? fm.moveItem(at: b, to: destino.appending(path: b.lastPathComponent))
            }
        }
        vindo.versoes.removeAll { v in indice.versoes.contains { $0.id == v.id } }
        indice.caminho = novo
        indice.versoes = (indice.versoes + vindo.versoes).sorted { $0.data < $1.data }
        podar(&indice, em: destino, agora: agora())
        try? gravarIndice(indice, em: destino)
        try? fm.removeItem(at: origem)
    }

    // MARK: espaço

    /// Bytes em disco de todos os projetos. Percorre a pasta: chame fora do ator principal.
    public func tamanhoUsado() -> Int {
        trava.withLock {
            let t = medir()
            total = t
            return t
        }
    }

    /// Apaga o histórico de todos os projetos.
    public func limpar() {
        trava.withLock {
            try? FileManager.default.removeItem(at: pasta)
            escritoPeloEditor = [:]
            total = 0
        }
    }

    private func medir() -> Int {
        var soma = 0
        guard let e = FileManager.default.enumerator(at: pasta, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        for case let u as URL in e {
            soma += (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return soma
    }

    /// Passou do teto: poda em segundo plano, uma poda de cada vez.
    private func podarSePassou() {
        let agendar: Bool = trava.withLock {
            guard !podaAgendada, let total, total > politica.tetoTotal else { return false }
            podaAgendada = true
            return true
        }
        guard agendar else { return }
        fila.async { [self] in
            podarPeloTetoAgora()
        }
    }

    /// Espera o que foi mandado para segundo plano (mover, podar, manutenção). Para testes.
    func esperar() {
        fila.sync {}
    }

    /// Tira as versões mais velhas, de qualquer projeto, até sobrar 90% do teto — a
    /// folga é para a poda não voltar a cada gravação.
    func podarPeloTetoAgora() {
        trava.withLock {
            podarPeloTeto()
            podaAgendada = false
        }
    }

    private func podarPeloTeto() {
        let fm = FileManager.default
        var soma = medir()
        guard soma > politica.tetoTotal else {
            total = soma
            return
        }
        let alvo = politica.tetoTotal / 10 * 9
        var arquivos: [(dir: URL, indice: Indice)] = []
        for proj in (try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: nil)) ?? [] {
            arquivos += indices(pastaDoProjeto: proj)
        }
        var todas: [(i: Int, v: Versao)] = []
        for (i, a) in arquivos.enumerated() {
            todas += a.indice.versoes.map { (i, $0) }
        }
        todas.sort { $0.v.data < $1.v.data }
        var mexidos = Set<Int>()
        for (i, v) in todas where soma > alvo {
            arquivos[i].indice.versoes.removeAll { $0.id == v.id }
            mexidos.insert(i)
            if !arquivos[i].indice.versoes.contains(where: { $0.hash == v.hash }), let b = blob(
                v.hash,
                em: arquivos[i].dir
            ) {
                soma -= (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? fm.removeItem(at: b)
            }
        }
        for i in mexidos {
            if arquivos[i].indice.versoes.isEmpty {
                try? fm.removeItem(at: arquivos[i].dir)
            } else {
                try? gravarIndice(arquivos[i].indice, em: arquivos[i].dir)
            }
        }
        total = medir()
    }

    /// Uma vez por dia, na abertura: tira o que passou de 30 dias de arquivos que ninguém
    /// mais tocou (a poda por arquivo só roda quando ele ganha versão nova), apaga
    /// conteúdo que nenhum índice cita — sobra de uma gravação interrompida — e mede o
    /// total, que é o que liga a poda pelo teto.
    public func manutencaoSePreciso() {
        fila.async { [self] in
            let marca = pasta.appending(path: "manutencao")
            let fm = FileManager.default
            let ultima = (try? fm.attributesOfItem(atPath: marca.path))?[.modificationDate] as? Date
            trava.withLock {
                if ultima.map({ agora().timeIntervalSince($0) > 86400 }) ?? true {
                    manutencao()
                    try? fm.createDirectory(at: pasta, withIntermediateDirectories: true)
                    try? Data().write(to: marca)
                    // Fora do backup do iCloud também: são até centenas de MB por aparelho,
                    // e o projeto em si já tem o seu caminho de volta (iCloud Drive, git).
                    var valores = URLResourceValues()
                    valores.isExcludedFromBackup = true
                    var p = pasta
                    try? p.setResourceValues(valores)
                }
                total = medir()
            }
            podarSePassou()
        }
    }

    func manutencao() {
        let fm = FileManager.default
        let momento = agora()
        for proj in (try? fm.contentsOfDirectory(at: pasta, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            guard (try? proj.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            for dir in (try? fm.contentsOfDirectory(at: proj, includingPropertiesForKeys: nil)) ?? [] {
                guard var indice = lerIndice(dir) else {
                    try? fm.removeItem(at: dir)
                    continue
                }
                podar(&indice, em: dir, agora: momento)
                if indice.versoes.isEmpty {
                    try? fm.removeItem(at: dir)
                    continue
                }
                try? gravarIndice(indice, em: dir)
                let citados = Set(indice.versoes.map(\.hash))
                for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
                    where f.lastPathComponent != "indice.json"
                {
                    if !citados.contains(f.deletingPathExtension().lastPathComponent) {
                        try? fm.removeItem(at: f)
                    }
                }
            }
        }
    }

    /// Poda de um arquivo: fora o que passou da idade e o que passou da conta, e o
    /// conteúdo que nenhuma versão restante usa.
    private func podar(_ indice: inout Indice, em dir: URL, agora momento: Date) {
        let limite = momento.addingTimeInterval(-Double(politica.diasPorVersao) * 86400)
        var ficam = indice.versoes.filter { $0.data >= limite }
        if ficam.count > politica.versoesPorArquivo {
            ficam = Array(ficam.suffix(politica.versoesPorArquivo))
        }
        guard ficam.count != indice.versoes.count else { return }
        let emUso = Set(ficam.map(\.hash))
        for v in indice.versoes where !emUso.contains(v.hash) {
            if let b = blob(v.hash, em: dir) {
                let tamanho = (try? b.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                try? FileManager.default.removeItem(at: b)
                total = total.map { max(0, $0 - tamanho) }
            }
        }
        indice.versoes = ficam
    }

    // MARK: projeto e caminho

    /// A pasta do projeto aqui dentro. O id de `.odete/project.json` quando existe — ele
    /// sobrevive a renomear o projeto e à troca de pasta do app a cada instalação —, e um
    /// hash do caminho para pasta de fora que não tem um.
    func projeto(_ raiz: URL) -> String {
        let chave = raiz.standardizedFileURL.path
        if let id = ids[chave] {
            return id
        }
        var id: String
        if let d = try? Data(contentsOf: raiz.appending(path: ".odete/project.json")),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let s = obj["id"] as? String, UUID(uuidString: s) != nil
        {
            id = s
        } else {
            // A pasta do app muda de nome a cada instalação; sem tirar esse pedaço, o
            // histórico de uma pasta de fora ficaria para trás a cada atualização.
            let caminho = raiz.resolvingSymlinksInPath().path.replacing(
                #/\/Containers\/Data\/Application\/[^\/]+\//#,
                with: "/Containers/Data/Application/app/"
            )
            id = "pasta-" + String(Self.hash(Data(caminho.utf8)).prefix(24))
        }
        ids[chave] = id
        return id
    }

    /// Caminho relativo à raiz. `/var` e `/private/var` são o mesmo lugar, e a comparação
    /// direta errava quando um lado vinha resolvido e o outro não.
    func relativo(_ url: URL, raiz: URL) -> String? {
        let r = raiz.standardizedFileURL.path
        let u = url.standardizedFileURL.path
        if u.hasPrefix(r + "/") {
            return String(u.dropFirst(r.count + 1))
        }
        let rr = raiz.resolvingSymlinksInPath().path
        // Só as pastas de cima são resolvidas: se o arquivo em si é um link, o caminho é
        // o do link, que é o que aparece na árvore.
        let ur = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appending(path: url.lastPathComponent).path
        if ur.hasPrefix(rr + "/") {
            return String(ur.dropFirst(rr.count + 1))
        }
        return nil
    }

    /// Arquivo que não entra: dentro de pasta ignorada, ou ruído como `.DS_Store`.
    func ignorado(_ rel: String) -> Bool {
        let partes = rel.split(separator: "/").map(String.init)
        if let ultimo = partes.last, Ignore.noiseFiles.contains(ultimo) {
            return true
        }
        return partes.dropLast().contains { politica.pastasIgnoradas.contains($0) }
    }

    /// Pasta que não se percorre: ela mesma, ou alguma de cima, é ignorada.
    func pastaIgnorada(_ rel: String) -> Bool {
        rel.split(separator: "/").contains { politica.pastasIgnoradas.contains(String($0)) }
    }

    /// A raiz de um arquivo que chegou sem ela: a mais funda entre as já vistas, e senão
    /// a primeira pasta de cima com `.odete` ou `.git`.
    private func acharRaiz(_ url: URL) -> URL? {
        let p = url.standardizedFileURL.path
        if let r = raizes.filter({ p.hasPrefix($0.standardizedFileURL.path + "/") })
            .max(by: { $0.path.count < $1.path.count })
        {
            return r
        }
        let fm = FileManager.default
        var d = url.deletingLastPathComponent().standardizedFileURL
        for _ in 0 ..< 40 {
            if d.path.contains("/node_modules") {
                return nil
            }
            if fm.fileExists(atPath: d.appending(path: ".odete").path) || fm
                .fileExists(atPath: d.appending(path: ".git").path)
            {
                return d
            }
            let pai = d.deletingLastPathComponent()
            if pai.path == d.path {
                return nil
            }
            d = pai
        }
        return nil
    }

    private func chave(_ projeto: String, _ caminho: String) -> String {
        "\(projeto)/\(caminho)"
    }

    private func pastaDoArquivo(_ projeto: String, _ caminho: String) -> URL {
        pasta.appending(path: projeto, directoryHint: .isDirectory)
            .appending(path: String(Self.hash(Data(caminho.utf8)).prefix(40)), directoryHint: .isDirectory)
    }

    private func indices(projeto: String) -> [(URL, Indice)] {
        indices(pastaDoProjeto: pasta.appending(path: projeto, directoryHint: .isDirectory))
    }

    private func indices(pastaDoProjeto proj: URL) -> [(dir: URL, indice: Indice)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: proj, includingPropertiesForKeys: nil)) ?? []
        return dirs.compactMap { d in lerIndice(d).map { (d, $0) } }
    }

    // MARK: disco

    private func lerIndice(_ dir: URL) -> Indice? {
        guard let d = try? Data(contentsOf: dir.appending(path: "indice.json")) else { return nil }
        return try? JSONDecoder().decode(Indice.self, from: d)
    }

    private func gravarIndice(_ indice: Indice, em dir: URL) throws {
        try JSONEncoder().encode(indice).write(to: dir.appending(path: "indice.json"), options: .atomic)
    }

    /// Texto comprime bem — um arquivo de código cabe em um terço —, e o teto rende o
    /// triplo. O que não comprime (vazio, ou já comprimido) vai cru, sem extensão.
    private func gravarBlob(_ dados: Data, hash: String, em dir: URL) throws -> Int {
        if !dados.isEmpty, let z = try? (dados as NSData).compressed(using: .lzfse) as Data, z.count < dados.count {
            try z.write(to: dir.appending(path: "\(hash).lzfse"), options: .atomic)
            return z.count
        }
        try dados.write(to: dir.appending(path: hash), options: .atomic)
        return dados.count
    }

    private func blob(_ hash: String, em dir: URL) -> URL? {
        let fm = FileManager.default
        let z = dir.appending(path: "\(hash).lzfse")
        if fm.fileExists(atPath: z.path) {
            return z
        }
        let cru = dir.appending(path: hash)
        return fm.fileExists(atPath: cru.path) ? cru : nil
    }

    private func lerBlob(_ hash: String, em dir: URL) -> Data? {
        guard let u = blob(hash, em: dir), let d = try? Data(contentsOf: u) else { return nil }
        if u.pathExtension == "lzfse" {
            return try? (d as NSData).decompressed(using: .lzfse) as Data
        }
        return d
    }

    /// SHA-256 em hexadecimal: o nome do conteúdo guardado, e o que a folha compara com o
    /// arquivo de agora para marcar a versão igual a ele.
    public static func hash(_ dados: Data) -> String {
        SHA256.hash(data: dados).map { String(format: "%02x", $0) }.joined()
    }
}
