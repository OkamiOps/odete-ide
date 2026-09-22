import Foundation
import JavaScriptCore
import OdeteI18n

/// `readBytes`/`writeBytes`: arquivo inteiro entre o disco e um `Uint8Array`, com POSIX puro
/// (`open`/`read`/`write`), sem Data nem base64 no meio.
extension HostBytes {
    /// `readBytes(caminho)` → `Uint8Array`, ou `{ error, path, message }` como os outros de HostFs.
    static func lerArquivo(_ a: Argumentos, _: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let r = caminhoC(a.ctx, a[0]) { lerTudo($0) } ?? (nil, 0, ENOENT)
        guard let p = r.0 else { return erroDeArquivo(a, r.2) }
        return uint8Array(a.ctx, tomando: p, r.1)
    }

    /// `writeBytes(caminho, bytes, anexar)` → `true` ou `{ error, path, message }`.
    static func escreverArquivo(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let anexar = JSValueToBoolean(a.ctx, a[2])
        var semBytes = false
        // O ponteiro dos bytes só é pego depois de o caminho virar string: converter pode rodar JS.
        let e = caminhoC(a.ctx, a[0]) { c -> Int32 in
            guard let dados = bytes(a.ctx, a[1]) else {
                semBytes = true; return 0
            }
            return escreverTudo(c, dados, anexar: anexar)
        } ?? ENOENT
        if semBytes {
            return lanca(a, exc, "writeBytes: typed array esperado")
        }
        return e == 0 ? JSValueMakeBoolean(a.ctx, true) : erroDeArquivo(a, e)
    }

    /// Roda `corpo` com o caminho JS em UTF-8 terminado em zero. Nil (vira ENOENT) para caminho
    /// vazio ou com NUL no meio: em C ele seria cortado ali e abriria outro arquivo — o Node
    /// também recusa. Substituto solto vira bytes que o APFS rejeita, nunca um prefixo do nome.
    private static func caminhoC<R>(_ ctx: JSContextRef, _ v: JSValueRef?, _ corpo: (UnsafePointer<CChar>) -> R) -> R? {
        comUTF16(ctx, v) { u, n -> R? in
            guard let u else { return nil }
            let t = Utf8.tamanho(u, n)
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: t + 1)
            defer { buf.deallocate() }
            _ = Utf8.codifica(u, n, em: buf, capacidade: t)
            buf[t] = 0
            if memchr(buf, 0, t) != nil {
                return nil
            }
            return buf.withMemoryRebound(to: CChar.self, capacity: t + 1) { corpo($0) }
        } ?? nil
    }

    /// Lê o arquivo inteiro num bloco de `malloc`. Devolve (bloco, tamanho, errno).
    static func lerTudo(_ caminho: UnsafePointer<CChar>) -> (UnsafeMutableRawPointer?, Int, Int32) {
        let fd = Darwin.open(caminho, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            return (nil, 0, errno)
        }
        defer { Darwin.close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 {
            return (nil, 0, errno)
        }
        if (st.st_mode & S_IFMT) == S_IFDIR {
            return (nil, 0, EISDIR)
        }
        // +1: a leitura que devolve 0 (fim) cabe sem realocar; arquivos que crescem ou sem
        // tamanho conhecido (fifo, /dev) dobram o bloco.
        var capacidade = max(Int(st.st_size), 0) + 1
        guard var buf = malloc(capacidade) else { return (nil, 0, ENOMEM) }
        var total = 0
        while true {
            if total == capacidade {
                capacidade = capacidade * 2 + 65536
                guard let maior = realloc(buf, capacidade) else {
                    free(buf); return (nil, 0, ENOMEM)
                }
                buf = maior
            }
            let r = Darwin.read(fd, buf + total, capacidade - total)
            if r == 0 {
                break
            }
            if r < 0 {
                if errno == EINTR {
                    continue
                }
                let e = errno
                free(buf)
                return (nil, 0, e)
            }
            total += r
        }
        return (buf, total, 0)
    }

    /// Escreve tudo (truncando ou anexando). Devolve 0 ou o errno.
    static func escreverTudo(_ caminho: UnsafePointer<CChar>, _ dados: UnsafeRawBufferPointer, anexar: Bool) -> Int32 {
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (anexar ? O_APPEND : O_TRUNC)
        let fd = Darwin.open(caminho, flags, 0o666)
        if fd < 0 {
            return errno
        }
        var feito = 0
        while feito < dados.count, let base = dados.baseAddress {
            let r = Darwin.write(fd, base + feito, dados.count - feito)
            if r < 0 {
                if errno == EINTR {
                    continue
                }
                let e = errno
                Darwin.close(fd)
                return e
            }
            feito += r
        }
        return Darwin.close(fd) == 0 || errno == EINTR ? 0 : errno
    }

    /// `{ error, path, message }` com o código POSIX no estilo do Node.
    private static func erroDeArquivo(_ a: Argumentos, _ e: Int32) -> JSValueRef? {
        let o = JSObjectMake(a.ctx, nil, nil)
        let codigo = nomesDeErro[e] ?? "EIO"
        let msg = e == ENOENT ? tr("no such file or directory") : minusculaInicial(String(cString: strerror(e)))
        poe(a.ctx, o, "error", texto(a.ctx, codigo))
        poe(a.ctx, o, "path", a[0] ?? JSValueMakeUndefined(a.ctx))
        poe(a.ctx, o, "message", texto(a.ctx, msg))
        return o
    }

    private static let nomesDeErro: [Int32: String] = [
        ENOENT: "ENOENT", ENOTDIR: "ENOTDIR", EISDIR: "EISDIR", EACCES: "EACCES", EPERM: "EPERM",
        EEXIST: "EEXIST", ENOSPC: "ENOSPC", EROFS: "EROFS", EMFILE: "EMFILE", ENFILE: "ENFILE",
        EBUSY: "EBUSY", EINVAL: "EINVAL", ENAMETOOLONG: "ENAMETOOLONG", ELOOP: "ELOOP", ENOMEM: "ENOMEM",
    ]

    private static func minusculaInicial(_ s: String) -> String {
        s.prefix(1).lowercased() + s.dropFirst()
    }
}
