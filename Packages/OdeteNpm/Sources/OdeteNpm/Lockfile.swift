import Foundation

/// package-lock.json v3.
///
/// A gravação sai no formato do npm (chaves na ordem do `json-stringify-nice`, a
/// indentação e a quebra do package.json), e o que a Odete não usa de uma entrada
/// (`license`, `engines`, `funding`…) volta para o arquivo como veio. Antes o lock saía
/// em ordem alfabética, com `" : "` e `\/`, e perdia esses campos: um `npm install` na
/// Odete reescrevia o lock inteiro no diff do git.
public struct Lockfile: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var version: String
        public var resolved: String?
        public var integrity: String?
        public var dependencies: [String: String]
        public var optionalDependencies: [String: String]
        public var bin: [String: String]
        public var dev: Bool
        public var native: Bool
        /// Só chega por `optionalDependencies`. Junto com `os`/`cpu`, é assim que o npm
        /// marca no lock os binários de plataforma — todos, de todos os sistemas, para o
        /// lock servir em qualquer máquina; quem instala decide qual cabe.
        public var optional = false
        public var os: [String] = []
        public var cpu: [String] = []
        /// O nome de verdade do pacote quando a pasta tem outro (alias `npm:`), ou o de um
        /// pacote local (`file:`, workspace), cuja chave é o caminho da pasta.
        public var name: String?
        public var peerDependencies: [String: String] = [:]
        /// Peers marcados como opcionais em `peerDependenciesMeta`.
        public var peersOpcionais: Set<String> = []
        /// Só está na árvore porque alguém o pediu como peer.
        public var peer = false
        /// Só alcançado por caminhos de dev ou de opcional, sem ser só de um tipo.
        public var devOptional = false
        /// `preinstall`/`install`/`postinstall` que a Odete não roda — não quer dizer
        /// código nativo (o `core-js` só imprime um recado).
        public var temScripts = false
        /// Atalho para uma pasta do projeto (`file:` de pasta, workspace): no lock é
        /// `{ "resolved": "<pasta>", "link": true }`, e a pasta tem a própria entrada.
        public var link = false
        /// O resto da entrada, do jeito que veio (do lock ou do registro).
        public var extras: JSONOrdenado = .objeto([])

        public init(
            version: String,
            resolved: String?,
            integrity: String?,
            dependencies: [String: String],
            optionalDependencies: [String: String],
            bin: [String: String],
            dev: Bool,
            native: Bool,
            optional: Bool = false,
            os: [String] = [],
            cpu: [String] = [],
            name: String? = nil,
            peerDependencies: [String: String] = [:],
            peersOpcionais: Set<String> = [],
            peer: Bool = false,
            temScripts: Bool = false,
            link: Bool = false,
            extras: JSONOrdenado = .objeto([])
        ) {
            self.version = version; self.resolved = resolved; self.integrity = integrity
            self.dependencies = dependencies; self.optionalDependencies = optionalDependencies; self.bin = bin
            self.dev = dev; self.native = native; self.optional = optional; self.os = os; self.cpu = cpu
            self.name = name; self.peerDependencies = peerDependencies; self.peersOpcionais = peersOpcionais
            self.peer = peer; self.temScripts = temScripts; self.link = link; self.extras = extras
        }

        /// `bundleDependencies`: vêm dentro do tarball, não se resolvem à parte.
        public var embutidas: Set<String> {
            if extras["bundleDependencies"]?.comoBool == true {
                return Set(dependencies.keys).union(optionalDependencies.keys)
            }
            return Set(extras["bundleDependencies"]?.comoListaDeTexto ?? [])
        }

        /// Binário de uma plataforma, opcional: fica no lock e não é baixado. Nenhum roda
        /// no iPad — nem o de darwin/arm64, que é do macOS.
        public var soDePlataforma: Bool {
            optional && (!os.isEmpty || !cpu.isEmpty)
        }

        /// Peers que o npm instala sozinho: os que não são opcionais.
        public var peersObrigatorios: [String: String] {
            peerDependencies.filter { !peersOpcionais.contains($0.key) }
        }

        /// Os campos que esta estrutura entende; o resto vai para `extras`.
        static let conhecidos: Set<String> = [
            "version", "resolved", "integrity", "dependencies", "optionalDependencies", "bin", "dev", "odete:native",
            "optional", "os", "cpu", "name", "peerDependencies", "peerDependenciesMeta", "peer", "hasInstallScript",
            "devOptional",
            "link",
        ]

        init?(_ m: JSONOrdenado) {
            guard case .objeto = m else { return nil }
            let link = m["link"]?.comoBool ?? false
            guard let ver = m["version"]?.comoTexto ?? (link ? "" : nil) else { return nil }
            var extras: [(String, JSONOrdenado)] = []
            for (k, v) in m.pares where !Self.conhecidos.contains(k) {
                extras.append((k, v))
            }
            self.init(
                version: ver,
                resolved: m["resolved"]?.comoTexto,
                integrity: m["integrity"]?.comoTexto,
                dependencies: m["dependencies"]?.comoMapaDeTexto ?? [:],
                optionalDependencies: m["optionalDependencies"]?.comoMapaDeTexto ?? [:],
                bin: m["bin"]?.comoMapaDeTexto ?? [:],
                dev: m["dev"]?.comoBool ?? false,
                native: m["odete:native"]?.comoBool ?? false,
                optional: m["optional"]?.comoBool ?? false,
                os: m["os"]?.comoListaDeTexto ?? [],
                cpu: m["cpu"]?.comoListaDeTexto ?? [],
                name: m["name"]?.comoTexto,
                peerDependencies: m["peerDependencies"]?.comoMapaDeTexto ?? [:],
                peersOpcionais: Set((m["peerDependenciesMeta"]?.pares ?? [])
                    .filter { $0.1["optional"]?.comoBool == true }.map(\.0)),
                peer: m["peer"]?.comoBool ?? false,
                temScripts: m["hasInstallScript"]?.comoBool ?? false,
                link: link,
                extras: .objeto(extras)
            )
            devOptional = m["devOptional"]?.comoBool ?? false
        }

        var json: JSONOrdenado {
            if link {
                return .objeto([("resolved", .texto(resolved ?? "")), ("link", .booleano(true))])
            }
            var m: [(String, JSONOrdenado)] = []
            if let name {
                m.append(("name", .texto(name)))
            }
            if !version.isEmpty {
                m.append(("version", .texto(version)))
            }
            if let resolved {
                m.append(("resolved", .texto(resolved)))
            }
            if let integrity {
                m.append(("integrity", .texto(integrity)))
            }
            if dev {
                m.append(("dev", .booleano(true)))
            }
            if optional {
                m.append(("optional", .booleano(true)))
            }
            if devOptional {
                m.append(("devOptional", .booleano(true)))
            }
            if peer {
                m.append(("peer", .booleano(true)))
            }
            if temScripts {
                m.append(("hasInstallScript", .booleano(true)))
            }
            if native {
                m.append(("odete:native", .booleano(true)))
            }
            for (k, v) in [
                ("dependencies", dependencies), ("optionalDependencies", optionalDependencies),
                ("peerDependencies", peerDependencies), ("bin", bin),
            ] where !v.isEmpty {
                m.append((k, .mapa(v)))
            }
            if !peersOpcionais.isEmpty {
                m.append((
                    "peerDependenciesMeta",
                    .objeto(peersOpcionais.sorted().map { ($0, .objeto([("optional", .booleano(true))])) })
                ))
            }
            if !os.isEmpty {
                m.append(("os", .listaDeTexto(os)))
            }
            if !cpu.isEmpty {
                m.append(("cpu", .listaDeTexto(cpu)))
            }
            let usados = Set(m.map(\.0))
            for (k, v) in extras.pares where !usados.contains(k) {
                m.append((k, v))
            }
            return .objeto(m)
        }
    }

    public var name: String
    /// chave: "node_modules/a", "node_modules/a/node_modules/b", ou a pasta de um pacote
    /// local ("packages/web", "../lib").
    public var packages: [String: Entry]
    /// A entrada `""` (o próprio projeto), como veio do arquivo.
    public var raiz: JSONOrdenado = .objeto([])

    public init(name: String, packages: [String: Entry] = [:]) {
        self.name = name; self.packages = packages
    }

    public static func load(_ url: URL) -> Lockfile? {
        guard let d = try? Data(contentsOf: url), let j = try? JSONOrdenado.ler(d),
              let versao = j["lockfileVersion"].flatMap({ v -> Int? in
                  if case let .numero(n) = v {
                      return Int(n)
                  }
                  return nil
              }), versao >= 2, let pk = j["packages"] else { return nil }
        var out = Lockfile(name: j["name"]?.comoTexto ?? "")
        for (k, v) in pk.pares {
            if k.isEmpty {
                out.raiz = v
                continue
            }
            if let e = Entry(v) {
                out.packages[k] = e
            }
        }
        return out
    }

    /// O lock inteiro, pronto para gravar. `raiz` é a entrada `""`.
    public func json(raiz: JSONOrdenado, versao: String? = nil, oculto: Bool = false) -> JSONOrdenado {
        var pk: [(String, JSONOrdenado)] = oculto ? [] : [("", raiz)]
        for (k, e) in packages {
            pk.append((k, e.json))
        }
        var topo: [(String, JSONOrdenado)] = [("name", .texto(name))]
        if let versao, !oculto {
            topo.append(("version", .texto(versao)))
        }
        topo += [("lockfileVersion", .numero("3")), ("requires", .booleano(true)), ("packages", .objeto(pk))]
        return JSONOrdenado.objeto(topo).ordenadoComoOLock()
    }

    public func save(
        to url: URL,
        raiz: JSONOrdenado,
        versao: String? = nil,
        estilo: JSONOrdenado.Estilo = .init()
    ) throws {
        try Data(json(raiz: raiz, versao: versao).gravado(estilo).utf8).write(to: url, options: .atomic)
    }

    /// Para quem monta a raiz à mão (testes, locks antigos): `{"name": ...}`.
    public func save(to url: URL, root: [String: String]) throws {
        try save(to: url, raiz: .mapa(root, ordenado: false))
    }

    /// Entrada que atende `name` a partir de um caminho ("node_modules/a" procura a/node_modules/name, depois
    /// node_modules/name).
    public func resolve(_ name: String, from: String) -> (key: String, entry: Entry)? {
        var base = from
        while true {
            let key = base.isEmpty ? "node_modules/\(name)" : "\(base)/node_modules/\(name)"
            if let e = packages[key] {
                return (key, e)
            }
            if base.isEmpty {
                return nil
            }
            guard let r = base.range(of: "/node_modules/", options: .backwards) else {
                // Pacote local fora do projeto (`../lib`): a resolução dele não sobe até o
                // node_modules do projeto — é o que o Node faria pelo caminho real.
                if base.hasPrefix("../") {
                    return nil
                }
                base = ""
                continue
            }
            base = String(base[..<r.lowerBound])
        }
    }
}
