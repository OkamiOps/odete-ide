import Foundation

/// O codificador/decodificador UTF-8 do bootstrap.js, igual unidade por unidade.
enum Utf8 {
    /// Decodifica como o JS antigo: sem validar bytes de continuação, U+FFFD para líder solto
    /// (0x80–0xC1) e para sequência cortada no fim (que encerra), pontos acima de U+10FFFF viram
    /// U+FFFD. `saida` precisa de `n` unidades (nunca sai mais que uma por byte). Devolve quantas.
    static func decodifica(_ b: UnsafePointer<UInt8>, _ n: Int, em saida: UnsafeMutablePointer<UInt16>) -> Int {
        var i = 0, k = 0
        @inline(__always) func cont(_ j: Int) -> UInt32 {
            UInt32(b[j]) & 63
        }
        while i < n {
            let c = UInt32(b[i])
            i += 1
            if c < 0x80 {
                saida[k] = UInt16(c); k += 1; continue
            }
            if c < 0xC2 {
                saida[k] = 0xFFFD; k += 1; continue
            }
            if c < 0xE0 {
                if i >= n {
                    saida[k] = 0xFFFD; k += 1; break
                }
                saida[k] = UInt16(((c & 31) << 6) | cont(i)); i += 1; k += 1; continue
            }
            if c < 0xF0 {
                if i + 1 >= n {
                    saida[k] = 0xFFFD; k += 1; break
                }
                saida[k] = UInt16(((c & 15) << 12) | (cont(i) << 6) | cont(i + 1)); i += 2; k += 1; continue
            }
            if i + 2 >= n {
                saida[k] = 0xFFFD; k += 1; break
            }
            let cp = ((c & 7) << 18) | (cont(i) << 12) | (cont(i + 1) << 6) | cont(i + 2)
            i += 3
            if cp > 0x10FFFF {
                saida[k] = 0xFFFD; k += 1
            } else if cp >= 0x10000 {
                let v = cp - 0x10000
                saida[k] = UInt16(0xD800 + (v >> 10)); saida[k + 1] = UInt16(0xDC00 + (v & 0x3FF)); k += 2
            } else {
                saida[k] = UInt16(cp); k += 1
            }
        }
        return k
    }

    /// Bytes que `codifica` produz. Substituto solto vira 3 bytes (o JS antigo não o trocava por
    /// U+FFFD, e o decodificador devolve o mesmo substituto: a ida e volta é exata).
    static func tamanho(_ u: UnsafePointer<UInt16>, _ n: Int) -> Int {
        var i = 0, t = 0
        while i < n {
            let c = u[i]
            if c < 0x80 {
                t += 1
            } else if c < 0x800 {
                t += 2
            } else if c >= 0xD800, c < 0xDC00, i + 1 < n, u[i + 1] >= 0xDC00, u[i + 1] < 0xE000 {
                t += 4; i += 1
            } else {
                t += 3
            }
            i += 1
        }
        return t
    }

    /// Codifica até acabar a string ou o espaço, sem cortar ponto de código. Devolve
    /// (unidades UTF-16 lidas, bytes escritos).
    static func codifica(
        _ u: UnsafePointer<UInt16>,
        _ n: Int,
        em d: UnsafeMutablePointer<UInt8>,
        capacidade: Int
    ) -> (Int, Int) {
        var i = 0, k = 0
        while i < n {
            var c = UInt32(u[i])
            if c < 0x80 {
                if k >= capacidade {
                    break
                }
                d[k] = UInt8(c); k += 1; i += 1; continue
            }
            var unidades = 1
            if c >= 0xD800, c < 0xDC00, i + 1 < n {
                let e = UInt32(u[i + 1])
                if e >= 0xDC00, e < 0xE000 {
                    c = 0x10000 + ((c - 0xD800) << 10) + (e - 0xDC00); unidades = 2
                }
            }
            if c < 0x800 {
                if k + 2 > capacidade {
                    break
                }
                d[k] = UInt8(0xC0 | (c >> 6)); d[k + 1] = UInt8(0x80 | (c & 63)); k += 2
            } else if c < 0x10000 {
                if k + 3 > capacidade {
                    break
                }
                d[k] = UInt8(0xE0 | (c >> 12)); d[k + 1] = UInt8(0x80 | ((c >> 6) & 63))
                d[k + 2] = UInt8(0x80 | (c & 63)); k += 3
            } else {
                if k + 4 > capacidade {
                    break
                }
                d[k] = UInt8(0xF0 | (c >> 18)); d[k + 1] = UInt8(0x80 | ((c >> 12) & 63))
                d[k + 2] = UInt8(0x80 | ((c >> 6) & 63)); d[k + 3] = UInt8(0x80 | (c & 63)); k += 4
            }
            i += unidades
        }
        return (i, k)
    }
}

/// O base64 do bootstrap.js, com as mesmas regras.
enum Base64 {
    static func codifica(_ b: UnsafeRawBufferPointer) -> Data {
        guard let p = b.baseAddress, b.count > 0 else { return Data() }
        return Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: b.count, deallocator: .none)
            .base64EncodedData()
    }

    /// `+/` → `-_` e sem `=` no fim.
    static func paraURL(_ d: inout Data) {
        while d.last == UInt8(ascii: "=") {
            d.removeLast()
        }
        d.withUnsafeMutableBytes { m in
            for i in m.indices {
                if m[i] == UInt8(ascii: "+") {
                    m[i] = UInt8(ascii: "-")
                } else if m[i] == UInt8(ascii: "/") {
                    m[i] = UInt8(ascii: "_")
                }
            }
        }
    }

    /// Valor de cada caractere no alfabeto (−1 fora dele); com `url`, `-` e `_` também valem.
    private static let tabela: [Int8] = {
        var t = [Int8](repeating: -1, count: 128)
        for (i, c) in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8.enumerated() {
            t[Int(c)] = Int8(i)
        }
        return t
    }()

    /// Decodifica ignorando o que não é do alfabeto (espaços, `=`). Resto de 1 caractere ainda
    /// rende um byte, e de 2 ou 3 rendem 1 ou 2 — o que o laço em JS fazia. `saida` precisa de
    /// `n / 4 * 3 + 3` bytes. Devolve quantos escreveu.
    static func decodifica(_ u: UnsafePointer<UInt16>, _ n: Int, url: Bool, em saida: UnsafeMutablePointer<UInt8>) -> Int {
        var grupo: UInt32 = 0, cheios = 0, k = 0
        tabela.withUnsafeBufferPointer { t in
            for i in 0 ..< n {
                let c = Int(u[i])
                var v: Int8 = c < 128 ? t[c] : -1
                if url, v < 0 {
                    v = c == 0x2D ? 62 : c == 0x5F ? 63 : -1
                }
                if v < 0 {
                    continue
                }
                grupo = grupo << 6 | UInt32(v)
                cheios += 1
                if cheios == 4 {
                    saida[k] = UInt8(grupo >> 16); saida[k + 1] = UInt8((grupo >> 8) & 255)
                    saida[k + 2] = UInt8(grupo & 255); k += 3
                    grupo = 0; cheios = 0
                }
            }
        }
        switch cheios {
        case 1: saida[k] = UInt8((grupo << 2) & 255); k += 1
        case 2: saida[k] = UInt8((grupo >> 4) & 255); k += 1
        case 3: saida[k] = UInt8(grupo >> 10); saida[k + 1] = UInt8((grupo >> 2) & 255); k += 2
        default: break
        }
        return k
    }
}
