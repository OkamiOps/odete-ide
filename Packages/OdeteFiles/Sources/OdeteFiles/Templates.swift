// swiftlint:disable line_length
import Foundation
import OdeteI18n

/// Modelos de projeto novo. `files` devolve caminho relativo → conteúdo.
public enum Template: String, CaseIterable, Identifiable, Sendable {
    case blank, viteReact, astro, swiftPlayground, swiftView

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .blank: tr("Em branco")
        case .viteReact: tr("Vite + React")
        case .swiftView: tr("SwiftUI (uma view)")
        case .astro: tr("Astro")
        case .swiftPlayground: tr("Swift Playground")
        }
    }

    public var blurb: String {
        switch self {
        case .blank: tr("index.html, CSS e JS. Sem build.")
        case .viteReact: tr("React 19 com TypeScript e Vite.")
        case .swiftView: tr("Um ContentView.swift para brincar no preview nativo.")
        case .astro: tr("Site estático com Astro.")
        case .swiftPlayground: tr("Pacote .swiftpm que abre no Swift Playgrounds.")
        }
    }

    public var symbol: String {
        switch self {
        case .blank: "doc"
        case .viteReact: "bolt"
        case .swiftView: "swift"
        case .astro: "sparkle"
        case .swiftPlayground: "swift"
        }
    }

    public func files(projectName: String) -> [String: String] {
        switch self {
        case .blank: Self.blank(projectName)
        case .viteReact: Self.viteReact(projectName)
        case .swiftView: Self.swiftView(projectName)
        case .astro: Self.astro(projectName)
        case .swiftPlayground: Self.swiftPlayground(projectName)
        }
    }

    static func readme(_ name: String, _ body: String) -> String {
        tr("# %1$@\n\nCriado na Odete, direto no iPad.\n\n%2$@\n", "\(name)", "\(body)")
    }

    static func blank(_ name: String) -> [String: String] {
        [
            "README.md": readme(
                name,
                tr(
                    "| arquivo | o que é |\n| --- | --- |\n| `index.html` | página do preview |\n| `src/style.css` | visual |\n| `src/main.js` | comportamento |"
                )
            ),
            "index.html": """
            <!doctype html>
            <html lang="pt-BR">
              <head>
                <meta charset="UTF-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <title>\(name)</title>
                <link rel="stylesheet" href="/src/style.css" />
              </head>
              <body>
                <main class="page">
                  <h1>\(name)</h1>
                  <p>Feito no iPad.</p>
                  <button id="ok" type="button">contar clique</button>
                  <p id="out">0 cliques</p>
                </main>
                <script type="module" src="/src/main.js"></script>
              </body>
            </html>
            """,
            "src/style.css": """
            :root { color-scheme: light dark; font-family: system-ui, sans-serif; }
            body { margin: 0; display: grid; place-items: center; min-height: 100vh; }
            .page { text-align: center; padding: 2rem; }
            button { font: inherit; padding: .6rem 1.2rem; border-radius: 999px; border: 1px solid currentColor; background: transparent; color: inherit; }
            """,
            "src/main.js": """
            const out = document.getElementById("out");
            const btn = document.getElementById("ok");
            let n = 0;
            btn.addEventListener("click", () => {
              n += 1;
              out.textContent = `${n} clique${n === 1 ? "" : "s"}`;
            });
            """,
        ]
    }

    static func viteReact(_ name: String) -> [String: String] {
        [
            "README.md": readme(name, tr("`npm run dev` sobe o Vite. Edite `src/App.tsx`.")),
            ".gitignore": "node_modules/\ndist/\n.DS_Store\n",
            "package.json": """
            {
              "name": "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
              "private": true,
              "type": "module",
              "scripts": { "dev": "vite", "build": "vite build", "preview": "vite preview" },
              "dependencies": { "react": "^19.2.0", "react-dom": "^19.2.0" },
              "devDependencies": { "@vitejs/plugin-react": "^5.2.0", "typescript": "^5.7.0", "vite": "^8.2.0" }
            }
            """,
            "index.html": """
            <!doctype html>
            <html lang="pt-BR">
              <head>
                <meta charset="UTF-8" />
                <meta name="viewport" content="width=device-width, initial-scale=1" />
                <title>\(name)</title>
              </head>
              <body>
                <div id="root"></div>
                <script type="module" src="/src/main.tsx"></script>
              </body>
            </html>
            """,
            "vite.config.ts": "import react from \"@vitejs/plugin-react\";\nimport { defineConfig } from \"vite\";\n\nexport default defineConfig({ plugins: [react()] });\n",
            "tsconfig.json": "{\n  \"compilerOptions\": {\n    \"target\": \"ES2022\",\n    \"module\": \"ESNext\",\n    \"moduleResolution\": \"bundler\",\n    \"jsx\": \"react-jsx\",\n    \"strict\": true,\n    \"skipLibCheck\": true\n  },\n  \"include\": [\"src\"]\n}\n",
            "src/main.tsx": "import { StrictMode } from \"react\";\nimport { createRoot } from \"react-dom/client\";\nimport { App } from \"./App\";\nimport \"./style.css\";\n\ncreateRoot(document.getElementById(\"root\")!).render(\n  <StrictMode>\n    <App />\n  </StrictMode>,\n);\n",
            "src/App.tsx": "import { useState } from \"react\";\n\nexport function App() {\n  const [n, setN] = useState(0);\n  return (\n    <main className=\"page\">\n      <h1>\(name)</h1>\n      <p>React no iPad.</p>\n      <button onClick={() => setN(n + 1)}>{n} cliques</button>\n    </main>\n  );\n}\n",
            "src/style.css": ":root { color-scheme: light dark; font-family: system-ui, sans-serif; }\nbody { margin: 0; display: grid; place-items: center; min-height: 100vh; }\n.page { text-align: center; }\n",
        ]
    }

    static func astro(_ name: String) -> [String: String] {
        [
            "README.md": readme(name, tr("`npm run dev` sobe o Astro. Páginas em `src/pages`.")),
            ".gitignore": "node_modules/\ndist/\n.astro/\n.DS_Store\n",
            "package.json": """
            {
              "name": "\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
              "private": true,
              "type": "module",
              "scripts": { "dev": "astro dev", "build": "astro build", "preview": "astro preview" },
              "dependencies": { "astro": "^5.0.0" }
            }
            """,
            "astro.config.mjs": "import { defineConfig } from \"astro/config\";\n\nexport default defineConfig({});\n",
            "src/pages/index.astro": "---\nconst title = \"\(name)\";\n---\n<html lang=\"pt-BR\">\n  <head>\n    <meta charset=\"UTF-8\" />\n    <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n    <title>{title}</title>\n  </head>\n  <body>\n    <main>\n      <h1>{title}</h1>\n      <p>Astro no iPad.</p>\n    </main>\n  </body>\n</html>\n",
        ]
    }

    static func contentView(_ name: String) -> String {
        """
        import SwiftUI

        struct ContentView: View {
            @State private var count = 0
            @State private var nome = ""
            @State private var escuro = false
            let frutas = ["Maçã", "Banana", "Uva"]

            var body: some View {
                NavigationStack {
                    List {
                        Section("Contador") {
                            Text("\\(count) toques").font(.title2)
                            Button("Mais um") { count += 1 }
                                .buttonStyle(.borderedProminent)
                        }
                        Section("Você") {
                            TextField("Seu nome", text: $nome)
                            Toggle("Modo escuro", isOn: $escuro)
                            if !nome.isEmpty {
                                Text("Olá, \\(nome)!").foregroundStyle(.green)
                            }
                        }
                        Section("Frutas") {
                            ForEach(frutas, id: \\.self) { fruta in
                                NavigationLink(fruta) {
                                    Text(fruta).font(.largeTitle).padding()
                                }
                            }
                        }
                    }
                    .navigationTitle("\(name)")
                }
            }
        }

        """
    }

    static func swiftView(_ name: String) -> [String: String] {
        [
            "README.md": readme(
                name,
                tr("Um arquivo SwiftUI. O Preview mostra a view na hora; para rodar de verdade, crie um pacote de app.")
            ),
            "ContentView.swift": contentView(name),
        ]
    }

    static func swiftPlayground(_ name: String) -> [String: String] {
        let ident = name.replacingOccurrences(of: " ", with: "")
        return [
            "README.md": readme(
                name,
                tr("Pacote de app para o Swift Playgrounds. Abra `%1$@.swiftpm` no Playgrounds para rodar.", "\(ident)")
            ),
            "\(ident).swiftpm/Package.swift": """
            // swift-tools-version: 5.9
            import AppleProductTypes
            import PackageDescription

            let package = Package(
                name: "\(ident)",
                platforms: [.iOS("17.0")],
                products: [
                    .iOSApplication(
                        name: "\(ident)",
                        targets: ["AppModule"],
                        bundleIdentifier: "com.example.\(ident.lowercased())",
                        teamIdentifier: "",
                        displayVersion: "1.0",
                        bundleVersion: "1",
                        appIcon: .placeholder(icon: .sparkles),
                        accentColor: .presetColor(.cyan),
                        supportedDeviceFamilies: [.pad, .phone],
                        supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft]
                    )
                ],
                targets: [
                    .executableTarget(name: "AppModule", path: ".")
                ]
            )
            """,
            "\(ident).swiftpm/MyApp.swift": "import SwiftUI\n\n@main\nstruct MyApp: App {\n    var body: some Scene {\n        WindowGroup {\n            ContentView()\n        }\n    }\n}\n",
            "\(ident).swiftpm/ContentView.swift": Self.contentView(name),
        ]
    }
}
