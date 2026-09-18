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
/// Sai pela saída padrão entre marcas porque variável de ambiente não atravessa do
/// `xcodebuild` para dentro do simulador.
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
        print("ODETE_CONTEXTO_INICIO")
        print(String(decoding: dados, as: UTF8.self))
        print("ODETE_CONTEXTO_FIM")
    }
}
