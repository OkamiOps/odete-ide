import Foundation

/// Até onde um processo (ou o shell) pode mexer no disco: a pasta do projeto e, para o
/// runtime, a pasta temporária do app.
///
/// O shell e o `fs` do runtime resolviam caminhos sem conferir nada: `rm -rf ../Outro`
/// apagou outro projeto, `cd ../proj2` saía da raiz (o prefixo era comparado sem a `/`, e
/// `proj2` começa com `proj`), e `fs.renameSync` num caminho qualquer do iPad passava. Aqui
/// o caminho é resolvido como o kernel resolveria — `..` e links simbólicos, inclusive link
/// quebrado, que no `open(O_CREAT)` criaria o alvo lá fora — e só vale se cair em
/// `raiz` ou abaixo de `raiz + "/"`.
public struct Confinamento: Sendable {
    /// As raízes permitidas, já resolvidas (caminho real, sem `/` no fim).
    public let raizes: [String]

    public init(raiz: URL, extras: [URL] = []) {
        raizes = ([raiz] + extras).map { Self.real($0.path) }
    }

    /// O caminho resolvido cai numa das raízes? `seguirUltimo: false` é para quem mexe na
    /// entrada em si (apagar, renomear, `lstat`, `readlink`): um link dentro do projeto que
    /// aponta para fora pode ser apagado, só não pode ser seguido.
    public func permite(_ caminho: String, seguirUltimo: Bool = true) -> Bool {
        let r = Self.real(caminho, seguirUltimo: seguirUltimo)
        return raizes.contains { Self.contem($0, r) }
    }

    /// `r` é `raiz` ou está abaixo dela. A `/` no fim é o que separa `proj` de `proj2`.
    public static func contem(_ raiz: String, _ r: String) -> Bool {
        raiz == "/" || r == raiz || r.hasPrefix(raiz + "/")
    }

    /// `..`, `.` e barras repetidas resolvidos só no texto, como o `path.normalize` do Node.
    /// Caminho relativo fica relativo; acima da raiz `/` não há nada.
    public static func normalizar(_ caminho: String) -> String {
        let absoluto = caminho.hasPrefix("/")
        var pilha: [Substring] = []
        for parte in caminho.split(separator: "/", omittingEmptySubsequences: true) {
            if parte == "." {
                continue
            }
            if parte == ".." {
                if let ultimo = pilha.last, ultimo != ".." {
                    pilha.removeLast()
                } else if !absoluto {
                    pilha.append(parte)
                }
                continue
            }
            pilha.append(parte)
        }
        let corpo = pilha.joined(separator: "/")
        return absoluto ? "/" + corpo : (corpo.isEmpty ? "." : corpo)
    }

    /// O caminho real: o `realpath(3)` quando tudo existe (uma chamada só, o caso comum) e,
    /// quando não, componente a componente, seguindo links — um link quebrado vira o alvo
    /// dele, que é onde a escrita iria parar. Com `seguirUltimo: false` o último componente
    /// não é seguido.
    public static func real(_ caminho: String, seguirUltimo: Bool = true) -> String {
        let n = normalizar(caminho.hasPrefix("/") ? caminho : FileManager.default.currentDirectoryPath + "/" + caminho)
        if n == "/" {
            return n
        }
        if !seguirUltimo {
            let pai = (n as NSString).deletingLastPathComponent
            let nome = (n as NSString).lastPathComponent
            let rp = real(pai)
            return rp == "/" ? "/" + nome : rp + "/" + nome
        }
        if let r = realpathC(n) {
            return r
        }
        return resolverAMao(n)
    }

    static func realpathC(_ caminho: String) -> String? {
        guard let p = realpath(caminho, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Resolução componente a componente, com limite de links (como o ELOOP do kernel).
    private static func resolverAMao(_ caminho: String) -> String {
        var pendentes = caminho.split(separator: "/").map(String.init).reversed() as [String]
        var atual = ""
        var links = 0
        while let comp = pendentes.popLast() {
            if comp == "." || comp.isEmpty {
                continue
            }
            if comp == ".." {
                atual = (atual as NSString).deletingLastPathComponent
                if atual == "/" {
                    atual = ""
                }
                continue
            }
            let proximo = atual + "/" + comp
            var st = stat()
            guard lstat(proximo, &st) == 0 else {
                // Não existe: o resto é só texto.
                atual = proximo
                for c in pendentes.reversed() {
                    atual = normalizar(atual + "/" + c)
                }
                return atual.isEmpty ? "/" : atual
            }
            if (st.st_mode & S_IFMT) == S_IFLNK, links < 40 {
                links += 1
                var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = readlink(proximo, &buf, buf.count - 1)
                guard n >= 0 else {
                    atual = proximo; continue
                }
                buf[n] = 0
                let alvo = String(cString: buf)
                let partes = alvo.split(separator: "/").map(String.init)
                if alvo.hasPrefix("/") {
                    atual = ""
                }
                pendentes.append(contentsOf: partes.reversed())
                continue
            }
            atual = proximo
        }
        return atual.isEmpty ? "/" : atual
    }
}
