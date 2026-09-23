import Foundation
import Synchronization

/// O esbuild carregado e o pacote de dependências feito antes do primeiro `npm run dev`.
///
/// Sem isto, o primeiro servidor de um projeto recém-instalado pagava tudo na hora em que
/// a pessoa esperava o Preview: carregar o esbuild (o módulo de 14 MB em wasm
/// interpretado), o build do app e o empacotamento do react-dom — uns oito segundos de
/// CPU num iPad sem JIT. O pacote de dependências fica em `node_modules/.odete-deps` e o
/// servidor aceita qualquer um que contenha o que ele pede; feito aqui, depois do
/// `npm install` ou quando o Preview de um projeto JS aparece, o servidor cai no caminho
/// rápido (medido: ~1 s com o pacote pronto).
///
/// Um aquecimento por projeto de cada vez. Quem vai subir o servidor espera o que estiver
/// em andamento (`esperar`): dois empacotamentos iguais no mesmo motor, ao mesmo tempo,
/// seriam o dobro do trabalho para o mesmo arquivo.
public enum Aquecimento {
    public struct Resultado: Sendable, Equatable {
        /// Fez o pacote agora (ou achou um que já servia, em `doDisco`).
        public var feito = false
        /// Por que não fez nada: `sem-node-modules`, `sem-index`, `ja-tinha`…
        public var motivo: String?
        public var pacotes = 0
        public var doDisco = false
        public var erro: String?
    }

    private static let emAndamento = Mutex<[String: Task<Resultado, Never>]>([:])

    /// Carrega o esbuild e faz o pacote de dependências de `raiz`, se der. `soSeFaltar`
    /// não faz o build do app quando já há pacote guardado para o lock de agora — é o que
    /// o Preview usa ao aparecer, para não gastar CPU à toa num projeto já aquecido.
    @discardableResult
    public static func aquecer(esbuild: Esbuild, raiz: URL, soSeFaltar: Bool = false) -> Task<Resultado, Never> {
        let chave = Esbuild.chave(raiz)
        return emAndamento.withLock { tabela in
            if let t = tabela[chave] {
                return t
            }
            let t = Task<Resultado, Never> {
                defer { _ = emAndamento.withLock { $0.removeValue(forKey: chave) } }
                return await rodar(esbuild: esbuild, raiz: raiz, soSeFaltar: soSeFaltar)
            }
            tabela[chave] = t
            return t
        }
    }

    /// Espera o aquecimento de `raiz` que estiver em andamento. Sem nenhum, volta na hora.
    public static func esperar(raiz: URL) async -> Resultado? {
        let t = emAndamento.withLock { $0[Esbuild.chave(raiz)] }
        return await t?.value
    }

    public static func emAndamento(raiz: URL) -> Bool {
        emAndamento.withLock { $0[Esbuild.chave(raiz)] != nil }
    }

    private static func rodar(esbuild: Esbuild, raiz: URL, soSeFaltar: Bool) async -> Resultado {
        do {
            _ = try await esbuild.ready()
            // Sem node_modules não há pacote para fazer: o motor carregado já é o ganho.
            guard FileManager.default.fileExists(atPath: raiz.appending(path: "node_modules").path) else {
                return Resultado(motivo: "sem-node-modules")
            }
            let js = Bundle.module.url(forResource: "js", withExtension: nil)!
            for arquivo in ["dependencias.js", "aquecimento.js"] {
                try await esbuild.engine.evaluate(
                    String(contentsOf: js.appending(path: arquivo), encoding: .utf8),
                    name: arquivo
                )
            }
            let json = try await esbuild.engine.call("__devAquece", [raiz.path, soSeFaltar])
            let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]) ?? [:]
            return Resultado(
                feito: (obj["feito"] as? Bool) ?? false,
                motivo: obj["motivo"] as? String,
                pacotes: (obj["pacotes"] as? Int) ?? 0,
                doDisco: (obj["doDisco"] as? Bool) ?? false,
                erro: obj["erro"] as? String
            )
        } catch {
            return Resultado(erro: error.localizedDescription)
        }
    }
}
