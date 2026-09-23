import Foundation
import Observation
import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI
import Synchronization

/// Onde ficam os projetos no iCloud Drive, perguntado fora do ator principal.
///
/// `url(forUbiquityContainerIdentifier:)` pode levar segundos — na primeira vez, sem
/// rede, com a conta trocada — e a própria Apple pede para não chamar da thread
/// principal. Ela era chamada no `init` da `RootView`, no `body` dos Ajustes e a cada
/// `cloudAvailable`: a tela travava esperando o iCloud responder. Agora a pergunta é
/// feita uma vez, numa tarefa à parte, e a resposta fica guardada.
public final class LocalDaNuvem: Sendable {
    public static let shared = LocalDaNuvem()

    private enum Estado {
        case naoPerguntado
        case perguntando(Task<URL?, Never>)
        case sabido(URL?)
    }

    private let estado = Mutex<Estado>(.naoPerguntado)
    private let perguntar: @Sendable () -> URL?

    /// `perguntar` roda fora do ator principal; os testes trocam por uma pasta qualquer.
    init(perguntar: @escaping @Sendable () -> URL? = LocalDaNuvem.perguntarAoSistema) {
        self.perguntar = perguntar
    }

    static let perguntarAoSistema: @Sendable () -> URL? = {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appending(path: "Documents/Projects", directoryHint: .isDirectory)
    }

    /// A resposta, se já chegou: `nil` é "ainda não sei"; `.some(nil)`, "sem iCloud".
    public var sabido: URL?? {
        estado.withLock {
            if case let .sabido(u) = $0 {
                return .some(u)
            }
            return nil
        }
    }

    /// A pasta `Projects` no iCloud Drive, ou `nil` se o iCloud não está disponível.
    public func raiz() async -> URL? {
        let tarefa: Task<URL?, Never> = estado.withLock { e in
            switch e {
            case let .sabido(u):
                return Task { u }
            case let .perguntando(t):
                return t
            case .naoPerguntado:
                let t = Task.detached(priority: .userInitiated) { [perguntar] in perguntar() }
                e = .perguntando(t)
                return t
            }
        }
        let u = await tarefa.value
        estado.withLock { $0 = .sabido(u) }
        return u
    }

    /// Pergunta e espera, sem `await`. Só para quem não tem tela para travar — o atalho
    /// que roda com o app em segundo plano.
    func raizAgora() -> URL? {
        if let s = sabido {
            return s
        }
        let u = perguntar()
        estado.withLock { $0 = .sabido(u) }
        return u
    }
}

// MARK: - mudar os projetos de lugar

/// Levar a pasta `Projects` de Documents para o iCloud Drive, ou de volta.
///
/// Antes era um laço no ator principal que: pulava com `continue` o projeto cujo nome já
/// existia no destino (ele ficava na origem e sumia do hub, porque o app passava a olhar
/// só o destino); parava no primeiro erro com metade dos projetos de cada lado e o app
/// ainda apontando para a origem; e deixava as outras janelas olhando a pasta velha.
/// Agora é uma transação: cada projeto vai com um nome livre no destino (`nome 2`); se
/// um falha, os que já foram voltam; e só no fim, tudo tendo ido, o app troca de lugar.
enum MudancaDeLugar {
    struct Renomeado: Sendable, Equatable {
        var de: String
        var para: String
    }

    enum Falha: LocalizedError, Equatable {
        /// Há arquivos que só existem no iCloud: tirar do iCloud agora levaria os
        /// marcadores, não os arquivos. O download foi pedido.
        case aindaNaNuvem([String])
        /// Parou em `nome`. `ficaram` são os que já tinham ido e não deu para trazer.
        case parou(nome: String, motivo: String, ficaram: [String])
        case semICloud

