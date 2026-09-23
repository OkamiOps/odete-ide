import Foundation

/// Uma regra de `overrides`: o valor para o próprio pacote (`"."` ou a regra em texto)
/// e as regras para o que está abaixo dele.
struct Sobrescrita: Sendable {
    var chave: String
    var valor: String?
    var filhos: [Sobrescrita]

    /// Lê o `overrides` do npm (e o `resolutions` do yarn e o `pnpm.overrides`, que
    /// valem para todo o projeto do mesmo jeito).
    static func raiz(_ pkg: PackageJSON) -> Sobrescrita {
        var filhos = ler(pkg.json["overrides"])
        for (k, v) in (pkg.json["resolutions"]?.pares ?? []) + (pkg.json["pnpm"]?["overrides"]?.pares ?? []) {
            // `**/pacote` do yarn vale em qualquer lugar: é a regra global do npm.
            let nome = k.hasPrefix("**/") ? String(k.dropFirst(3)) : k
            if let s = v.comoTexto, !nome.contains("/") || nome.hasPrefix("@") {
                filhos.append(Sobrescrita(chave: nome, valor: s, filhos: []))
            }
        }
        return Sobrescrita(chave: "", valor: nil, filhos: filhos)
    }

    static func ler(_ j: JSONOrdenado?) -> [Sobrescrita] {
        (j?.pares ?? []).compactMap { k, v in
            if let s = v.comoTexto {
                return Sobrescrita(chave: k, valor: s, filhos: [])
            }
            guard case .objeto = v else { return nil }
            return Sobrescrita(chave: k, valor: v["."]?.comoTexto, filhos: ler(.objeto(v.pares.filter { $0.0 != "." })))
        }
    }

    /// A regra deste nível que vale para o pacote `nome` pedido com `faixa`.
    func regra(_ nome: String, faixa: String) -> Sobrescrita? {
        filhos.last { r in
            let (n, seletor) = Pedido.separarNomeEFaixa(r.chave)
            guard n == nome else { return false }
            guard !seletor.isEmpty else { return true }
            // `pacote@^1` só vale para pedido que cai nessa faixa.
            let sel = SemverRange(seletor)
            if let v = Version(faixa) {
                return sel.satisfies(v)
            }
            if let menor = SemverRange(faixa).menorVersao, sel.satisfies(menor) {
                return true
            }
            if let menor = sel.menorVersao {
                return SemverRange(faixa).satisfies(menor)
            }
            return false
        }
    }
}

/// Packuments pedidos antes da hora, com limite de quantos ficam no ar ao mesmo tempo.
///
/// Antes a resolução pedia um, esperava, pedia o próximo: numa árvore de trezentos
/// pacotes, trezentas idas e voltas ao registro em fila. Aqui a fila de pedidos anda na
/// frente, e quem resolve só espera o que ainda não chegou.
///
/// Vive dentro de uma resolução só, sem sair da tarefa dela.
final class BuscaDePackuments {
    private var tarefas: [String: Task<Packument, Error>] = [:]
    private let registry: any RegistryClient
    private let vagas: Vagas

    init(registry: any RegistryClient, simultaneas: Int) {
        self.registry = registry
        vagas = Vagas(simultaneas)
    }

    /// Pedidos ainda não entregues, no ar ou já chegados.
    var pendentes: Int {
        tarefas.count
    }

    func pedir(_ nome: String) {
        guard tarefas[nome] == nil else { return }
        let registry = registry
        let vagas = vagas
        tarefas[nome] = Task {
            await vagas.esperar()
            do {
                try Task.checkCancellation()
                let p = try await registry.packument(nome)
                await vagas.liberar()
                return p
            } catch {
                await vagas.liberar()
                throw error
            }
        }
    }

    /// Já buscado por outro caminho (o `npm install x` busca antes de resolver).
    func semear(_ nome: String, _ p: Packument) {
        tarefas[nome] = Task { p }
    }

    /// Entrega o packument e esquece dele. Sem pedido feito, pede agora.
    func tomar(_ nome: String) async throws -> Packument {
        pedir(nome)
        guard let t = tarefas.removeValue(forKey: nome) else { throw CancellationError() }
        return try await t.value
    }

    func descartar(_ nome: String) {
        tarefas.removeValue(forKey: nome)?.cancel()
    }

    func cancelarTudo() {
        for t in tarefas.values {
            t.cancel()
        }
        tarefas.removeAll()
    }
}

/// Semáforo para `async`: no máximo `n` dentro ao mesmo tempo, os outros esperam em fila.
actor Vagas {
    private var livres: Int
    private var esperando: [CheckedContinuation<Void, Never>] = []

    init(_ n: Int) {
        livres = n
    }

    func esperar() async {
        if livres > 0 {
            livres -= 1
            return
        }
        await withCheckedContinuation { esperando.append($0) }
    }

    func liberar() {
        if esperando.isEmpty {
            livres += 1
        } else {
            esperando.removeFirst().resume()
        }
    }
}
