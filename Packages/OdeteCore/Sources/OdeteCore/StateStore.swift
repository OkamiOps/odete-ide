import Foundation
import Synchronization

/// Lê e grava `ChromeSnapshot` como JSON, com gravação debounced.
public final class StateStore: Sendable {
    public let url: URL
    private let debounce: Duration
    private let pending = Mutex<Task<Void, Never>?>(nil)

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Odete", directoryHint: .isDirectory).appending(path: "state.json")
    }

    public init(url: URL = StateStore.defaultURL(), debounce: Duration = .milliseconds(300)) {
        self.url = url
        self.debounce = debounce
    }

    public func load() -> ChromeSnapshot {
        carregar().snapshot
    }

    /// O estado lido e se a leitura falhou.
    public struct Leitura: Sendable {
        public var snapshot: ChromeSnapshot
        /// Havia um state.json e não deu para ler. Não é instalação nova: quem decide
        /// algo "só para instalação nova" (ligar o iCloud) não pode decidir por isso.
        public var falhou: Bool
    }

    /// Lê o estado. A decodificação é tolerante campo a campo (ver `ChromeSnapshot`);
    /// chegar aqui com falha é arquivo que nem JSON é mais.
    ///
    /// Antes, qualquer falha virava um estado novo em folha, e o próximo salvamento
    /// gravava por cima: o arquivo velho ia embora sem ninguém ver. Agora ele fica ao
    /// lado como `state.json.falhou-<data>`, e o estado novo sai marcado como de quem já
    /// passou pelas boas-vindas — a existência do arquivo diz isso.
    public func carregar() -> Leitura {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Leitura(snapshot: ChromeSnapshot(), falhou: false)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url), let snap = try? dec.decode(ChromeSnapshot.self, from: data) {
            return Leitura(snapshot: snap, falhou: false)
        }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let carimbo = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let guardado = url.deletingLastPathComponent().appending(path: "\(url.lastPathComponent).falhou-\(carimbo)")
        try? FileManager.default.copyItem(at: url, to: guardado)
        var snap = ChromeSnapshot()
        snap.welcomeDone = true
        return Leitura(snapshot: snap, falhou: true)
    }

    public func saveNow(_ snapshot: ChromeSnapshot) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(snapshot)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Agenda a gravação; chamadas seguidas dentro da janela coalescem numa só.
    public func scheduleSave(_ snapshot: ChromeSnapshot) {
        let wait = debounce
        let task = Task { [self] in
            try? await Task.sleep(for: wait)
            if Task.isCancelled {
                return
            }
            try? saveNow(snapshot)
        }
        pending.withLock { old in
            old?.cancel()
            old = task
        }
    }

    /// Espera a gravação pendente terminar (para testes e para encerrar o app).
    public func flush() async {
        let task = pending.withLock { $0 }
        await task?.value
    }
}
