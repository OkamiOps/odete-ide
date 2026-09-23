import CryptoKit
import Foundation
import OdeteI18n

public struct PackumentVersion: Sendable, Hashable {
    public var version: Version
    public var dependencies: [String: String]
    public var optionalDependencies: [String: String]
    public var peerDependencies: [String: String]
    public var bin: [String: String]
    public var tarball: String
    public var integrity: String?
    public var os: [String]
    public var cpu: [String]
    public var hasInstallScript: Bool
    public var deprecated: String?
    /// Peers marcados como opcionais em `peerDependenciesMeta`: o npm não instala esses.
    public var peersOpcionais: Set<String> = []
    /// O que o lock do npm guarda da versão e a Odete só repassa (`engines`, `funding`,
    /// `deprecated`, `license`, `libc`).
    public var extras: JSONOrdenado = .objeto([])

    public init(
        version: Version,
        dependencies: [String: String],
        optionalDependencies: [String: String],
        peerDependencies: [String: String],
        bin: [String: String],
        tarball: String,
        integrity: String?,
        os: [String],
        cpu: [String],
        hasInstallScript: Bool,
        deprecated: String?,
        peersOpcionais: Set<String> = [],
        extras: JSONOrdenado = .objeto([])
    ) {
        self.version = version; self.dependencies = dependencies; self.optionalDependencies = optionalDependencies
        self.peerDependencies = peerDependencies; self.bin = bin; self.tarball = tarball; self.integrity = integrity
        self.os = os; self.cpu = cpu; self.hasInstallScript = hasInstallScript; self.deprecated = deprecated
        self.peersOpcionais = peersOpcionais; self.extras = extras
    }
}

extension JSONOrdenado {
    /// O que o `JSONSerialization` devolveu, em JSON ordenado (a ordem do dicionário não
    /// existe mais; quem grava o lock ordena de novo).
    static func de(_ v: Any) -> JSONOrdenado? {
        switch v {
        case let s as String: return .texto(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return .booleano(n.boolValue)
            }
            return .numero(n.stringValue)
        case let l as [Any]: return .lista(l.compactMap { de($0) })
        case let m as [String: Any]:
            return .objeto(m.keys.sorted().compactMap { k in de(m[k] as Any).map { (k, $0) } })
        case is NSNull: return .nulo
        default: return nil
        }
    }
}

public struct Packument: Sendable, Hashable {
    public var name: String
    public var distTags: [String: String]
    public var versions: [Version: PackumentVersion]

    public init(name: String, distTags: [String: String], versions: [Version: PackumentVersion]) {
        self.name = name; self.distTags = distTags; self.versions = versions
    }

    public static func parse(_ data: Data) throws -> Packument {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = j["name"] as? String else { throw NpmError.registry(tr("packument inválido")) }
        var out: [Version: PackumentVersion] = [:]
        for (k, v) in (j["versions"] as? [String: Any]) ?? [:] {
            guard let ver = Version(k), let m = v as? [String: Any], let dist = m["dist"] as? [String: Any],
                  let tar = dist["tarball"] as? String else { continue }
            func deps(_ key: String) -> [String: String] {
                (m[key] as? [String: String]) ?? [:]
            }
            var bin: [String: String] = [:]
            if let b = m["bin"] as? [String: String] {
                bin = Self.normalizarBin(b)
            } else if let b = m["bin"] as? String {
                let short = name.split(separator: "/").last.map(String.init) ?? name
                bin = Self.normalizarBin([short: b])
            }
            let meta = (m["peerDependenciesMeta"] as? [String: Any]) ?? [:]
            var extras: [(String, JSONOrdenado)] = []
            for k in ["deprecated", "engines", "funding", "libc", "license", "bundleDependencies"] {
                if let v = m[k] ?? (k == "bundleDependencies" ? m["bundledDependencies"] : nil),
                   let j = JSONOrdenado.de(v)
                {
                    extras.append((k, k == "funding" ? j.fundingComoONpm : j))
                }
            }
            out[ver] = PackumentVersion(
                version: ver,
                dependencies: deps("dependencies"),
                optionalDependencies: deps("optionalDependencies"),
                peerDependencies: deps("peerDependencies"),
                bin: bin,
                tarball: tar,
                integrity: dist["integrity"] as? String,
                os: (m["os"] as? [String]) ?? [],
                cpu: (m["cpu"] as? [String]) ?? [],
                hasInstallScript: (m["hasInstallScript"] as? Bool) ?? false,
                deprecated: m["deprecated"] as? String,
                peersOpcionais: Set(meta.compactMap { k, v in
                    ((v as? [String: Any])?["optional"] as? Bool) == true ? k : nil
                }),
                extras: .objeto(extras)
            )
        }
        return Packument(name: name, distTags: (j["dist-tags"] as? [String: String]) ?? [:], versions: out)
    }

