import Foundation

/// Portado de `detectStack` em `src/lib/workspace/npm.ts`, mais Swift.
public struct Stack: Hashable, Sendable {
    public enum Kind: String, Sendable { case spa, ssr, api, swift, html }
    public var id: String
    public var kind: Kind
    public var label: String

    public static let html = Stack(id: "html", kind: .html, label: "HTML")

    public static func detect(paths: some Sequence<String>, packageJSON: Data?) -> Stack {
        let list = Array(paths)
        if list
            .contains(where: {
                $0 == "Package.swift" || $0.hasSuffix(".swiftpm/Package.swift") || $0.hasSuffix(".swift") && !$0
                    .contains("/")
            })
        {
            return Stack(id: "swift", kind: .swift, label: "Swift")
        }
        var all: [String: String] = [:]
        if let data = packageJSON,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in ["dependencies", "devDependencies"] {
                if let deps = obj[key] as? [String: String] {
                    all.merge(deps) { a, _ in a }
                }
            }
        }
        if all["next"] != nil {
            return Stack(id: "next", kind: .ssr, label: "Next.js")
        }
        if all["astro"] != nil {
            return Stack(id: "astro", kind: .ssr, label: "Astro")
        }
        if all["@remix-run/react"] != nil || all["@remix-run/node"] != nil || all["remix"] != nil {
            return Stack(id: "remix", kind: .ssr, label: "Remix")
        }
        if all["@nestjs/core"] != nil {
            return Stack(id: "nest", kind: .api, label: "Nest")
        }
        if all["@tanstack/react-start"] != nil || all["@tanstack/start"] != nil {
            return Stack(id: "tanstack-start", kind: .ssr, label: "TanStack Start")
        }
        if all["vite"] != nil || all["@vitejs/plugin-react"] !=
            nil
        {
            return Stack(id: "vite", kind: .spa, label: "Vite")
        }
        if all["react-scripts"] != nil {
            return Stack(id: "cra", kind: .spa, label: "CRA")
        }
        if all["react"] != nil {
            return Stack(id: "react", kind: .spa, label: "React")
        }
        return .html
    }

    /// O que o agente precisa saber sobre a pilha antes de escrever qualquer arquivo.
    ///
    /// A detecção já existia, mas só a tela usava. O agente começava cego: num projeto
    /// Astro ele criava `index.html` na raiz, que o Astro ignora, e a pessoa tinha que
    /// dizer no chat em que tipo de projeto estava — sendo que foi o próprio Hub que
    /// criou o projeto a partir de um modelo.
    public var regrasParaOAgente: String {
        let comum = "Projeto: \(label). Siga a convenção da pilha; não misture com outra."
        switch id {
        case "astro":
            return """
            \(comum)
            Páginas ficam em `src/pages/*.astro`, e a rota vem do nome do arquivo:
            `src/pages/index.astro` é `/`. Não crie `index.html` na raiz — o Astro o ignora.
            Componentes em `src/components/*.astro`, estáticos em `public/`.
            O servidor sobe com `npm run dev`, na porta 4321.
            """
        case "vite", "react", "cra":
            return """
            \(comum)
            `index.html` na raiz é a porta de entrada e carrega `src/main.tsx` (ou `.jsx`)
            por `<script type="module">`. Componentes em `src/`. Estáticos em `public/`.
            O servidor sobe com `npm run dev`, na porta 5173.
            """
        case "next":
            return """
            \(comum)
            Rotas em `app/` (App Router) ou `pages/`, conforme o que o projeto já usa —
            olhe antes de criar. Estáticos em `public/`. Não crie `index.html` na raiz.
            O Preview renderiza no servidor e hidrata componente marcado com
            `'use client'`; `middleware.ts`, `next/font` e Server Actions com
            `'use server'` no topo do arquivo funcionam. `next build` ainda não roda.
            """
        case "remix", "tanstack-start":
            return """
            \(comum)
            Rotas em `app/routes/`, seguindo o que já existe na pasta. Não crie
            `index.html` na raiz.
            """
        case "nest":
            return """
            \(comum)
            É uma API: módulos, controllers e services em `src/`. Não há página para o
            Preview; teste pelas rotas HTTP no terminal.
            """
        case "swift":
            return """
            \(comum)
            SwiftUI em arquivos `.swift`. Views pequenas, sem Combine, compatível com
            Swift Playgrounds no iPad. Não há npm nem servidor aqui.
            """
        default:
            return """
            \(comum)
            `index.html` é a página do Preview, CSS em `src/style.css`, JS em
            `src/main.js`. Sem framework e sem dependência nova.
            """
        }
    }
}
