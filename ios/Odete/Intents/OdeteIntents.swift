import AppIntents
import OdeteApp

/// Um projeto da Odete, para os parâmetros dos atalhos.
struct ProjetoEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Projeto")
    static let defaultQuery = ProjetoQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ProjetoQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ProjetoEntity] {
        IntentBridge.shared.projects().filter { identifiers.contains($0.id) }.map { ProjetoEntity(
            id: $0.id,
            name: $0.name
        ) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ProjetoEntity] {
        IntentBridge.shared.projects().map { ProjetoEntity(id: $0.id, name: $0.name) }
    }
}

enum TemplateOption: String, AppEnum {
    case blank, viteReact, astro, swiftPlayground, swiftView
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Modelo")
    static let caseDisplayRepresentations: [TemplateOption: DisplayRepresentation] = [
        .blank: "Em branco", .viteReact: "Vite + React", .astro: "Astro", .swiftPlayground: "Swift Playground",
        .swiftView: "SwiftUI View",
    ]
}

struct AbrirProjetoIntent: AppIntent {
    static let title: LocalizedStringResource = "Abrir projeto"
    static let description = IntentDescription("Abre um projeto na Odete.")
    static let openAppWhenRun = true
    @Parameter(title: "Projeto") var projeto: ProjetoEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard IntentBridge.shared.openProject(projeto.id) else { throw IntentError.naoEncontrado }
        return .result()
    }
}

struct RodarComandoIntent: AppIntent {
    static let title: LocalizedStringResource = "Rodar comando"
    static let description = IntentDescription("Roda um comando no terminal do projeto (ex.: npm run dev).")
    static let openAppWhenRun = true
    @Parameter(title: "Projeto") var projeto: ProjetoEntity
    @Parameter(title: "Comando") var comando: String

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard IntentBridge.shared.runCommand(comando, in: projeto.id) else { throw IntentError.naoEncontrado }
        return .result(value: "Rodando `\(comando)` em \(projeto.name).")
    }
}

struct PerguntarAoAgenteIntent: AppIntent {
    static let title: LocalizedStringResource = "Perguntar à Odete"
    static let description = IntentDescription("Faz uma pergunta ao agente e devolve a resposta.")
    @Parameter(title: "Pergunta") var pergunta: String
    @Parameter(title: "Projeto") var projeto: ProjetoEntity?

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let answer = try await IntentBridge.shared.ask(pergunta, in: projeto?.id)
        return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
    }
}

struct NovoProjetoIntent: AppIntent {
    static let title: LocalizedStringResource = "Novo projeto"
    static let description = IntentDescription("Cria um projeto a partir de um modelo.")
    static let openAppWhenRun = true
    @Parameter(title: "Nome") var nome: String
    @Parameter(title: "Modelo", default: .blank) var modelo: TemplateOption

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<ProjetoEntity> {
        guard let p = IntentBridge.shared.newProject(name: nome, template: modelo.rawValue)
        else { throw IntentError.naoCriado }
        _ = IntentBridge.shared.openProject(p.id)
        return .result(value: ProjetoEntity(id: p.id, name: p.name))
    }
}

enum IntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case naoEncontrado, naoCriado
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .naoEncontrado: "Projeto não encontrado na Odete."
        case .naoCriado: "Não deu para criar o projeto (nome inválido ou já existe)."
        }
    }
}

struct OdeteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PerguntarAoAgenteIntent(),
            phrases: ["Perguntar à \(.applicationName)", "Pergunte à \(.applicationName)"],
            shortTitle: "Perguntar à Odete",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: AbrirProjetoIntent(),
            phrases: ["Abrir projeto na \(.applicationName)"],
            shortTitle: "Abrir projeto",
            systemImageName: "folder"
        )
    }
}
