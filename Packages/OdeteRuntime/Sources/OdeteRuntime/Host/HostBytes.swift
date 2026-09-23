import Foundation
import JavaScriptCore
import Security

/// Bytes e texto atravessando a ponte sem base64.
///
/// No iPad o JavaScriptCore de um app de terceiros roda sem JIT: todo laço byte a byte em JS
/// (base64, UTF-8) é interpretado, e só ler o esbuild.wasm (14 MB) custava segundos. Estas
/// funções usam a API C do JSC para entregar ao JS um `Uint8Array` de verdade (a memória é
/// nossa, solta pelo desalocador quando o GC recolhe o array) e para ler direto da memória de
/// typed arrays e ArrayBuffers. São callbacks C sem estado, sem o custo de conversão dos blocos
/// ObjC. As regras de UTF-8, base64 e latin1 repetem exatamente as do JS que substituem
/// (bootstrap.js), inclusive as esquisitices, para ninguém ver texto diferente por causa do tamanho.
enum HostBytes {
    static func install(_ rt: JSRuntime) {
        guard let ctx = rt.context.jsGlobalContextRef, let host = rt.host.jsValueRef else { return }
        registrar(rt)
        let def = { (nome: String, fn: JSObjectCallAsFunctionCallback) in define(ctx, host, nome, fn) }
        def("readBytes") { c, _, _, n, a, e in HostBytes.lerArquivo(Argumentos(c, n, a), e) }
        def("writeBytes") { c, _, _, n, a, e in HostBytes.escreverArquivo(Argumentos(c, n, a), e) }
        def("utf8Decode") { c, _, _, n, a, e in HostBytes.utf8Decode(Argumentos(c, n, a), e) }
        def("utf8Encode") { c, _, _, n, a, e in HostBytes.utf8Encode(Argumentos(c, n, a), e) }
        def("utf8EncodeInto") { c, _, _, n, a, e in HostBytes.utf8EncodeInto(Argumentos(c, n, a), e) }
        def("utf8Length") { c, _, _, n, a, e in HostBytes.utf8Length(Argumentos(c, n, a), e) }
        def("latin1Decode") { c, _, _, n, a, e in HostBytes.latin1Decode(Argumentos(c, n, a), e) }
        def("latin1Encode") { c, _, _, n, a, e in HostBytes.latin1Encode(Argumentos(c, n, a), e) }
        def("utf16leDecode") { c, _, _, n, a, e in HostBytes.utf16leDecode(Argumentos(c, n, a), e) }
        def("b64Encode") { c, _, _, n, a, e in HostBytes.b64Encode(Argumentos(c, n, a), e) }
        def("b64Decode") { c, _, _, n, a, e in HostBytes.b64Decode(Argumentos(c, n, a), e) }
        def("gzipBytes") { c, _, _, n, a, e in HostBytes.gzipBytes(Argumentos(c, n, a), e) }
        def("hashBytes") { c, _, _, n, a, e in HostBytes.hashBytes(Argumentos(c, n, a), e) }
        def("randomFill") { c, _, _, n, a, e in HostBytes.randomFill(Argumentos(c, n, a), e) }
        def("hmacBytes") { c, _, _, n, a, e in HostBytes.hmacBytes(Argumentos(c, n, a), e) }
        def("pbkdf2Bytes") { c, _, _, n, a, e in HostBytes.pbkdf2Bytes(Argumentos(c, n, a), e) }
        def("writeRaw") { c, _, _, n, a, e in HostBytes.escreverSaida(Argumentos(c, n, a), e) }
        def("compilar") { c, _, _, n, a, e in HostBytes.compilar(Argumentos(c, n, a), e) }
        def("lerFd") { c, _, _, n, a, e in HostBytes.lerDescritor(Argumentos(c, n, a), e) }
        def("escreverFd") { c, _, _, n, a, e in HostBytes.escreverDescritor(Argumentos(c, n, a), e) }
    }

    private static func define(
        _ ctx: JSGlobalContextRef,
        _ alvo: JSObjectRef,
        _ nome: String,
        _ fn: JSObjectCallAsFunctionCallback
    ) {
        let n = JSStringCreateWithUTF8CString(nome)
        defer { JSStringRelease(n) }
        let f = JSObjectMakeFunctionWithCallback(ctx, n, fn)
        JSObjectSetProperty(ctx, alvo, n, f, JSPropertyAttributes(kJSPropertyAttributeDontEnum), nil)
    }

