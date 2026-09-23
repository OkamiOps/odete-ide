import Foundation

/// `import(x)` em código que não passa pelo esbuild vira `__odete_import(x)`.
///
/// O JSC só resolve `import()` com um carregador de módulos que um JSContext não tem: num
/// script avaliado ele rejeita sem dizer nada útil, e o `prettier` (bin) e o `eslint`, que
/// carregam a configuração assim, morriam calados. Código ESM/TS vem do esbuild já sem
/// `import()`; o que sobra é CJS carregado cru e corpo de `new Function`.
///
/// A troca precisa de um analisador léxico de verdade — o `typescript.js` tem `import(` em
/// strings de mensagem e em código que ele gera, e mexer nelas mudaria a saída do `tsc`. Este
/// reconhece comentários, strings, templates (com `${}` aninhado) e regex (pelo token
/// anterior, como os minificadores fazem); fora disso, `import` como palavra solta seguida de
/// `(` é a chamada. Continua de fora: `obj.import(`, e o método `import(a) { … }`.
enum ReescritaDeImport {
    static let nome = Array("__odete_import".utf8)

    /// O código com as chamadas trocadas, ou nil se não havia nenhuma.
    static func reescrever(_ fonte: String) -> String? {
        var fonte = fonte
        return fonte.withUTF8 { u -> String? in
            guard temCandidato(u) else { return nil }
            let posicoes = achar(u)
            guard !posicoes.isEmpty else { return nil }
            var saida = [UInt8]()
            saida.reserveCapacity(u.count + posicoes.count * 8)
            var inicio = 0
            for p in posicoes {
                saida.append(contentsOf: u[inicio ..< p])
                saida.append(contentsOf: nome)
                inicio = p + 6 // "import"
            }
            saida.append(contentsOf: u[inicio...])
            return String(decoding: saida, as: UTF8.self)
        }
    }

    /// Filtro barato antes do analisador: há `import` seguido (talvez de espaço) de `(`?
    private static func temCandidato(_ u: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = u.count
        var i = 0
        while i + 6 < n {
            if u[i] == 0x69, u[i + 1] == 0x6D, u[i + 2] == 0x70, u[i + 3] == 0x6F, u[i + 4] == 0x72, u[i + 5] == 0x74 {
                var j = i + 6
                while j < n, u[j] == 0x20 || u[j] == 0x09 || u[j] == 0x0A || u[j] == 0x0D {
                    j += 1
                }
                if j < n, u[j] == 0x28 {
                    return true
                }
            }
            i += 1
        }
        return false
    }

    private static func ehIdent(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x24
            || c >= 0x80
    }

