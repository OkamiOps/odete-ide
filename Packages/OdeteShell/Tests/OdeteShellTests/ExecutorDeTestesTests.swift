import Foundation
import OdeteI18n
import OdeteRuntime
@testable import OdeteShell
import Testing

/// `npx vitest run` com o executor embutido, o aviso do TypeScript 7 e a volta rápida do
/// `node`. Sem rede: os projetos são montados aqui.
@Suite(.serialized) struct ExecutorDeTestesTests {
    init() {
        Texto.escolher(.ptBR)
    }

    /// Um projeto com três arquivos de teste: um em CJS (sem esbuild), um em TS com ESM e um
    /// que falha de propósito.
    func projeto() throws -> URL {
        let raiz = FileManager.default.temporaryDirectory.appending(
            path: "odete-vt-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let src = raiz.appending(path: "src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: raiz.appending(path: "node_modules/pacote"),
            withIntermediateDirectories: true
        )
        let arquivos: [String: String] = [
            "package.json": #"{"name":"vt","type":"module","scripts":{"test":"vitest run"}}"#,
            "src/soma.ts": "export const soma = (a: number, b: number): number => a + b;\n",
            "src/soma.test.ts": """
            import { describe, expect, it, vi, beforeEach } from "vitest";
            import { soma } from "./soma.js";

            let n = 0;
            beforeEach(() => { n++; });
            describe("soma", () => {
              it("soma", () => { expect(soma(2, 3)).toBe(5); expect(n).toBe(1); });
              it.each([[1, 1, 2], [2, 2, 4]])("%i + %i = %i", (a, b, r) => { expect(soma(a, b)).toBe(r); });
              it("assíncrono", async () => {
                await expect(Promise.resolve({ a: [1, 2] })).resolves.toEqual({ a: [1, 2] });
                await expect(Promise.reject(new Error("não"))).rejects.toThrow("não");
              });
              it("espiões", () => {
                const f = vi.fn((x: number) => x * 2);
                f(4);
                expect(f).toHaveBeenCalledWith(4);
                expect(f.mock.results[0].value).toBe(8);
                const o = { oi: () => "oi" };
                const s = vi.spyOn(o, "oi").mockReturnValue("tchau");
                expect(o.oi()).toBe("tchau");
                s.mockRestore();
                expect(o.oi()).toBe("oi");
              });
              it.skip("pulado", () => { throw new Error("não roda"); });
              it.todo("depois");
            });
            """,
            "src/objetos.test.cjs": """
            const { test, expect } = require("vitest");
            test("objetos", () => {
              expect({ a: 1, b: { c: [1, 2] }, d: undefined }).toEqual({ a: 1, b: { c: [1, 2] } });
              expect({ a: 1, b: { c: [1, 2] } }).toMatchObject({ b: { c: [1, 2] } });
              expect([{ id: 1 }, { id: 2 }]).toContainEqual({ id: 2 });
              expect({ id: 1, nome: "x" }).toEqual(expect.objectContaining({ nome: expect.any(String) }));
              expect(() => { throw new TypeError("ruim"); }).toThrow(TypeError);
              expect(0.1 + 0.2).toBeCloseTo(0.3);
              expect("olá mundo").toMatch(/mundo$/);
            });
            """,
            "src/falha.test.js": """
            import { it, expect } from "vitest";
            it("passa", () => { expect([1, 2, 3]).toContain(2); });
            it("falha de propósito", () => { expect({ n: 1 + 1 }).toEqual({ n: 3 }); });
            """,
            // Não é teste: fica fora da busca, como node_modules.
            "node_modules/pacote/x.test.js": "throw new Error('não era para carregar');",
        ]
        for (caminho, texto) in arquivos {
            try texto.write(to: raiz.appending(path: caminho), atomically: true, encoding: .utf8)
        }
        return raiz
    }

    @Test func achaOsArquivosDeTeste() throws {
        let raiz = try projeto()
        let nomes = ExecutorDeTestes.arquivos(em: raiz).map(\.lastPathComponent)
        #expect(nomes == ["falha.test.js", "objetos.test.cjs", "soma.test.ts"])
        #expect(ExecutorDeTestes.arquivos(em: raiz, filtros: ["soma"]).map(\.lastPathComponent) == ["soma.test.ts"])
        #expect(ExecutorDeTestes.ehArquivoDeTeste("a.spec.tsx") && ExecutorDeTestes.ehArquivoDeTeste("b.test.mjs"))
        #expect(!ExecutorDeTestes.ehArquivoDeTeste("teste.ts") && !ExecutorDeTestes.ehArquivoDeTeste("a.test.css"))
    }

    @Test func vitestRunComFalha() async throws {
        let raiz = try projeto()
        let sh = Shell(root: raiz)
        let o = Out()
        let codigo = await sh.run("npm test", sink: o.sink)
        let tudo = o.out + "\n" + o.err
        #expect(codigo == 1, Comment(rawValue: tudo))
        #expect(o.out.contains("executor embutido da Odete"), Comment(rawValue: tudo))
        #expect(o.out.contains(" ✓ src/soma.test.ts (7 tests | 2 skipped)"), Comment(rawValue: tudo))
        #expect(o.out.contains(" ✓ src/objetos.test.cjs (1 test)"), Comment(rawValue: tudo))
        #expect(o.out.contains(" ❯ src/falha.test.js (2 tests | 1 failed)"), Comment(rawValue: tudo))
        #expect(o.out.contains(" FAIL  src/falha.test.js > falha de propósito"), Comment(rawValue: tudo))
        #expect(o.out.contains("AssertionError: expected { n: 2 } to deeply equal { n: 3 }"), Comment(rawValue: tudo))
        #expect(o.out.contains("-   \"n\": 3,\n+   \"n\": 2,"), Comment(rawValue: tudo))
        #expect(o.out.contains("Test Files  1 failed | 2 passed (3)"), Comment(rawValue: tudo))
        #expect(o.out.contains("Tests  1 failed | 7 passed | 1 skipped | 1 todo (10)"), Comment(rawValue: tudo))
    }

