import Foundation
import OdeteCore
import OdeteFiles

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
                if active == p {
                    active = np
                }
            }
        }
        persistTabs()
    }
}
