import Darwin
import Foundation
import OdeteCore
import OdeteI18n

/// Leitor e escritor tar (ustar + GNU longname + caminho de pax).
public enum Tar {
    public struct Entry: Sendable {
        public var path: String; public var data: Data; public var isDir: Bool; public var mode: Int; public var link: String?
    }

    /// Quanto a extração descomprime de cada vez. É tudo o que ela segura além do
    /// próprio `.tgz`: o `.tar` inteiro nunca existe na memória.
    static let tamanhoDoPedaco = 256 * 1024

    // MARK: leitura aos pedaços

    /// O que o leitor encontra no fluxo, na ordem em que aparece.
    enum Evento {
        case pasta(caminho: String, modo: Int)
        case link(caminho: String, destino: String, modo: Int)
        case inicioDeArquivo(caminho: String, modo: Int, tamanho: Int)
        case dados(UnsafeRawBufferPointer)
        case fimDeArquivo
    }

    /// Lê um tar que chega aos pedaços, sem precisar dele inteiro.
    ///
    /// O arquivo é uma sequência de blocos de 512 bytes: cabeçalho, corpo arredondado
    /// para o bloco, cabeçalho... O leitor guarda só o cabeçalho em montagem e, para os
    /// cabeçalhos especiais, o corpo deles (nome longo do GNU, atributos do pax), que são
    /// pequenos. O corpo de arquivo passa direto para quem escuta.
    struct Leitor {
        private enum Estado {
            case cabecalho
            /// Corpo de arquivo comum: vai para fora em `dados`.
            case corpo(restam: Int, sobra: Int)
            /// Corpo de cabeçalho especial: fica aqui até terminar.
            case especial(tipo: UInt8, restam: Int, sobra: Int)
            case pulo(restam: Int)
            case fim
        }

        private var estado = Estado.cabecalho
        private var bloco: [UInt8] = []
        private var especial: [UInt8] = []
        private var nomeLongo: String?
        private var destinoLongo: String?
        private var caminhoPax: String?
        private var destinoPax: String?

        /// Teto para corpo de cabeçalho especial: nome de arquivo não passa disso, e um
        /// tarball malformado não pode fazer o leitor guardar o arquivo inteiro.
        static let tetoEspecial = 1 << 20

        mutating func consumir(_ entrada: UnsafeRawBufferPointer, _ ouvir: (Evento) throws -> Void) throws {
            var i = 0
            while i < entrada.count {
                switch estado {
                case .fim:
                    return
                case .cabecalho:
                    let n = min(512 - bloco.count, entrada.count - i)
                    bloco.append(contentsOf: entrada[i ..< i + n])
                    i += n
                    if bloco.count == 512 {
                        try fecharCabecalho(ouvir)
                        bloco.removeAll(keepingCapacity: true)
                    }
                case let .corpo(restam, sobra):
                    let n = min(restam, entrada.count - i)
                    try ouvir(.dados(UnsafeRawBufferPointer(rebasing: entrada[i ..< i + n])))
                    i += n
                    if restam - n == 0 {
                        try ouvir(.fimDeArquivo)
                        estado = sobra > 0 ? .pulo(restam: sobra) : .cabecalho
                    } else {
                        estado = .corpo(restam: restam - n, sobra: sobra)
                    }
                case let .especial(tipo, restam, sobra):
                    let n = min(restam, entrada.count - i)
                    especial.append(contentsOf: entrada[i ..< i + n])
                    i += n
                    if restam - n == 0 {
                        guardarEspecial(tipo)
                        estado = sobra > 0 ? .pulo(restam: sobra) : .cabecalho
                    } else {
                        estado = .especial(tipo: tipo, restam: restam - n, sobra: sobra)
                    }
                case let .pulo(restam):
                    let n = min(restam, entrada.count - i)
                    i += n
                    estado = restam - n == 0 ? .cabecalho : .pulo(restam: restam - n)
                }
            }
        }

        /// Um arquivo que acaba no meio de um corpo está truncado. Acabar no meio do
        /// enchimento, de algo que seria pulado ou de um cabeçalho não perde nada — o
        /// leitor de antes também parava ali sem reclamar —, e passa.
        var terminouInteiro: Bool {
            switch estado {
            case .cabecalho, .fim, .pulo: true
            case .corpo, .especial: false
            }
        }

