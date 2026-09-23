import Foundation
import JavaScriptCore
import OdeteI18n
import Synchronization

/// `readBytes`/`writeBytes`: arquivo inteiro entre o disco e um `Uint8Array`, com POSIX puro
/// (`open`/`read`/`write`), sem Data nem base64 no meio. Aqui também ficam o stdout em bytes
/// (`writeRaw`) e a leitura/escrita por descritor (`lerFd`/`escreverFd`), que escrevem direto
/// na memória do typed array.
extension HostBytes {
    /// Os callbacks C não carregam contexto: o runtime de cada contexto fica aqui.
    private final class Fraco: @unchecked Sendable {
        weak var rt: JSRuntime?
        init(_ rt: JSRuntime) {
            self.rt = rt
        }
    }

    private static let runtimes = Mutex<[UInt: Fraco]>([:])

    static func registrar(_ rt: JSRuntime) {
        guard let g = rt.context.jsGlobalContextRef else { return }
        let chave = UInt(bitPattern: g)
        runtimes.withLock { tabela in
            tabela = tabela.filter { $0.value.rt != nil }
            tabela[chave] = Fraco(rt)
        }
    }

    static func runtime(_ ctx: JSContextRef) -> JSRuntime? {
        let chave = UInt(bitPattern: JSContextGetGlobalContext(ctx))
        return runtimes.withLock { $0[chave]?.rt }
    }

    /// `readBytes(caminho)` → `Uint8Array`, ou `{ error, path, message }` como os outros de HostFs.
    static func lerArquivo(_ a: Argumentos, _: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        var bloqueio: [String: Any]?
        let r = caminhoC(a.ctx, a[0]) { c -> (UnsafeMutableRawPointer?, Int, Int32) in
            if let rt = runtime(a.ctx), let e = rt.bloqueado(String(cString: c)) {
                bloqueio = e
                return (nil, 0, EACCES)
            }
            return lerTudo(c)
        } ?? (nil, 0, ENOENT)
        if let bloqueio {
            return objetoDeErro(a, bloqueio)
        }
        guard let p = r.0 else { return erroDeArquivo(a, r.2) }
        return uint8Array(a.ctx, tomando: p, r.1)
    }

    /// `writeBytes(caminho, bytes, anexar)` → `true` ou `{ error, path, message }`.
    static func escreverArquivo(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let anexar = JSValueToBoolean(a.ctx, a[2])
        var semBytes = false
        var bloqueio: [String: Any]?
        // O ponteiro dos bytes só é pego depois de o caminho virar string: converter pode rodar JS.
        let e = caminhoC(a.ctx, a[0]) { c -> Int32 in
            if let rt = runtime(a.ctx), let b = rt.bloqueado(String(cString: c)) {
                bloqueio = b
                return EACCES
            }
            guard let dados = bytes(a.ctx, a[1]) else {
                semBytes = true; return 0
            }
            return escreverTudo(c, dados, anexar: anexar)
        } ?? ENOENT
        if semBytes {
            return lanca(a, exc, "writeBytes: typed array esperado")
        }
        if let bloqueio {
            return objetoDeErro(a, bloqueio)
        }
        return e == 0 ? JSValueMakeBoolean(a.ctx, true) : erroDeArquivo(a, e)
    }

    /// `writeRaw(fd, bytes | string)`: o `process.stdout.write` de verdade — bytes crus, sem
    /// linha implícita. Binário redirecionado para arquivo chega inteiro, e três `write`s
    /// parciais viram uma linha só na tela.
    static func escreverSaida(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let rt = runtime(a.ctx) else { return JSValueMakeUndefined(a.ctx) }
        if rt.interrompido.load(ordering: .relaxed) {
            let r = lanca(a, exc, "process interrupted")
            if let e = exc?.pointee, let o = JSValueToObject(a.ctx, e, nil) {
                poe(a.ctx, o, "__odeteExit", JSValueMakeBoolean(a.ctx, true))
            }
            return r
        }
        let kind: OutputKind = JSValueToNumber(a.ctx, a[0], nil) == 2 ? .err : .out
        let dados: Data
        if let v = a[1], JSValueIsString(a.ctx, v) {
            dados = comUTF16(a.ctx, v) { u, n -> Data in
                guard let u else { return Data() }
                let t = Utf8.tamanho(u, n)
                var d = Data(count: t)
                d.withUnsafeMutableBytes { m in
                    _ = Utf8.codifica(u, n, em: m.baseAddress!.assumingMemoryBound(to: UInt8.self), capacidade: t)
                }
                return d
            } ?? Data()
        } else if let b = bytes(a.ctx, a[1]) {
            dados = Data(b)
        } else {
            return lanca(a, exc, "writeRaw: string ou typed array esperado")
        }
        rt.emitirBruto(kind, dados)
        return JSValueMakeUndefined(a.ctx)
    }

