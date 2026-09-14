import Foundation
import JavaScriptCore

/// Sistema de arquivos síncrono. Caminhos absolutos; o JS resolve relativos contra cwd.
enum HostFs {
    static func err(_ code: String, _ path: String, _ msg: String) -> [String: Any] { ["error": code, "path": path, "message": msg] }

    static func install(_ rt: JSRuntime) {
        let h = rt.host
        let fm = FileManager.default

        let readText: @convention(block) (String) -> Any = { p in
            guard let d = fm.contents(atPath: p) else { return err("ENOENT", p, "no such file or directory") }
            return String(decoding: d, as: UTF8.self)
        }
        h.setObject(readText, forKeyedSubscript: "readText" as NSString)

        let readB64: @convention(block) (String) -> Any = { p in
            guard let d = fm.contents(atPath: p) else { return err("ENOENT", p, "no such file or directory") }
            return d.base64EncodedString()
        }
        h.setObject(readB64, forKeyedSubscript: "readB64" as NSString)

        let writeText: @convention(block) (String, String, Bool) -> Any = { p, text, append in
            do {
                if append, let fh = FileHandle(forWritingAtPath: p) {
                    try fh.seekToEnd(); try fh.write(contentsOf: Data(text.utf8)); try fh.close()
                } else {
                    try Data(text.utf8).write(to: URL(fileURLWithPath: p))
                }
                return true
            } catch { return err("EACCES", p, error.localizedDescription) }
        }
        h.setObject(writeText, forKeyedSubscript: "writeText" as NSString)

        let writeB64: @convention(block) (String, String, Bool) -> Any = { p, b64, append in
            guard let data = Data(base64Encoded: b64) else { return err("EINVAL", p, "base64") }
            do {
                if append, let fh = FileHandle(forWritingAtPath: p) {
                    try fh.seekToEnd(); try fh.write(contentsOf: data); try fh.close()
                } else {
                    try data.write(to: URL(fileURLWithPath: p))
                }
                return true
            } catch { return err("EACCES", p, error.localizedDescription) }
        }
        h.setObject(writeB64, forKeyedSubscript: "writeB64" as NSString)

        let stat: @convention(block) (String) -> Any = { p in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return err("ENOENT", p, "no such file or directory") }
            let attrs = (try? fm.attributesOfItem(atPath: p)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
            let mtime = ((attrs[.modificationDate] as? Date) ?? .now).timeIntervalSince1970 * 1000
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let link = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink
            return ["isDir": isDir.boolValue, "size": size, "mtime": mtime, "mode": mode, "isLink": link]
        }
        h.setObject(stat, forKeyedSubscript: "stat" as NSString)

        let exists: @convention(block) (String) -> Bool = { fm.fileExists(atPath: $0) }
        h.setObject(exists, forKeyedSubscript: "exists" as NSString)

        let readdir: @convention(block) (String) -> Any = { p in
            do { return try fm.contentsOfDirectory(atPath: p).sorted() } catch { return err("ENOENT", p, "no such file or directory") }
        }
        h.setObject(readdir, forKeyedSubscript: "readdir" as NSString)

        let mkdir: @convention(block) (String, Bool) -> Any = { p, recursive in
            if fm.fileExists(atPath: p) { return recursive ? true : err("EEXIST", p, "file already exists") }
            do { try fm.createDirectory(atPath: p, withIntermediateDirectories: recursive); return true } catch { return err("ENOENT", p, error.localizedDescription) }
        }
        h.setObject(mkdir, forKeyedSubscript: "mkdir" as NSString)

        let rm: @convention(block) (String, Bool, Bool) -> Any = { p, recursive, force in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir) else { return force ? true : err("ENOENT", p, "no such file or directory") }
            if isDir.boolValue, !recursive, !((try? fm.contentsOfDirectory(atPath: p))?.isEmpty ?? true) { return err("ENOTEMPTY", p, "directory not empty") }
            do { try fm.removeItem(atPath: p); return true } catch { return err("EACCES", p, error.localizedDescription) }
        }
        h.setObject(rm, forKeyedSubscript: "rm" as NSString)

        let rename: @convention(block) (String, String) -> Any = { a, b in
            do {
                if fm.fileExists(atPath: b) { try fm.removeItem(atPath: b) }
                try fm.moveItem(atPath: a, toPath: b); return true
            } catch { return err("ENOENT", a, error.localizedDescription) }
        }
        h.setObject(rename, forKeyedSubscript: "rename" as NSString)

        let copy: @convention(block) (String, String) -> Any = { a, b in
            do {
                if fm.fileExists(atPath: b) { try fm.removeItem(atPath: b) }
                try fm.copyItem(atPath: a, toPath: b); return true
            } catch { return err("ENOENT", a, error.localizedDescription) }
        }
        h.setObject(copy, forKeyedSubscript: "copy" as NSString)

        let realpath: @convention(block) (String) -> String = { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        h.setObject(realpath, forKeyedSubscript: "realpath" as NSString)

        let symlink: @convention(block) (String, String) -> Any = { target, path in
            do { try fm.createSymbolicLink(atPath: path, withDestinationPath: target); return true } catch { return err("EEXIST", path, error.localizedDescription) }
        }
        h.setObject(symlink, forKeyedSubscript: "symlink" as NSString)
        let readlink: @convention(block) (String) -> Any = { p in
            do { return try fm.destinationOfSymbolicLink(atPath: p) } catch { return err("EINVAL", p, "not a link") }
        }
        h.setObject(readlink, forKeyedSubscript: "readlink" as NSString)
        let chmod: @convention(block) (String, Int) -> Any = { p, mode in
            do { try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: p); return true } catch { return err("ENOENT", p, error.localizedDescription) }
        }
        h.setObject(chmod, forKeyedSubscript: "chmod" as NSString)
    }
}
