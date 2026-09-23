import Foundation
import OdeteI18n

/// Onde cada pacote fica na árvore, o que vem do registro, os workspaces e as marcas
/// do npm (`dev`, `optional`, `peer`, `devOptional`).
extension Resolvedor {
    // MARK: - Onde colocar

    /// A pasta cuja `node_modules` guarda a chave: `node_modules/a` → `""`,
    /// `node_modules/a/node_modules/b` → `node_modules/a`.
    static func nivel(de key: String) -> String {
        guard let r = key.range(of: "/node_modules/", options: .backwards) else {
            return key.hasPrefix("node_modules/") ? "" : key
        }
        return String(key[..<r.lowerBound])
    }

    static func chave(_ base: String, _ nome: String) -> String {
        base.isEmpty ? "node_modules/\(nome)" : "\(base)/node_modules/\(nome)"
    }

    /// Os níveis por onde a resolução do Node passa a partir de `from`, do mais fundo ao
    /// projeto. Pasta local fora do projeto (`../lib`) para nela: o Node resolve pelo
    /// caminho real, e de lá não se enxerga o node_modules do projeto.
    static func niveis(_ from: String) -> [String] {
        var out: [String] = []
        var b = from
        while true {
            out.append(b)
            if b.isEmpty {
                return out
            }
            if let r = b.range(of: "/node_modules/", options: .backwards) {
                b = String(b[..<r.lowerBound])
            } else if b.hasPrefix("../") {
                return out
            } else {
                b = ""
            }
        }
    }

    static func achar(_ name: String, from: String, in tree: [String: Node]) -> (String, Node)? {
        for base in niveis(from) {
            let key = chave(base, name)
            if let n = tree[key] {
                return (key, n)
            }
        }
        return nil
    }

    /// Põe o pacote o mais alto possível: sobe a partir de quem pediu enquanto o nível
    /// estiver livre e colocá-lo ali não esconder de ninguém a versão que já usava.
    ///
    /// Antes só o topo era conferido: livre, ia para lá; ocupado, ia para dentro de quem
    /// pediu. Um nível do meio com outra versão do mesmo pacote passava despercebido — o
    /// pacote ficava no topo, e quem estava embaixo enxergava a do meio.
    func colocar(_ w: Want, _ c: Lockfile.Entry) -> String? {
        let cadeia = Self.niveis(w.from)
        var escolhido = cadeia[0]
        if let ex = tree[Self.chave(escolhido, w.name)] {
            if mesmo(ex.entry, c) {
                return nil
            }
            falhar(w, tr(
                "%1$@: %2$@ pede %3$@, mas já há %4$@ no mesmo lugar",
                w.name,
                w.quem,
                w.range,
                ex.entry.version
            ))
            return nil
        }
        for base in cadeia.dropFirst() {
            if tree[Self.chave(base, w.name)] != nil || esconderia(w.name, c, em: base) || !peersServem(c, em: base) {
                break
            }
            escolhido = base
        }
        let key = Self.chave(escolhido, w.name)
        tree[key] = Node(name: w.name, entry: c, parentKey: w.from)
        return key
    }

    /// Os peers do pacote, vistos de `base`, atendem o que ele pede? Opcional também
    /// conta quando está lá: o `fdir` pede `picomatch@^3 || ^4` como peer opcional, e no
    /// topo com o `picomatch@2` do tailwind 3 ele ficaria com o errado — o npm o deixa
    /// dentro do `tinyglobby`, ao lado do `picomatch@4`.
    func peersServem(_ c: Lockfile.Entry, em base: String) -> Bool {
        for (nome, faixa) in c.peerDependencies {
            guard let (_, n) = Self.achar(nome, from: base, in: tree), !n.entry.link,
                  let v = Version(n.entry.version) else { continue }
            let r = SemverRange(Pedido.de(faixa).faixaDoRegistro ?? "*")
            if !r.isAny, !r.satisfies(v) {
                return false
            }
        }
        return true
    }

    func mesmo(_ a: Lockfile.Entry, _ b: Lockfile.Entry) -> Bool {
        a.version == b.version && a.name == b.name && a.link == b.link && (a.link ? a.resolved == b.resolved : true)
    }