    /// Os argumentos de um callback C, com acesso seguro por índice.
    struct Argumentos {
        let ctx: JSContextRef
        let n: Int
        let v: UnsafePointer<JSValueRef?>?

        init(_ ctx: JSContextRef?, _ n: Int, _ v: UnsafePointer<JSValueRef?>?) {
            self.ctx = ctx!
            self.n = n
            self.v = v
        }

        subscript(_ i: Int) -> JSValueRef? {
            i < n ? v?[i] : nil
        }
    }

    // MARK: - ponte: bytes e strings do JS

    /// Ponteiro e tamanho dos bytes de um typed array (qualquer tipo) ou ArrayBuffer, sem cópia.
    /// DataView não entra: o JS normaliza para `Uint8Array` antes. O ponteiro só vale até a
    /// próxima chamada à API do JSC que possa rodar JS.
    static func bytes(_ ctx: JSContextRef, _ v: JSValueRef?) -> UnsafeRawBufferPointer? {
        guard let v else { return nil }
        let tipo = JSValueGetTypedArrayType(ctx, v, nil)
        if tipo == kJSTypedArrayTypeNone {
            return nil
        }
        if tipo == kJSTypedArrayTypeArrayBuffer {
            let n = JSObjectGetArrayBufferByteLength(ctx, v, nil)
            guard n > 0, let p = JSObjectGetArrayBufferBytesPtr(ctx, v, nil) else { return vazio }
            return UnsafeRawBufferPointer(start: p, count: n)
        }
        let n = JSObjectGetTypedArrayByteLength(ctx, v, nil)
        // O ponteiro é o começo do ArrayBuffer inteiro; a vista começa `byteOffset` depois.
        guard n > 0, let base = JSObjectGetTypedArrayBytesPtr(ctx, v, nil) else { return vazio }
        let deslocamento = JSObjectGetTypedArrayByteOffset(ctx, v, nil)
        return UnsafeRawBufferPointer(start: base + deslocamento, count: n)
    }

