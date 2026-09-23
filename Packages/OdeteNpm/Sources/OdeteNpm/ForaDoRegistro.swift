import CryptoKit
import Foundation
import OdeteI18n

/// Pacotes que não vêm do registro (URL, GitHub, `.tgz` e pasta local, workspace) e as
/// arestas de cada nó colocado.
extension Resolvedor {
    /// Pacote que vem de fora do registro: URL, GitHub ou `.tgz` local. O package.json
    /// de dentro do tarball diz versão e dependências.
    func deFora(_ w: Want, resolvido: String, baixar: String, integridade: Bool) async {
        if let (_, existing) = Self.achar(w.name, from: w.from, in: tree), existing.entry.resolved == resolvido {
            return
        }
        var c: Lockfile.Entry
        var novo = false
        if let lock, let (_, le) = lock.resolve(w.name, from: w.from), le.resolved == resolvido {
            c = le
        } else {
            novo = true
            do {
                let dados = try await installer.dadosDoTarball(baixar, integrity: nil)
                guard let m = try Tar.manifesto(dados), let j = try? JSONOrdenado.ler(m) else {
                    falhar(w, tr("%1$@: o pacote em %2$@ não tem package.json", w.name, resolvido)); return
                }
                let manifesto = PackageJSON(json: j, url: URL(filePath: "/"))
                c = Lockfile.Entry(
                    version: manifesto.version ?? "0.0.0",
                    resolved: resolvido,
                    integrity: integridade && !resolvido.hasPrefix("file:")
                        ? "sha512-" + Data(SHA512.hash(data: dados)).base64EncodedString() : nil,
                    dependencies: manifesto.dependencies,
                    optionalDependencies: manifesto.optionalDependencies,
                    bin: manifesto.bin,
                    dev: w.dev,
                    native: Installer.dependeDeNativo(manifesto.dependencies),
                    name: manifesto.json["name"]?.comoTexto == w.name ? nil : manifesto.json["name"]?.comoTexto,
                    peerDependencies: manifesto.peerDependencies,
                    peersOpcionais: manifesto.peersOpcionais,
                    temScripts: manifesto.temScriptDeInstalacao
                )
            } catch {
                report.semRede = report.semRede || Installer.ehErroDeRede(error)
                falhar(w, error.localizedDescription)
                return
            }
        }
        c.dev = w.dev
        c.optional = w.optional
        guard let key = colocar(w, c) else { return }
        // Veio agora: `license` e companhia saem do package.json depois de extraído.
        tree[key]?.novo = novo
        enfileirarFilhos(de: key, c, w)
    }

    /// `file:` de pasta e workspace: `node_modules/<nome>` vira atalho para a pasta, e as
    /// dependências da pasta entram na árvore a partir dela.
    func ligar(_ w: Want, pasta: String) {
        let alvo = installer.project.appending(path: pasta)
        let manifesto = PackageJSON(url: alvo.appending(path: "package.json"))
        guard manifesto.existe else {
            falhar(w, tr("%1$@: não há package.json em %2$@", w.name, pasta))
            return
        }
        if let (_, existing) = Self.achar(w.name, from: w.from, in: tree), existing.entry.link,
           existing.entry.resolved == pasta
        {
            return
        }
        let versao = manifesto.version ?? ""
        var link = Lockfile.Entry(
            version: versao, resolved: pasta, integrity: nil, dependencies: [:], optionalDependencies: [:],
            bin: [:], dev: w.dev, native: false, link: true
        )
        link.optional = w.optional
        guard colocar(w, link) != nil else { return }
        guard tree[pasta] == nil else { return }
        let nomeReal = manifesto.json["name"]?.comoTexto
        let destino = Lockfile.Entry(
            version: versao, resolved: nil, integrity: nil,
            dependencies: manifesto.dependencies, optionalDependencies: manifesto.optionalDependencies,
            bin: manifesto.bin, dev: w.dev, native: false, name: nomeReal,
            peerDependencies: manifesto.peerDependencies, peersOpcionais: manifesto.peersOpcionais
        )
        tree[pasta] = Node(name: nomeReal ?? w.name, entry: destino, parentKey: "")
        // Do workspace, o npm instala também as devDependencies — é código do projeto.
        var devs: [Want] = []
        if workspaces.values.contains(where: { $0.pasta == pasta }) {
            for (n, r) in manifesto.devDependencies where destino.dependencies[n] == nil {
                devs.append(Want(
                    name: n, range: r, from: pasta, dev: true, optional: false, quem: w.name, regras: w.regras
                ))
                dependentes[n, default: []].insert(pasta)
            }
        }
        enfileirarFilhos(de: pasta, destino, w, extras: devs)
    }

    /// Dependências, opcionais e peers obrigatórios de um nó recém-colocado: viram as
    /// arestas dele, e ele entra na fila de prioridade.
    func enfileirarFilhos(de key: String, _ c: Lockfile.Entry, _ w: Want, extras: [Want] = []) {
        var regras = w.regras
        let faixa = Pedido.de(w.range).faixaDoRegistro ?? ""
        let internas = w.regras.compactMap { $0.regra(w.name, faixa: faixa) }.filter { !$0.filhos.isEmpty }
        if let r = internas.last {
            regras.append(r)
        }
        let quem = c.name ?? w.name
        var wants: [Want] = extras
        // O que vem dentro do tarball (`bundleDependencies`) não se resolve à parte: o
        // `@tailwindcss/oxide-wasm32-wasi` traz o próprio `@emnapi/core`, e resolvê-lo
        // aqui punha no topo uma versão que o npm não põe.
        var vistos = Set(extras.map(\.name)).union(c.embutidas)
        for (dn, dr) in c.dependencies where vistos.insert(dn).inserted {
            wants.append(Want(name: dn, range: dr, from: key, dev: w.dev, optional: false, quem: quem, regras: regras))
            dependentes[dn, default: []].insert(key)
        }
        for (dn, dr) in c.optionalDependencies where vistos.insert(dn).inserted {
            wants.append(Want(name: dn, range: dr, from: key, dev: w.dev, optional: true, quem: quem, regras: regras))
            dependentes[dn, default: []].insert(key)
        }
        // O peer fica ao lado de quem pediu: é da pasta de cima que os dois o enxergam.
        let lado = Self.nivel(de: key)
        for (dn, dr) in c.peersObrigatorios where vistos.insert(dn).inserted {
            wants.append(Want(
                name: dn, range: dr, from: lado, dev: w.dev, optional: false, peer: true, quem: quem, regras: regras
            ))
            dependentes[dn, default: []].insert(key)
        }
        empurrar(key, wants)
    }
}
