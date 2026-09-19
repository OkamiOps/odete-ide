import Foundation
@testable import OdeteAgent
import Testing

/// Imprime o que o provedor da Apple realmente manda ao modelo.
///
/// Não é teste de comportamento: é a ponte para a bancada. O modelo do sistema não existe
/// no simulador, então quem experimenta com ele de verdade é um programa à parte, rodando
/// no Mac — onde o mesmo modelo existe. E esse programa precisa receber o texto **que o
/// app manda**, não uma cópia escrita à mão que envelhece em dois dias.
///
/// Sai pela saída padrão, em pedaços numerados de base64. Parece exagero e não é: o
/// `xcodebuild` entremeia as linhas dos outros testes no meio de um `print` grande, e o
/// JSON chega picado do outro lado. Numerado, dá para remontar na ordem certa; em base64,
/// nenhum pedaço traz acento cortado ao meio. Arquivo não serve: o temporário do
/// simulador some quando o processo de teste termina.
struct DespejaContexto {
    @Test func despeja() throws {
        let sistema = Prompts.build(
            mode: .build,
            fileList: ["index.html", "src/main.js", "src/style.css", "README.md"],
            extras: []
        )
        let pacote: [String: Any] = [
            "instrucoes": AppleProvider.instrucoes(sistema, comFerramentas: true),
            "ferramentas": Tools.forMode(.build).map {
                ["nome": $0.name, "descricao": $0.description, "parametros": $0.parametersJSON]
            },
        ]
        let dados = try JSONSerialization.data(withJSONObject: pacote, options: [.sortedKeys])
        let codificado = Array(dados.base64EncodedString())
        for (i, pedaco) in stride(from: 0, to: codificado.count, by: 400).enumerated() {
            let fim = min(pedaco + 400, codificado.count)
            print(String(format: "ODETE_CTX %03d %@", i, String(codificado[pedaco ..< fim])))
        }
    }
}
