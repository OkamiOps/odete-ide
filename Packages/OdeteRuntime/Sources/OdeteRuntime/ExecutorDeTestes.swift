import Foundation

/// O executor de testes embutido: o básico do vitest (describe/it/expect/vi) num processo só.
///
/// O vitest de verdade não sobe no iPad — o vite 8 dele precisa do binário nativo do rolldown,
/// e os pools rodam cada arquivo num worker_thread ou num processo filho. O `npx vitest` do
/// terminal roda este script como principal de um `JSProcess` (com o transformador do esbuild,
/// para os testes em TS). Ver o comentário no topo do `vitest-embutido.js`.
public enum ExecutorDeTestes {
    /// O script; recebe em `argv[2]` um JSON com `Opcoes`.
    public static var script: URL {
        Bundle.module.url(forResource: "node", withExtension: nil)!.appending(path: "vitest-embutido.js")
    }

    /// O que o script espera receber.
    public struct Opcoes: Encodable, Sendable {
        /// A raiz do projeto: os nomes dos arquivos saem relativos a ela.
        public var raiz: String
        /// A versão do vitest instalado, só para o cabeçalho (`RUN v…`).
        public var versao: String
        /// Os arquivos de teste, em caminho absoluto e na ordem de execução.
        public var arquivos: [String]
        /// `-t`: expressão regular sobre o nome completo do teste.
        public var padrao: String?
        /// `--testTimeout`, em ms (o padrão do vitest é 5000).
        public var tempoLimite: Int?
        /// `--reporter=verbose`: lista cada teste, não só os que falharam.
        public var detalhado: Bool

        public init(
            raiz: String,
            versao: String,
            arquivos: [String],
            padrao: String? = nil,
            tempoLimite: Int? = nil,
            detalhado: Bool = false
        ) {
            self.raiz = raiz
            self.versao = versao
            self.arquivos = arquivos
            self.padrao = padrao
            self.tempoLimite = tempoLimite
            self.detalhado = detalhado
        }

        /// O argumento para o script.
        public var json: String {
            (try? String(decoding: JSONEncoder().encode(self), as: UTF8.self)) ?? "{}"
        }
    }

    /// O padrão de arquivos do vitest (`**/*.{test,spec}.?(c|m)[jt]s?(x)`).
    public static func ehArquivoDeTeste(_ nome: String) -> Bool {
        nome.range(of: #"\.(test|spec)\.[cm]?[jt]sx?$"#, options: .regularExpression) != nil
    }

    /// Os arquivos de teste sob `raiz`, em ordem, fora de `node_modules` e de pastas ocultas
    /// (`.git`, `.odete`). `filtros` são os do `vitest run abc`: basta o caminho relativo
    /// conter um deles.
    public static func arquivos(em raiz: URL, filtros: [String] = []) -> [URL] {
        let fm = FileManager.default
        guard let e = fm.enumerator(
            at: raiz,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) else { return [] }
        let base = raiz.standardizedFileURL.path
        var achados: [URL] = []
        for case let u as URL in e {
            let nome = u.lastPathComponent
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if nome.hasPrefix(".") || nome == "node_modules" || nome == "node_modules.nosync" {
                    e.skipDescendants()
                }
                continue
            }
            guard ehArquivoDeTeste(nome) else { continue }
            let caminho = u.standardizedFileURL.path
            let relativo = caminho.hasPrefix(base + "/") ? String(caminho.dropFirst(base.count + 1)) : caminho
            if filtros.isEmpty || filtros.contains(where: { relativo.contains($0) }) {
                achados.append(u)
            }
        }
        return achados.sorted { $0.path < $1.path }
    }
}
