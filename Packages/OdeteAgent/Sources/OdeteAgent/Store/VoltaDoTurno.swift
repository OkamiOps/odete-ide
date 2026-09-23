import CryptoKit
import Foundation
import OdeteI18n

/// Como um arquivo estava num instante.
///
/// Tamanho e hora de modificação custam uma chamada de `stat` e bastam para quase tudo. O
/// resumo do conteúdo só entra para o que o turno mexeu: é ele que diz que um arquivo cuja
/// hora mudou — o editor regravou o mesmo texto depois de recarregar — continua igual.
struct Assinatura: Codable, Sendable, Hashable {
    var tamanho: Int64
    /// Nanossegundos desde 1970. Em `Date`, com a estratégia ISO 8601 do manifesto, viraria
    /// segundo cheio, e duas gravações no mesmo segundo pareceriam uma só.
    var mtime: Int64
    /// SHA-256 do conteúdo, em hexadecimal.
    var resumo: String?

    /// Chaves curtas: o fim do turno guarda uma destas por arquivo do projeto.
    enum CodingKeys: String, CodingKey { case tamanho = "t", mtime = "m", resumo = "h" }

    /// A assinatura e a hora da última mudança de qualquer tipo no arquivo (`ctime`), ou
    /// `nil` se não há arquivo comum ali.
    ///
    /// O `ctime` não vai para o disco: serve só no fim do turno, para saber se a mudança
    /// aconteceu enquanto o shell do agente rodava. Ele é melhor que a hora de modificação
    /// para isso porque ninguém consegue voltá-lo — `cp -p`, `unzip` e `touch -d` põem uma
    /// hora antiga no `mtime`, mas o `ctime` fica sendo a hora em que mexeram.
    static func ler(_ url: URL) -> (assinatura: Assinatura, ctime: Int64)? {
        var st = stat()
        guard stat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        let a = Assinatura(tamanho: Int64(st.st_size), mtime: nanos(st.st_mtimespec))
        return (a, nanos(st.st_ctimespec))
    }

    static func de(_ url: URL) -> Assinatura? {
        ler(url)?.assinatura
    }

    static func nanos(_ t: timespec) -> Int64 {
        Int64(t.tv_sec) * 1_000_000_000 + Int64(t.tv_nsec)
    }

