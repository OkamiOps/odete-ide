import Foundation
@testable import OdeteNpm
import Testing

/// O install da Odete contra o registro de verdade, para comparar com o npm do Mac.
///
/// Não roda no `make unit` (vai à rede). Liga com `TEST_RUNNER_ODETE_COMPARAR_DIR=<pasta>`:
/// cada subpasta com `package.json` é copiada para `<subpasta>-odete`, instalada, e depois
/// recebe o `npm install` com os argumentos de `add.json` (`["-D", "ms@2"]`). Quem compara
/// é o script do lado do Mac, com o npm real rodando o mesmo roteiro em `<subpasta>-npm`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["ODETE_COMPARAR_DIR"] != nil))
struct ComparacaoComNpmTests {
    @Test func instalaComoONpm() async throws {
        let base = try URL(filePath: #require(ProcessInfo.processInfo.environment["ODETE_COMPARAR_DIR"]))
        let fm = FileManager.default
        for nome in try fm.contentsOfDirectory(atPath: base.path).sorted() where !nome.contains("-") {
            let origem = base.appending(path: nome)
            guard fm.fileExists(atPath: origem.appending(path: "package.json").path) else { continue }
            let destino = base.appending(path: "\(nome)-odete")
            try? fm.removeItem(at: destino)
            try fm.createDirectory(at: destino, withIntermediateDirectories: true)
            try fm.copyItem(at: origem.appending(path: "package.json"), to: destino.appending(path: "package.json"))
            let inst = Installer(project: destino, registry: HTTPRegistry())
            let inicio = ContinuousClock.now
            let rep = try await inst.install()
            print(
                "COMPARA \(nome) install: \(rep.installed.count) pacotes em \(ContinuousClock.now - inicio)",
                "falhas=\(rep.failed) ignorados=\(rep.skipped) avisos=\(rep.avisos)"
            )
            #expect(rep.failed.isEmpty, "\(nome): \(rep.failed)")
            try fm.copyItem(
                at: destino.appending(path: "package-lock.json"),
                to: destino.appending(path: "package-lock.depois-do-install.json")
            )
            if let d = try? Data(contentsOf: origem.appending(path: "add.json")),
               let args = try JSONSerialization.jsonObject(with: d) as? [String]
            {
                let specs = args.filter { !$0.hasPrefix("-") }.map(Installer.Spec.init)
                let rep2 = try await inst.install(
                    add: specs,
                    dev: args.contains("-D"),
                    exato: args.contains("-E")
                )
                print("COMPARA \(nome) add \(args): \(rep2.added) falhas=\(rep2.failed)")
                #expect(rep2.failed.isEmpty, "\(nome): \(rep2.failed)")
            }
        }
    }
}
