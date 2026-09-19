import Foundation

/// Avisa quando o projeto muda — e só quando muda.
///
/// A versão anterior tinha um relógio: de dois em dois segundos varria a árvore inteira
/// somando datas de modificação para comparar com a soma anterior, e o servidor de
/// desenvolvimento tinha outro igual, de segundo em segundo. Funcionava, e era trabalho
/// jogado fora: num projeto parado, cada volta do relógio percorria o disco para
/// descobrir que nada tinha acontecido. Num iPad isso é bateria e calor.
///
/// Aqui não há relógio. Cada pasta ganha um `DispatchSource` do próprio kernel, que só
/// acorda quando alguém escreve, renomeia ou apaga. Parado, o custo é zero — nem uma
/// leitura de disco, nem um despertar de CPU.
///
/// Duas coisas que o relógio cobria de graça e aqui precisam ser ditas:
///
/// - **Pasta nova** precisa ganhar observador, senão o que nasce dentro dela passa
///   despercebido. Por isso todo aviso de pasta ressincroniza a lista.
/// - **Conteúdo reescrito não mexe na data da pasta.** Quem observa pasta não vê o agente
///   nem o terminal reescrevendo um arquivo já aberto. Por isso os arquivos abertos são
///   acompanhados um a um, via `acompanhar(_:)`.
public final class ObservadorDeArquivos: @unchecked Sendable {
    /// Pastas que não entram: quem tem dezenas de milhares de subpastas gastaria o limite
    /// de descritores do processo para vigiar o que ninguém edita à mão.
    static let ignoradas: Set<String> = [
        "node_modules", ".git", ".build", "dist", ".next", ".cache", "build", ".odete",
    ]

    /// Teto de descritores. iOS dá alguns milhares por processo e o app usa os dele para
    /// outras coisas; parar de descer é melhor que ficar sem descritor na hora de abrir
    /// um arquivo.
    public static let tetoPadrao = 400

    private let raiz: URL
    private let aoMudar: @Sendable () -> Void
    private let aoMudarArquivo: (@Sendable (String) -> Void)?
    private let teto: Int
    private let fila = DispatchQueue(label: "odete.observador", qos: .utility)

    private var pastas: [String: DispatchSourceFileSystemObject] = [:]
    private var arquivos: [String: DispatchSourceFileSystemObject] = [:]
    private var acompanhados: Set<String> = []
    private var pendente: DispatchWorkItem?
    private var ligado = false

    public init(
        raiz: URL,
        aoMudar: @escaping @Sendable () -> Void,
        aoMudarArquivo: (@Sendable (String) -> Void)? = nil,
        teto: Int = ObservadorDeArquivos.tetoPadrao
    ) {
        self.raiz = raiz
        self.aoMudar = aoMudar
        self.aoMudarArquivo = aoMudarArquivo
        self.teto = teto
    }

    deinit { pararAgora() }

    public func comecar() {
        fila.async { [self] in
            ligado = true
            sincronizarPastas()
        }
    }

    public func parar() {
        fila.async { [self] in pararAgora() }
    }

    private func pararAgora() {
        ligado = false
        pendente?.cancel()
        pendente = nil
        for (_, s) in pastas {
            s.cancel()
        }
        pastas.removeAll()
        for (_, s) in arquivos {
            s.cancel()
        }
        arquivos.removeAll()
    }

    /// Os arquivos que merecem observador próprio: as abas abertas.
    ///
    /// Chamar de novo troca a lista inteira — abrir e fechar aba é a operação comum, e
    /// fazer o chamador calcular diferença só espalharia a contabilidade.
    public func acompanhar(_ caminhos: [String]) {
        fila.async { [self] in
            let novos = Set(caminhos)
            guard novos != acompanhados else { return }
            acompanhados = novos
            for (caminho, fonte) in arquivos where !novos.contains(caminho) {
                fonte.cancel()
                arquivos.removeValue(forKey: caminho)
            }
            for caminho in novos where arquivos[caminho] == nil {
                armarArquivo(caminho)
            }
        }
    }

    // MARK: - Pastas

    /// As pastas observáveis abaixo de `raiz`, já sem as pesadas e já limitadas ao teto.
    ///
    /// Vive fora da instância para o teste poder conferir a regra sem montar observador.
    static func pastasPara(raiz: URL, teto: Int = tetoPadrao) -> [URL] {
        var achadas = [raiz]
        var fila = [raiz]
        while !fila.isEmpty, achadas.count < teto {
            let atual = fila.removeFirst()
            let filhas = (try? FileManager.default.contentsOfDirectory(
                at: atual,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for f in filhas.sorted(by: { $0.path < $1.path }) {
                guard achadas.count < teto else { break }
                guard !ignoradas.contains(f.lastPathComponent) else { continue }
                guard (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
                achadas.append(f)
                fila.append(f)
            }
        }
        return Array(achadas.prefix(teto))
    }

    private func sincronizarPastas() {
        guard ligado else { return }
        let querem = Set(Self.pastasPara(raiz: raiz, teto: teto).map(\.path))
        for (caminho, fonte) in pastas where !querem.contains(caminho) {
            fonte.cancel()
            pastas.removeValue(forKey: caminho)
        }
        for caminho in querem where pastas[caminho] == nil {
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
            // Pasta que muda pode ter ganhado ou perdido subpasta, e subpasta nova sem
            // observador é um ponto cego. Ressincronizar aqui é o preço de não ter relógio.
            sincronizarPastas()
            avisar()
        }
        fonte.setCancelHandler { close(fd) }
        fonte.resume()
        pastas[caminho] = fonte
    }

    // MARK: - Arquivos abertos

    private func armarArquivo(_ caminho: String) {
        let fd = open(caminho, O_EVTONLY)
        guard fd >= 0 else { return }
        let fonte = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend],
            queue: fila
        )
        fonte.setEventHandler { [weak self] in
            guard let self else { return }
            let evento = fonte.data
            aoMudarArquivo?(caminho)
            // Gravar temporário e renomear por cima — que é como quase toda ferramenta
            // escreve — deixa este descritor preso ao arquivo antigo, que já não existe.
            // Sem rearmar num caminho novo, o primeiro aviso seria também o último.
            if evento.contains(.rename) || evento.contains(.delete) {
                rearmarArquivo(caminho)
            }
        }
        fonte.setCancelHandler { close(fd) }
        fonte.resume()
        arquivos[caminho] = fonte
    }

    private func rearmarArquivo(_ caminho: String) {
        arquivos[caminho]?.cancel()
        arquivos.removeValue(forKey: caminho)
        // Uma folga curta porque entre o renome e o arquivo novo existir há uma fresta.
        fila.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, ligado, acompanhados.contains(caminho) else { return }
            armarArquivo(caminho)
        }
    }

    // MARK: - Aviso

    /// Uma gravação costuma chegar como vários eventos seguidos; avisar em cada um faria
    /// a árvore ser remontada três vezes por salvamento.
    private func avisar() {
        pendente?.cancel()
        let trabalho = DispatchWorkItem { [aoMudar] in aoMudar() }
        pendente = trabalho
        fila.asyncAfter(deadline: .now() + 0.2, execute: trabalho)
    }
}