    /// O `bin` como o `npm-normalize-package-bin` deixa: nome sem pasta, caminho sem `./`
    /// e sem `..` que saia do pacote. É o que o lock do npm grava, e o atalho de `.bin`
    /// com `./` no meio funcionava do mesmo jeito — só o lock ficava diferente.
    public static func normalizarBin(_ bin: [String: String]) -> [String: String] {
        func limpo(_ s: String) -> String {
            var partes: [Substring] = []
            for p in s.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
                if p == "." {
                    continue
                }
                if p == ".." {
                    _ = partes.popLast()
                } else {
                    partes.append(p)
                }
            }
            return partes.joined(separator: "/")
        }
        var out: [String: String] = [:]
        for (k, v) in bin {
            let nome = limpo(k.replacingOccurrences(of: ":", with: "/")).split(separator: "/").last
                .map(String.init) ?? ""
            let alvo = limpo(v)
            if !nome.isEmpty, !alvo.isEmpty {
                out[nome] = alvo
            }
        }
        return out
    }

    /// Escolhe a versão para uma faixa (ou tag).
    public func pick(_ spec: String) -> PackumentVersion? {
        Self.escolher(spec, distTags: distTags, versoes: versions.keys, depreciadas: depreciadas)
            .flatMap { versions[$0] }
    }

    /// Versões marcadas como `deprecated` no registro.
    var depreciadas: Set<Version> {
        Set(versions.values.filter { $0.deprecated != nil }.map(\.version))
    }

    /// A regra de `pick` só com o que ela precisa: as tags e a lista de versões.
    ///
    /// Separada para a resolução poder guardar só isso de um packument depois de
    /// escolher — os dados de cada versão (dependências, tarball, binários) são a parte
    /// pesada, e de milhares de versões só uma ou duas acabam usadas.
    ///
    /// A ordem é a do `npm-pick-manifest`: a tag pedida; senão o `latest`, se a faixa
    /// aceitar ele e ele não estiver depreciado (um `6.0.0-next` ou um `5.9.0` publicado
    /// com outra tag não passa na frente do que o autor marcou como atual); senão a maior
    /// que serve, fugindo das depreciadas quando há outra.
    static func escolher(
        _ spec: String,
        distTags: [String: String],
        versoes: some Collection<Version>,
        depreciadas: Set<Version> = []
    ) -> Version? {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if let tagged = distTags[s.isEmpty ? "latest" : s], let v = Version(tagged), versoes.contains(v) {
            return v
        }
        let range = SemverRange(s)
        if let latest = distTags["latest"], let v = Version(latest), versoes.contains(v),
           range.isAny || range.satisfies(v), !depreciadas.contains(v)
        {
            return v
        }
        let servem = versoes.filter { range.satisfies($0) }
        return servem.filter { !depreciadas.contains($0) }.max() ?? servem.max()
    }
}

public enum NpmError: LocalizedError, Sendable {
    case registry(String), notFound(String), noVersion(String, String), tarball(String), io(String), native(String)
    public var errorDescription: String? {
        switch self {
        case let .registry(m): tr("registro: %1$@", "\(m)")
        case let .notFound(n): tr("pacote não encontrado: %1$@", "\(n)")
        case let .noVersion(n, r): tr("nenhuma versão de %1$@ satisfaz %2$@", "\(n)", "\(r)")
        case let .tarball(m): "tarball: \(m)"
        case let .io(m): m
        case let .native(n): tr("%1$@ tem código nativo e não roda no iPad", "\(n)")
        }
    }
}

/// De onde vêm packuments e tarballs.
public protocol RegistryClient: Sendable {
    func packument(_ name: String) async throws -> Packument
    func tarball(_ url: String, integrity: String?) async throws -> Data
    /// O documento completo de uma versão (`/<nome>/<versão>`), com o que o packument
    /// abreviado não traz — `license`, `libc`. Só para o que não é baixado (binário de
    /// plataforma): do resto, o package.json no disco diz o mesmo.
    func manifestoCompleto(_ name: String, _ version: String) async throws -> Data?
}