    /// `lerFd(fd, destino, posição)` → bytes lidos (posição < 0: a atual do descritor). Lê
    /// direto na memória do `Uint8Array`; o `readSync` antes relia o arquivo inteiro a cada
    /// chamada.
    static func lerDescritor(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let rt = runtime(a.ctx) else { return JSValueMakeUndefined(a.ctx) }
        let fd = Int32(JSValueToNumber(a.ctx, a[0], nil))
        let pos = JSValueToNumber(a.ctx, a[2], nil)
        guard rt.descritores.contains(fd) else { return erroDeArquivo(a, EBADF) }
        guard let b = bytes(a.ctx, a[1]) else { return lanca(a, exc, "lerFd: Uint8Array esperado") }
        guard let base = b.baseAddress, b.count > 0 else { return JSValueMakeNumber(a.ctx, 0) }
        let alvo = UnsafeMutableRawPointer(mutating: base)
        var n: Int
        repeat {
            n = pos >= 0 ? pread(fd, alvo, b.count, off_t(pos)) : Darwin.read(fd, alvo, b.count)
        } while n < 0 && errno == EINTR
        return n < 0 ? erroDeArquivo(a, errno) : JSValueMakeNumber(a.ctx, Double(n))
    }

    /// `escreverFd(fd, bytes, posição)` → bytes escritos (posição < 0: a atual).
    static func escreverDescritor(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let rt = runtime(a.ctx) else { return JSValueMakeUndefined(a.ctx) }
        let fd = Int32(JSValueToNumber(a.ctx, a[0], nil))
        let pos = JSValueToNumber(a.ctx, a[2], nil)
        guard rt.descritores.contains(fd) else { return erroDeArquivo(a, EBADF) }
        guard let b = bytes(a.ctx, a[1]) else { return lanca(a, exc, "escreverFd: Uint8Array esperado") }
        guard let base = b.baseAddress, b.count > 0 else { return JSValueMakeNumber(a.ctx, 0) }
        var feito = 0
        while feito < b.count {
            let r = pos >= 0
                ? pwrite(fd, base + feito, b.count - feito, off_t(pos) + off_t(feito))
                : Darwin.write(fd, base + feito, b.count - feito)
            if r < 0 {
                if errno == EINTR {
                    continue
                }
                return erroDeArquivo(a, errno)
            }
            feito += r
        }
        return JSValueMakeNumber(a.ctx, Double(feito))
    }

    /// Roda `corpo` com o caminho JS em UTF-8 terminado em zero. Nil (vira ENOENT) para caminho
    /// vazio ou com NUL no meio: em C ele seria cortado ali e abriria outro arquivo — o Node
    /// também recusa. Substituto solto vira U+FFFD, como no Node, nunca um prefixo do nome.
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
        let codigo = HostFs.nomes[e] ?? "EIO"
        let msg = e == ENOENT ? tr("no such file or directory") : String(cString: strerror(e)).minusculaNoComeco
        poe(a.ctx, o, "error", texto(a.ctx, codigo))
        poe(a.ctx, o, "path", a[0] ?? JSValueMakeUndefined(a.ctx))
        poe(a.ctx, o, "message", texto(a.ctx, msg))
        return o
    }

    /// O mesmo formato, a partir do dicionário de `HostFs.err`.
    private static func objetoDeErro(_ a: Argumentos, _ d: [String: Any]) -> JSValueRef? {
        let o = JSObjectMake(a.ctx, nil, nil)
        for (k, v) in d {
            poe(a.ctx, o, k, texto(a.ctx, "\(v)"))
        }
        return o
    }
}
