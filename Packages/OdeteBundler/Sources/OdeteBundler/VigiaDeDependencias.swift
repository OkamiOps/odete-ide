import Foundation

/// Vigia só o que o build do dev server leu — e compara conteúdo, não data.
///
/// O servidor tinha um observador do projeto inteiro, além do que o app já tem, e
/// qualquer evento em qualquer pasta derrubava o cache e recarregava o Preview. Ligar o
/// servidor ao observador do app não dá daqui (ele mora no modelo do workspace e não diz
/// qual arquivo mudou), então este fica barato e preciso:
///
/// - **Só o grafo.** Arquivos que algum build leu (fora de `node_modules`), as pastas
///   deles e a raiz. Um `README.md` editado não acorda ninguém.
/// - **Conteúdo, não data.** O salvamento automático regrava o arquivo com o mesmo texto
///   a cada pausa na digitação; a data muda, o hash não, e o aviso não sai.
/// - **Sem relógio.** `DispatchSource` do kernel por arquivo e por pasta: parado, custa
///   zero. Pasta porque quase toda ferramenta grava num temporário e renomeia por cima
///   (o evento é da pasta); arquivo porque `echo >> x` escreve no lugar (o evento é dele).
/// - **Arquivo novo** só é contado se nasce numa pasta vigiada — o JS decide se importa
///   (um import quebrado que agora acha o arquivo, por exemplo).
final class VigiaDeDependencias: @unchecked Sendable {
    typealias Aviso = @Sendable (_ alterados: [String], _ criados: [String]) -> Void

    /// Pastas que não descem: a de pacotes é vigiada só no primeiro nível, e as outras
    /// são saída de build ou metadado.
    static let ignoradas: Set<String> = [".git", ".build", "dist", ".next", ".cache", "build", ".odete"]

    /// Onde moram os pacotes. Em projeto do iCloud a pasta de verdade é
    /// `node_modules.nosync` e `node_modules` é um atalho para ela; as duas valem igual:
    /// ninguém desce nelas, e mexer nelas é mudança de ambiente (refaz tudo, com calma).
    static let pastasDePacotes = ["node_modules", "node_modules.nosync"]

    /// Teto de descritores de arquivo (as pastas têm o seu). Projeto maior que isso segue
    /// vigiado pela pasta, que pega a gravação atômica — a do editor e a do agente.
    static let tetoDeArquivos = 200
    static let tetoDePastas = 120

    private struct Marca: Equatable {
        var data: Date?
        var tamanho: Int
        var resumo: Int
    }

    private let raiz: String
    private let aoMudar: Aviso
    private let fila = DispatchQueue(label: "odete.devserver.vigia", qos: .utility)
    private var desejados: Set<String> = []
    private var marcas: [String: Marca] = [:]
    private var fontesDeArquivo: [String: DispatchSourceFileSystemObject] = [:]
    private var fontesDePasta: [String: DispatchSourceFileSystemObject] = [:]
    private var nomes: [String: Set<String>] = [:]
    private var pastasPedidas: Set<String> = []
    private var arquivosSujos: Set<String> = []
    private var pastasSujas: Set<String> = []
    private var alteradosPendentes: Set<String> = []
    private var pendente: DispatchWorkItem?
    private var ligado = true

    init(raiz: URL, aoMudar: @escaping Aviso) {
        self.raiz = raiz.standardizedFileURL.path
        self.aoMudar = aoMudar
    }

    deinit {
        pararAgora()
    }

    /// Troca o que é vigiado. `arquivos` traz a data de modificação que o build viu (ms
    /// desde 1970), quando se sabe: se a do disco já é outra, o arquivo mudou entre o build
    /// ler e este observador armar, e isso conta como mudança.
    func vigiar(arquivos: [(caminho: String, mtime: Double?)], pastas: [String]) {
        fila.async { [self] in
            guard ligado else { return }
            let novos = Set(arquivos.map(\.caminho))
            for (caminho, fonte) in fontesDeArquivo where !novos.contains(caminho) {
                fonte.cancel()
                fontesDeArquivo.removeValue(forKey: caminho)
            }
            for caminho in desejados.subtracting(novos) {
                marcas.removeValue(forKey: caminho)
            }
            desejados = novos
            for (caminho, visto) in arquivos where marcas[caminho] == nil {
                let atual = Self.marca(de: caminho)
                marcas[caminho] = atual
                if let visto, let data = atual?.data,
                   abs(data.timeIntervalSince1970 * 1000 - visto) > 1
                {
                    alteradosPendentes.insert(caminho)
                }
                if atual != nil, fontesDeArquivo.count < Self.tetoDeArquivos {
                    armarArquivo(caminho)
                }
            }
            var querem = Set(pastas.compactMap { maisProximaExistente($0) })
            querem.insert(raiz)
            for caminho in novos {
                querem.insert((caminho as NSString).deletingLastPathComponent)
            }
            pastasPedidas = querem
            sincronizarPastas()
            if !alteradosPendentes.isEmpty {
                agendar()
            }
        }
    }

