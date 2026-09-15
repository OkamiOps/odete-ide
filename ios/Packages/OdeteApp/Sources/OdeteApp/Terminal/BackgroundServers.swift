import Foundation
import UIKit

/// O que acontece com o servidor de dev quando o app sai da frente.
///
/// O iOS suspende as threads do app: a porta continua presa, mas ninguém atende. Medido
/// com o app no fundo, a porta segue listada e o `curl` devolve 000 — ou seja, o
/// servidor vira zumbi e o preview fica girando em cima de nada quando você volta.
///
/// Aqui há duas defesas. Ao sair, uma tarefa de segundo plano segura o app pelo tempo que
/// o sistema conceder, que cobre a ida rápida ao Safari. Ao voltar, cada porta é testada
/// de verdade e a que não responder é derrubada e subida de novo, com o preview
/// reapontado — em vez de deixar o chip verde mentindo.
public extension RunModel {
    /// Segura o app acordado enquanto o sistema deixar.
    func aoSairDeCena() {
        guard !servers.isEmpty, tarefaDeFundo == .invalid else { return }
        tarefaDeFundo = UIApplication.shared.beginBackgroundTask(withName: "odete-dev-server") { [weak self] in
            Task { @MainActor in self?.soltarTarefaDeFundo() }
        }
    }

    func soltarTarefaDeFundo() {
        guard tarefaDeFundo != .invalid else { return }
        UIApplication.shared.endBackgroundTask(tarefaDeFundo)
        tarefaDeFundo = .invalid
    }

    /// Volta para a frente: solta a tarefa e confere quem sobreviveu.
    func aoVoltarParaCena() {
        soltarTarefaDeFundo()
        Task { await revisarServidores() }
    }

    /// Testa cada porta e ressuscita a que morreu.
    internal func revisarServidores() async {
        guard !servers.isEmpty else { return }
        var mortos: [(porta: Int, comando: String)] = []
        for s in servers where await !Self.responde(s.port) {
            mortos.append((s.port, s.command))
        }
        guard !mortos.isEmpty else { return }
        let sessao = active ?? newSession()
        for morto in mortos {
            for j in jobs where j.ports.contains(morto.porta) {
                j.kill()
            }
            sessao.append(.system, "o servidor em :\(morto.porta) não sobreviveu ao app ir para o fundo")
        }
        pruneServers()
        // Subir de novo em vez de só avisar: a pessoa saiu do app e voltou, não pediu
        // para parar nada.
        if let primeiro = mortos.first {
            sessao.append(.system, "subindo de novo…")
            sessao.run(primeiro.comando)
        }
    }

    /// Uma requisição curta, que é a única forma honesta de saber: a porta continua
    /// presa mesmo depois de o servidor parar de atender.
    internal static func responde(_ porta: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(porta)/") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2
        req.httpMethod = "HEAD"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse) != nil
        } catch {
            return false
        }
    }
}
