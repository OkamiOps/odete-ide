import Foundation
import OdeteAgent
import OdeteCore
import OdeteI18n

/// O que a tela já sabe sobre erros, no formato das ferramentas do agente.
///
/// Lê as mesmas fontes que o painel Problemas e a barra de status — `allLint` (regras e
/// sintaxe dos arquivos abertos), `run.diagnostics` (o esbuild do servidor de dev),
/// `swiftDiagnostics` e os erros do console do preview —, para o agente contar a mesma
/// coisa que a pessoa está vendo. Mora numa extensão à parte para não mexer no modelo.
extension WorkspaceModel {
    func problemasParaOAgente() -> [Problema] {
        var out: [Problema] = []
        for item in allLint {
            let gravidade: Problema.Gravidade = switch item.issue.severity {
            case .error: .error
            case .warning: .warning
            case .info: .info
            }
            out.append(Problema(
                arquivo: item.path,
                linha: item.issue.line,
                coluna: item.issue.column,
                gravidade: gravidade,
                mensagem: item.issue.message,
                fonte: item.issue.rule == "syntax" ? "syntax" : "lint"
            ))
        }
        for d in run.diagnostics {
            let gravidade: Problema.Gravidade = switch d.kind {
            case .error: .error
            case .warning: .warning
            case .info: .info
            }
            out.append(Problema(
                arquivo: Self.caminhoNoProjeto(d.file, root: root),
                linha: d.line,
                coluna: d.column,
                gravidade: gravidade,
                mensagem: d.text,
                fonte: d.source.isEmpty ? "build" : d.source
            ))
        }
        for d in swiftDiagnostics {
            out.append(Problema(
                arquivo: Self.caminhoNoProjeto(d.file, root: root),
                linha: d.line,
                coluna: nil,
                gravidade: d.kind == .error ? .error : .warning,
                mensagem: d.message,
                fonte: "swift"
            ))
        }
        // Do console, só o que o painel também conta como problema: os erros.
        for c in preview.console where c.level == .error {
            out.append(Problema(
                arquivo: Self.caminhoNoProjeto(c.file, root: root),
                linha: c.line,
                coluna: nil,
                gravidade: .error,
                mensagem: c.text,
                fonte: "preview"
            ))
        }
        return out
    }

    func consoleParaOAgente(_ n: Int) -> [LinhaDoConsole] {
        preview.console.suffix(max(1, n)).map {
            LinhaDoConsole(
                nivel: $0.level.rawValue,
                texto: $0.text,
                arquivo: Self.caminhoNoProjeto($0.file, root: root) ?? $0.file,
                linha: $0.line
            )
        }
    }

    /// Onde o shell do agente está, relativo à raiz. Sem aba do agente ainda, é a raiz —
    /// e não se cria uma só para perguntar.
    func pastaDoShellDoAgente() -> String {
        guard let id = run.agentSessionId, let s = run.sessions.first(where: { $0.id == id }) else { return "" }
        let cwd = s.shell.cwd.standardizedFileURL.path, base = root.standardizedFileURL.path
        return cwd.hasPrefix(base + "/") ? String(cwd.dropFirst(base.count + 1)) : ""
    }

    /// O caminho de um diagnóstico dentro do projeto, ou nada.
    ///
    /// Chega de tudo quanto é jeito: absoluto na pasta do projeto, URL do servidor de dev
    /// com `/@odete/js/` no meio, caminho relativo. A mesma conta do painel Problemas —
    /// e, como lá, só vale se o arquivo existe: apontar o agente para um arquivo que não
    /// está no projeto é mandá-lo procurar o que não vai achar.
    nonisolated static func caminhoNoProjeto(_ f: String?, root: URL) -> String? {
        guard var p = f, !p.isEmpty else { return nil }
        // URL (do servidor de dev, do esquema estático do preview, `file://`): vale o
        // caminho dela. Se ele existir no projeto, é arquivo do projeto.
        if let u = URL(string: p), u.scheme != nil {
            p = u.path
        }
        p = p.replacingOccurrences(of: root.standardizedFileURL.path + "/", with: "")
            .replacingOccurrences(of: root.path + "/", with: "")
        for prefixo in ["/@odete/js/", "/@odete/css/"] where p.hasPrefix(prefixo) {
            p.removeFirst(prefixo.count)
        }
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        guard !p.isEmpty, FileManager.default.fileExists(atPath: root.appending(path: p).path) else { return nil }
        return p
    }
}

public extension AgentModel {
    /// Pede ao agente para consertar problemas que a tela já mostra.
    ///
    /// É o que um botão "Consertar com a Odete" no painel Problemas chama: sem argumentos,
    /// o pedido é para tudo e o agente começa por `read_problems`; com uma lista — um
    /// problema tocado, os de um arquivo —, eles vão escritos no pedido. O painel do agente
    /// aparece, o modo Chat (que não edita) vira Build, e o que a pessoa estava digitando
    /// no compositor volta para lá depois do envio.
    ///
    /// Com `enviar: false` o pedido só entra no compositor, para a pessoa completar.
    func consertarComOdete(_ problemas: [Problema] = [], enviar: Bool = true) {
        let pedido: String
        if problemas.isEmpty {
            pedido = tr(
                "Corrija os problemas que a Odete está mostrando. Comece com read_problems e leia cada arquivo antes de mudar."
            )
        } else {
            let lista = problemas.prefix(20).map { "- " + $0.linhaDeTexto }.joined(separator: "\n")
            pedido = tr(
                "Corrija estes problemas:\n%1$@\n\nLeia cada arquivo antes de mudar e confira com read_problems no fim.",
                lista
            )
        }
        if mode == .chat {
            setMode(.build)
        }
        chrome.snapshot.agentVisible = true
        chrome.snapshot.phoneTab = .agent
        guard enviar else {
            draft = draft.isEmpty ? pedido : pedido + "\n\n" + draft
            focusRequest += 1
            return
        }
        let rascunho = draft
        let anexos = attachments
        draft = pedido
        attachments = []
        send()
        draft = rascunho
        attachments = anexos
    }
}