        private mutating func fecharCabecalho(_ ouvir: (Evento) throws -> Void) throws {
            if bloco.allSatisfy({ $0 == 0 }) {
                estado = .fim
                return
            }
            func str(_ r: Range<Int>) -> String {
                String(decoding: bloco[r].prefix { $0 != 0 }, as: UTF8.self)
            }
            func oct(_ r: Range<Int>) -> Int {
                Int(str(r).trimmingCharacters(in: .whitespaces), radix: 8) ?? 0
            }
            let tamanho = oct(124 ..< 136)
            let tipo = bloco[156]
            let sobra = (512 - tamanho % 512) % 512
            // Cabeçalhos que só descrevem o próximo: o corpo deles fica aqui dentro.
            if tipo == UInt8(ascii: "L") || tipo == UInt8(ascii: "K") || tipo == UInt8(ascii: "x") {
                guard tamanho <= Self.tetoEspecial else { throw NpmError.tarball(tr("tar inválido")) }
                especial.removeAll(keepingCapacity: true)
                estado = tamanho > 0 ? .especial(tipo: tipo, restam: tamanho, sobra: sobra) : .cabecalho
                return
            }
            var nome = str(0 ..< 100)
            let prefixo = str(345 ..< 500)
            if !prefixo.isEmpty {
                nome = prefixo + "/" + nome
            }
            if let longo = caminhoPax ?? nomeLongo {
                nome = longo
            }
            let destino = destinoPax ?? destinoLongo ?? str(157 ..< 257)
            nomeLongo = nil; destinoLongo = nil; caminhoPax = nil; destinoPax = nil
            let modo = oct(100 ..< 108)
            switch tipo {
            case UInt8(ascii: "5"):
                try ouvir(.pasta(caminho: nome, modo: modo))
            case UInt8(ascii: "0"), 0, UInt8(ascii: "7"):
                try ouvir(.inicioDeArquivo(caminho: nome, modo: modo, tamanho: tamanho))
                if tamanho == 0 {
                    try ouvir(.fimDeArquivo)
                } else {
                    estado = .corpo(restam: tamanho, sobra: sobra)
                    return
                }
            case UInt8(ascii: "2"):
                try ouvir(.link(caminho: nome, destino: destino, modo: modo))
            default:
                // Link físico, pax global, dispositivos: nada disso vira arquivo de pacote.
                break
            }
            let pular = tamanho + sobra
            estado = pular > 0 ? .pulo(restam: pular) : .cabecalho
        }

        private mutating func guardarEspecial(_ tipo: UInt8) {
            switch tipo {
            case UInt8(ascii: "L"): nomeLongo = String(decoding: especial.prefix { $0 != 0 }, as: UTF8.self)
            case UInt8(ascii: "K"): destinoLongo = String(decoding: especial.prefix { $0 != 0 }, as: UTF8.self)
            default:
                // Registros "<tamanho> <chave>=<valor>\n". Só o caminho e o destino de
                // link interessam: é por eles que o pax guarda nome comprido.
                for registro in String(decoding: especial, as: UTF8.self).split(separator: "\n") {
                    guard let espaco = registro.firstIndex(of: " "),
                          let igual = registro[espaco...].firstIndex(of: "=") else { continue }
                    let chave = registro[registro.index(after: espaco) ..< igual]
                    let valor = String(registro[registro.index(after: igual)...])
                    if chave == "path" {
                        caminhoPax = valor
                    } else if chave == "linkpath" {
                        destinoPax = valor
                    }
                }
            }
            especial.removeAll(keepingCapacity: true)
        }
    }

    // MARK: API

    public static func read(_ data: Data) throws -> [Entry] {
        var out: [Entry] = []
        var leitor = Leitor()
        var corpo = Data()
        var atual: (caminho: String, modo: Int)?
        try data.withUnsafeBytes { bytes in
            try leitor.consumir(bytes) { evento in
                switch evento {
                case let .pasta(caminho, modo):
                    out.append(Entry(path: caminho, data: Data(), isDir: true, mode: modo, link: nil))
                case let .link(caminho, destino, modo):
                    out.append(Entry(path: caminho, data: Data(), isDir: false, mode: modo, link: destino))
                case let .inicioDeArquivo(caminho, modo, tamanho):
                    atual = (caminho, modo)
                    corpo = Data(capacity: tamanho)
                case let .dados(pedaco):
                    corpo.append(pedaco.assumingMemoryBound(to: UInt8.self))
                case .fimDeArquivo:
                    if let a = atual {
                        out.append(Entry(path: a.caminho, data: corpo, isDir: false, mode: a.modo, link: nil))
                    }
                    atual = nil
                    corpo = Data()
                }
            }
        }
        return out
    }

