import Foundation
import OdeteI18n
@testable import OdeteShell
import Testing

/// Prova de fumaça com os ~30 pacotes mais usados do npm: `require`/`import` e um uso mínimo
/// de cada um, no terminal da Odete, comparando com a saída do node do Mac.
///
/// Desligada por padrão — precisa das fixtures baixadas com o npm do Mac. Para ligar:
///
///     cd /private/tmp/odete-fumaca && npm i zod yargs chalk express … mime typescript@6
///     node gerar.js && node esperado.js
///     TEST_RUNNER_ODETE_FUMACA=/private/tmp/odete-fumaca xcodebuild test …
///
/// `gerar.js` escreve um script por pacote em `fumaca/`; `esperado.js` grava a saída de
/// referência em `esperado.json`. O resultado (passa/falha, tempo, o que saiu) vai para
/// `resultado-<jit|semjit>.md` na mesma pasta.
struct FumacaDePacotesTests {
    static let pasta = ProcessInfo.processInfo.environment["ODETE_FUMACA"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: pasta != nil), .timeLimit(.minutes(30)))
    func pacotesMaisUsados() async throws {
        Texto.escolher(.ptBR)
        let raiz = try #require(Self.pasta)
        let esperado = try JSONSerialization.jsonObject(with: Data(contentsOf: raiz.appending(path: "esperado.json")))
            as? [String: String] ?? [:]
        let sh = Shell(root: raiz)
        let modo = ProcessInfo.processInfo.environment["JSC_useJIT"] == "false" ? "semjit" : "jit"
        var tabela = ["| pacote | resultado | tempo | saída |", "|---|---|---|---|"]
        var falhas: [String] = []
        for arquivo in esperado.keys.sorted() {
            let o = Out()
            let t0 = ContinuousClock.now
            // Cancelado o vigia, o `sleep` volta na hora: sem o `guard`, o Ctrl+C dele pegava
            // o próximo pacote.
            let vigia = Task {
                guard await (try? Task.sleep(for: .seconds(180))) != nil else { return }
                sh.cancel()
            }
            var codigo = await sh.run("node fumaca/\(arquivo)", sink: o.sink)
            vigia.cancel()
            // Quem abre servidor vira job no terminal (o prompt volta): espera o job acabar
            // e tira o aviso do job da saída.
            var saida = o.out
            if saida.contains("kill %"), !sh.jobs.isEmpty {
                let limite = ContinuousClock.now + .seconds(120)
                while !sh.jobs.isEmpty, ContinuousClock.now < limite {
                    try await Task.sleep(for: .milliseconds(50))
                }
                if !sh.jobs.isEmpty {
                    codigo = 124
                    sh.killAll()
                }
                try await Task.sleep(for: .milliseconds(100))
                saida = o.out.split(separator: "\n").filter { !$0.contains("kill %") }.joined(separator: "\n")
            }
            let dt = ContinuousClock.now - t0
            let ok = codigo == 0 && saida == esperado[arquivo]
            if !ok {
                falhas.append(arquivo)
            }
            let segundos = Double(dt.components.seconds) + Double(dt.components.attoseconds) / 1e18
            let resumo = (ok ? saida : "código \(codigo); saída: \(saida.prefix(200)); erro: \(o.err.prefix(400))")
                .replacingOccurrences(of: "\n", with: "⏎").replacingOccurrences(of: "|", with: "\\|")
            tabela
                .append(
                    "| \(arquivo) | \(ok ? "passa" : "FALHA") | \(String(format: "%.2f s", segundos)) | \(resumo) |"
                )
        }
        try (tabela.joined(separator: "\n") + "\n").write(
            to: raiz.appending(path: "resultado-\(modo).md"), atomically: true, encoding: .utf8
        )
        #expect(falhas.isEmpty, Comment(rawValue: "falharam: \(falhas.joined(separator: ", "))"))
    }
}
