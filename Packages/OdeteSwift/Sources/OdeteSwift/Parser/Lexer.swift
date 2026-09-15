import Foundation

enum TokenKind: Equatable {
    case ident(String), int(Int), double(Double), string(String), punct(String), newline, eof
}

struct Token: Equatable {
    var kind: TokenKind
    var line: Int
    /// Havia espaço antes deste token (para distinguir `a -1` de `a - 1` não importa aqui; usado para `.x` colado).
    var spaceBefore: Bool
}

/// Tokenizador do subconjunto: identificadores, números, strings (com o conteúdo cru), pontuação e quebras de linha.
struct Lexer {
    let src: [Character]
    var i = 0
    var line = 1
    var tokens: [Token] = []

    init(_ s: String) {
        src = Array(s)
    }

    static let ops3 = ["...", "..<", "<<=", ">>="]
    static let ops2 = ["==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "*=", "/=", "->", "??"]

    mutating func run() -> [Token] {
        var space = false
        while i < src.count {
            let c = src[i]
            if c ==
                "\n"
            {
                tokens
                    .append(Token(kind: .newline, line: line, spaceBefore: space)); line += 1; i +=
                    1; space = false; continue
            }
            if c == " " || c == "\t" || c == "\r" {
                i += 1; space = true; continue
            }
            if c == "/", i + 1 < src.count,
               src[i + 1] == "/"
            {
                while i < src.count, src[i] != "\n" {
                    i += 1
                }; continue
            }
            if c == "/", i + 1 < src.count, src[i + 1] == "*" {
                i += 2
                while i + 1 < src.count,
                      !(src[i] == "*" && src[i + 1] == "/")
                {
                    if src[i] == "\n" {
                        line += 1
                    }; i += 1
                }
                i += 2; continue
            }
            let start = line
            if c.isLetter || c == "_" || c == "@" || c == "#" || c == "$" {
                var s = String(c); i += 1
                while i < src.count, src[i].isLetter || src[i].isNumber || src[i] == "_" {
                    s.append(src[i]); i += 1
                }
                tokens.append(Token(kind: .ident(s), line: start, spaceBefore: space)); space = false; continue
            }
            if c.isNumber {
                var s = ""; var isDouble = false
                while i < src.count,
                      src[i]
                      .isNumber || src[i] == "_" ||
                      (src[i] == "." && i + 1 < src.count && src[i + 1].isNumber && !isDouble)
                {
                    if src[i] == "." {
                        isDouble = true
                    }
                    if src[i] != "_" {
                        s.append(src[i])
                    }
                    i += 1
                }
                tokens.append(Token(
                    kind: isDouble ? .double(Double(s) ?? 0) : .int(Int(s) ?? 0),
                    line: start,
                    spaceBefore: space
                )); space = false; continue
            }
            if c == "\"" {
                // string simples ou multilinha """
                if i + 2 < src.count, src[i + 1] == "\"", src[i + 2] == "\"" {
                    i += 3
                    while i < src.count, src[i] != "\n" {
                        i += 1
                    }
                    var s = ""
                    while i + 2 < src.count,
                          !(src[i] == "\"" && src[i + 1] == "\"" && src[i + 2] == "\"")
                    {
                        if src[i] == "\n" {
                            line += 1
                        }; s.append(src[i]); i += 1
                    }
                    i += 3
                    tokens.append(Token(
                        kind: .string(s.trimmingCharacters(in: .newlines)),
                        line: start,
                        spaceBefore: space
                    )); space = false; continue
                }
                i += 1
                var s = ""; var depth = 0
                while i < src.count {
                    let d = src[i]
                    if d == "\\", i + 1 < src.count {
                        if src[i + 1] == "(" {
                            depth += 1; s.append("\\("); i += 2; continue
                        }
                        s.append(d); s.append(src[i + 1]); i += 2; continue
                    }
                    if depth >
                        0
                    {
                        if d == "(" {
                            depth += 1
                        } else if d == ")" {
                            depth -= 1
                        }; s.append(d); i += 1; continue
                    }
                    if d == "\"" {
                        break
                    }
                    if d == "\n" {
                        line += 1
                    }
                    s.append(d); i += 1
                }
                i += 1
                tokens.append(Token(kind: .string(s), line: start, spaceBefore: space)); space = false; continue
            }
            let rest = String(src[i ..< min(i + 3, src.count)])
            if let op = Self.ops3.first(where: { rest.hasPrefix($0) }) {
                tokens.append(Token(
                    kind: .punct(op),
                    line: start,
                    spaceBefore: space
                )); i += 3; space = false; continue
            }
            if let op = Self.ops2.first(where: { rest.hasPrefix($0) }) {
                tokens.append(Token(
                    kind: .punct(op),
                    line: start,
                    spaceBefore: space
                )); i += 2; space = false; continue
            }
            tokens.append(Token(kind: .punct(String(c)), line: start, spaceBefore: space)); i += 1; space = false
        }
        tokens.append(Token(kind: .eof, line: line, spaceBefore: false))
        return tokens
    }
}