        var errorDescription: String? {
            switch self {
            case let .aindaNaNuvem(nomes):
                tr(
                    "Alguns arquivos de %1$@ ainda estão só no iCloud. O download foi pedido; tente de novo quando terminar.",
                    nomes.joined(separator: ", ")
                )
            case let .parou(nome, motivo, ficaram) where ficaram.isEmpty:
                tr("Não deu para mover %1$@ (%2$@). Nada mudou de lugar.", nome, motivo)
            case let .parou(nome, motivo, ficaram):
                tr(
                    "Não deu para mover %1$@ (%2$@). Estes ficaram no destino e não voltaram: %3$@.",
                    nome,
                    motivo,
                    ficaram.joined(separator: ", ")
                )
            case .semICloud:
                tr("iCloud Drive indisponível neste aparelho.")
            }
        }
    }

    /// Um movimento: de onde, para onde, e se o destino é o iCloud.
    typealias Mover = @Sendable (_ de: URL, _ para: URL, _ paraNuvem: Bool) throws -> Void

    static let moverDeVerdade: Mover = { de, para, paraNuvem in
        let fm = FileManager()
        if paraNuvem {
            try fm.setUbiquitous(true, itemAt: de, destinationURL: para)
        } else if (try? de.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) == true {
            try fm.setUbiquitous(false, itemAt: de, destinationURL: para)
        } else {
            try fm.moveItem(at: de, to: para)
        }
    }