    /// Pôr `nome` em `base/node_modules` mudaria o que algum dependente já resolvido
    /// enxerga — e a versão nova não serve para ele?
    func esconderia(_ nome: String, _ c: Lockfile.Entry, em base: String) -> Bool {
        guard !base.isEmpty else { return false }
        for d in dependentes[nome] ?? [] where d == base || d.hasPrefix(base + "/node_modules/") {
            guard let (rk, _) = Self.achar(nome, from: d, in: tree) else { continue }
            let nivelAtual = Self.nivel(de: rk)
            // Só esconde se o que ele usa está acima de `base`.
            let acima = nivelAtual.isEmpty || base.hasPrefix(nivelAtual + "/node_modules/")
            guard acima, nivelAtual != base else { continue }
            if !serve(c, para: d, nome: nome) {
                return true
            }
        }
        return false
    }

    /// A versão de `c` atende o que `dependente` pede para `nome`?
    func serve(_ c: Lockfile.Entry, para dependente: String, nome: String) -> Bool {
        let e = dependente.isEmpty ? nil : tree[dependente]?.entry
        let spec = dependente.isEmpty
            ? (pkg.dependencies[nome] ?? pkg.devDependencies[nome] ?? pkg.optionalDependencies[nome])
            : (e?.dependencies[nome] ?? e?.optionalDependencies[nome] ?? e?.peerDependencies[nome])
        guard let spec, case let .registro(real, faixa) = Pedido.de(spec), let v = Version(c.version) else {
            return true
        }
        guard (c.name ?? nome) == (real.isEmpty ? nome : real) else { return false }
        return SemverRange(faixa).isAny || SemverRange(faixa).satisfies(v)
    }

    // MARK: - Registro

    /// A versão que a faixa pede, com os dados dela; `nil` se nenhuma serve.
    func versao(_ nome: String, _ faixa: String) async throws -> PackumentVersion? {
        if var g = guardados[nome] {
            guard let v = Packument.escolher(
                faixa,
                distTags: g.distTags,
                versoes: g.versoes,
                depreciadas: g.depreciadas
            ) else { return nil }
            if let pv = g.escolhidas[v] {
                return pv
            }
            let p = try await busca.tomar(nome)
            guard let pv = p.versions[v] else { return nil }
            g.escolhidas[v] = pv
            guardados[nome] = g
            return pv
        }
        let p = try await busca.tomar(nome)
        let pv = p.pick(faixa)
        guardados[nome] = Installer.PackumentGuardado(
            distTags: p.distTags,
            versoes: Array(p.versions.keys),
            depreciadas: p.depreciadas,
            escolhidas: pv.map { [$0.version: $0] } ?? [:]
        )
        return pv
    }

    // MARK: - Workspaces

    /// `workspaces` do package.json: cada pasta vira `node_modules/<nome>` apontando para
    /// ela, e as dependências dela entram na árvore do projeto.
    func carregarWorkspaces() throws -> [Want] {
        let fm = FileManager.default
        var pastas: [String] = []
        for padrao in pkg.workspaces {
            let limpo = padrao.hasPrefix("./") ? String(padrao.dropFirst(2)) : padrao
            if limpo.hasSuffix("/*") || limpo.hasSuffix("/**") {
                let base = String(limpo[..<limpo.lastIndex(of: "/")!])
                let dir = installer.project.appending(path: base)
                for n in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where !n.hasPrefix(".") {
                    if fm.fileExists(atPath: dir.appending(path: n).appending(path: "package.json").path) {
                        pastas.append(base.isEmpty ? n : "\(base)/\(n)")
                    }
                }
            } else if fm
                .fileExists(atPath: installer.project.appending(path: limpo).appending(path: "package.json").path)
            {
                pastas.append(limpo.hasSuffix("/") ? String(limpo.dropLast()) : limpo)
            }
        }
        for pasta in pastas {
            let p = PackageJSON(url: installer.project.appending(path: pasta).appending(path: "package.json"))
            guard let nome = p.json["name"]?.comoTexto else { continue }
            workspaces[nome] = (pasta, p)
        }
        // Os workspaces entram na árvore como dependências do projeto.
        var out: [Want] = []
        for (nome, ws) in workspaces {
            out.append(Want(
                name: nome, range: "file:\(ws.pasta)", from: "", dev: false, optional: false, quem: pkg.name,
                regras: [regrasDaRaiz]
            ))
            dependentes[nome, default: []].insert("")
        }
        return out
    }

    // MARK: - dev, optional, peer