    /// Palavras depois das quais `/` começa uma regex, não uma divisão.
    private static let antesDeRegex: [[UInt8]] = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case", "do", "else",
        "yield", "await",
    ].map { Array($0.utf8) }

    /// Compara os bytes de `u[a..<b]` com uma palavra, sem criar String (o typescript.js tem
    /// um milhão de identificadores).
    private static func igual(_ u: UnsafeBufferPointer<UInt8>, _ a: Int, _ b: Int, _ p: [UInt8]) -> Bool {
        guard b - a == p.count else { return false }
        for k in 0 ..< p.count where u[a + k] != p[k] {
            return false
        }
        return true
    }

    private static let palavraImport = Array("import".utf8)

    /// Onde começa cada `import` que é chamada.
    static func achar(_ u: UnsafeBufferPointer<UInt8>) -> [Int] {
        let n = u.count
        var i = 0
        var achados: [Int] = []
        // O que veio antes, para decidir regex × divisão e `.import`.
        enum Anterior { case nada, palavraDeRegex, ponto, valor, abre }
        var anterior = Anterior.nada
        // Pilha de templates: cada nível guarda quantas chaves abertas há na expressão `${}`.
        var templates: [Int] = []

        func pularString(_ aspa: UInt8) {
            i += 1
            while i < n {
                let c = u[i]
                if c == 0x5C {
                    i += 2; continue
                }
                if c == aspa || c == 0x0A {
                    i += 1; return
                }
                i += 1
            }
        }
        /// Anda pelo texto do template até o fim dele ou até um `${`. Devolve true se parou num `${`.
        func pularTemplate() -> Bool {
            while i < n {
                let c = u[i]
                if c == 0x5C {
                    i += 2; continue
                }
                if c == 0x60 {
                    i += 1; return false
                }
                if c == 0x24, i + 1 < n, u[i + 1] == 0x7B {
                    i += 2; return true
                }
                i += 1
            }
            return false
        }
        func pularRegex() {
            i += 1
            var classe = false
            while i < n {
                let c = u[i]
                if c == 0x5C {
                    i += 2; continue
                }
                if c == 0x0A {
                    return
                }
                if classe {
                    if c == 0x5D {
                        classe = false
                    }
                } else if c == 0x5B {
                    classe = true
                } else if c == 0x2F {
                    i += 1
                    while i < n, ehIdent(u[i]) {
                        i += 1
                    }
                    return
                }
                i += 1
            }
        }
        /// Depois de `(` na posição `a`, o `)` que fecha e o próximo caractere que conta.
        func depoisDoParenteses(_ a: Int) -> UInt8? {
            var j = a + 1
            var nivel = 1
            while j < n, nivel > 0 {
                let c = u[j]
                if c == 0x22 || c == 0x27 || c == 0x60 {
                    let aspa = c
                    j += 1
                    while j < n, u[j] != aspa {
                        j += u[j] == 0x5C ? 2 : 1
                    }
                } else if c == 0x28 {
                    nivel += 1
                } else if c == 0x29 {
                    nivel -= 1
                }
                j += 1
            }
            while j < n, u[j] == 0x20 || u[j] == 0x09 || u[j] == 0x0A || u[j] == 0x0D {
                j += 1
            }
            return j < n ? u[j] : nil
        }

        while i < n {
            let c = u[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i += 1
            case 0x2F: // /
                if i + 1 < n, u[i + 1] == 0x2F {
                    while i < n, u[i] != 0x0A {
                        i += 1
                    }
                } else if i + 1 < n, u[i + 1] == 0x2A {
                    i += 2
                    while i + 1 < n, !(u[i] == 0x2A && u[i + 1] == 0x2F) {
                        i += 1
                    }
                    i += 2
                } else {
                    let regex: Bool = switch anterior {
                    case .valor: false
                    default: true
                    }
                    if regex {
                        pularRegex()
                        anterior = .valor
                    } else {
                        i += 1
                        anterior = .abre
                    }
                }
            case 0x22, 0x27:
                pularString(c)
                anterior = .valor
            case 0x60:
                i += 1
                if pularTemplate() {
                    templates.append(0)
                    anterior = .abre
                } else {
                    anterior = .valor
                }
            case 0x7B: // {
                if !templates.isEmpty {
                    templates[templates.count - 1] += 1
                }
                i += 1
                anterior = .abre
            case 0x7D: // }
                if let topo = templates.last {
                    if topo == 0 {
                        // Fim do `${ }`: volta para o texto do template.
                        templates.removeLast()
                        i += 1
                        if pularTemplate() {
                            templates.append(0)
                            anterior = .abre
                        } else {
                            anterior = .valor
                        }
                        continue
                    }
                    templates[templates.count - 1] -= 1
                }
                i += 1
                anterior = .abre
            case 0x29, 0x5D: // ) ]
                i += 1
                anterior = .valor
            case 0x2E: // .
                if i + 1 < n, u[i + 1] >= 0x30, u[i + 1] <= 0x39 {
                    i += 1
                    while i < n, ehIdent(u[i]) || u[i] == 0x2E {
                        i += 1
                    }
                    anterior = .valor
                } else if i + 2 < n, u[i + 1] == 0x2E, u[i + 2] == 0x2E {
                    i += 3
                    anterior = .abre
                } else {
                    i += 1
                    anterior = .ponto
                }
            default:
                if c >= 0x30, c <= 0x39 {
                    while i < n, ehIdent(u[i]) || u[i] == 0x2E {
                        i += 1
                    }
                    anterior = .valor
                } else if ehIdent(c) {
                    let inicio = i
                    while i < n, ehIdent(u[i]) {
                        i += 1
                    }
                    if igual(u, inicio, i, palavraImport) {
                        var ehPropriedade = false
                        if case .ponto = anterior {
                            ehPropriedade = true
                        }
                        var j = i
                        while j < n, u[j] == 0x20 || u[j] == 0x09 || u[j] == 0x0A || u[j] == 0x0D {
                            j += 1
                        }
                        if !ehPropriedade, j < n, u[j] == 0x28, depoisDoParenteses(j) != 0x7B {
                            achados.append(inicio)
                        }
                    }
                    if case .ponto = anterior {
                        anterior = .valor // nome de propriedade: depois dele `/` é divisão
                    } else {
                        let fim = i
                        anterior = antesDeRegex.contains { igual(u, inicio, fim, $0) } ? .palavraDeRegex : .valor
                    }
                } else {
                    // Operadores e pontuação: depois deles vem um valor, então `/` é regex.
                    i += 1
                    anterior = .abre
                }
            }
        }
        return achados
    }
}
