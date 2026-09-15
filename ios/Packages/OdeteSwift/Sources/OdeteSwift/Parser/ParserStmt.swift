import Foundation
import SwiftUI

/// Blocos e statements: o que fica entre chaves.
extension Parser {
    mutating func parseBlock() throws -> [Stmt] {
        try expect("{")
        var out: [Stmt] = []
        while true {
            skipNewlines()
            if at("}") {
                advance(); return out
            }
            if isEOF {
                throw ParseError(line: line, message: "bloco sem fechar")
            }
            try out.append(parseStmt())
            if at(";") {
                advance()
            }
        }
    }

    mutating func parseStmt() throws -> Stmt {
        let l = line
        if at("let") || at("var") {
            return try .varDecl(parseVarDecl())
        }
        if at("func") {
            return try .funcDecl(parseFunc())
        }
        if at("return") {
            advance(); if isNewline || at("}") {
                return .returnStmt(nil, line: l)
            }; return try .returnStmt(
                parseExpr(),
                line: l
            )
        }
        if at("if") {
            let e = try parseIf(); if case let .ifExpr(c, a, b, _) = e {
                return .ifStmt(c, a, b, line: l)
            }; return .expr(
                e,
                line: l
            )
        }
        if at("for") {
            advance()
            let name = try ident()
            try expect("in")
            let seq = try parseExpr()
            let body = try parseBlock()
            return .forIn(name, seq, body, line: l)
        }
        let e = try parseExpr()
        if case let .punct(op) = cur.kind, ["=", "+=", "-=", "*=", "/="].contains(op) {
            advance(); skipNewlines()
            let v = try parseExpr()
            return .assign(e, op, v, line: l)
        }
        return .expr(e, line: l)
    }

    mutating func parseIf() throws -> Expr {
        let l = line
        try expect("if")
        var cond: Expr
        if at("let") { // if let x = y  → tratamos como `y != nil`
            advance(); let n = try ident(); try expect("="); let v = try parseExprNoTrailing()
            cond = .binary("!=", v, .ident("nil", line: l))
            _ = n
        } else {
            cond = try parseExprNoTrailing()
        }
        let then = try parseBlock()
        var els: [Stmt]?
        skipNewlines()
        if at("else") {
            advance(); skipNewlines()
            if at("if") {
                let e = try parseIf(); els = [.expr(e, line: e.line)]
            } else {
                els = try parseBlock()
            }
        }
        return .ifExpr(cond, then, els, line: l)
    }
}
