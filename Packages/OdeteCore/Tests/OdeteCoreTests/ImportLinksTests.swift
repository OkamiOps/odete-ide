import Foundation
@testable import OdeteCore
import Testing

struct ImportLinksTests {
    @Test func achaOsCaminhosDeUmArquivoTSX() {
        let texto = """
        import { useState } from "react";
        import Card from "./Card";
        import { api } from "../lib/api";
        export * from "./tipos";
        const x = require("./velho");
        """
        let links = ImportLinks.find(text: texto, language: .tsx)
        #expect(links.map(\.spec) == ["react", "./Card", "../lib/api", "./tipos", "./velho"])
    }

    @Test func oIntervaloCobreSoOCaminho() throws {
        let texto = #"import Card from "./Card";"#
        let l = try #require(ImportLinks.find(text: texto, language: .tsx).first)
        let inicio = texto.index(texto.startIndex, offsetBy: l.range.lowerBound)
        let fim = texto.index(texto.startIndex, offsetBy: l.range.upperBound)
        #expect(String(texto[inicio ..< fim]) == "./Card")
    }

    @Test func cssTambemTemImport() {
        let links = ImportLinks.find(text: "@import \"./base.css\";", language: .css)
        #expect(links.map(\.spec) == ["./base.css"])
    }

    @Test func markdownNaoTem() {
        #expect(ImportLinks.find(text: "import x from \"y\"", language: .markdown).isEmpty)
    }

    // MARK: para onde aponta

    let arquivos: Set<String> = [
        "src/App.tsx", "src/Card.tsx", "src/lib/api.ts",
        "src/ui/index.ts", "src/estilo.css", "package.json",
    ]

    @Test func relativoSemExtensao() {
        #expect(ImportLinks.resolve("./Card", de: "src/App.tsx", arquivos: arquivos) == "src/Card.tsx")
    }

    @Test func sobePastaComPontoPonto() {
        #expect(ImportLinks.resolve("../estilo.css", de: "src/lib/api.ts", arquivos: arquivos) == "src/estilo.css")
    }

    @Test func pastaComIndex() {
        #expect(ImportLinks.resolve("./ui", de: "src/App.tsx", arquivos: arquivos) == "src/ui/index.ts")
    }

    @Test func pacoteInstaladoNaoEArquivoDoProjeto() {
        #expect(ImportLinks.resolve("react", de: "src/App.tsx", arquivos: arquivos) == nil)
    }

    @Test func caminhoQueNaoExisteNaoAponta() {
        #expect(ImportLinks.resolve("./Sumiu", de: "src/App.tsx", arquivos: arquivos) == nil)
    }

    @Test func apelidoDoTsconfig() {
        let cfg = Data(#"{"compilerOptions":{"baseUrl":".","paths":{"@/*":["./src/*"]}}}"#.utf8)
        let a = ImportLinks.aliases(tsconfig: cfg)
        #expect(a == ["@/": "src/"])
        #expect(ImportLinks.resolve("@/Card", de: "src/App.tsx", arquivos: arquivos, aliases: a) == "src/Card.tsx")
    }

    @Test func semTsconfigNaoHaApelido() {
        #expect(ImportLinks.aliases(tsconfig: nil).isEmpty)
    }
}