    static func agora() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000_000)
    }

    /// SHA-256 do arquivo, ou `nil` se ele não dá para ler.
    static func resumir(_ url: URL) -> String? {
        guard let d = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let hex = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(64)
        for b in SHA256.hash(data: d) {
            out.append(hex[Int(b >> 4)])
            out.append(hex[Int(b & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// O arquivo em `url`, agora, é o mesmo que ficou no fim do turno?
    ///
    /// Os dois ausentes contam como iguais. Com a hora diferente, só o resumo salva: sem ele
    /// a resposta é "mudou", que é o lado seguro — na dúvida, o arquivo fica como está.
    static func igual(_ agora: Assinatura?, _ noFim: Assinatura?, _ url: URL) -> Bool {
        switch (agora, noFim) {
        case (nil, nil): return true
        case let (a?, f?):
            guard a.tamanho == f.tamanho else { return false }
            if a.mtime == f.mtime {
                return true
            }
            guard let r = f.resumo else { return false }
            return resumir(url) == r
        default: return false
        }
    }
}

/// O fim do turno, em `.odete/checkpoints/<id>/fim.json`.
///
/// Fora do manifesto pelo mesmo motivo de `escritas.json`: a lista de checkpoints é lida
/// ao abrir o projeto, para saber se há o que desfazer, e uma assinatura por arquivo do
/// projeto em cada um dos oito manifestos pesaria nessa leitura. Isto só é lido quando a
/// pessoa pede para desfazer.
struct FimDoTurno: Codable {
    var em: Date
    /// Como cada arquivo do projeto ficou quando o turno terminou. O que não está aqui não
    /// existia — e é por isso que um arquivo criado pela pessoa depois nunca é apagado.
    var assinaturas: [String: Assinatura]
    /// O que o turno criou, mudou ou apagou. Só isto o desfazer toca.
    var doTurno: [String]

    /// Teto da soma dos arquivos resumidos no fim do turno. Acima disso o resto fica só com
    /// tamanho e hora — e, se a hora mudar, fica como está.
    static let tetoDeResumo: Int64 = 64_000_000

    /// Folga em volta de cada janela do shell, para um disco que guarda a hora arredondada
    /// não jogar para fora dela o que aconteceu dentro. Curta de propósito: o que a pessoa
    /// salvar colado num comando do agente cai na janela e passa a contar como do turno.
    static let folga: Int64 = 250_000_000

    /// Mede o projeto no fim do turno e separa o que foi do turno.
    ///
    /// É do turno o que as ferramentas de escrita do agente tocaram, e o que mudou (ou
    /// nasceu) enquanto o shell do agente rodava um comando que escreve. O que mudou fora
    /// dessas janelas é da pessoa, no editor, ou de um servidor que ela deixou rodando — e
    /// desfazer o turno não é desfazer o trabalho dela. O que sumiu no turno conta como do
    /// turno se o shell chegou a rodar: devolver um arquivo apagado nunca perde nada.
    static func medir(
        _ cp: Checkpoint,
        raiz: URL,
        caminhos: [String],
        inicio: [String: Assinatura],
        janelas: [ClosedRange<Int64>]
    ) -> FimDoTurno {
        var assinaturas: [String: Assinatura] = [:]
        var ctimes: [String: Int64] = [:]
        // `depois` entra porque o arquivo que já estava no retrato do começo não é copiado
        // de novo na escrita, e por isso não aparece em `capturados`.
        let escritos = cp.escritos
        // O que o agente escreveu fora da lista do projeto (o plano em `.odete/`) também
        // precisa de retrato.
        for p in Set(caminhos).union(escritos) {
            guard let (a, c) = Assinatura.ler(raiz.appending(path: p)) else { continue }
            assinaturas[p] = a
            ctimes[p] = c
        }
        // Menos o que foi anotado e não mudou — o `package.json` de um `npm install` que
        // não instalou nada —, para a mensagem do desfazer não dizer que ele voltou.
        var doTurno = escritos.filter { p in
            guard let antes = inicio[p], let agora = assinaturas[p] else { return true }
            return antes != agora
        }
        for (p, a) in assinaturas where !escritos.contains(p) && inicio[p] != a {
            if let c = ctimes[p], janelas.contains(where: { $0.contains(c) }) {
                doTurno.insert(p)
            }
        }
        if !janelas.isEmpty {
            for p in cp.paths where assinaturas[p] == nil {
                doTurno.insert(p)
            }
        }
        var orcamento = tetoDeResumo
        for p in doTurno.sorted() {
            guard var a = assinaturas[p], a.tamanho <= orcamento else { continue }
            a.resumo = Assinatura.resumir(raiz.appending(path: p))
            orcamento -= a.tamanho
            assinaturas[p] = a
        }
        return FimDoTurno(em: .now, assinaturas: assinaturas, doTurno: doTurno.sorted())
    }
}

/// O que desfazer um turno fez — ou, na prévia, o que vai fazer.
public struct VoltaDoTurno: Sendable, Equatable {
    public var titulo: String
    /// Voltaram ao conteúdo de antes do turno.
    public var voltaram: [String] = []
    /// Nasceram no turno e saíram.
    public var apagados: [String] = []
    /// O turno mexeu, e a pessoa mexeu de novo depois: ficam como ela deixou.
    public var mantidos: [String] = []
    /// Passavam de `CheckpointStore.tetoPorArquivo`: não há cópia para voltar.
    public var grandes: [String] = []
    /// O turno mudou pelo shell um arquivo que não estava no retrato do começo.
    public var semCopia: [String] = []
    /// Turno de uma versão antiga, ou que não chegou ao fim: sem como saber se a pessoa
    /// mexeu depois, fica como está.
    public var naoConferidos: [String] = []

    public init(titulo: String) {
        self.titulo = titulo
    }

    /// Quantos nomes cabem numa linha antes do "e mais".
    static let tetoDaLista = 8

    /// A mensagem que vai para a conversa: o que voltou, o que saiu e, principalmente, o
    /// que ficou e por quê. Desfazer calado era o que deixava a pessoa sem saber que um
    /// arquivo dela tinha ido embora.
    ///
    /// Cada frase escrita por extenso, e não numa tabela: é assim que o `make i18n` enxerga
    /// as chaves e cobra a tradução delas.
    public var mensagem: String {
        var linhas = [tr("voltou: %1$@", titulo)]
        if !voltaram.isEmpty {
            linhas.append(tr("Voltaram ao que eram antes do turno: %1$@", Self.lista(voltaram)))
        }
        if !apagados.isEmpty {
            linhas.append(tr("Apagados, por terem nascido no turno: %1$@", Self.lista(apagados)))
        }
        if !mantidos.isEmpty {
            linhas.append(tr("Não voltaram, porque você mexeu neles depois do turno: %1$@", Self.lista(mantidos)))
        }
        if !grandes.isEmpty {
            linhas.append(tr("Não voltaram, por passarem de 10 MB: %1$@", Self.lista(grandes)))
        }
        if !semCopia.isEmpty {
            linhas.append(tr("Não voltaram, por não haver cópia de antes do turno: %1$@", Self.lista(semCopia)))
        }
        if !naoConferidos.isEmpty {
            linhas.append(tr(
                "Não voltaram, porque não dá para conferir se você mexeu neles depois do turno: %1$@",
                Self.lista(naoConferidos)
            ))
        }
        return linhas.joined(separator: "\n")
    }

    /// `a, b, c` — ou os primeiros e "e mais N".
    public static func lista(_ caminhos: [String]) -> String {
        guard caminhos.count > tetoDaLista else { return caminhos.joined(separator: ", ") }
        return tr(
            "%1$@ e mais %2$@",
            caminhos.prefix(tetoDaLista).joined(separator: ", "),
            "\(caminhos.count - tetoDaLista)"
        )
    }
}

extension Checkpoint {
    /// Tudo o que as ferramentas de escrita do agente tocaram no turno — inclusive o que
    /// o shell dele apagou ou criou num caminho que dava para ler na linha de comando.
    var escritos: Set<String> {
        Set(capturados + criados + grandes).union((depois ?? [:]).keys)
    }
}

extension CheckpointStore {
    /// O que desfazer `cp` faria, sem mexer em nada.
    ///
    /// `manter` são caminhos que ficam como estão de qualquer jeito, como se a pessoa
    /// tivesse mexido depois: é por onde a tela protege o que está no editor e ainda não
    /// foi gravado — o disco não sabe dessa edição, e voltar o arquivo levaria a aba junto.
    func planejar(_ cp: Checkpoint, manter: Set<String> = []) -> VoltaDoTurno {
        var v = planejarPeloDisco(cp)
        let presos = (v.voltaram + v.apagados).filter(manter.contains)
        guard !presos.isEmpty else { return v }
        v.voltaram.removeAll(where: manter.contains)
        v.apagados.removeAll(where: manter.contains)
        v.mantidos = (v.mantidos + presos).sorted()
        return v
    }

    private func planejarPeloDisco(_ cp: Checkpoint) -> VoltaDoTurno {
        var v = VoltaDoTurno(titulo: cp.title)
        let copias = dir.appending(path: "\(cp.id)/files")
        let fm = FileManager.default
        func temCopia(_ p: String) -> Bool {
            fm.fileExists(atPath: copias.appending(path: p).path)
        }
        guard let fim = fim(cp.id) else { return planejarSemFim(cp, v, temCopia: temCopia) }
        // Existia antes do turno: estava na lista do começo, ou foi copiado antes da
        // primeira escrita, ou era grande demais para copiar.
        let doComeco = Set(cp.paths).union(cp.capturados).union(cp.grandes)
        for p in fim.doTurno {
            let url = root.appending(path: p)
            let agora = Assinatura.de(url)
            guard Assinatura.igual(agora, fim.assinaturas[p], url) else {
                // Mudou depois do turno. Só não entra na lista se o turno criou e a pessoa
                // já apagou: aí não há nada de ninguém para guardar nem para voltar.
                if agora != nil || doComeco.contains(p) {
                    v.mantidos.append(p)
                }
                continue
            }
            if doComeco.contains(p) {
                if temCopia(p) {
                    v.voltaram.append(p)
                } else if cp.grandes.contains(p) {
                    v.grandes.append(p)
                } else {
                    v.semCopia.append(p)
                }
            } else if agora != nil {
                v.apagados.append(p)
            }
        }
        return v
    }

    /// Sem o fim do turno — turno de uma versão antiga, ou que o app não chegou a fechar.
    ///
    /// Aqui não existe varredura: o que não foi escrito pelas ferramentas do agente não é
    /// tocado. E mesmo o que foi só volta se ainda tem o conteúdo que o agente deixou,
    /// conferido pelo resumo anotado na hora da escrita. Os turnos de antes desta versão
    /// não têm esse resumo: nada deles é apagado nem sobrescrito — a lista vai na mensagem,
    /// e a pessoa decide.
    private func planejarSemFim(
        _ cp: Checkpoint,
        _ volta: VoltaDoTurno,
        temCopia: (String) -> Bool
    ) -> VoltaDoTurno {
        var v = volta
        v.grandes = cp.grandes
        let fm = FileManager.default
        guard let depois = cp.depois else {
            v.naoConferidos = (cp.capturados + cp.criados).filter {
                fm.fileExists(atPath: root.appending(path: $0).path) || temCopia($0)
            }.sorted()
            return v
        }
        for p in cp.criados.sorted() {
            let url = root.appending(path: p)
            guard fm.fileExists(atPath: url.path) else { continue }
            guard let r = depois[p] else {
                v.naoConferidos.append(p); continue
            }
            if Assinatura.resumir(url) == r {
                v.apagados.append(p)
            } else {
                v.mantidos.append(p)
            }
        }
        // O que existia antes e foi escrito: copiado na escrita, ou já no retrato do começo.
        let mudados = Set(cp.capturados).union(depois.keys).subtracting(cp.criados)
        for p in mudados.sorted() where temCopia(p) {
            let url = root.appending(path: p)
            guard let r = depois[p] else {
                v.naoConferidos.append(p); continue
            }
            // Vazio é "o agente deixou apagado" (um `rm` do shell).
            let atual = fm.fileExists(atPath: url.path) ? Assinatura.resumir(url) ?? "?" : ""
            if atual == r {
                v.voltaram.append(p)
            } else {
                v.mantidos.append(p)
            }
        }
        return v
    }

    /// O fim gravado do turno `id`, se ele chegou a fechar.
    func fim(_ id: String) -> FimDoTurno? {
        guard let d = try? Data(contentsOf: dir.appending(path: "\(id)/fim.json")) else { return nil }
        return try? JSONDecoder().decode(FimDoTurno.self, from: d)
    }

    /// Aplica o plano: copia de volta, apaga o que o turno criou e tira as pastas que ele
    /// criou e ficaram vazias.
    func aplicar(_ v: VoltaDoTurno, de cp: Checkpoint) {
        let fm = FileManager.default
        for p in v.apagados {
            try? fm.removeItem(at: root.appending(path: p))
        }
        for p in v.voltaram {
            let src = dir.appending(path: "\(cp.id)/files/\(p)"), dst = root.appending(path: p)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
        // Das mais fundas para as mais rasas: `src/a/b` sai antes de `src/a`.
        for pasta in cp.pastasCriadas.sorted(by: { $0.count > $1.count }) {
            let u = root.appending(path: pasta)
            if (try? fm.contentsOfDirectory(atPath: u.path))?.isEmpty == true {
                try? fm.removeItem(at: u)
            }
        }
    }
}
