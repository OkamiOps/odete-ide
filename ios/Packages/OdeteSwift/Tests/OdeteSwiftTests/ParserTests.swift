@testable import OdeteSwift
import Testing

func parse(_ s: String) -> SwiftFile {
    Parser.parse(file: "T.swift", source: s)
}

func body(_ s: String) -> [Stmt] {
    parse("struct V: View { var body: some View {\n\(s)\n} }").structs[0].body!
}

struct ParserTests {
    @Test func literalsAndInterpolation() {
        let b = body(#"Text("Olá \(nome), \(n + 1) vezes")"#)
        guard case let .expr(.call(.ident("Text", _), args, _, _), _) = b[0],
              case let .string(segs) = args[0].value else { Issue.record("Text"); return }
        #expect(segs.count == 5)
        if case let .text(t) = segs[0] {
            #expect(t == "Olá ")
        } else {
            Issue.record("seg0")
        }
        if case let .expr(.binary("+", .ident("n", _), .int(1))) = segs[3] {} else {
            Issue.record("seg3: \(segs[3])")
        }
        let lit = body("Text(\"a\\nb\")\nText(String(3.5))")
        #expect(lit.count == 2)
    }

    @Test func callsModifiersTrailing() {
        let b = body("""
        VStack(spacing: 8) {
            Text("oi")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Button("Toca") { count += 1 }
            Button(action: { count -= 1 }) { Text("menos") }
        }
        .padding()
        """)
        #expect(b.count == 1)
        guard case let .expr(
            .call(.member(.call(.ident("VStack", _), vargs, trailing, _), "padding", _), _, _, _),
            _
        ) = b[0] else { Issue.record("VStack.padding: \(b[0])"); return }
        #expect(vargs.count == 1 && vargs[0].label == "spacing" && trailing.count == 1 && trailing[0].1.body.count == 3)
        // Text com dois modificadores
        guard case let .expr(textExpr, _) = trailing[0].1.body[0], case let .call(
            .member(.call(.member(.call(.ident("Text", _), _, _, _), "font", _), fontArgs, _, _), "foregroundStyle", _),
            fsArgs,
            _,
            _
        ) = textExpr else { Issue.record("modificadores: \(trailing[0].1.body[0])"); return }
        if case .member(nil, "largeTitle", _) = fontArgs[0].value {} else {
            Issue.record("largeTitle")
        }
        if case .member(nil, "red", _) = fsArgs[0].value {} else {
            Issue.record("red")
        }
        // Button com trailing closure e assign
        guard case let .expr(.call(.ident("Button", _), bargs, btr, _), _) = trailing[0].1.body[1], case let .assign(
            .ident("count", _),
            "+=",
            .int(1),
            _
        ) = btr[0].1.body[0] else { Issue.record("button"); return }
        #expect(bargs.count == 1)
        guard case let .expr(.call(.ident("Button", _), b2args, b2tr, _), _) = trailing[0].1.body[2],
              case .closure = b2args[0].value else { Issue.record("button2"); return }
        #expect(b2args[0].label == "action" && b2tr.count == 1)
    }

    @Test func stateVarsFuncsAndMain() throws {
        let f = parse("""
        import SwiftUI

        @main
        struct MyApp: App {
            var body: some Scene {
                WindowGroup { ContentView() }
            }
        }

        struct ContentView: View {
            @State private var count = 0
            @State var on: Bool = false
            let title = "Contador"
            var dobro: Int { count * 2 }

            func zerar() { count = 0 }

            var body: some View {
                Toggle("Ligado", isOn: $on)
                if count > 3 {
                    Text("muito")
                } else if count > 1 {
                    Text("médio")
                } else {
                    Text("pouco")
                }
                ForEach(0..<3) { i in
                    Text("linha \\(i)")
                }
                ForEach(items, id: \\.self) { item in Text(item) }
            }
        }
        """)
        #expect(f.diagnostics.isEmpty, "\(f.diagnostics)")
        #expect(f.structs.count == 2 && f.structs[0].isMain && f.structs[0].isApp && f.structs[1].isView)
        let cv = f.structs[1]
        #expect(cv.vars.map(\.name) == ["count", "on", "title", "dobro"] && cv.vars[0].attr == .state && cv.vars[1]
            .typeName == "Bool" && cv.vars[3].isLet)
        #expect(cv.funcs.count == 1 && cv.funcs[0].name == "zerar")
        let b = try #require(cv.body)
        #expect(b.count == 4)
        if case let .expr(.call(_, args, _, _), _) = b[0],
           case let .ident(s, _) = args[1].value
        {
            #expect(s == "$on")
        } else {
            Issue.record("toggle")
        }
        if case let .ifStmt(.binary(">", _, .int(3)), then, els, _) = b[1] {
            #expect(then.count == 1 && els?.count == 1)
        } else {
            Issue.record("if: \(b[1])")
        }
        if case let .expr(.call(.ident("ForEach", _), args, tr, _), _) = b[2], case .range(
            .int(0),
            .int(3),
            closed: false
        ) = args[0].value {
            #expect(tr[0].1.params == ["i"])
        } else {
            Issue.record("foreach")
        }
        if case let .expr(.call(.ident("ForEach", _), args, tr, _), _) = b[3] {
            #expect(args.count == 2 && args[1].label == "id" && tr[0].1.params == ["item"])
        } else {
            Issue.record("foreach2")
        }
    }

    @Test func errorsHaveLines() {
        let f = parse("""
        struct V: View {
            var body: some View {
                Text("ok")
                Text(
            }
        }
        """)
        #expect(!f.diagnostics.isEmpty && f.diagnostics[0].kind == .error && f.diagnostics[0].line >= 4)
        let g =
            parse(
                "struct A: View { var body: some View { Text(\"a\") } }\nextension A { func x() {} }\nenum E { case a }"
            )
        #expect(g.structs.count == 1 && g.diagnostics.allSatisfy { $0.kind == .warning } && g.diagnostics.count == 2)
    }

    @Test func expressionsOperators() {
        let b = body("Text(a == 1 && !b || c >= 2 ? \"x\" : \"y\").opacity(0.5 * 2 - 1)")
        guard case let .expr(.call(.member(.call(_, args, _, _), "opacity", _), oargs, _, _), _) = b[0]
        else { Issue.record("expr"); return }
        if case .ternary(.binary("||", .binary("&&", _, .unary("!", _)), _), _, _) = args[0].value {}
        else {
            Issue.record("ternary: \(args[0].value)")
        }
        if case .binary("-", .binary("*", .double(0.5), .int(2)), .int(1)) = oargs[0].value {}
        else {
            Issue.record("arith: \(oargs[0].value)")
        }
        let arr = body("List([\"a\", \"b\"], id: \\.self) { s in Text(s) }")
        if case let .expr(.call(_, args, _, _), _) = arr[0],
           case let .array(items) = args[0].value
        {
            #expect(items.count == 2)
        } else {
            Issue.record("array")
        }
    }
}