    /// As marcas do npm, pelo caminho a partir do projeto: `dev` é o que só se alcança
    /// por `devDependencies`; `optional`, o que só se alcança passando por uma dependência
    /// opcional; `peer`, o que só se alcança passando por um peer. Marcar na hora de pôr o
    /// pacote na árvore errava quando o primeiro a pedir era um dev e o segundo não.
    func calcularMarcas() {
        enum Tipo { case normal, opcional, peer }
        func arestas(_ k: String) -> [(String, Tipo)] {
            guard let n = tree[k] else { return [] }
            if n.entry.link {
                return n.entry.resolved.map { [($0, .normal)] } ?? []
            }
            var out: [(String, Tipo)] = []
            for d in n.entry.dependencies.keys {
                if let (rk, _) = Self.achar(d, from: k, in: tree) {
                    out.append((rk, .normal))
                }
            }
            for d in n.entry.optionalDependencies.keys {
                if let (rk, _) = Self.achar(d, from: k, in: tree) {
                    out.append((rk, .opcional))
                }
            }
            for d in n.entry.peersObrigatorios.keys where n.entry.dependencies[d] == nil {
                if let (rk, _) = Self.achar(d, from: Self.nivel(de: k), in: tree) {
                    out.append((rk, .peer))
                }
            }
            return out
        }
        func daRaiz(_ nomes: [String: String], _ t: Tipo) -> [(String, Tipo)] {
            nomes.keys.compactMap { n in Self.achar(n, from: "", in: tree).map { ($0.0, t) } }
        }
        let prod = daRaiz(pkg.dependencies, .normal) + daRaiz(pkg.optionalDependencies, .opcional)
            + daRaiz(pkg.peerDependencies.filter { !pkg.peersOpcionais.contains($0.key) }, .peer)
            + daRaiz(Dictionary(uniqueKeysWithValues: workspaces.keys.map { ($0, "*") }), .normal)
        let dev = daRaiz(pkg.devDependencies, .normal)
        func alcance(_ inicio: [(String, Tipo)], passaPor: (Tipo) -> Bool) -> Set<String> {
            var vistos = Set<String>()
            var pilha = inicio.filter { passaPor($0.1) }.map(\.0)
            while let k = pilha.popLast() {
                guard vistos.insert(k).inserted else { continue }
                for (a, t) in arestas(k) where passaPor(t) && !vistos.contains(a) {
                    pilha.append(a)
                }
            }
            return vistos
        }
        /// O que se alcança sem passar por um binário de plataforma é o que vai para o disco.
        func arestasSemPlataforma(_ k: String) -> [(String, Tipo)] {
            arestas(k).filter { a, _ in tree[a].map { !$0.entry.soDePlataforma } ?? false }
        }
        var noDisco = Set<String>()
        var pilhaDoDisco = (prod + dev).map(\.0).filter { tree[$0].map { !$0.entry.soDePlataforma } ?? false }
        while let k = pilhaDoDisco.popLast() {
            guard noDisco.insert(k).inserted else { continue }
            pilhaDoDisco += arestasSemPlataforma(k).map(\.0).filter { !noDisco.contains($0) }
        }
        for (k, var n) in tree where !n.entry.soDePlataforma {
            n.soNoLock = !noDisco.contains(k)
            tree[k] = n
        }
        let deProducao = alcance(prod) { _ in true }
        let semOpcional = alcance(prod + dev) { $0 != .opcional }
        let semPeer = alcance(prod + dev) { $0 != .peer }
        // `devOptional`: todo caminho do projeto até ele passa por uma devDependency ou por
        // uma opcional, mas não só por um tipo (senão é `dev` ou `optional`). É o
        // `detect-libc`: do `sharp` opcional do `next` e do `lightningcss` do tailwind (dev).
        let obrigatorioEmProducao = alcance(prod) { $0 != .opcional }
        for (k, var n) in tree where !n.entry.link {
            n.entry.dev = !deProducao.contains(k)
            // Binário de plataforma é opcional por definição: foi assim que ele entrou.
            n.entry.optional = n.entry.soDePlataforma || !semOpcional.contains(k)
            n.entry.peer = !semPeer.contains(k)
            n.entry.devOptional = !obrigatorioEmProducao.contains(k) && !n.entry.dev && !n.entry.optional
            tree[k] = n
        }
    }
}