    static var vazio: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: nil, count: 0)
    }

    /// Um `Uint8Array` novo com uma cópia de `fonte`.
    static func uint8Array(_ ctx: JSContextRef, copiando fonte: UnsafeRawBufferPointer) -> JSValueRef? {
        let n = fonte.count
        guard let p = malloc(max(n, 1)) else { return nil }
        if n > 0, let origem = fonte.baseAddress {
            memcpy(p, origem, n)
        }
        return uint8Array(ctx, tomando: p, n)
    }

    /// Um `Uint8Array` que passa a ser dono de `p` (vindo de `malloc`); o GC chama `free`.
    static func uint8Array(_ ctx: JSContextRef, tomando p: UnsafeMutableRawPointer, _ n: Int) -> JSValueRef? {
        // Se falhar, o próprio JSC chama o desalocador: não há `free` a fazer aqui.
        JSObjectMakeTypedArrayWithBytesNoCopy(
            ctx,
            kJSTypedArrayTypeUint8Array,
            p,
            n,
            { bytes, _ in free(bytes) },
            nil,
            nil
        )
    }

    /// Roda `corpo` com as unidades UTF-16 da string JS (cópia do JSC, válida só dentro).
    static func comUTF16<R>(
        _ ctx: JSContextRef,
        _ v: JSValueRef?,
        _ corpo: (UnsafePointer<UInt16>?, Int) -> R
    ) -> R? {
        guard let v, let s = JSValueToStringCopy(ctx, v, nil) else { return nil }
        defer { JSStringRelease(s) }
        let n = JSStringGetLength(s)
        return corpo(n > 0 ? JSStringGetCharactersPtr(s) : nil, n)
    }

    /// String JS a partir de UTF-16.
    static func texto(_ ctx: JSContextRef, utf16 p: UnsafePointer<UInt16>?, _ n: Int) -> JSValueRef? {
        guard n > 0, let p else { return texto(ctx, "") }
        let s = JSStringCreateWithCharacters(p, n)
        defer { JSStringRelease(s) }
        return JSValueMakeString(ctx, s)
    }

    /// String JS de 8 bits a partir de bytes latin1 (ASCII incluso): o JSC guarda assim metade
    /// da memória de uma string de 16 bits.
    static func texto(_ ctx: JSContextRef, latin1 p: UnsafeRawPointer?, _ n: Int) -> JSValueRef? {
        guard n > 0, let p,
              let cf = CFStringCreateWithBytesNoCopy(
                  nil,
                  p.assumingMemoryBound(to: UInt8.self),
                  n,
                  CFStringBuiltInEncodings.isoLatin1.rawValue,
                  false,
                  kCFAllocatorNull
              ) else { return texto(ctx, "") }
        let s = JSStringCreateWithCFString(cf)
        defer { JSStringRelease(s) }
        return JSValueMakeString(ctx, s)
    }

    static func texto(_ ctx: JSContextRef, _ s: String) -> JSValueRef? {
        let j = JSStringCreateWithUTF8CString(s)
        defer { JSStringRelease(j) }
        return JSValueMakeString(ctx, j)
    }

    /// Lança um `Error` no JS e devolve `undefined`.
    static func lanca(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?, _ msg: String) -> JSValueRef? {
        var args: [JSValueRef?] = [texto(a.ctx, msg)]
        exc?.pointee = JSObjectMakeError(a.ctx, 1, &args, nil)
        return JSValueMakeUndefined(a.ctx)
    }

    static func poe(_ ctx: JSContextRef, _ o: JSObjectRef?, _ nome: String, _ v: JSValueRef?) {
        let n = JSStringCreateWithUTF8CString(nome)
        defer { JSStringRelease(n) }
        JSObjectSetProperty(ctx, o, n, v, JSPropertyAttributes(kJSPropertyAttributeNone), nil)
    }

    // MARK: - UTF-8

    /// `utf8Decode(bytes)` → string. As mesmas regras do decodificador JS de sempre (bootstrap.js).
    static func utf8Decode(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let b = bytes(a.ctx, a[0]) else { return lanca(a, exc, "utf8Decode: typed array esperado") }
        guard let base = b.baseAddress, b.count > 0 else { return texto(a.ctx, "") }
        if soASCII(base, b.count) {
            return texto(a.ctx, latin1: base, b.count)
        }
        let saida = UnsafeMutablePointer<UInt16>.allocate(capacity: b.count)
        defer { saida.deallocate() }
        let n = Utf8.decodifica(base.assumingMemoryBound(to: UInt8.self), b.count, em: saida)
        return texto(a.ctx, utf16: saida, n)
    }

    /// `utf8Encode(string)` → `Uint8Array`.
    static func utf8Encode(_ a: Argumentos, _: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        if let r = pelaCF(a.ctx, a[0], { cf, n, cap -> JSValueRef? in
            guard let p = malloc(max(cap, 1)) else { return nil }
            var usados: CFIndex = 0
            let convertidos = CFStringGetBytes(
                cf, CFRange(location: 0, length: n), CFStringBuiltInEncodings.UTF8.rawValue, 0, false,
                p.assumingMemoryBound(to: UInt8.self), cap, &usados
            )
            guard convertidos == n else {
                free(p); return nil
            }
            return uint8Array(a.ctx, tomando: realloc(p, max(usados, 1)) ?? p, usados)
        }) {
            return r
        }
        return comUTF16(a.ctx, a[0]) { u, n -> JSValueRef? in
            let total = u.map { Utf8.tamanho($0, n) } ?? 0
            guard let p = malloc(max(total, 1)) else { return nil }
            if let u {
                _ = Utf8.codifica(u, n, em: p.assumingMemoryBound(to: UInt8.self), capacidade: total)
            }
            return uint8Array(a.ctx, tomando: p, total)
        } ?? JSValueMakeUndefined(a.ctx)
    }

    /// `utf8EncodeInto(string, destino)` → `{ read, written }`, como `TextEncoder.encodeInto`:
    /// só escreve pontos de código inteiros.
    static func utf8EncodeInto(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        // A string primeiro, o ponteiro do destino depois (converter pode rodar JS).
        let r = comUTF16(a.ctx, a[0]) { u, n -> (Int, Int)? in
            guard let destino = bytes(a.ctx, a[1]) else { return nil }
            guard let u, let d = destino.baseAddress else { return (0, 0) }
            let alvo = UnsafeMutableRawPointer(mutating: d).assumingMemoryBound(to: UInt8.self)
            return Utf8.codifica(u, n, em: alvo, capacidade: destino.count)
        }
        guard let (lidos, escritos) = r ?? (0, 0) else { return lanca(a, exc, "encodeInto: Uint8Array esperado") }
        let o = JSObjectMake(a.ctx, nil, nil)
        poe(a.ctx, o, "read", JSValueMakeNumber(a.ctx, Double(lidos)))
        poe(a.ctx, o, "written", JSValueMakeNumber(a.ctx, Double(escritos)))
        return o
    }

    /// `utf8Length(string)` → quantos bytes `utf8Encode` produziria.
    static func utf8Length(_ a: Argumentos, _: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let pelaCF = pelaCF(a.ctx, a[0]) { cf, n, cap -> Int? in
            var usados: CFIndex = 0
            let convertidos = CFStringGetBytes(
                cf, CFRange(location: 0, length: n), CFStringBuiltInEncodings.UTF8.rawValue, 0, false, nil, cap, &usados
            )
            return convertidos == n ? usados : nil
        }
        let n = pelaCF ?? comUTF16(a.ctx, a[0]) { u, n in u.map { Utf8.tamanho($0, n) } ?? 0 } ?? 0
        return JSValueMakeNumber(a.ctx, Double(n))
    }

    /// Caminho rápido da codificação: o conversor UTF-8 do CoreFoundation, otimizado mesmo num
    /// build de Debug (onde o laço em Swift é ~10× mais lento; 5 MB caem de ~70 para ~6 ms). Com
    /// `lossByte` 0 ele nunca troca um caractere; num substituto solto ele para, `corpo` devolve
    /// nil e vale o laço de `Utf8.codifica`, que o codifica como o JS antigo. Só a partir de 256
    /// unidades: abaixo disso criar a CFString custa mais que o laço. `cap` é o pior caso (3 bytes
    /// por unidade).
    private static func pelaCF<R>(
        _ ctx: JSContextRef,
        _ v: JSValueRef?,
        _ corpo: (CFString, CFIndex, CFIndex) -> R?
    ) -> R? {
        guard let v, let s = JSValueToStringCopy(ctx, v, nil) else { return nil }
        defer { JSStringRelease(s) }
        let n = JSStringGetLength(s)
        guard n >= 256, let cf = JSStringCopyCFString(kCFAllocatorDefault, s),
              CFStringGetLength(cf) == n else { return nil }
        return corpo(cf, n, n * 3)
    }

    /// Todos os bytes abaixo de 0x80? Oito de cada vez.
    static func soASCII(_ p: UnsafeRawPointer, _ n: Int) -> Bool {
        var i = 0
        while i + 8 <= n {
            if p.loadUnaligned(fromByteOffset: i, as: UInt64.self) & 0x8080_8080_8080_8080 != 0 {
                return false
            }
            i += 8
        }
        while i < n {
            if p.load(fromByteOffset: i, as: UInt8.self) & 0x80 != 0 {
                return false
            }
            i += 1
        }
        return true
    }

    // MARK: - latin1 e UTF-16LE

    /// `latin1Decode(bytes)` → string, um caractere por byte.
    static func latin1Decode(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let b = bytes(a.ctx, a[0]) else { return lanca(a, exc, "latin1Decode: typed array esperado") }
        return texto(a.ctx, latin1: b.baseAddress, b.count)
    }

    /// `latin1Encode(string)` → `Uint8Array`, o byte baixo de cada caractere. Um par substituto
    /// vira um byte só (o do alto), como o `Uint8Array.from(str, …)` que isto substitui, que
    /// percorre a string por ponto de código.
    static func latin1Encode(_ a: Argumentos, _: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        comUTF16(a.ctx, a[0]) { u, n -> JSValueRef? in
            guard let p = malloc(max(n, 1))?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var k = 0
            if let u {
                var i = 0
                while i < n {
                    let c = u[i]
                    p[k] = UInt8(truncatingIfNeeded: c)
                    k += 1
                    let par = c >= 0xD800 && c < 0xDC00 && i + 1 < n && u[i + 1] >= 0xDC00 && u[i + 1] < 0xE000
                    i += par ? 2 : 1
                }
            }
            return uint8Array(a.ctx, tomando: UnsafeMutableRawPointer(p), k)
        } ?? JSValueMakeUndefined(a.ctx)
    }

    /// `utf16leDecode(bytes)` → string; um byte ímpar no fim é descartado.
    static func utf16leDecode(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let b = bytes(a.ctx, a[0]) else { return lanca(a, exc, "utf16leDecode: typed array esperado") }
        let n = b.count / 2
        guard n > 0, let base = b.baseAddress else { return texto(a.ctx, "") }
        let u = UnsafeMutablePointer<UInt16>.allocate(capacity: n)
        defer { u.deallocate() }
        for i in 0 ..< n {
            u[i] = UInt16(littleEndian: base.loadUnaligned(fromByteOffset: i * 2, as: UInt16.self))
        }
        return texto(a.ctx, utf16: u, n)
    }

    // MARK: - base64

    /// `b64Encode(bytes, url)` → string. Com `url`, alfabeto `-_` e sem `=`.
    static func b64Encode(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let b = bytes(a.ctx, a[0]) else { return lanca(a, exc, "b64Encode: typed array esperado") }
        let url = JSValueToBoolean(a.ctx, a[1])
        var saida = Base64.codifica(b)
        if url {
            Base64.paraURL(&saida)
        }
        return saida.withUnsafeBytes { texto(a.ctx, latin1: $0.baseAddress, $0.count) }
    }

    /// `b64Decode(string, url)` → `Uint8Array`. Ignora tudo fora do alfabeto (inclusive `=`).
    static func b64Decode(_ a: Argumentos, _: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let url = JSValueToBoolean(a.ctx, a[1])
        // Base64 canônico, o caso comum, vai pelo decodificador do Foundation, rápido mesmo num
        // build de Debug. Ele recusa o que foge do padrão (espaço, `=` no meio, sem padding), e
        // para isso vale o laço com as regras antigas; no que ele aceita, o resultado é o mesmo.
        if !url, let v = a[0], let s = JSValueToStringCopy(a.ctx, v, nil) {
            defer { JSStringRelease(s) }
            if let d = Data(base64Encoded: JSStringCopyCFString(kCFAllocatorDefault, s) as String) {
                return d.withUnsafeBytes { uint8Array(a.ctx, copiando: $0) }
            }
        }
        return comUTF16(a.ctx, a[0]) { u, n -> JSValueRef? in
            let cap = n / 4 * 3 + 3
            guard var p = malloc(cap) else { return nil }
            let k = u.map { Base64.decodifica($0, n, url: url, em: p.assumingMemoryBound(to: UInt8.self)) } ?? 0
            if cap - k > 65536, let menor = realloc(p, max(k, 1)) {
                p = menor
            }
            return uint8Array(a.ctx, tomando: p, k)
        } ?? JSValueMakeUndefined(a.ctx)
    }

    // MARK: - zlib, hash, aleatório

    /// `gzipBytes(bytes, comprimir)` → `Uint8Array` (vazio se falhar, como o `gzip` em base64).
    static func gzipBytes(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let b = bytes(a.ctx, a[0]) else { return lanca(a, exc, "gzipBytes: typed array esperado") }
        let dados = Data(b)
        let saida = (JSValueToBoolean(a.ctx, a[1]) ? Gzip.compress(dados) : Gzip.decompress(dados)) ?? Data()
        return saida.withUnsafeBytes { uint8Array(a.ctx, copiando: $0) }
    }

    /// `hashBytes(algoritmo, bytes)` → `Uint8Array` com o digest. Algoritmo que não existe
    /// lança, como no Node ("Digest method not supported"); antes caía no SHA-256 calado.
    static func hashBytes(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let algo = comUTF16(a.ctx, a[0]) { u, n in u.map { String(utf16CodeUnits: $0, count: n) } ?? "" } ?? ""
        guard let b = bytes(a.ctx, a[1]) else { return lanca(a, exc, "hashBytes: typed array esperado") }
        guard let digest = Hash.digest(algo: algo, data: b) else { return lanca(a, exc, "Digest method not supported") }
        return digest.withUnsafeBytes { uint8Array(a.ctx, copiando: $0) }
    }

    /// `hmacBytes(algoritmo, chave, bytes)` → `Uint8Array`.
    static func hmacBytes(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        let algo = comUTF16(a.ctx, a[0]) { u, n in u.map { String(utf16CodeUnits: $0, count: n) } ?? "" } ?? ""
        guard let k = bytes(a.ctx, a[1]) else { return lanca(a, exc, "hmacBytes: chave em typed array") }
        let chave = Data(k)
        guard let b = bytes(a.ctx, a[2]) else { return lanca(a, exc, "hmacBytes: typed array esperado") }
        guard let mac = Hash.hmac(algo: algo, chave: chave, data: b) else {
            return lanca(a, exc, "Invalid digest: \(algo)")
        }
        return mac.withUnsafeBytes { uint8Array(a.ctx, copiando: $0) }
    }

    /// `pbkdf2Bytes(senha, sal, iterações, tamanho, algoritmo)` → `Uint8Array`.
    static func pbkdf2Bytes(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let s = bytes(a.ctx, a[0]) else { return lanca(a, exc, "pbkdf2: senha em typed array") }
        let senha = Data(s)
        guard let sl = bytes(a.ctx, a[1]) else { return lanca(a, exc, "pbkdf2: sal em typed array") }
        let sal = Data(sl)
        let iteracoes = Int(JSValueToNumber(a.ctx, a[2], nil))
        let tamanho = Int(JSValueToNumber(a.ctx, a[3], nil))
        let algo = comUTF16(a.ctx, a[4]) { u, n in u.map { String(utf16CodeUnits: $0, count: n) } ?? "" } ?? ""
        guard let chave = Hash.pbkdf2(senha: senha, sal: sal, iteracoes: iteracoes, tamanho: tamanho, algo: algo) else {
            return lanca(a, exc, "Invalid digest: \(algo)")
        }
        return chave.withUnsafeBytes { uint8Array(a.ctx, copiando: $0) }
    }

    /// `randomFill(bytes)` → o próprio array, preenchido por `SecRandomCopyBytes`.
    static func randomFill(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let b = bytes(a.ctx, a[0]) else { return lanca(a, exc, "randomFill: typed array esperado") }
        if let p = b.baseAddress, b.count > 0 {
            _ = SecRandomCopyBytes(kSecRandomDefault, b.count, UnsafeMutableRawPointer(mutating: p))
        }
        return a[0]
    }

    // MARK: - módulos

    /// `compilar(fonte, arquivo)` → o valor do script avaliado com `arquivo` como origem.
    ///
    /// O loader avaliava cada módulo com `eval` e um `//# sourceURL=`, que o JSC ignora: todo
    /// quadro de pilha de código de módulo saía como "fn@", sem arquivo nem linha — o
    /// `err.stack`, o erro fatal e o `getFileName()` dos CallSites (o depd, dentro do express,
    /// procura o chamador por ele). `JSEvaluateScript` com a URL de origem dá arquivo e linha.
    /// Erro de sintaxe volta como exceção para o JS, sem passar pelo `exceptionHandler`.
    static func compilar(_ a: Argumentos, _ exc: UnsafeMutablePointer<JSValueRef?>?) -> JSValueRef? {
        guard let fonte = a[0], let js = JSValueToStringCopy(a.ctx, fonte, nil) else {
            return lanca(a, exc, "compilar: fonte esperada")
        }
        defer { JSStringRelease(js) }
        let origem = a[1].flatMap { JSValueToStringCopy(a.ctx, $0, nil) }
        defer { origem.map(JSStringRelease) }
        var erro: JSValueRef?
        let r = JSEvaluateScript(a.ctx, js, nil, origem, 1, &erro)
        if let erro {
            exc?.pointee = erro
            return JSValueMakeUndefined(a.ctx)
        }
        return r
    }

    // MARK: - blocos ObjC (http, fetch)

    /// Bytes de um valor vindo por um bloco ObjC: typed array/ArrayBuffer (copiado) ou, para
    /// quem ainda manda assim, string base64.
    static func dados(_ v: JSValue?) -> Data {
        guard let v, !v.isUndefined, !v.isNull else { return Data() }
        if v.isString {
            return Data(base64Encoded: v.toString() ?? "") ?? Data()
        }
        guard let ctx = v.context?.jsGlobalContextRef, let b = bytes(ctx, v.jsValueRef) else { return Data() }
        return Data(b)
    }

    /// Um `Uint8Array` com a cópia de `dados`, para passar como argumento de `JSRuntime.call`.
    static func valor(_ dados: Data, em context: JSContext) -> JSValue {
        let ref = dados.withUnsafeBytes { uint8Array(context.jsGlobalContextRef, copiando: $0) }
        return JSValue(jsValueRef: ref, in: context)
    }
}
