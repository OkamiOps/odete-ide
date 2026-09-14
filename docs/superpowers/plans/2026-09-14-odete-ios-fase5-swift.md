# Odete iOS Fase 5 — Swift — Plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Projetos `.swiftpm` editados na Odete, com preview nativo do subconjunto de SwiftUI e abertura no Swift Playgrounds.

**Architecture:** Pacote `OdeteSwift` com `Parser/` (Lexer, Parser, AST), `Runtime/` (Value, Interpreter, ViewInstance @Observable), `Render/` (SwiftUI `SwiftView` que renderiza a árvore), `Package/` (PlaygroundPackage, PlaygroundLauncher). App: `SwiftPreviewPane` no lugar do PreviewPane quando a stack é Swift; Problemas recebe diagnósticos "swift".

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, UIDocumentInteractionController.

**Spec:** `docs/superpowers/specs/2026-09-14-odete-ios-fase5-swift-design.md`

## Global Constraints

- iOS/iPadOS 26+, Swift 6 strict concurrency, sem compilador no iPad.
- Textos em pt-BR. Erros sempre com arquivo e linha.
- Cada task termina com `xcodebuild test` do pacote no simulador `7B54EEE5-3B0E-40E8-98CA-D14509F539DD` verde e commit na branch `iOS`.

---

### Task 1: Lexer e parser (Marco 1)

**Files:** `ios/Packages/OdeteSwift/Package.swift`, `Sources/OdeteSwift/Parser/{Token,Lexer,AST,Parser,Diagnostic}.swift`; `Tests/OdeteSwiftTests/ParserTests.swift`.

**Interfaces:**
- `enum Expr: literal(Literal), ident(String), member(Expr, String), call(Expr, [Arg], trailing: [Closure]), binary(op, Expr, Expr), unary(op, Expr), closure(Closure), array([Expr]), range(Expr, Expr, closed: Bool), ifElse(cond, [Stmt], [Stmt]), interpolated([Segment])`.
- `enum Stmt: expr(Expr), varDecl(name, kind: .state|.binding|.let|.var, type?, initial: Expr?), assign(target: Expr, op: "=|+=|-=", value: Expr), funcDecl(name, params, body), ifStmt, forEach`.
- `struct ViewStruct { name, conforms: [String], props: [Stmt], body: [Stmt], funcs, isMain }`.
- `Parser.parse(file: String, source: String) -> (structs: [ViewStruct], diagnostics: [SwiftDiagnostic])`.

- [x] Testes: literais/interpolação, chamada com rótulos e trailing closure, modificadores encadeados em várias linhas, `@State private var n = 0`, `if/else` no body, `ForEach(0..<3) { i in … }`, duas structs, erro com linha.
- [x] Implementar. Commit: `swift: lexer e parser do subconjunto`.

### Task 2: Interpretador e render (Marco 2)

**Files:** `Sources/OdeteSwift/Runtime/{Value,Interpreter,ViewInstance}.swift`, `Sources/OdeteSwift/Render/{SwiftView,Modifiers,Builtins}.swift`; `Tests/OdeteSwiftTests/{InterpreterTests,RenderTests}.swift`.

**Interfaces:**
- `enum Value { string, int, double, bool, array, color, font, closure, view(ViewNode), none }`.
- `struct ViewNode { kind: String, args: [String: Value], children: [ViewNode], modifiers: [(String, [Value])], line: Int }`.
- `@Observable final class ViewInstance { state: [String: Value]; func evalBody() -> ViewNode }`.
- `Program { structs; func instance(of name: String) -> ViewInstance }`.
- `struct SwiftView: View { let node: ViewNode; let instance: ViewInstance }`.

- [x] Testes: contador (`Button { n += 1 }` + `Text("\(n)")`), toggle bind, ForEach range, TextField binding, modificadores cor/fonte/padding aplicados, fora do subconjunto vira placeholder com aviso, `ImageRenderer` do template não vazio.
- [x] Implementar. Commit: `swift: interpretador e render nativo do subconjunto de SwiftUI`.

### Task 3: Pacote, Playgrounds e app (Marco 3)

**Files:** `Sources/OdeteSwift/Package/{PlaygroundPackage,PlaygroundLauncher}.swift`; app: `OdeteApp/Sources/OdeteApp/Preview/SwiftPreviewPane.swift`, `PreviewPane.swift` (delegar quando stack Swift), `ProblemsPane.swift` (fonte swift), `RunModel`/`WorkspaceModel` (`swiftProgram` recompila no reload), `OdeteShell` (`swift` explica), `Templates.swift` (template melhor + `swiftUIComponent`), skills embutida.

- [x] Testes: `PlaygroundPackage` do template (nome, main, arquivos); `WorkspaceModel` com template Swift produz programa e preview sem diagnósticos.
- [x] Implementar; verificar no simulador (editar `ContentView`, salvar, ver preview; botão Playgrounds abre folha). Commit: `swift: preview no app, abrir no Playgrounds, templates`.

### Task 4: Fechamento

- [x] `make lint`, `make unit`, `make test`; README (seção Swift); memória; commit `ios: fase 5 concluída`.
