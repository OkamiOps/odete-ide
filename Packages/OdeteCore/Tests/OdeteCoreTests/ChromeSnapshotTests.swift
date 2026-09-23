import Foundation
@testable import OdeteCore
import Testing

struct ChromeSnapshotTests {
    /// O estado salvo de quem usou uma versão anterior pode ter painel que não existe
    /// mais. Se isso derrubar a decodificação, some tudo junto: tema, abas, projetos.
    @Test func painelDesconhecidoViraArquivosSemLevarORestoJunto() throws {
        let json = """
        {"side":"outline","theme":"cursor","sideOpen":true,"sideWidth":321,"center":"preview"}
        """
        let snap = try JSONDecoder().decode(ChromeSnapshot.self, from: Data(json.utf8))
        #expect(snap.side == .files)
        #expect(snap.theme == .cursor)
        #expect(snap.sideWidth == 321)
        #expect(snap.center == .preview)
    }

    @Test func painelConhecidoContinuaValendo() throws {
        let json = #"{"side":"git"}"#
        let snap = try JSONDecoder().decode(ChromeSnapshot.self, from: Data(json.utf8))
        #expect(snap.side == .git)
    }

    /// Um valor que esta versão não conhece — tema novo, fonte removida, modo que mudou
    /// de nome — zerava o state.json inteiro: abas, ajustes e o fim do onboarding. Agora
    /// vale o padrão só daquele campo.
    @Test(arguments: [
        ("theme", #""neon""#), ("themeLight", #""neon""#), ("themeDark", #""neon""#),
        ("center", #""triplo""#), ("phoneTab", #""relogio""#), ("sideSide", #""cima""#),
        ("agentSide", #""cima""#), ("termPlace", #""janela""#), ("termFont", #""comic""#),
        ("sideWidth", #""largo""#), ("welcomeDone", #""sim""#), ("tabsByProject", #""nada""#),
        ("editor", #"{"minimap":"xl","fontFamily":"comic","fontSize":17}"#),
    ])
    func valorDesconhecidoZeraSoOCampo(chave: String, valor: String) throws {
        let pid = "11111111-1111-1111-1111-111111111111"
        var campos: [String: String] = [
            "welcomeDone": "true", "projectsInCloud": "true", "theme": #""latte""#, "sideWidth": "300",
            "lastProjectId": #""\#(pid)""#,
            "tabsByProject": #"["\#(pid)",[{"path":"a.ts","isDirty":false}]]"#,
        ]
        campos[chave] = valor
        let json = "{" + campos.map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",") + "}"
        let snap = try JSONDecoder().decode(ChromeSnapshot.self, from: Data(json.utf8))
        #expect(snap.projectsInCloud)
        #expect(snap.lastProjectId == UUID(uuidString: pid))
        if chave != "welcomeDone" {
            #expect(snap.welcomeDone)
        }
        if chave != "tabsByProject" {
            #expect(try snap.tabsByProject[#require(UUID(uuidString: pid))]?.map(\.path) == ["a.ts"])
        }
        if chave != "theme" {
            #expect(snap.theme == .latte)
        } else {
            #expect(snap.theme == ChromeSnapshot().theme)
        }
        if chave == "editor" {
            #expect(snap.editor.fontSize == 17)
            #expect(snap.editor.minimap == EditorPrefs().minimap)
        }
    }

    /// Uma aba estragada não leva as abas do projeto, nem as dos outros projetos.
    @Test func abaEstragadaNaoLevaAsOutras() throws {
        let a = "11111111-1111-1111-1111-111111111111", b = "22222222-2222-2222-2222-222222222222"
        let json = """
        {"welcomeDone":true,"tabsByProject":["\(a)",[{"path":"um.ts"},{"isDirty":true},{"path":"dois.ts","isDirty":true}],
        "nao-e-uuid",[{"path":"x"}],"\(b)",[{"path":"b.ts","isDirty":false}]],
        "agentByProject":["\(a)",{"model":"m","mode":"plan"}]}
        """
        let snap = try JSONDecoder().decode(ChromeSnapshot.self, from: Data(json.utf8))
        #expect(snap.welcomeDone)
        #expect(try snap.tabsByProject[#require(UUID(uuidString: a))]?.map(\.path) == ["um.ts", "dois.ts"])
        #expect(try snap.tabsByProject[#require(UUID(uuidString: b))]?.map(\.path) == ["b.ts"])
        // Preferência do agente gravada antes de um campo existir: o resto continua.
        #expect(try snap.agentByProject[#require(UUID(uuidString: a))]?.model == "m")
        #expect(try snap.agentByProject[#require(UUID(uuidString: a))]?.mode == "plan")
        #expect(try snap.agentByProject[#require(UUID(uuidString: a))]?.permit == AgentPrefs().permit)
    }

    /// O que se grava hoje volta igual.
    @Test func idaEVoltaContinuaIgual() throws {
        var s = ChromeSnapshot()
        s.welcomeDone = true
        s.theme = .darcula
        s.editor.minimap = .l
        let pid = UUID()
        s.tabsByProject[pid] = [EditorTab(path: "a", isDirty: true)]
        s.activeTabByProject[pid] = "a"
        s.expandedByProject[pid] = ["src"]
        var ag = AgentPrefs()
        ag.model = "x"
        s.agentByProject[pid] = ag
        s.syntaxOverrides = ["keyword": "#ff0000"]
        let d = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(ChromeSnapshot.self, from: d) == s)
    }
}
