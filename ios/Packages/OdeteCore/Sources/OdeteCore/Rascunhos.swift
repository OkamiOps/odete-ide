import Foundation

/// O texto não salvo dos arquivos abertos, guardado fora do projeto.
///
/// O iPad encerra app suspenso quando precisa de memória, sem aviso e sem chance de
/// gravar nada. Com o salvamento automático desligado, tudo o que estava digitado e não
/// salvo ia junto — e gravar por cima do arquivo na saída seria desobedecer justamente
/// quem desligou o automático. O rascunho fica aqui, ao lado do estado da janela, e
/// volta marcado como não salvo na abertura seguinte.
public struct Rascunhos: Sendable {
    public let url: URL

    public static func defaultURL(projeto: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Odete/Rascunhos", directoryHint: .isDirectory)
            .appending(path: "\(projeto).json")
    }

    public init(url: URL) {
        self.url = url
    }

    public init(projeto: String) {
        self.init(url: Self.defaultURL(projeto: projeto))
    }

    public func ler() -> [String: String] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    /// Melhor esforço: um rascunho que não consegue ser gravado não pode atrapalhar a
    /// saída do app nem virar alerta na cara de quem só trocou de aplicativo.
    public func gravar(_ textos: [String: String]) {
        guard !textos.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? JSONEncoder().encode(textos).write(to: url, options: .atomic)
    }
}