    @Test func vitestComFiltrosPassa() async throws {
        let raiz = try projeto()
        let sh = Shell(root: raiz)
        let o = Out()
        #expect(
            await sh.run("npx vitest run objetos soma -t soma", sink: o.sink) == 0,
            Comment(rawValue: o.out + o.err)
        )
        #expect(!o.out.contains("falha.test.js"), Comment(rawValue: o.out))
        // -t deixa de fora o teste de objetos (o nome dele não tem "soma").
        #expect(o.out.contains(" ↓ src/objetos.test.cjs (1 test | 1 skipped)"), Comment(rawValue: o.out))
        #expect(o.out.contains("Tests  5 passed | 2 skipped | 1 todo (8)"), Comment(rawValue: o.out))
        let o2 = Out()
        #expect(await sh.run("npx vitest run nada-disso", sink: o2.sink) == 1)
        #expect(o2.err.contains("Nenhum arquivo de teste"))
    }

    /// Erro ao carregar um arquivo (e `vi.mock`, que o executor não tem) vira suíte falha
    /// com a mensagem, e não um processo que sai com 0 calado.
    @Test func arquivoQueNaoCarregaFalhaComMensagem() async throws {
        let raiz = try projeto()
        try """
        const { vi, it } = require("vitest");
        vi.mock("./x");
        it("nunca", () => {});
        """.write(to: raiz.appending(path: "src/mock.test.cjs"), atomically: true, encoding: .utf8)
        let sh = Shell(root: raiz)
        let o = Out()
        #expect(await sh.run("npx vitest run mock", sink: o.sink) == 1)
        #expect(o.out.contains(" FAIL  src/mock.test.cjs [ src/mock.test.cjs ]"), Comment(rawValue: o.out + o.err))
        #expect(o.out.contains("vi.mock ainda não existe no executor embutido"), Comment(rawValue: o.out))
    }

    /// jsdom e setupFiles da config não existem no executor: avisa em vez de calar.
    @Test func configComJsdomAvisa() async throws {
        let raiz = try projeto()
        try #"export default { test: { environment: "jsdom" } };"#
            .write(to: raiz.appending(path: "vitest.config.ts"), atomically: true, encoding: .utf8)
        let sh = Shell(root: raiz)
        let o = Out()
        _ = await sh.run("npx vitest run objetos", sink: o.sink)
        #expect(o.err.contains("aviso: vitest.config.ts usa environment: jsdom"), Comment(rawValue: o.err))
    }

    /// `npm i -D typescript` hoje traz o 7, que é só um lançador do binário em Go.
    @Test func tscDoTypeScript7ExplicaOQueFazer() async throws {
        let raiz = try projeto()
        let ts = raiz.appending(path: "node_modules/typescript")
        try FileManager.default.createDirectory(at: ts.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: raiz.appending(path: "node_modules/.bin"),
            withIntermediateDirectories: true
        )
        try #"{"name":"typescript","version":"7.0.2","bin":{"tsc":"bin/tsc"}}"#
            .write(to: ts.appending(path: "package.json"), atomically: true, encoding: .utf8)
        try "#!/usr/bin/env node\nimport \"../lib/tsc.js\";\n"
            .write(to: ts.appending(path: "bin/tsc"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: raiz.appending(path: "node_modules/.bin/tsc").path,
            withDestinationPath: "../typescript/bin/tsc"
        )
        let sh = Shell(root: raiz)
        let o = Out()
        #expect(await sh.run("tsc --noEmit", sink: o.sink) == 1)
        #expect(o.err.contains("TypeScript 7.0.2 é o compilador nativo (Go)") && o.err
            .contains("npm i -D typescript@6"))
    }

    /// Processo longo sem porta, passada a janela do job (consulta a cada 200 ms): o Ctrl+C
    /// ainda derruba. O processo nunca terminaria sozinho; o limite é folgado porque a máquina
    /// dos testes pode estar carregada, e quem não cancela falha em vez de travar o teste.
    @Test func ctrlCDerrubaProcessoLongoDepoisDaJanela() async throws {
        let raiz = try projeto()
        let sh = Shell(root: raiz)
        let o = Out()
        let fim = NodeCommand.Termino()
        let rodando = Task {
            let c = await sh.run("node -e \"setInterval(() => {}, 1000)\"", sink: o.sink)
            fim.marcar(c)
        }
        try await Task.sleep(for: .milliseconds(1800))
        #expect(fim.codigo == nil, "terminou sozinho: \(o.out) \(o.err)")
        sh.cancel()
        let limite = ContinuousClock.now + .seconds(5)
        while fim.codigo == nil, ContinuousClock.now < limite {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(fim.codigo == 130, "Ctrl+C não derrubou o processo em 5 s")
        if fim.codigo != nil {
            await rodando.value
        }
    }

    /// O `node` que termina logo volta logo: antes todo processo levava no mínimo 1,5 s.
    @Test func nodeCurtoNaoEsperaUmSegundoEMeio() async throws {
        let raiz = try projeto()
        let sh = Shell(root: raiz)
        let o = Out()
        _ = await sh.run("node -e \"1\"", sink: o.sink) // aquece
        let t0 = ContinuousClock.now
        #expect(await sh.run("node -e \"console.log(40 + 2)\"", sink: o.sink) == 0)
        let d = ContinuousClock.now - t0
        #expect(o.out.contains("42"))
        #expect(d < .milliseconds(1000), "levou \(d)")
    }
}