    func parar() {
        fila.async { [self] in pararAgora() }
    }

    /// Os arquivos vigiados agora (com marca de conteúdo). Para teste.
    var vigiados: Set<String> {
        fila.sync { Set(marcas.keys) }
    }

    private func pararAgora() {
        ligado = false
        pendente?.cancel()
        pendente = nil
        avisoDoAmbiente?.cancel()
        avisoDoAmbiente = nil
        for (_, f) in fontesDeArquivo {
            f.cancel()
        }
        fontesDeArquivo.removeAll()
        for (_, f) in fontesDePasta {
            f.cancel()
        }
        fontesDePasta.removeAll()
    }

    // MARK: - Pastas

    /// A pasta pedida, ou a mais próxima que existe acima dela (dentro da raiz). O import
    /// quebrado de `./componentes/Botao` aponta para uma pasta que talvez ainda não exista.
    private func maisProximaExistente(_ pasta: String) -> String? {
        var atual = (pasta as NSString).standardizingPath
        while atual.hasPrefix(raiz) {
            var ehPasta: ObjCBool = false
            if FileManager.default.fileExists(atPath: atual, isDirectory: &ehPasta), ehPasta.boolValue {
                return atual
            }
            let acima = (atual as NSString).deletingLastPathComponent
            if acima == atual {
                break
            }
            atual = acima
        }
        return nil
    }

    private func sincronizarPastas() {
        for (caminho, fonte) in fontesDePasta where !pastasPedidas.contains(caminho) {
            fonte.cancel()
            fontesDePasta.removeValue(forKey: caminho)
            nomes.removeValue(forKey: caminho)
        }
        for caminho in pastasPedidas where fontesDePasta[caminho] == nil {
            guard fontesDePasta.count < Self.tetoDePastas else { break }
            armarPasta(caminho)
        }
    }

