import Foundation
import JavaScriptCore
import OdeteI18n

/// Sistema de arquivos síncrono. Caminhos absolutos; o JS resolve relativos contra cwd.
///
/// Tudo em POSIX (`stat`, `opendir`, `rename`, `open`…): o FileManager custava um `stat`
/// com ponte ObjC por entrada — andar pelo node_modules levava 0,7 s sem JIT — e tinha
/// semântica diferente da do Node em pontos que machucam: `rename` apagava a pasta de
/// destino antes de mover, `stat` não seguia link nem `lstat` existia. Todo caminho passa
/// pelo `Confinamento` do runtime quando há um.
enum HostFs {
    static func err(_ code: String, _ path: String, _ msg: String) -> [String: Any] {
        [
            "error": code,
            "path": path,
            "message": msg,
        ]
    }

    /// Erro no formato do Node a partir de um `errno`.
    static func erro(_ e: Int32, _ path: String) -> [String: Any] {
        let msg = e == ENOENT ? tr("no such file or directory") : String(cString: strerror(e)).minusculaNoComeco
        return err(nomes[e] ?? "EIO", path, msg)
    }

    static let nomes: [Int32: String] = [
        ENOENT: "ENOENT", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR", EACCES: "EACCES", EPERM: "EPERM",
        EEXIST: "EEXIST", ENOSPC: "ENOSPC", EROFS: "EROFS", EMFILE: "EMFILE", ENFILE: "ENFILE",
        EBUSY: "EBUSY", EINVAL: "EINVAL", ENAMETOOLONG: "ENAMETOOLONG", ELOOP: "ELOOP", ENOMEM: "ENOMEM",
        ENOTEMPTY: "ENOTEMPTY", EXDEV: "EXDEV", EBADF: "EBADF", EAGAIN: "EAGAIN", EMLINK: "EMLINK",
    ]

