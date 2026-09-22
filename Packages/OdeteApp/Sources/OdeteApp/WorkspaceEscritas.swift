import Foundation

/// O aviso do observador que o próprio salvamento provoca.
///
/// Gravar é criar um temporário e renomeá-lo por cima, e a pasta do arquivo acusa a
/// mudança. Cada aviso desses remontava a árvore, relia no ator principal toda aba limpa,
/// trocava árvore, caminhos, pacotes e scripts (o que redesenhava árvore, editor e
/// terminal), rodava o status do git de novo e fazia o preview Swift recompilar — um
/// segundo depois de cada pausa na digitação, com salvamento automático. Quando o aviso é
/// só da gravação do app, nada disso muda, e nada disso roda.
extension WorkspaceModel {
    /// O observador avisou que alguma pasta do projeto mudou.
    ///
    /// Com gravação do próprio app pendente, quem decide é `conferirEscritasProprias`: se o
    /// aviso foi só dela, nada é relido.
    func externalReload() {
        if escritas.temPendentes {
            conferirEscritasProprias()
            return
        }
        recarregarDeFora()
    }

    /// Scripts são pares sem `Equatable`, e o `@Observable` só deixa de avisar quando o
    /// valor novo é igual se souber comparar: sem isto, toda remontagem da árvore
    /// redesenhava o terminal, que é quem lista os scripts.
    func trocarScripts(_ novos: [(nome: String, comando: String)]) {
        guard novos.map(\.nome) != scripts.map(\.nome) || novos.map(\.comando) != scripts.map(\.comando)
        else { return }
        scripts = novos
    }

    /// Decide, fora do ator principal, se o aviso foi só das gravações do app. Se não foi,
    /// recarrega como sempre.
    func conferirEscritasProprias() {
        guard let base = escritas.base else {
            // A fotografia de depois da gravação ainda não chegou: sem ela não dá para
            // saber, e recarregar é o lado seguro.
            escritas.esquecer()
            recarregarDeFora()
            return
        }
        let pendentes = escritas.pendentes
        let raiz = root
        escritas.esquecer()
        Task.detached(priority: .utility) {
            let agora = EscritasProprias.assinaturaDasPastas(raiz: raiz)
            let soDoApp = EscritasProprias.soProprias(pendentes: pendentes, base: base, agora: agora) {
                try? String(contentsOf: raiz.appending(path: $0), encoding: .utf8)
            }
            guard !soDoApp else { return }
            await self.recarregarDeFora()
        }
    }

    /// Guarda o que acabou de ser gravado e tira, fora do ator principal, a fotografia das
    /// pastas logo depois — é contra ela que o próximo aviso do observador é comparado.
    func registrarEscritaPropria(_ caminho: String, _ texto: String) {
        let seq = escritas.registrar(caminho, texto: texto)
        let raiz = root
        Task.detached(priority: .utility) {
            let base = EscritasProprias.assinaturaDasPastas(raiz: raiz)
            await self.anotarBase(base, sequencia: seq)
        }
    }

    private func anotarBase(_ base: [String: Date], sequencia: Int) {
        escritas.anotarBase(base, sequencia: sequencia)
    }
}

/// O que o próprio app gravou no disco e o observador ainda não avisou.
///
/// O observador de pastas não diz o que mudou, só que algo mudou numa pasta. Para saber
/// se o aviso foi só do salvamento do app, cada gravação guarda o caminho e a impressão
/// do conteúdo, e logo depois tira uma fotografia das pastas (a data de modificação de
/// cada uma). Criar, apagar ou renomear qualquer coisa numa pasta muda a data dela; então,
/// se no aviso as pastas estão como na fotografia e cada arquivo gravado ainda tem o que
/// o app escreveu, nada além do app mexeu ali.
struct EscritasProprias {
    /// Caminho relativo → impressão do conteúdo gravado.
    private(set) var pendentes: [String: UInt64] = [:]
    /// As pastas logo depois da última gravação.
    private(set) var base: [String: Date]?
    /// Sobe a cada gravação: a fotografia de uma gravação antiga que chega atrasada não
    /// vale pela da nova.
    private(set) var sequencia = 0

    var temPendentes: Bool {
        !pendentes.isEmpty
    }

    mutating func registrar(_ caminho: String, texto: String) -> Int {
        pendentes[caminho] = Self.impressao(texto)
        base = nil
        sequencia += 1
        return sequencia
    }

    mutating func anotarBase(_ fotografia: [String: Date], sequencia s: Int) {
        if s == sequencia {
            base = fotografia
        }
    }

    mutating func esquecer() {
        pendentes = [:]
        base = nil
    }

    /// O aviso foi só das gravações do app?
    static func soProprias(
        pendentes: [String: UInt64],
        base: [String: Date],
        agora: [String: Date],
        ler: (String) -> String?
    ) -> Bool {
        guard !pendentes.isEmpty, base == agora else { return false }
        return pendentes.allSatisfy { caminho, marca in ler(caminho).map(impressao) == marca }
    }

    /// FNV-1a de 64 bits sobre os bytes UTF-8. Não é `hashValue` porque este muda a cada
    /// execução, e a conta tem de ser a mesma dos dois lados da comparação.
    static func impressao(_ texto: String) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in texto.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }

    /// Pastas que o observador não vigia — as mesmas de `ObservadorDeArquivos`: o que
    /// muda ali não chega como aviso, então também não entra na fotografia.
    static let ignoradas: Set<String> = [
        "node_modules", ".git", ".build", "dist", ".next", ".cache", "build", ".odete",
    ]

    /// A data de modificação de cada pasta vigiada, com o mesmo teto do observador.
    static func assinaturaDasPastas(raiz: URL, teto: Int = 400) -> [String: Date] {
        let fm = FileManager.default
        var out: [String: Date] = [:]
        if let d = (try? fm.attributesOfItem(atPath: raiz.path))?[.modificationDate] as? Date {
            out[raiz.path] = d
        }
        var fila = [raiz]
        while !fila.isEmpty, out.count < teto {
            let atual = fila.removeFirst()
            let filhas = (try? fm.contentsOfDirectory(
                at: atual,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for f in filhas where out.count < teto && !ignoradas.contains(f.lastPathComponent) {
                guard let v = try? f.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                      v.isDirectory == true else { continue }
                out[f.path] = v.contentModificationDate ?? .distantPast
                fila.append(f)
            }
        }
        return out
    }
}
