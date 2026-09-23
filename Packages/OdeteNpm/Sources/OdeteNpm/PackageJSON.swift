import Foundation
import OdeteCore

/// O package.json, lido e gravado como o npm faz: mesma ordem de campos, mesma
/// indentação e mesma quebra de linha; só as listas de dependências saem ordenadas.
public struct PackageJSON: Sendable {
    public var json: JSONOrdenado
    public var url: URL
    /// O formato do arquivo lido, para gravar do mesmo jeito.
    public var estilo: JSONOrdenado.Estilo
    /// O arquivo existia e era JSON de objeto.
    public let existe: Bool

    public init(url: URL) {
        self.url = url
        let dados = try? Data(contentsOf: url)
        if let dados, let j = try? JSONOrdenado.ler(dados), case .objeto = j {
            json = j
            existe = true
        } else {
            json = .objeto([])
            existe = false
        }
        estilo = JSONOrdenado.Estilo.de(dados)
    }

    /// Um package.json que não veio de arquivo (o de dentro de um tarball).
    public init(json: JSONOrdenado, url: URL) {
        self.json = json
        self.url = url
        estilo = JSONOrdenado.Estilo()
        existe = true
    }

    /// `preinstall`, `install` ou `postinstall`: o que o npm rodaria ao instalar.
    public var temScriptDeInstalacao: Bool {
        let s = scripts
        return s["preinstall"] != nil || s["install"] != nil || s["postinstall"] != nil
    }

    /// As listas que o npm ordena ao gravar, mesmo as que ele não mexeu.
    static let listasOrdenadas = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"]

    public var name: String {
        json["name"]?.comoTexto ?? url.deletingLastPathComponent().lastPathComponent
    }

    public var version: String? {
        json["version"]?.comoTexto
    }

    public var dependencies: [String: String] {
        json["dependencies"]?.comoMapaDeTexto ?? [:]
    }

    public var devDependencies: [String: String] {
        json["devDependencies"]?.comoMapaDeTexto ?? [:]
    }

    public var optionalDependencies: [String: String] {
        json["optionalDependencies"]?.comoMapaDeTexto ?? [:]
    }

    public var peerDependencies: [String: String] {
        json["peerDependencies"]?.comoMapaDeTexto ?? [:]
    }

    /// Peers que o pacote marcou como opcionais: esses o npm não instala sozinho.
    public var peersOpcionais: Set<String> {
        Set((json["peerDependenciesMeta"]?.pares ?? []).filter { $0.1["optional"]?.comoBool == true }.map(\.0))
    }

    public var scripts: [String: String] {
        json["scripts"]?.comoMapaDeTexto ?? [:]
    }

    public var bin: [String: String] {
        if let s = json["bin"]?.comoTexto {
            let curto = name.split(separator: "/").last.map(String.init) ?? name
            return [curto: s]
        }
        return json["bin"]?.comoMapaDeTexto ?? [:]
    }

    /// `workspaces` como lista ou no formato do yarn (`{ "packages": [...] }`).
    public var workspaces: [String] {
        if let l = json["workspaces"]?.comoLista {
            return l.compactMap(\.comoTexto)
        }
        return json["workspaces"]?["packages"]?.comoListaDeTexto ?? []
    }

    public var allDependencies: [String: String] {
        dependencies.merging(devDependencies) { a, _ in a }
    }

    public mutating func set(_ name: String, range: String, dev: Bool) {
        let alvo = dev ? "devDependencies" : "dependencies"
        let outra = dev ? "dependencies" : "devDependencies"
        var deps = json[alvo] ?? .objeto([])
        deps[name] = .texto(range)
        json[alvo] = deps
        if var o = json[outra] {
            o[name] = nil
            json[outra] = o
        }
        // Instalado de novo sem ser opcional: deixa de ser opcional, como no npm.
        if var o = json["optionalDependencies"] {
            o[name] = nil
            json["optionalDependencies"] = o
        }
    }

    public mutating func remove(_ name: String) {
        for key in ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"] {
            guard var deps = json[key] else { continue }
            deps[name] = nil
            json[key] = deps
        }
    }

    /// O texto que `save` grava.
    public func textoGravado() -> String {
        var j = json
        for key in Self.listasOrdenadas {
            guard let deps = j[key], case let .objeto(pares) = deps else { continue }
            // Lista vazia sai, como no npm (`npm uninstall` do último pacote tira o campo).
            if pares.isEmpty {
                j[key] = nil
            } else {
                j[key] = .objeto(pares.sorted { JSONOrdenado.menorComoONpm($0.0, $1.0) })
            }
        }
        return j.gravado(estilo)
    }

    public func save() throws {
        HistoricoDeArquivos.guardar(url, origem: .terminal)
        try Data(textoGravado().utf8).write(to: url, options: .atomic)
    }
}
