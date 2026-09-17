import Foundation
import FoundationModels

/// Sinal de que o modelo pediu uma ferramenta e a geração pode parar aí.
///
/// Não é falha: é o jeito de interromper a sessão no instante em que o pedido chega.
/// O framework chamaria a ferramenta por dentro e continuaria escrevendo sozinho, e é
/// justamente isso que não pode acontecer — ver `FerramentaDaOdete`.
struct PedidoDeFerramenta: Error {}

/// Uma ferramenta da Odete oferecida ao modelo do sistema.
///
/// Ela **não executa nada**: anota o pedido e encerra a geração. Quem executa é o
/// `AgentLoop`, como já faz com qualquer outro provedor — é ele que mostra a chamada na
/// tela, segura o que precisa de confirmação e guarda o patch para você aceitar pedaço
/// por pedaço. Deixar o framework executar por dentro da sessão pularia tudo isso, e o
/// modelo da Apple passaria a ser o único que mexe no projeto sem ninguém ver.
///
/// O caminho de chamada de ferramenta do próprio modelo é usado de propósito, em vez de
/// pedir um JSON no meio do texto: num modelo pequeno a gramática guiada é a diferença
/// entre acertar o nome do campo quase sempre e acertar às vezes.
@available(iOS 26.0, *)
struct FerramentaDaOdete: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let anotar: @Sendable (String, String) -> Void

    func call(arguments: GeneratedContent) async throws -> String {
        anotar(name, arguments.jsonString)
        throw PedidoDeFerramenta()
    }
}

/// Traduz o schema JSON das ferramentas para o schema que o `FoundationModels` entende.
///
/// As duas pontas descrevem a mesma coisa — um objeto com campos, alguns obrigatórios —
/// mas por caminhos diferentes: de um lado dicionário de JSON Schema, que é o que os
/// provedores por HTTP mandam; do outro `DynamicGenerationSchema`, que é o que vira
/// gramática na hora de gerar. Só o que as ferramentas da Odete realmente usam está
/// traduzido aqui: texto, número, booleano, lista e escolha entre opções fixas.
@available(iOS 26.0, *)
enum EsquemaApple {
    static func esquema(de spec: ToolSpec) throws -> GenerationSchema {
        try GenerationSchema(root: objeto(nome: spec.name, json: spec.parameters), dependencies: [])
    }

    static func objeto(nome: String, json: [String: Any]) -> DynamicGenerationSchema {
        let campos = json["properties"] as? [String: Any] ?? [:]
        let obrigatorios = Set(json["required"] as? [String] ?? [])
        // Ordem alfabética, e não a que o dicionário devolver: dicionário não tem ordem,
        // e um schema que muda de forma a cada rodada é exatamente o tipo de coisa que
        // faz um modelo pequeno trocar o nome do campo no meio de uma conversa.
        let propriedades = campos.keys.sorted().map { chave in
            let campo = campos[chave] as? [String: Any] ?? [:]
            return DynamicGenerationSchema.Property(
                name: chave,
                description: campo["description"] as? String,
                schema: valor(campo, nome: "\(nome)_\(chave)"),
                isOptional: !obrigatorios.contains(chave)
            )
        }
        return DynamicGenerationSchema(
            name: nome,
            description: json["description"] as? String,
            properties: propriedades
        )
    }

    static func valor(_ campo: [String: Any], nome: String) -> DynamicGenerationSchema {
        // `enum` primeiro: um campo de opções fixas também tem `type: string`, e virar
        // texto livre aqui perderia a única garantia que ele dá.
        if let opcoes = campo["enum"] as? [String], !opcoes.isEmpty {
            return DynamicGenerationSchema(name: nome, anyOf: opcoes)
        }
        switch campo["type"] as? String {
        case "number", "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "array":
            let itens = campo["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(arrayOf: valor(itens, nome: "\(nome)_item"))
        default:
            return DynamicGenerationSchema(type: String.self)
        }
    }
}