    public static func write(_ entries: [Entry]) -> Data {
        var out = Data()
        for e in entries {
            var name = e.path
            if name.utf8.count > 99 {
                let l = Data(name.utf8) + [0]
                out.append(header(name: "././@LongLink", size: l.count, type: UInt8(ascii: "L"), mode: 0o644))
                out.append(padded(l))
            }
            name = String(name.utf8.prefix(99))!
            if let link = e.link {
                out.append(header(name: name, size: 0, type: UInt8(ascii: "2"), mode: e.mode, link: link))
                continue
            }
            out.append(header(
                name: name,
                size: e.isDir ? 0 : e.data.count,
                type: e.isDir ? UInt8(ascii: "5") : UInt8(ascii: "0"),
                mode: e.mode
            ))
            if !e.isDir {
                out.append(padded(e.data))
            }
        }
        out.append(Data(count: 1024))
        return out
    }

    static func padded(_ d: Data) -> Data {
        d + Data(count: (512 - d.count % 512) % 512)
    }

    static func header(name: String, size: Int, type: UInt8, mode: Int, link: String = "") -> Data {
        var h = Data(count: 512)
        func put(_ s: String, at: Int, len: Int) {
            let b = Array(s.utf8.prefix(len)); h.replaceSubrange(
                at ..< at + b.count,
                with: b
            )
        }
        put(name, at: 0, len: 100)
        put(String(format: "%07o", mode), at: 100, len: 8)
        put("0000000", at: 108, len: 8); put("0000000", at: 116, len: 8)
        put(String(format: "%011o", size), at: 124, len: 12)
        put(String(format: "%011o", Int(Date().timeIntervalSince1970)), at: 136, len: 12)
        put("        ", at: 148, len: 8)
        h[156] = type
        put(link, at: 157, len: 100)
        put("ustar", at: 257, len: 6); put("00", at: 263, len: 2)
        let sum = h.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o", sum) + "\0 ", at: 148, len: 8)
        return h
    }