    /// Faz a mudança. Síncrono e longo: é para rodar fora do ator principal.
    static func executar(
        de origem: URL,
        para destino: URL,
        paraNuvem: Bool,
        mover: Mover = moverDeVerdade,
        progresso: (Int, Int) -> Void = { _, _ in }
    ) throws -> [Renomeado] {
        let fm = FileManager()
        try fm.createDirectory(at: destino, withIntermediateDirectories: true)
        let itens = ((try? fm.contentsOfDirectory(
            at: origem,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        if !paraNuvem {
            let pendentes = itens.filter(temArquivoSoNaNuvem)
            if !pendentes.isEmpty {
                throw Falha.aindaNaNuvem(pendentes.map(\.lastPathComponent))
            }
        }
        var feitos: [(de: URL, para: URL)] = []
        var renomeados: [Renomeado] = []
        progresso(0, itens.count)
        for item in itens {
            let nome = item.lastPathComponent
            let livre = nomeLivre(nome, em: destino)
            let alvo = destino.appending(path: livre, directoryHint: .isDirectory)
            do {
                if paraNuvem {
                    // Antes de mover: senão o iCloud começa a subir o node_modules no
                    // próprio movimento. Ver `PastaDeModulos`.
                    _ = PastaDeModulos.migrarSePreciso(item, nuvem: true)
                }
                try mover(item, alvo, paraNuvem)
            } catch {
                // Desfaz o que já foi, do último para o primeiro.
                var ficaram: [String] = []
                for f in feitos.reversed() {
                    do { try mover(f.para, f.de, !paraNuvem) } catch { ficaram.append(f.para.lastPathComponent) }
                }
                throw Falha.parou(nome: nome, motivo: error.localizedDescription, ficaram: ficaram)
            }
            feitos.append((item, alvo))
            if livre != nome {
                renomeados.append(Renomeado(de: nome, para: livre))
            }
            progresso(feitos.count, itens.count)
        }
        return renomeados
    }

    /// `nome`, ou `nome 2`, `nome 3`… o primeiro que não existe em `pasta`.
    static func nomeLivre(_ nome: String, em pasta: URL) -> String {
        var candidato = nome
        var n = 2
        while FileManager.default.fileExists(atPath: pasta.appending(path: candidato).path) {
            candidato = "\(nome) \(n)"
            n += 1
        }
        return candidato
    }

    /// Algum arquivo da pasta ainda não baixou do iCloud? Pede o download dos que faltam.
    static func temArquivoSoNaNuvem(_ pasta: URL) -> Bool {
        let fm = FileManager()
        let chaves: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isDirectoryKey]
        guard let e = fm.enumerator(at: pasta, includingPropertiesForKeys: chaves) else { return false }
        var falta = false
        for case let u as URL in e {
            let nome = u.lastPathComponent
            if nome == PastaDeModulos.nomeForaDaNuvem {
                e.skipDescendants()
                continue
            }
            let v = try? u.resourceValues(forKeys: Set(chaves))
            let marcador = nome.hasPrefix(".") && nome.hasSuffix(".icloud")
            // Pasta não tem estado de download que valha: só os arquivos contam.
            let arquivo = v?.isDirectory != true
            if marcador || (arquivo && v?.isUbiquitousItem == true && v?.ubiquitousItemDownloadingStatus != .current) {
                falta = true
                try? fm.startDownloadingUbiquitousItem(at: u)
            }
        }
        return falta
    }
}

/// O andamento da mudança de lugar, visto por todas as janelas.
@MainActor
@Observable
public final class EstadoDaMudanca {
    public internal(set) var andando = false
    public internal(set) var feitos = 0
    public internal(set) var total = 0
    /// O que dizer ao fim: erro, ou os projetos que mudaram de nome.
    public var aviso: String?
}

// MARK: - a chave nos Ajustes

/// "Projetos no iCloud Drive": pede confirmação, mostra o andamento e conta o que houve.
///
/// Ligar e desligar movem todos os projetos de lugar — desligar trazia tudo do iCloud
/// para dentro do app sem perguntar. Serve aos Ajustes do iPad e aos do layout estreito.
struct ChaveDoICloud: View {
    @Environment(ChromeState.self) private var chrome
    @Environment(AppModel.self) private var app
    /// Nos Ajustes do iPad o nome vem da linha do cartão; no formulário, do próprio toggle.
    var comRotulo = true
    @State private var pedido: Bool?
    private let mudanca = Janelas.shared.mudanca

    var body: some View {
        Toggle(tr("Projetos no iCloud Drive"), isOn: Binding(
            get: { chrome.snapshot.projectsInCloud },
            set: { pedido = $0 }
        ))
        .labelsHidden(!comRotulo)
        .disabled(mudanca.andando || (app.nuvemDisponivel != true && !chrome.snapshot.projectsInCloud))
        .task { await app.atualizarNuvem() }
        .confirmationDialog(
            pedido == true ? tr("Levar os projetos para o iCloud Drive?") :
                tr("Trazer os projetos para dentro do app?"),
            isPresented: Binding(get: { pedido != nil }, set: {
                if !$0 {
                    pedido = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button(pedido == true ? tr("Levar para o iCloud") : tr("Trazer para o app")) {
                let paraNuvem = pedido == true
                pedido = nil
                Task { await Janelas.shared.mudarLugar(paraNuvem: paraNuvem) }
            }
            Button(tr("Cancelar"), role: .cancel) { pedido = nil }
        } message: {
            Text(pedido == true
                ? tr(
                    "Os %1$@ projetos do app vão para o iCloud Drive. Os projetos abertos fecham enquanto isso.",
                    "\(app.projects.filter { !$0.external }.count)"
                )
                : tr(
                    "Os %1$@ projetos saem do iCloud Drive e passam a morar só neste iPad: desinstalar o app apaga tudo. Os projetos abertos fecham enquanto isso.",
                    "\(app.projects.filter { !$0.external }.count)"
                ))
        }
        .alert(tr("iCloud Drive"), isPresented: Binding(get: { mudanca.aviso != nil }, set: {
            if !$0 {
                mudanca.aviso = nil
            }
        })) {
            Button(tr("OK")) { mudanca.aviso = nil }
        } message: { Text(mudanca.aviso ?? "") }
    }
}

/// A barra de andamento enquanto os projetos mudam de lugar.
struct AndamentoDaMudanca: View {
    @Environment(\.theme) private var theme
    private let mudanca = Janelas.shared.mudanca

    var body: some View {
        if mudanca.andando {
            ProgressView(value: Double(mudanca.feitos), total: Double(max(mudanca.total, 1))) {
                Text(tr("Movendo projetos… %1$@ de %2$@", "\(mudanca.feitos)", "\(mudanca.total)"))
                    .font(OdeteFont.ui(11)).foregroundStyle(theme.fgMuted)
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func labelsHidden(_ esconder: Bool) -> some View {
        if esconder {
            labelsHidden()
        } else {
            self
        }
    }
}
