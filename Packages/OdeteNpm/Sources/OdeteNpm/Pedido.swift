import Foundation

/// O que um `"nome": "<spec>"` do package.json pede, como o `npm-package-arg` separa.
///
/// Antes a resolução só entendia faixa do registro: `npm:` buscava o packument pelo
/// nome do alias (o `string-width-cjs` do `@isaacs/cliui` não existe no registro, e o
/// glob@10, o rimraf 5 e o tailwind 3 não instalavam), e URL, GitHub, `file:` e
/// `workspace:` viravam "ignorado" com saída 0 — a dependência faltava calada.
public enum Pedido: Equatable, Sendable {
    /// Do registro. `nome` é o do pacote de verdade (num alias, o de depois do `npm:`).
    case registro(nome: String, faixa: String)
    /// Tarball por URL.
    case tarball(url: String)
    /// Repositório do GitHub, baixado pelo codeload (não há git para clonar).
    case github(dono: String, repo: String, ref: String?)
    /// Pasta local (`file:`, `link:`, caminho relativo): vira atalho, como no npm.
    case pasta(caminho: String)
    /// `.tgz` local.
    case arquivo(caminho: String)
    /// `workspace:*`, `workspace:^1.0.0` (pnpm, yarn): o pacote do workspace com esse nome.
    case workspace(faixa: String)
    /// Git em outro lugar (GitLab, Bitbucket, servidor próprio): sem git no iPad, não dá.
    case git(url: String)

    public static func de(_ spec: String) -> Pedido {
        let s = spec.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("npm:") {
            let resto = String(s.dropFirst(4))
            let (nome, faixa) = separarNomeEFaixa(resto)
            return .registro(nome: nome, faixa: faixa.isEmpty ? "latest" : faixa)
        }
        if s.hasPrefix("workspace:") {
            return .workspace(faixa: String(s.dropFirst("workspace:".count)))
        }
        if s.hasPrefix("file:") || s.hasPrefix("link:") {
            let caminho = String(s.dropFirst(5)).replacingOccurrences(of: "^//", with: "", options: .regularExpression)
            return ehArquivoTar(caminho) ? .arquivo(caminho: caminho) : .pasta(caminho: caminho)
        }
        if s.hasPrefix("./") || s.hasPrefix("../") || s.hasPrefix("/") || s.hasPrefix("~/") || s == "." || s == ".." {
            return ehArquivoTar(s) ? .arquivo(caminho: s) : .pasta(caminho: s)
        }
        if s.hasPrefix("http://") || s.hasPrefix("https://"), ehArquivoTar(s) {
            return .tarball(url: s)
        }
        if let gh = github(s) {
            return gh
        }
        if s.hasPrefix("git+") || s.hasPrefix("git://") || s.hasPrefix("git@") || s.hasPrefix("ssh://") {
            return .git(url: s)
        }
        if s.hasPrefix("http://") || s.hasPrefix("https://") {
            return .tarball(url: s)
        }
        return .registro(nome: "", faixa: s.isEmpty ? "latest" : s)
    }

    static func ehArquivoTar(_ s: String) -> Bool {
        s.hasSuffix(".tgz") || s.hasSuffix(".tar.gz") || s.hasSuffix(".tar")
    }

    /// `nome@faixa`, com escopo (`@a/b@1`).
    static func separarNomeEFaixa(_ s: String) -> (String, String) {
        let inicio = s.hasPrefix("@") ? s.index(after: s.startIndex) : s.startIndex
        if let at = s[inicio...].firstIndex(of: "@") {
            return (String(s[..<at]), String(s[s.index(after: at)...]))
        }
        return (s, "")
    }

    /// As formas de GitHub que o npm aceita: `github:dono/repo`, o atalho `dono/repo`,
    /// `git+https://github.com/…`, `git://github.com/…`, `git+ssh://git@github.com/…`,
    /// `git@github.com:…` e `https://github.com/dono/repo` — com ou sem `#ref`.
    static func github(_ s: String) -> Pedido? {
        var corpo = s
        var ref: String?
        if let h = corpo.firstIndex(of: "#") {
            ref = String(corpo[corpo.index(after: h)...])
            corpo = String(corpo[..<h])
        }
        // `#semver:^1.2` pede uma tag por faixa: sem git, fica o que o nome da tag diz.
        if let r = ref, r.hasPrefix("semver:") {
            ref = String(r.dropFirst("semver:".count)).trimmingCharacters(in: CharacterSet(charactersIn: "^~=v"))
        }
        if ref?.isEmpty == true {
            ref = nil
        }
        var caminho: String?
        if corpo.hasPrefix("github:") {
            caminho = String(corpo.dropFirst("github:".count))
        } else {
            for prefixo in [
                "git+https://github.com/", "git+http://github.com/", "git://github.com/", "https://github.com/",
                "http://github.com/", "git+ssh://git@github.com/", "ssh://git@github.com/", "git@github.com:",
                "git+ssh://git@github.com:",
            ] where corpo.hasPrefix(prefixo) {
                caminho = String(corpo.dropFirst(prefixo.count))
                break
            }
        }
        if caminho == nil {
            // Atalho `dono/repo`: uma barra só, sem protocolo, sem escopo e sem ponto na frente.
            let partes = corpo.split(separator: "/", omittingEmptySubsequences: false)
            if partes.count == 2, !corpo.hasPrefix("@"), !corpo.hasPrefix("."), !corpo.contains(":"),
               !corpo.contains(" "), partes.allSatisfy({ !$0.isEmpty })
            {
                caminho = corpo
            }
        }
        guard var c = caminho else { return nil }
        if c.hasSuffix(".git") {
            c = String(c.dropLast(4))
        }
        let partes = c.split(separator: "/")
        guard partes.count >= 2 else { return nil }
        return .github(dono: String(partes[0]), repo: String(partes[1]), ref: ref)
    }

    /// Faixa do registro, se for do registro.
    public var faixaDoRegistro: String? {
        if case let .registro(_, f) = self {
            return f
        }
        return nil
    }

    /// Como o lock do npm escreve a origem de um pacote do GitHub.
    public static func resolvidoDoGithub(dono: String, repo: String, ref: String?) -> String {
        "git+ssh://git@github.com/\(dono)/\(repo).git" + (ref.map { "#\($0)" } ?? "")
    }

    /// De onde baixar o `.tar.gz` de um `resolved` do lock que aponta para o GitHub
    /// (escrito pela Odete ou pelo npm, com o commit depois do `#`). `nil` se não for.
    public static func codeload(deResolvido r: String) -> String? {
        guard !ehArquivoTar(r), case let .github(dono, repo, ref) = github(r) ?? .git(url: "") else { return nil }
        return "https://codeload.github.com/\(dono)/\(repo)/tar.gz/\(ref ?? "HEAD")"
    }
}