    static func install(_ rt: JSRuntime) {
        let h = rt.host
        func def(_ nome: String, _ bloco: Any) {
            h.setObject(bloco, forKeyedSubscript: nome as NSString)
        }

        let readText: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p) {
                return e
            }
            let (buf, n, e) = HostBytes.lerTudo(p)
            guard let buf else { return erro(e, p) }
            defer { free(buf) }
            return String(decoding: UnsafeRawBufferPointer(start: buf, count: n), as: UTF8.self)
        }
        def("readText", readText)

        let readB64: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p) {
                return e
            }
            guard let d = FileManager.default.contents(atPath: p) else { return erro(ENOENT, p) }
            return d.base64EncodedString()
        }
        def("readB64", readB64)

        let writeText: @convention(block) (String, String, Bool) -> Any = { [unowned rt] p, text, append in
            if let e = rt.bloqueado(p) {
                return e
            }
            var s = text
            let r = s.withUTF8 { u in
                HostBytes.escreverTudo(p, UnsafeRawBufferPointer(u), anexar: append)
            }
            return r == 0 ? true : erro(r, p)
        }
        def("writeText", writeText)

        let writeB64: @convention(block) (String, String, Bool) -> Any = { [unowned rt] p, b64, append in
            if let e = rt.bloqueado(p) {
                return e
            }
            guard let data = Data(base64Encoded: b64) else { return err("EINVAL", p, "base64") }
            let r = data.withUnsafeBytes { HostBytes.escreverTudo(p, $0, anexar: append) }
            return r == 0 ? true : erro(r, p)
        }
        def("writeB64", writeB64)

        // Formato antigo (dicionário), para quem ainda chama; o fs.js usa `statx`.
        let statAntigo: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p) {
                return e
            }
            var st = Darwin.stat()
            guard statPOSIX(p, &st) == 0 else { return erro(errno, p) }
            var lst = Darwin.stat()
            let link = lstat(p, &lst) == 0 && (lst.st_mode & S_IFMT) == S_IFLNK
            return [
                "isDir": (st.st_mode & S_IFMT) == S_IFDIR, "size": Int(st.st_size),
                "mtime": ms(st.st_mtimespec), "mode": Int(st.st_mode & 0o7777), "isLink": link,
            ]
        }
        def("stat", statAntigo)

        // `statx(caminho, seguir)` → [dev, ino, mode, nlink, uid, gid, rdev, size, blksize,
        // blocks, atimeMs, mtimeMs, ctimeMs, birthtimeMs]. `seguir` falso é o `lstat`.
        let statx: @convention(block) (String, Bool) -> Any = { [unowned rt] p, seguir in
            if let e = rt.bloqueado(p, seguirUltimo: seguir) {
                return e
            }
            var st = Darwin.stat()
            let r = seguir ? statPOSIX(p, &st) : lstat(p, &st)
            guard r == 0 else { return erro(errno, p) }
            return campos(st)
        }
        def("statx", statx)

        let exists: @convention(block) (String) -> Bool = { [unowned rt] p in
            if rt.bloqueado(p) != nil {
                return false
            }
            return Darwin.access(p, F_OK) == 0
        }
        def("exists", exists)

        let readdir: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p) {
                return e
            }
            guard let (nomes, _) = listar(p) else { return erro(errno, p) }
            return nomes
        }
        def("readdir", readdir)

        // `readdirTipos(caminho)` → [nomes, tipos] (0 outro, 1 arquivo, 2 pasta, 3 link), sem
        // um `stat` por entrada: o tipo vem do próprio `readdir`.
        let readdirTipos: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p) {
                return e
            }
            guard let (nomes, tipos) = listar(p) else { return erro(errno, p) }
            return [nomes, tipos]
        }
        def("readdirTipos", readdirTipos)

        let mkdir: @convention(block) (String, Bool, Int) -> Any = { [unowned rt] p, recursive, modo in
            if let e = rt.bloqueado(p) {
                return e
            }
            let m = mode_t(modo > 0 ? modo : 0o777)
            if !recursive {
                return Darwin.mkdir(p, m) == 0 ? true : erro(errno, p)
            }
            // Recursivo: devolve a primeira pasta criada, como o Node (ou `true` se já existia).
            var faltando: [String] = []
            var atual = p
            var st = Darwin.stat()
            while statPOSIX(atual, &st) != 0 {
                faltando.append(atual)
                let pai = (atual as NSString).deletingLastPathComponent
                if pai == atual || pai.isEmpty {
                    break
                }
                atual = pai
            }
            if faltando.isEmpty {
                return (st.st_mode & S_IFMT) == S_IFDIR ? true : erro(EEXIST, p)
            }
            for d in faltando.reversed() where Darwin.mkdir(d, m) != 0 && errno != EEXIST {
                return erro(errno, d)
            }
            return faltando.last ?? true
        }
        def("mkdir", mkdir)

        let rm: @convention(block) (String, Bool, Bool) -> Any = { [unowned rt] p, recursive, force in
            if let e = rt.bloqueado(p, seguirUltimo: false) {
                return e
            }
            if let raiz = rt.confinamento?.raizes.first, Confinamento.real(p, seguirUltimo: false) == raiz {
                return err("EPERM", p, tr("não apago a raiz do projeto"))
            }
            var st = Darwin.stat()
            guard lstat(p, &st) == 0 else { return force && errno == ENOENT ? true : erro(errno, p) }
            if (st.st_mode & S_IFMT) != S_IFDIR {
                return unlink(p) == 0 ? true : erro(errno, p)
            }
            if !recursive {
                return rmdir(p) == 0 ? true : erro(errno, p)
            }
            // Apaga o conteúdo sem seguir links: um link para fora some, o alvo fica.
            return apagarArvore(p) ?? true
        }
        def("rm", rm)

        // `rename(2)` puro: arquivo sobre pasta é EISDIR, pasta sobre pasta cheia é ENOTEMPTY,
        // como no Node. Antes o destino era apagado antes de mover — pasta inteira inclusive.
        let rename: @convention(block) (String, String) -> Any = { [unowned rt] a, b in
            if let e = rt.bloqueado(a, seguirUltimo: false) ?? rt.bloqueado(b, seguirUltimo: false) {
                return e
            }
            return Darwin.rename(a, b) == 0 ? true : erro(errno, a)
        }
        def("rename", rename)

        // `copyFileSync`: arquivo para arquivo; destino pasta é EISDIR (nunca apaga nada).
        let copy: @convention(block) (String, String) -> Any = { [unowned rt] a, b in
            if let e = rt.bloqueado(a) ?? rt.bloqueado(b) {
                return e
            }
            return copiarArquivo(a, b).map { erro($0, $0 == ENOENT ? a : b) } ?? true
        }
        def("copy", copy)

        // `cpSync(origem, destino, recursivo, sobrescrever)`: pasta vira mescla, como no Node.
        let cp: @convention(block) (String, String, Bool, Bool) -> Any = { [unowned rt] a, b, recursivo, sobrescrever in
            if let e = rt.bloqueado(a) ?? rt.bloqueado(b) {
                return e
            }
            return copiarArvore(a, b, recursivo: recursivo, sobrescrever: sobrescrever) ?? true
        }
        def("cp", cp)

        let realpath: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p) {
                return e
            }
            return Confinamento.realpathC(p) ?? erro(errno, p)
        }
        def("realpath", realpath)

        // Chave de módulo: o caminho real, ou o próprio caminho se algo falhar.
        let caminhoReal: @convention(block) (String) -> String = { p in Confinamento.realpathC(p) ?? p }
        def("caminhoReal", caminhoReal)

        let symlink: @convention(block) (String, String) -> Any = { [unowned rt] target, path in
            if let e = rt.bloqueado(path, seguirUltimo: false) {
                return e
            }
            return Darwin.symlink(target, path) == 0 ? true : erro(errno, path)
        }
        def("symlink", symlink)

        let readlink: @convention(block) (String) -> Any = { [unowned rt] p in
            if let e = rt.bloqueado(p, seguirUltimo: false) {
                return e
            }
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = Darwin.readlink(p, &buf, buf.count - 1)
            guard n >= 0 else { return erro(errno, p) }
            buf[n] = 0
            return String(cString: buf)
        }
        def("readlink", readlink)

        let chmod: @convention(block) (String, Int) -> Any = { [unowned rt] p, mode in
            if let e = rt.bloqueado(p) {
                return e
            }
            return Darwin.chmod(p, mode_t(mode)) == 0 ? true : erro(errno, p)
        }
        def("chmod", chmod)

        let access: @convention(block) (String, Int) -> Any = { [unowned rt] p, mode in
            if let e = rt.bloqueado(p) {
                return e
            }
            return Darwin.access(p, Int32(mode)) == 0 ? true : erro(errno, p)
        }
        def("access", access)

        let utimes: @convention(block) (String, Double, Double) -> Any = { [unowned rt] p, atime, mtime in
            if let e = rt.bloqueado(p) {
                return e
            }
            var tempos = [timeval(segundos: atime), timeval(segundos: mtime)]
            return Darwin.utimes(p, &tempos) == 0 ? true : erro(errno, p)
        }
        def("utimes", utimes)

        let truncate: @convention(block) (String, Int) -> Any = { [unowned rt] p, len in
            if let e = rt.bloqueado(p) {
                return e
            }
            return Darwin.truncate(p, off_t(len)) == 0 ? true : erro(errno, p)
        }
        def("truncate", truncate)

        let mkdtemp: @convention(block) (String) -> Any = { [unowned rt] prefixo in
            if let e = rt.bloqueado(prefixo) {
                return e
            }
            var modelo = Array((prefixo + "XXXXXX").utf8CString)
            guard Darwin.mkdtemp(&modelo) != nil else { return erro(errno, prefixo) }
            return String(cString: modelo)
        }
        def("mkdtemp", mkdtemp)

        // MARK: descritores

        // `abrir(caminho, flags, modo)` → fd. As flags chegam já em O_* do Darwin.
        let abrir: @convention(block) (String, Int, Int) -> Any = { [unowned rt] p, flags, modo in
            if let e = rt.bloqueado(p) {
                return e
            }
            let fd = Darwin.open(p, Int32(flags) | O_CLOEXEC, mode_t(modo > 0 ? modo : 0o666))
            guard fd >= 0 else { return erro(errno, p) }
            var st = Darwin.stat()
            if fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, Int32(flags) & O_ACCMODE != O_RDONLY {
                Darwin.close(fd)
                return erro(EISDIR, p)
            }
            rt.descritores.insert(fd)
            return Int(fd)
        }
        def("abrir", abrir)

        let fechar: @convention(block) (Int) -> Any = { [unowned rt] fd in
            guard rt.descritores.remove(Int32(fd)) != nil else { return erro(EBADF, "") }
            return Darwin.close(Int32(fd)) == 0 ? true : erro(errno, "")
        }
        def("fechar", fechar)

        let fstatx: @convention(block) (Int) -> Any = { [unowned rt] fd in
            guard rt.descritores.contains(Int32(fd)) else { return erro(EBADF, "") }
            var st = Darwin.stat()
            guard fstat(Int32(fd), &st) == 0 else { return erro(errno, "") }
            return campos(st)
        }
        def("fstatx", fstatx)

        let ftruncar: @convention(block) (Int, Int) -> Any = { [unowned rt] fd, len in
            guard rt.descritores.contains(Int32(fd)) else { return erro(EBADF, "") }
            return ftruncate(Int32(fd), off_t(len)) == 0 ? true : erro(errno, "")
        }
        def("ftruncar", ftruncar)
    }

    // MARK: - ajudantes

    static func ms(_ t: timespec) -> Double {
        Double(t.tv_sec) * 1000 + Double(t.tv_nsec) / 1_000_000
    }

    static func campos(_ st: Darwin.stat) -> [Double] {
        [
            Double(st.st_dev), Double(st.st_ino), Double(st.st_mode), Double(st.st_nlink), Double(st.st_uid),
            Double(st.st_gid), Double(st.st_rdev), Double(st.st_size), Double(st.st_blksize), Double(st.st_blocks),
            ms(st.st_atimespec), ms(st.st_mtimespec), ms(st.st_ctimespec), ms(st.st_birthtimespec),
        ]
    }

    /// Nomes (em ordem) e tipos de uma pasta; nil com `errno` preenchido.
    static func listar(_ p: String) -> ([String], [Int])? {
        guard let dir = opendir(p) else { return nil }
        defer { closedir(dir) }
        var itens: [(String, Int)] = []
        while let e = Darwin.readdir(dir) {
            var ent = e.pointee
            let nome = withUnsafePointer(to: &ent.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(ent.d_namlen) + 1) { String(cString: $0) }
            }
            if nome == "." || nome == ".." {
                continue
            }
            var tipo = switch Int32(ent.d_type) {
            case DT_REG: 1
            case DT_DIR: 2
            case DT_LNK: 3
            default: 0
            }
            if Int32(ent.d_type) == DT_UNKNOWN {
                var st = Darwin.stat()
                if lstat(p + "/" + nome, &st) == 0 {
                    let f = st.st_mode & S_IFMT
                    tipo = f == S_IFREG ? 1 : f == S_IFDIR ? 2 : f == S_IFLNK ? 3 : 0
                }
            }
            itens.append((nome, tipo))
        }
        itens.sort { $0.0 < $1.0 }
        return (itens.map(\.0), itens.map(\.1))
    }

    /// Apaga uma pasta e o que há nela, sem seguir links. Devolve o erro do primeiro que falhar.
    static func apagarArvore(_ p: String) -> [String: Any]? {
        guard let (nomes, tipos) = listar(p) else { return erro(errno, p) }
        for (nome, tipo) in zip(nomes, tipos) {
            let filho = p + "/" + nome
            if tipo == 2 {
                if let e = apagarArvore(filho) {
                    return e
                }
            } else if unlink(filho) != 0 {
                return erro(errno, filho)
            }
        }
        return rmdir(p) == 0 ? nil : erro(errno, p)
    }

    /// Copia um arquivo (dados e permissões). Devolve o errno ou nil.
    static func copiarArquivo(_ a: String, _ b: String) -> Int32? {
        var st = Darwin.stat()
        if statPOSIX(b, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
            return EISDIR
        }
        guard statPOSIX(a, &st) == 0 else { return errno }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            return EISDIR
        }
        return copyfile(a, b, nil, copyfile_flags_t(COPYFILE_DATA | COPYFILE_SECURITY)) == 0 ? nil : errno
    }

    static func copiarArvore(_ a: String, _ b: String, recursivo: Bool, sobrescrever: Bool) -> [String: Any]? {
        var st = Darwin.stat()
        guard lstat(a, &st) == 0 else { return erro(errno, a) }
        let tipo = st.st_mode & S_IFMT
        if tipo == S_IFLNK {
            var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = Darwin.readlink(a, &buf, buf.count - 1)
            guard n >= 0 else { return erro(errno, a) }
            buf[n] = 0
            if lstat(b, &st) == 0 {
                guard sobrescrever else { return nil }
                unlink(b)
            }
            return Darwin.symlink(buf, b) == 0 ? nil : erro(errno, b)
        }
        if tipo != S_IFDIR {
            if statPOSIX(b, &st) == 0 {
                if (st.st_mode & S_IFMT) == S_IFDIR {
                    return erro(EISDIR, b)
                }
                guard sobrescrever else { return nil }
            }
            return copiarArquivo(a, b).map { erro($0, b) }
        }
        guard recursivo else { return err("ERR_FS_EISDIR", a, "Recursive option is required to copy a directory") }
        if statPOSIX(b, &st) != 0 {
            guard Darwin.mkdir(b, 0o777) == 0 else { return erro(errno, b) }
        } else if (st.st_mode & S_IFMT) != S_IFDIR {
            return erro(ENOTDIR, b)
        }
        guard let (nomes, _) = listar(a) else { return erro(errno, a) }
        for nome in nomes {
            if let e = copiarArvore(a + "/" + nome, b + "/" + nome, recursivo: true, sobrescrever: sobrescrever) {
                return e
            }
        }
        return nil
    }
}

/// O `stat(2)`: dentro de HostFs o nome `stat` é também o do struct.
private func statPOSIX(_ p: String, _ st: inout stat) -> Int32 {
    stat(p, &st)
}

extension JSRuntime {
    /// O erro do confinamento, se o caminho estiver fora; nil se pode seguir. Também é aqui
    /// que um processo morto com Ctrl+C para de mexer em arquivo.
    func bloqueado(_ caminho: String, seguirUltimo: Bool = true) -> [String: Any]? {
        if lancarSeInterrompido() {
            return HostFs.err("EINTR", caminho, "interrupted")
        }
        return foraDoProjeto(caminho, seguirUltimo: seguirUltimo)
    }
}

extension timeval {
    init(segundos: Double) {
        let s = floor(segundos)
        self.init(tv_sec: Int(s), tv_usec: Int32((segundos - s) * 1_000_000))
    }
}

extension String {
    var minusculaNoComeco: String {
        prefix(1).lowercased() + dropFirst()
    }
}
