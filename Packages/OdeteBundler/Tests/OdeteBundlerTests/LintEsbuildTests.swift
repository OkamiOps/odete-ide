import Foundation
import OdeteBundler
import Testing

/// O erro de sintaxe de TS/TSX vem do esbuild. Se esse caminho falha calado, a tela diz
/// "no problems" com o arquivo quebrado na frente — que é pior do que não ter checagem.
struct LintEsbuildTests {
    func esbuild() -> Esbuild {
        Esbuild(root: FileManager.default.temporaryDirectory)
    }

    @Test func aspasQueNaoFechamEmTS() async throws {
        let d = try await esbuild().lint("const a = 'sem fechar;\nconst b = 1;\n", file: "a.ts")
        #expect(d.contains { $0.kind == .error }, "esbuild não reportou aspas abertas: \(d)")
    }

    @Test func virgulaQueFaltaEmTSX() async throws {
        let codigo = """
        const o = {
          a: 1
          b: 2
        };
        """
        let d = try await esbuild().lint(codigo, file: "a.tsx")
        #expect(d.contains { $0.kind == .error }, "esbuild não reportou a vírgula faltando: \(d)")
        #expect(d.first?.line != nil, "o erro veio sem linha, então não dá para apontar na tela")
    }

    @Test func chaveQueNaoFechaEmTS() async throws {
        let d = try await esbuild().lint("function f() {\n  return 1;\n", file: "a.ts")
        #expect(d.contains { $0.kind == .error }, "esbuild não reportou a chave aberta: \(d)")
    }

    @Test func codigoValidoNaoAcusaNada() async throws {
        let codigo = """
        type A = { n: number };
        export const f = (a: A): number => a.n + 1;
        """
        let d = try await esbuild().lint(codigo, file: "a.ts")
        #expect(!d.contains { $0.kind == .error }, "acusou erro em TS válido: \(d)")
    }
}
