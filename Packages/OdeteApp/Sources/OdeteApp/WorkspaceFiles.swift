import Foundation
import OdeteCore
import OdeteFiles
import OdeteI18n

/// Criar, renomear, mover e apagar dentro do projeto — a parte do `WorkspaceModel` que
/// mexe no disco. Mora aqui para o corpo da classe caber numa leitura.
public extension WorkspaceModel {
    private func dir(of path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        if ops.isDirectory(path) {
            return path
        }
        return path.split(separator: "/").dropLast().joined(separator: "/")
    }

    @discardableResult
    func createFile(near path: String?, name: String? = nil) -> String? {
        let d = dir(of: path)
        let rel = name.map { d.isEmpty ? $0 : "\(d)/\($0)" } ?? ops.freeName(in: d, base: "sem-titulo", ext: "txt")
        do {
            try ops.createFile(rel)
            expanded.insert(d)
            reload()
            openFile(rel)
            return rel
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func createFolder(near path: String?, name: String) {
        let d = dir(of: path)
        let rel = d.isEmpty ? name : "\(d)/\(name)"
        do {
            try ops.createDirectory(rel)
            expanded.insert(d)
            expanded.insert(rel)
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func rename(_ path: String, to newName: String, registrando: Bool = true) {
        do {
            let dest = try ops.rename(path, to: newName)
            remap(path, to: dest)
            if registrando {
                ultimaAcao = .renomeado(de: path, para: dest)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func move(_ path: String, into folder: String, registrando: Bool = true) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let dest = folder.isEmpty ? name : "\(folder)/\(name)"
        guard dest != path else { return }
        do {
            try ops.move(path, to: dest)
            remap(path, to: dest)
            expanded.insert(folder)
            if registrando {
                ultimaAcao = .movido(de: path, para: dest)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    func delete(_ path: String) {
        // Aba com alteração não salva dentro do que vai para a lixeira: o texto dela é
        // gravado antes, e vai junto. Antes a aba era fechada à força e o que estava
        // digitado sumia — nem o "desfazer" da árvore trazia de volta, porque o que foi
        // para a lixeira era o arquivo sem as alterações. Se não dá para gravar (disco em
        // conflito), nada é apagado.
        for t in tabs where t.isDirty && (t.path == path || t.path.hasPrefix(path + "/")) {
            guard save(t.path) else {
                self.error = tr("Não apaguei %1$@: as alterações de %2$@ não puderam ser salvas.", path, t.path)
                return
            }
        }
        do {
            let lixo = try ops.delete(path)
            ultimaAcao = .apagado(path: path, lixo: lixo)
            for t in tabs where t.path == path || t.path.hasPrefix(path + "/") {
                closeTab(t.path, force: true)
            }
            reload()
        } catch { self.error = error.localizedDescription }
    }

    private func remap(_ old: String, to new: String) {
        for i in tabs.indices {
            let p = tabs[i].path
            if p == old || p.hasPrefix(old + "/") {
                let np = new + p.dropFirst(old.count)
                tabs[i].path = np
                buffers[np] = buffers.removeValue(forKey: p)
                moverEstadoDoDisco(de: p, para: np)
                if active == p {
                    active = np
                }
            }
        }
        persistTabs()
    }
}