public extension RegistryClient {
    func manifestoCompleto(_: String, _: String) async throws -> Data? {
        nil
    }
}

/// registry.npmjs.org com cache em disco.
public struct HTTPRegistry: RegistryClient {
    public var base: URL
    public var cacheDir: URL
    public var session: URLSession

    public static func defaultCache() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(
            path: "odete-npm",
            directoryHint: .isDirectory
        )
    }

    public init(
        base: URL = URL(string: "https://registry.npmjs.org")!,
        cacheDir: URL = HTTPRegistry.defaultCache(),
        session: URLSession = .shared
    ) {
        self.base = base; self.cacheDir = cacheDir; self.session = session
    }

    /// URL do packument; escopos viram `@scope%2Fnome` (appending(path:) codificaria o `%` de novo).
    public func packumentURL(_ name: String) -> URL {
        let enc = name.hasPrefix("@") ? name.replacingOccurrences(of: "/", with: "%2F") : name
        let b = base.absoluteString.hasSuffix("/") ? String(base.absoluteString.dropLast()) : base.absoluteString
        return URL(string: b + "/" + enc)!
    }

    public func manifestoCompleto(_ name: String, _ version: String) async throws -> Data? {
        let u = packumentURL(name).appending(path: version)
        let (data, resp) = try await session.data(from: u)
        guard (200 ..< 300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else { return nil }
        return data
    }

    public func packument(_ name: String) async throws -> Packument {
        var req = URLRequest(url: packumentURL(name))
        req.setValue("application/vnd.npm.install-v1+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 {
            throw NpmError.notFound(name)
        }
        guard (200 ..< 300).contains(code) else { throw NpmError.registry(tr(
            "HTTP %1$@ para %2$@",
            "\(code)",
            "\(name)"
        )) }
        return try Packument.parse(data)
    }

    /// Confere o pacote baixado contra o `integrity` que o registro e o lock declaram.
    ///
    /// O valor já vinha do registro e era guardado no lock, mas ninguém comparava: download
    /// corrompido ou registro trocado instalava calado dentro do projeto.
    static func conferir(_ data: Data, contra integrity: String?, nome: String) throws {
        guard let integrity, let corte = integrity.firstIndex(of: "-") else { return }
        let algoritmo = String(integrity[..<corte])
        let esperado = String(integrity[integrity.index(after: corte)...])
        let obtido: String? = switch algoritmo {
        case "sha512": Data(SHA512.hash(data: data)).base64EncodedString()
        case "sha256": Data(SHA256.hash(data: data)).base64EncodedString()
        case "sha1": Data(Insecure.SHA1.hash(data: data)).base64EncodedString()
        default: nil
        }
        // Algoritmo que não conhecemos não vira erro: seria travar a instalação por algo
        // que talvez esteja certo.
        guard let obtido else { return }
        guard obtido == esperado else {
            throw NpmError.tarball(tr(
                "o conteúdo de %1$@ não bate com o integrity declarado (%2$@)",
                "\(nome)",
                "\(algoritmo)"
            ))
        }
    }

    public func tarball(_ url: String, integrity: String?) async throws -> Data {
        let key = (integrity ?? url).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(
                of: "=",
                with: ""
            )
        let file = cacheDir.appending(path: key + ".tgz")
        // Mapeado em vez de lido: as páginas do arquivo são do cache do sistema, que as
        // devolve sozinho quando falta memória, e não contam como memória do app. O
        // arquivo nunca é reescrito no lugar (a gravação é atômica), então o mapa não
        // muda por baixo da extração.
        if let d = try? Data(contentsOf: file, options: .mappedIfSafe) {
            // Cache também passa pela conferência: arquivo pode ter sido truncado na
            // gravação ou mexido depois.
            if (try? Self.conferir(d, contra: integrity, nome: url)) != nil {
                return d
            }
            try? FileManager.default.removeItem(at: file)
        }
        guard let u = URL(string: url) else { throw NpmError.tarball(tr("URL inválida %1$@", "\(url)")) }
        let (data, resp) = try await session.data(from: u)
        guard (200 ..< 300).contains((resp as? HTTPURLResponse)?.statusCode ?? 0)
        else { throw NpmError.tarball(tr("HTTP ao baixar %1$@", "\(url)")) }
        try Self.conferir(data, contra: integrity, nome: url)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        return data
    }
}