    private func armarPasta(_ caminho: String) {
        let fd = open(caminho, O_EVTONLY)
        guard fd >= 0 else { return }
        let fonte = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: fila
        )
        fonte.setEventHandler { [weak self] in
            guard let self else { return }
            pastasSujas.insert(caminho)
            agendar()
        }
        fonte.setCancelHandler { close(fd) }
        fonte.resume()
        fontesDePasta[caminho] = fonte
        nomes[caminho] = Self.listar(caminho)
    }

    private static func listar(_ pasta: String) -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: pasta)) ?? [])
    }

    /// Nome de arquivo que interessa como "novo". Temporário de gravação atômica e
    /// arquivo oculto não — exceto `.env`, que muda o build inteiro.
    private static func interessa(_ nome: String) -> Bool {
        if nome.hasPrefix(".env") {
            return true
        }
        return !nome.hasPrefix(".") && !nome.hasSuffix("~") && !nome.contains(".sb-")
    }

    // MARK: - Arquivos

    private func armarArquivo(_ caminho: String) {
        let fd = open(caminho, O_EVTONLY)
        guard fd >= 0 else { return }
        let fonte = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: fila
        )
        fonte.setEventHandler { [weak self] in
            guard let self else { return }
            let evento = fonte.data
            arquivosSujos.insert(caminho)
            // Renomear por cima deixa este descritor preso ao arquivo antigo: sem rearmar
            // no caminho, o primeiro aviso seria o último.
            if evento.contains(.rename) || evento.contains(.delete) {
                fonte.cancel()
                fontesDeArquivo.removeValue(forKey: caminho)
            }
            agendar()
        }
        fonte.setCancelHandler { close(fd) }
        fonte.resume()
        fontesDeArquivo[caminho] = fonte
    }

    // MARK: - Conferência

    /// Uma gravação vira vários eventos seguidos; confere uma vez, logo depois do último.
    private func agendar() {
        pendente?.cancel()
        let trabalho = DispatchWorkItem { [weak self] in self?.conferir() }
        pendente = trabalho
        fila.asyncAfter(deadline: .now() + 0.08, execute: trabalho)
    }

    private func conferir() {
        guard ligado else { return }
        var alterados = alteradosPendentes
        var criados: [String] = []
        alteradosPendentes.removeAll()
        var aConferir = arquivosSujos
        arquivosSujos.removeAll()
        let pastas = pastasSujas
        pastasSujas.removeAll()
        for pasta in pastas {
            let antes = nomes[pasta] ?? []
            let agora = Self.listar(pasta)
            nomes[pasta] = agora
            for nome in agora.subtracting(antes) where Self.interessa(nome) {
                criados += novos(em: (pasta as NSString).appendingPathComponent(nome))
            }
            for nome in antes.subtracting(agora) where Self.interessa(nome) {
                alterados.insert((pasta as NSString).appendingPathComponent(nome))
            }
            // Gravação atômica troca o arquivo sem mudar a lista de nomes: quem mora na
            // pasta e é dependência precisa ser conferido pelo conteúdo.
            for caminho in desejados where (caminho as NSString).deletingLastPathComponent == pasta {
                aConferir.insert(caminho)
            }
        }
        for caminho in aConferir where desejados.contains(caminho) {
            let antes = marcas[caminho]
            let atual = Self.marca(de: caminho, anterior: antes)
            if atual?.resumo != antes?.resumo || (atual == nil) != (antes == nil) {
                alterados.insert(caminho)
            }
            marcas[caminho] = atual
            if atual != nil, fontesDeArquivo[caminho] == nil, fontesDeArquivo.count < Self.tetoDeArquivos {
                armarArquivo(caminho)
            }
        }
        // Pasta nova ainda vazia também passa a ser vigiada: o arquivo pode nascer nela
        // segundos depois.
        sincronizarPastas()
        let doAmbiente = alterados.filter(ehAmbiente) + criados.filter(ehAmbiente)
        if !doAmbiente.isEmpty {
            avisarAmbienteQuandoSossegar(doAmbiente)
        }
        let soAlterados = alterados.filter { !ehAmbiente($0) }.sorted()
        let soCriados = criados.filter { !ehAmbiente($0) }.sorted()
        guard !soAlterados.isEmpty || !soCriados.isEmpty else { return }
        aoMudar(soAlterados, soCriados)
    }

    // MARK: - Pacotes

    /// `npm install` grava o package.json no começo, enche node_modules durante e grava o
    /// package-lock.json no fim. Cada um desses refaz o build do zero; avisar a cada lote
    /// seria refazer várias vezes no meio da instalação, com node_modules pela metade. O
    /// aviso sai quando a instalação sossega.
    static let sossegoDosPacotes: TimeInterval = 1.5

    private var ambientePendente: Set<String> = []
    private var avisoDoAmbiente: DispatchWorkItem?

    private func ehAmbiente(_ caminho: String) -> Bool {
        let dePacotes = Self.pastasDePacotes.contains { nome in
            let pacotes = raiz + "/" + nome
            return caminho == pacotes || caminho.hasPrefix(pacotes + "/")
        }
        return dePacotes || caminho == raiz + "/package.json" || caminho == raiz + "/package-lock.json"
    }

    private func avisarAmbienteQuandoSossegar(_ caminhos: [String]) {
        ambientePendente.formUnion(caminhos)
        avisoDoAmbiente?.cancel()
        let trabalho = DispatchWorkItem { [weak self] in
            guard let self, ligado, !ambientePendente.isEmpty else { return }
            let lista = ambientePendente.sorted()
            ambientePendente.removeAll()
            aoMudar(lista, [])
        }
        avisoDoAmbiente = trabalho
        fila.asyncAfter(deadline: .now() + Self.sossegoDosPacotes, execute: trabalho)
    }

    /// O que nasceu: o próprio arquivo, ou tudo dentro da pasta nova (e a pasta passa a
    /// ser vigiada, senão o que for criado dentro dela depois passaria despercebido).
    private func novos(em caminho: String) -> [String] {
        var ehPasta: ObjCBool = false
        guard FileManager.default.fileExists(atPath: caminho, isDirectory: &ehPasta) else { return [] }
        guard ehPasta.boolValue else { return [caminho] }
        let nome = (caminho as NSString).lastPathComponent
        // Pacote é assunto do JS (instalar muda o build inteiro), e descer em
        // node_modules gastaria descritor em milhares de pastas que ninguém edita.
        if Self.pastasDePacotes.contains(where: { nome == $0 || caminho.contains("/\($0)/") }) {
            return [caminho]
        }
        guard !Self.ignoradas.contains(nome), caminho.hasPrefix(raiz) else { return [] }
        pastasPedidas.insert(caminho)
        var achados: [String] = []
        for filho in Self.listar(caminho) where Self.interessa(filho) {
            achados += novos(em: (caminho as NSString).appendingPathComponent(filho))
        }
        return achados
    }

    /// Data, tamanho e resumo do conteúdo. A data e o tamanho só servem para não ler de
    /// novo o que não mudou de jeito nenhum; quem decide é o resumo — o salvamento
    /// automático muda a data e deixa o conteúdo igual.
    private static func marca(de caminho: String, anterior: Marca? = nil) -> Marca? {
        guard let atributos = try? FileManager.default.attributesOfItem(atPath: caminho),
              (atributos[.type] as? FileAttributeType) != .typeDirectory
        else { return nil }
        let data = atributos[.modificationDate] as? Date
        let tamanho = (atributos[.size] as? NSNumber)?.intValue ?? 0
        if let anterior, anterior.data == data, anterior.tamanho == tamanho {
            return anterior
        }
        guard let conteudo = FileManager.default.contents(atPath: caminho) else { return nil }
        var h = Hasher()
        conteudo.withUnsafeBytes { h.combine(bytes: $0) }
        return Marca(data: data, tamanho: tamanho, resumo: h.finalize())
    }
}