    /// Extrai um `.tgz` de pacote npm (prefixo `package/` removido) em `dir`.
    ///
    /// Descomprime aos pedaços e escreve cada arquivo direto no disco enquanto o corpo
    /// chega. Antes, o `.tar` inteiro era montado na memória, copiado mais uma vez para
    /// ser lido e cada arquivo ganhava a própria cópia antes de ser gravado — umas três
    /// vezes o pacote descompactado, e o `next` passa de cem megas descompactado.
    public static func extractPackage(_ tgz: Data, to dir: URL) throws {
        var gravador = Gravador(raiz: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var leitor = Leitor()
        let ok: Bool
        do {
            ok = try GzipCodec.descomprimir(tgz, pedaco: tamanhoDoPedaco) { pedaco in
                try leitor.consumir(pedaco) { try gravador.receber($0) }
            }
        } catch {
            gravador.fechar()
            throw error
        }
        gravador.fechar()
        guard ok else { throw NpmError.tarball(tr("gzip inválido")) }
        guard leitor.terminouInteiro else { throw NpmError.tarball(tr("tar inválido")) }
        gravador.criarLinks()
    }

    /// O package.json de um `.tgz` (o da pasta de cima, seja ela `package/` ou a
    /// `repo-<commit>/` do GitHub), sem extrair nada. É o que diz nome, versão e
    /// dependências de um pacote que veio por URL.
    public static func manifesto(_ tgz: Data) throws -> Data? {
        struct Achou: Error {}
        var leitor = Leitor()
        var achado: Data?
        var lendo = false
        do {
            let ok = try GzipCodec.descomprimir(tgz, pedaco: tamanhoDoPedaco) { pedaco in
                try leitor.consumir(pedaco) { evento in
                    switch evento {
                    case let .inicioDeArquivo(caminho, _, tamanho):
                        lendo = Gravador.relativo(caminho) == "package.json"
                        if lendo {
                            achado = Data(capacity: tamanho)
                        }
                    case let .dados(p):
                        if lendo {
                            achado?.append(p.assumingMemoryBound(to: UInt8.self))
                        }
                    case .fimDeArquivo:
                        if lendo {
                            throw Achou()
                        }
                    default:
                        break
                    }
                }
            }
            guard ok else { throw NpmError.tarball(tr("gzip inválido")) }
        } catch is Achou {
            return achado
        }
        return nil
    }

    /// Recebe os eventos do leitor e grava no disco, arquivo por arquivo.
    ///
    /// As regras de caminho são as de sempre: tira o primeiro componente (`package/`),
    /// ignora o que não tem componente depois dele e qualquer coisa com `..`. Pasta já
    /// criada não é criada de novo — num pacote com milhares de arquivos, são milhares de
    /// chamadas ao sistema a menos.
    struct Gravador {
        let raiz: URL
        private var criadas: Set<String> = []
        private var aberto: Int32 = -1
        private var executavel = false
        private var caminhoAberto = ""
        /// Links do pacote, criados só depois de todos os arquivos.
        private var links: [(caminho: String, destino: String)] = []

        init(raiz: URL) {
            self.raiz = raiz
        }

        /// O destino, lido a partir da pasta do link, continua dentro do pacote? Absoluto
        /// nunca: `/etc/passwd` dentro de um pacote não é coisa de pacote.
        static func destinoFicaDentro(_ rel: String, _ destino: String) -> Bool {
            guard !destino.isEmpty, !destino.hasPrefix("/") else { return false }
            var pilha = rel.split(separator: "/").dropLast().map(String.init)
            for parte in destino.split(separator: "/") {
                switch parte {
                case ".": continue
                case "..":
                    guard !pilha.isEmpty else { return false }
                    pilha.removeLast()
                default: pilha.append(String(parte))
                }
            }
            return true
        }

        /// Cria os links e confere cada um pelo caminho real: uma corrente de links que
        /// individualmente ficam dentro (`a -> b/..`, `b -> ..`) ainda pode sair. O que
        /// sai do pacote, ou não leva a lugar nenhum, é apagado.
        func criarLinks() {
            let fm = FileManager.default
            let base = raiz.resolvingSymlinksInPath().standardizedFileURL.path
            for (rel, destino) in links {
                let dest = raiz.appending(path: rel)
                try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dest)
                try? fm.createSymbolicLink(atPath: dest.path, withDestinationPath: destino)
            }
            for (rel, _) in links {
                let dest = raiz.appending(path: rel)
                guard let real = realpath(dest.path, nil) else {
                    try? fm.removeItem(at: dest)
                    continue
                }
                let caminho = String(cString: real)
                free(real)
                if caminho != base, !caminho.hasPrefix(base + "/") {
                    try? fm.removeItem(at: dest)
                }
            }
        }

        static func relativo(_ caminho: String) -> String? {
            guard let i = caminho.firstIndex(of: "/") else { return nil }
            let rel = String(caminho[caminho.index(after: i)...])
            guard !rel.isEmpty, !rel.contains("..") else { return nil }
            return rel
        }

        private mutating func criarPasta(_ url: URL) throws {
            let p = url.path
            guard !criadas.contains(p) else { return }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            criadas.insert(p)
        }

        mutating func receber(_ evento: Evento) throws {
            switch evento {
            case let .pasta(caminho, _):
                guard let rel = Self.relativo(caminho) else { return }
                try criarPasta(raiz.appending(path: rel))
            case let .link(caminho, destino, _):
                // O link só nasce no fim (`criarLinks`): criado aqui, um arquivo que viesse
                // depois com o caminho atravessando esse link seria escrito onde o link
                // aponta — `lib -> ../../..` seguido de `lib/x.js` escrevia fora do pacote.
                guard let rel = Self.relativo(caminho), Self.destinoFicaDentro(rel, destino) else { return }
                links.append((rel, destino))
            case let .inicioDeArquivo(caminho, modo, _):
                guard let rel = Self.relativo(caminho) else { return }
                let dest = raiz.appending(path: rel)
                try criarPasta(dest.deletingLastPathComponent())
                caminhoAberto = dest.path
                executavel = modo & 0o111 != 0
                // Sem seguir link: se o próprio pacote pôs um link com esse nome antes, o
                // arquivo toma o lugar dele, como fazia a gravação atômica de antes — e
                // não escreve no que o link aponta.
                let flags = O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC
                var fd = open(caminhoAberto, flags, 0o666)
                if fd < 0, errno == ELOOP {
                    unlink(caminhoAberto)
                    fd = open(caminhoAberto, flags, 0o666)
                }
                guard fd >= 0 else { throw Self.erro(caminhoAberto) }
                aberto = fd
            case let .dados(pedaco):
                guard aberto >= 0, var p = pedaco.baseAddress else { return }
                var resta = pedaco.count
                while resta > 0 {
                    let n = Darwin.write(aberto, p, resta)
                    if n < 0 {
                        if errno == EINTR {
                            continue
                        }
                        throw Self.erro(caminhoAberto)
                    }
                    resta -= n
                    p += n
                }
            case .fimDeArquivo:
                guard aberto >= 0 else { return }
                if executavel {
                    fchmod(aberto, 0o755)
                }
                let fd = aberto
                aberto = -1
                guard close(fd) == 0 else { throw Self.erro(caminhoAberto) }
            }
        }

        /// Arquivo que ficou aberto porque a extração parou no meio.
        mutating func fechar() {
            if aberto >= 0 {
                close(aberto)
                aberto = -1
            }
        }

        static func erro(_ caminho: String) -> NpmError {
            NpmError.io("\(caminho): \(String(cString: strerror(errno)))")
        }
    }
}
