import Foundation
import FoundationModels

// Bancada: roda o modelo do sistema com o MESMO contexto que o app manda (contexto.json,
// despejado pelo teste DespejaContexto) e imprime a sequência de chamadas de ferramenta.
// É o laço do agente reproduzido: sessão refeita por rodada a partir da transcrição,
// ferramenta que anota e aborta, ferramentas executadas de verdade num projeto temporário.

struct Pedido: Error {}

final class Caixa: @unchecked Sendable {
    private var v: (String, String)?
    private let l = NSLock()
    func por(_ n: String, _ a: String) {
        l.lock(); if v == nil {
            v = (n, a)
        }; l.unlock()
    }

    func pega() -> (String, String)? {
        l.lock(); defer { v = nil; l.unlock() }; return v
    }

    func espia() -> Bool {
        l.lock(); defer { l.unlock() }; return v != nil
    }
}

struct Anotadora: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String
    let name: String
    let description: String
    let parameters: GenerationSchema
    let caixa: Caixa
    func call(arguments: GeneratedContent) async throws -> String {
        caixa.por(name, arguments.jsonString)
        throw Pedido()
    }
}

func esquema(_ nome: String, _ json: [String: Any]) throws -> GenerationSchema {
    let campos = json["properties"] as? [String: Any] ?? [:]
    let obrig = Set(json["required"] as? [String] ?? [])
    let props = campos.keys.sorted().map { chave -> DynamicGenerationSchema.Property in
        let campo = campos[chave] as? [String: Any] ?? [:]
        let s = if let op = campo["enum"] as? [String], !op.isEmpty {
            DynamicGenerationSchema(name: "\(nome)_\(chave)", anyOf: op)
        } else {
            switch campo["type"] as? String {
            case "number", "integer": DynamicGenerationSchema(type: Int.self)
            case "boolean": DynamicGenerationSchema(type: Bool.self)
            default: DynamicGenerationSchema(type: String.self)
            }
        }
        return .init(
            name: chave,
            description: campo["description"] as? String,
            schema: s,
            isOptional: !obrig.contains(chave)
        )
    }
    return try GenerationSchema(root: DynamicGenerationSchema(name: nome, properties: props), dependencies: [])
}

// MARK: projeto de mentira, ferramentas de verdade

let raiz = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "bancada-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: raiz.appending(path: "src"), withIntermediateDirectories: true)
let arquivos: [String: String] = [
    "index.html": """
    <!doctype html>
    <html lang="pt-BR">
      <head><link rel="stylesheet" href="/src/style.css" /></head>
      <body>
        <main class="page">
          <h1>Apple Validation</h1>
          <button id="ok" type="button">Count Click</button>
          <p id="out">0 cliques</p>
        </main>
        <script type="module" src="/src/main.js"></script>
      </body>
    </html>
    """,
    "src/style.css": """
    :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
    body { margin: 0; display: grid; place-items: center; min-height: 100vh; }
    .page { text-align: center; padding: 2rem; }
    button { font: inherit; padding: .6rem 1.2rem; }
    """,
    "src/main.js": "const out = document.getElementById(\"out\");\nlet n = 0;\n",
    "README.md": "# Apple Validation\n",
]
for (c, t) in arquivos {
    try t.write(to: raiz.appending(path: c), atomically: true, encoding: .utf8)
}

func roda(_ nome: String, _ args: [String: Any]) -> String {
    let caminho = (args["path"] as? String) ?? ""
    let url = raiz.appending(path: caminho)
    switch nome {
    case "read_file":
        return (try? String(contentsOf: url, encoding: .utf8)) ?? "não existe: \(caminho)"
    case "list_dir":
        return arquivos.keys.sorted().joined(separator: "\n")
    case "str_replace":
        guard let antes = try? String(contentsOf: url, encoding: .utf8) else { return "não existe: \(caminho)" }
        let velho = (args["old"] as? String) ?? "", novo = (args["new"] as? String) ?? ""
        guard velho != novo else { return "old e new são iguais — isso não mudaria nada." }
        guard antes.contains(velho), !velho.isEmpty else { return "trecho não encontrado — leia o arquivo de novo" }
        let depois = antes.replacingOccurrences(of: velho, with: novo)
        try? depois.write(to: url, atomically: true, encoding: .utf8)
        return "escrito \(caminho) (\(antes.components(separatedBy: "\n").count) → \(depois.components(separatedBy: "\n").count) linhas)"
    case "write_file":
        guard let conteudo = args["content"] as? String else { return "faltou content" }
        try? conteudo.write(to: url, atomically: true, encoding: .utf8)
        return "escrito \(caminho)"
    default:
        return "ok"
    }
}

// MARK: contexto real, vindo do app

struct ContextoRuim: Error {}

func dicionario(_ d: Data) throws -> [String: Any] {
    guard let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ContextoRuim() }
    return o
}

let dados = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let ctx = try dicionario(dados)
guard let instrucoes = ctx["instrucoes"] as? String,
      let specs = ctx["ferramentas"] as? [[String: String]]
else { throw ContextoRuim() }

