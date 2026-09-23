import Foundation

/// Níveis de esforço: quais o modelo aceita e como cada um vira parâmetro.
///
/// Quem diz os níveis é o modelo — a Models API da Anthropic, a lista do Codex, o
/// catálogo do models.dev ou um 400 que citou os aceitos (ver `Capacidades`). Antes era
/// uma tabela de expressões regulares sobre o nome do modelo, e cada lançamento novo
/// caía no ramo errado dela até alguém lembrar de mexer aqui.
public enum Effort {
    public static let order = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    public static let labels = [
        "none": "None",
        "minimal": "Min",
        "low": "Low",
        "medium": "Mid",
        "high": "High",
        "xhigh": "Extra",
        "max": "Max",
    ]

    /// Os níveis de quem pensa por orçamento (`budget_tokens`): "none" desliga o thinking.
    static let niveisDeOrcamento = ["none", "low", "medium", "high", "max"]

    public static func options(kind: ProviderKind, model: String, fromAPI: [String]? = nil) -> [String] {
        options(kind: kind, model: model, fromAPI: fromAPI, registro: .compartilhado, catalogo: .compartilhado)
    }

    static func options(
        kind: ProviderKind,
        model: String,
        fromAPI: [String]?,
        registro: RegistroDeCapacidades,
        catalogo: CatalogoDeModelos?
    ) -> [String] {
        // O modelo do sistema não tem nível de esforço.
        if kind == .apple {
            return []
        }
        if let f = fromAPI, !f.isEmpty {
            return ordenar(f)
        }
        let id = model.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty else { return [] }
        let c = (registro.ler(kind, id) ?? Capacidades())
            .completada(com: catalogo?.entradaSemEsperar(kind: kind, model: id)?.capacidades)
        return opcoes(c, familia: Familia(kind))
    }

    /// Os níveis a oferecer para um modelo com estas capacidades. Sem informação, os da
    /// geração mais nova da família.
    static func opcoes(_ c: Capacidades?, familia: Familia) -> [String] {
        if let e = c?.esforcos, !e.isEmpty {
            return e
        }
        if c?.pensamento == .orcamento {
            return niveisDeOrcamento
        }
        if c?.esforcos != nil || c?.pensamento == .nenhum {
            return []
        }
        return familia.esforcosMaisNovos
    }

    public static func defaultOption(_ options: [String]) -> String {
        if options.isEmpty {
            return ""
        }
        if options.contains("medium") {
            return "medium"
        }
        if options.contains("high") {
            return "high"
        }
        return options[(options.count - 1) / 2]
    }

    /// O nível que vai no pedido: o escolhido, se o modelo aceita; senão o aceito mais
    /// perto dele (no empate, o mais baixo). Nulo quando não há o que mandar.
    static func nivel(_ pedido: String, aceitos: [String]) -> String? {
        let p = pedido.lowercased().trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, !aceitos.isEmpty else { return nil }
        if aceitos.contains(p) {
            return p
        }
        guard let alvo = order.firstIndex(of: p) else { return nil }
        let perto = aceitos.compactMap { a in order.firstIndex(of: a).map { (a, abs($0 - alvo), $0) } }
            .min { ($0.1, $0.2) < ($1.1, $1.2) }
        return perto?.0
    }

    /// Orçamento de thinking para o modelo que ainda pede `budget_tokens`: uma fração da
    /// saída, sempre abaixo dela (a API recusa orçamento maior ou igual a `max_tokens`).
    static func orcamento(_ nivel: String, saida: Int) -> Int? {
        let fracao: Double
        switch nivel {
        case "minimal", "low": fracao = 1.0 / 16
        case "medium": fracao = 1.0 / 8
        case "high": fracao = 1.0 / 4
        case "xhigh": fracao = 3.0 / 8
        case "max": fracao = 1.0 / 2
        default: return nil
        }
        let teto = saida - 1024
        guard teto >= 1024 else { return nil }
        return min(teto, max(1024, Int(Double(saida) * fracao)))
    }

    /// Na ordem conhecida; um nível que ainda não existia aqui vai para o fim em vez de
    /// sumir.
    static func ordenar(_ niveis: [String]) -> [String] {
        let l = niveis.map { $0.lowercased() }
        var novos: [String] = []
        for n in l where !order.contains(n) && !novos.contains(n) {
            novos.append(n)
        }
        return order.filter(l.contains) + novos
    }
}