let caixa = Caixa()
let ferramentas: [any Tool] = try specs.compactMap { spec in
    guard let nome = spec["nome"], let descricao = spec["descricao"], let params = spec["parametros"]
    else { throw ContextoRuim() }
    return try Anotadora(
        name: nome,
        description: descricao,
        parameters: esquema(nome, dicionario(Data(params.utf8))),
        caixa: caixa
    )
}

// MARK: o laço

enum Fala { case pessoa(String), assistente(String), chamada(String, String, String), resultado(String, String, String)
}

let pedidoTexto = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "deixa o botão azul"
var falas: [Fala] = [.pessoa(pedidoTexto)]
var sequencia: [String] = []
var repetidas: [String: Int] = [:]

for rodada in 1 ... 20 {
    var entradas: [Transcript.Entry] = [.instructions(.init(
        segments: [.text(.init(content: instrucoes))],
        toolDefinitions: ferramentas.map { Transcript.ToolDefinition(tool: $0) }
    ))]
    // Três estados: nada feito, leu mas não editou, já editou. A ordem muda em cada um —
    // mandar "aplique com str_replace" depois de aplicado é pedir para aplicar de novo.
    var leu = false, editou = false
    for f in falas {
        if case let .resultado(_, nome, texto) = f {
            if nome == "read_file" || nome == "list_dir" || nome == "grep" {
                leu = true
            }
            if texto.hasPrefix("escrito ") {
                editou = true
            }
        }
    }
    var errouTrecho = false
    for f in falas {
        if case let .resultado(_, _, texto) = f {
            if texto.hasPrefix("trecho não encontrado") {
                errouTrecho = true
            } else if !texto.isEmpty {
                errouTrecho = false
            }
        }
    }
    var prompt = if errouTrecho {
        "Pedido: \(pedidoTexto)\n\nO trecho não foi encontrado no arquivo. Chame read_file de novo e copie daí o texto exato antes de tentar outra vez."
    } else if editou {
        "Pedido: \(pedidoTexto)\n\nA mudança já foi aplicada no arquivo. Diga em uma frase o que mudou e pare. Não chame mais ferramentas."
    } else if leu {
        "Pedido: \(pedidoTexto)\n\nAgora aplique a mudança chamando str_replace, com old copiado exatamente do que você leu. Não explique antes de chamar."
    } else {
        "\(pedidoTexto)\n\nPrimeiro passo: chame read_file no arquivo que precisa mudar, ou list_dir se não souber qual. Não explique antes de chamar."
    }
    for (i, f) in falas.enumerated() {
        switch f {
        case let .pessoa(t):
            if i != falas.count - 1 {
                entradas.append(.prompt(.init(segments: [.text(.init(content: t))])))
            }
        case let .assistente(t):
            entradas.append(.response(.init(assetIDs: [], segments: [.text(.init(content: t))])))
        case let .chamada(id, nome, args):
            entradas.append(.toolCalls(.init([.init(
                id: id,
                toolName: nome,
                arguments: (try? GeneratedContent(json: args)) ??
                    GeneratedContent(args)
            )])))
        case let .resultado(id, nome, texto):
            entradas.append(.toolOutput(.init(id: id, toolName: nome, segments: [.text(.init(content: texto))])))
        }
    }
    let sessao = LanguageModelSession(model: .default, tools: ferramentas, transcript: Transcript(entries: entradas))
    var texto = ""
    do {
        let temp = Double(ProcessInfo.processInfo.environment["ODETE_TEMP"] ?? "0.6") ?? 0.6
        let r = try await sessao.respond(
            to: prompt,
            options: GenerationOptions(temperature: temp, maximumResponseTokens: 2730)
        )
        texto = r.content
    } catch {
        if !caixa.espia() {
            print("ERRO rodada \(rodada): \(error)"); break
        }
    }
    guard let (nome, args) = caixa.pega() else {
        if !texto.isEmpty {
            falas.append(.assistente(texto))
        }
        sequencia.append("texto: \(texto.prefix(90).replacingOccurrences(of: "\n", with: " "))")
        print("— fim na rodada \(rodada)")
        break
    }
    let assinatura = "\(nome)|\(args)"
    repetidas[assinatura, default: 0] += 1
    let id = "c\(rodada)"
    falas.append(.chamada(id, nome, args))
    let saida: String
    if repetidas[assinatura]! > 3 {
        saida = "Você já chamou \(nome) com estes mesmos argumentos e o resultado não mudou. Não repita: use o que já leu. Se a mudança já foi feita, diga o que mudou e encerre."
        sequencia.append("\(nome) [repetida]")
    } else {
        let a = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        saida = roda(nome, a)
        sequencia.append("\(nome) \((a["path"] as? String) ?? "")")
    }
    falas.append(.resultado(id, nome, saida))
}

print("\n=== sequência (\(sequencia.count)) ===")
for (i, s) in sequencia.enumerated() {
    print(String(format: "%2d. %@", i + 1, s))
}

print("\n=== style.css final ===")
print((try? String(contentsOf: raiz.appending(path: "src/style.css"), encoding: .utf8)) ?? "?")
