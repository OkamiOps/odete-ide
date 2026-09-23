import Darwin
import Foundation
import OdeteI18n
@testable import OdeteShell
import Synchronization
import Testing

/// Sonda: o `tsc` de verdade, o language service do TypeScript e o vitest rodam no motor
/// da Odete? Quanto custam?
///
/// Só roda com `ODETE_ESPIKE=1` (no xcodebuild: `TEST_RUNNER_ODETE_ESPIKE=1`) e com
/// `ODETE_ESPIKE_DIR` apontando para a pasta dos projetos de teste, montados fora do
/// repositório com o npm do Mac (`app/`: Vite + React + TS 6 com um erro de tipo proposital
/// em `src/components/Counter.tsx:6`; `vt/`: vitest com três arquivos de teste). Nada aqui
/// usa a rede. Sem JIT (`TEST_RUNNER_JSC_useJIT=false`) é o número que vale: é o que o iPad
/// impõe a apps de terceiros. Imprime linhas `ESPIKE`.
@Suite(.serialized) struct EspikeTypeScriptTests {
    static let ambiente = ProcessInfo.processInfo.environment
    static let ligado = ambiente["ODETE_ESPIKE"] == "1" && ambiente["ODETE_ESPIKE_DIR"] != nil
    static var pasta: URL {
        URL(fileURLWithPath: ambiente["ODETE_ESPIKE_DIR"] ?? "/nao-existe", isDirectory: true)
    }

    static var app: URL {
        pasta.appending(path: "app")
    }

    init() {
        Texto.escolher(.ptBR)
    }

    /// Roda uma linha no shell da Odete (o mesmo caminho do terminal) e imprime o custo.
    /// Passado o `limite`, cancela como o Ctrl+C do terminal.
    @discardableResult
    func medir(_ nome: String, _ linha: String, em raiz: URL, limite: Duration = .seconds(300)) async -> (Int32, Out) {
        let sh = Shell(root: raiz)
        let o = Out()
        devolverMemoriaLivre()
        let antes = pegada()
        let amostras = AmostradorDePegada()
        let vigia = Task {
            try? await Task.sleep(for: limite)
            if !Task.isCancelled {
                print("ESPIKE \(nome): passou de \(limite), cancelando")
                sh.cancel()
            }
        }
        let c0 = cpuDoProcesso()
        let t0 = ContinuousClock.now
        let codigo = await sh.run(linha, sink: o.sink)
        let d = ContinuousClock.now - t0
        let cpu = cpuDoProcesso() - c0
        vigia.cancel()
        let pico = amostras.parar()
        let parede = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        let mb = { (b: Int) in String(format: "%.0f", Double(b) / 1_048_576) }
        print(String(
            format: "ESPIKE %@ jit=%@ parede=%.2fs cpu=%.2fs pegada-antes=%@MB pico=%@MB (+%@MB) codigo=%d",
            nome, Self.ambiente["JSC_useJIT"] ?? "padrao", parede, cpu, mb(antes), mb(pico), mb(pico - antes), codigo
        ))
        let texto = o.lines.withLock { $0.map { ($0.0 == .err ? "ERR " : "") + $0.1 } }
        for linha in texto.joined(separator: "\n").split(separator: "\n", omittingEmptySubsequences: false).prefix(80) {
            print("ESPIKE   | \(linha)")
        }
        return (codigo, o)
    }

    /// Para investigar: roda `ODETE_ESPIKE_CMD` na subpasta `ODETE_ESPIKE_CWD` (padrão `app`).
    @Test(.enabled(if: ligado && ambiente["ODETE_ESPIKE_CMD"] != nil)) func comandoAvulso() async {
        await medir(
            "avulso", Self.ambiente["ODETE_ESPIKE_CMD"] ?? "",
            em: Self.pasta.appending(path: Self.ambiente["ODETE_ESPIKE_CWD"] ?? "app"), limite: .seconds(120)
        )
    }

    // MARK: - tsc

    @Test(.enabled(if: ligado)) func tscNoProjeto() async {
        let (codigo, o) = await medir("tsc-projeto", "npx tsc --noEmit -p .", em: Self.app)
        #expect(codigo == 2, Comment(rawValue: o.err))
        // Com NO_COLOR o tsc sai do modo "pretty" (cores ANSI, que o terminal mostraria cruas).
        #expect(
            o.out.contains("src/components/Counter.tsx(6,9): error TS2322"),
            Comment(rawValue: o.out + o.err)
        )
    }

    /// As fases do próprio tsc (parse, bind, check) medidas por ele mesmo.
    @Test(.enabled(if: ligado)) func tscFases() async {
        await medir("tsc-fases", "npx tsc --noEmit -p . --extendedDiagnostics --pretty false", em: Self.app)
    }

    /// Um arquivo só, sem tsconfig: o custo mínimo (a lib padrão, com o DOM, ainda entra).
    @Test(.enabled(if: ligado)) func tscUmArquivo() async {
        let (codigo, o) = await medir(
            "tsc-um-arquivo", "npx tsc --noEmit --ignoreConfig src/lib/format.ts", em: Self.app
        )
        #expect(codigo == 0, Comment(rawValue: o.out + o.err))
    }

    /// Um arquivo só, com a lib mínima (sem DOM).
    @Test(.enabled(if: ligado)) func tscUmArquivoSemDOM() async {
        let (codigo, o) = await medir(
            "tsc-um-arquivo-es2023",
            "npx tsc --noEmit --ignoreConfig --lib es2023 --target es2023 src/lib/format.ts",
            em: Self.app
        )
        #expect(codigo == 0, Comment(rawValue: o.out + o.err))
    }

    // MARK: - language service

    /// O que diagnóstico de tipos no editor custaria: um LanguageService vivo, e o tempo de
    /// `getSyntacticDiagnostics` + `getSemanticDiagnostics` de um arquivo depois de cada edição.
    @Test(.enabled(if: ligado)) func languageService() async throws {
        let script = Self.app.appending(path: ".odete-espike-ls.cjs")
        try Self.scriptDoLanguageService.write(to: script, atomically: true, encoding: .utf8)
        let (codigo, o) = await medir("language-service", "node .odete-espike-ls.cjs", em: Self.app)
        #expect(codigo == 0, Comment(rawValue: o.out + o.err))
        #expect(o.out.contains("ESPIKE ls-primeiro-diagnostico"), Comment(rawValue: o.out + o.err))
    }

    static let scriptDoLanguageService = #"""
    const agora = () => performance.now();
    const linha = (nome, ms, extra = "") => console.log(`ESPIKE ${nome} ${ms.toFixed(0)} ms ${extra}`);
    const mediana = (a) => [...a].sort((x, y) => x - y)[a.length >> 1];
    let t = agora();
    const ts = require("typescript");
    linha("ls-require-typescript", agora() - t, ts.version);
    const fs = require("fs"), path = require("path");
    const cwd = process.cwd();
    t = agora();
    const cfg = ts.getParsedCommandLineOfConfigFile(path.join(cwd, "tsconfig.json"), {}, {
      ...ts.sys,
      onUnRecoverableConfigFileDiagnostic: (d) => { throw new Error(ts.flattenDiagnosticMessageText(d.messageText, "\n")); },
    });
    const docs = new Map();
    for (const f of cfg.fileNames) docs.set(f, { v: 0, texto: fs.readFileSync(f, "utf8") });
    const host = {
      getScriptFileNames: () => [...docs.keys()],
      getScriptVersion: (f) => String(docs.has(f) ? docs.get(f).v : 0),
      getScriptSnapshot: (f) => {
        const d = docs.get(f);
        if (d) return ts.ScriptSnapshot.fromString(d.texto);
        const s = ts.sys.readFile(f);
        return s === undefined ? undefined : ts.ScriptSnapshot.fromString(s);
      },
      getCurrentDirectory: () => cwd,
      getCompilationSettings: () => cfg.options,
      getDefaultLibFileName: (o) => ts.getDefaultLibFilePath(o),
      fileExists: ts.sys.fileExists, readFile: ts.sys.readFile, readDirectory: ts.sys.readDirectory,
      directoryExists: ts.sys.directoryExists, getDirectories: ts.sys.getDirectories, realpath: ts.sys.realpath,
      useCaseSensitiveFileNames: () => ts.sys.useCaseSensitiveFileNames,
    };
    const ls = ts.createLanguageService(host, ts.createDocumentRegistry());
    linha("ls-criar", agora() - t, cfg.fileNames.length + " arquivos");
    const diag = (f) => [...ls.getSyntacticDiagnostics(f), ...ls.getSemanticDiagnostics(f)];
    const mostra = (ds) => ds.map((d) => {
      const p = d.file ? d.file.getLineAndCharacterOfPosition(d.start) : { line: -1, character: -1 };
      return `${d.file ? path.relative(cwd, d.file.fileName) : "?"}(${p.line + 1},${p.character + 1}) TS${d.code}`;
    }).join("; ");
    const alvo = path.join(cwd, "src/components/Counter.tsx");
    t = agora();
    const d0 = diag(alvo);
    linha("ls-primeiro-diagnostico", agora() - t, mostra(d0));
    // Cada volta é uma pausa na digitação: o texto muda, a versão sobe, o editor pede os
    // diagnósticos do arquivo aberto.
    const base = docs.get(alvo).texto;
    const tempos = [];
    for (let i = 0; i < 9; i++) {
      const d = docs.get(alvo);
      d.texto = base.replace("times", "vezes" + i);
      d.v++;
      const t2 = agora();
      diag(alvo);
      tempos.push(agora() - t2);
    }
    linha("ls-edicao-mesmo-arquivo-mediana", mediana(tempos), "min " + Math.min(...tempos).toFixed(0) + " max " + Math.max(...tempos).toFixed(0));
    // Editar um arquivo de que os outros dependem e pedir os diagnósticos de quem importa.
    const lib = path.join(cwd, "src/lib/todos.ts"), app = path.join(cwd, "src/App.tsx");
    const baseLib = docs.get(lib).texto;
    const tempos2 = [];
    for (let i = 0; i < 5; i++) {
      const d = docs.get(lib);
      d.texto = baseLib.replace("open: number;", "open: number; extra" + i + "?: string;");
      d.v++;
      const t2 = agora();
      diag(app);
      tempos2.push(agora() - t2);
    }
    linha("ls-edicao-dependencia-mediana", mediana(tempos2));
    // O painel de problemas: todos os arquivos depois de uma edição.
    docs.get(alvo).v++;
    t = agora();
    let n = 0;
    for (const f of docs.keys()) n += diag(f).length;
    linha("ls-projeto-inteiro-apos-edicao", agora() - t, n + " diagnosticos");
    // Autocompletar no meio do arquivo editado.
    const pos = base.indexOf("setN((x)") + 4;
    t = agora();
    const c = ls.getCompletionsAtPosition(alvo, pos, {});
    linha("ls-completions", agora() - t, (c ? c.entries.length : 0) + " entradas");
    """#

    // MARK: - vitest

    /// O vitest de verdade, chamado pelo caminho dele (o `npx vitest` agora é o embutido),
    /// com cada pool. O que ele escrever (ou não) é o resultado.
    @Test(.enabled(if: ligado), arguments: [
        "",
        "--pool=threads",
        "--pool=vmThreads",
        "--pool=threads --no-isolate --no-file-parallelism --maxWorkers=1",
    ])
    func vitestDeVerdade(_ opcoes: String) async {
        await medir(
            "vitest-real[\(opcoes)]", "node node_modules/vitest/vitest.mjs run \(opcoes)",
            em: Self.pasta.appending(path: "vt"), limite: .seconds(120)
        )
    }

    /// O executor embutido nos mesmos três arquivos.
    @Test(.enabled(if: ligado)) func vitestEmbutido() async {
        let (codigo, o) = await medir("vitest-embutido", "npx vitest run", em: Self.pasta.appending(path: "vt"))
        #expect(codigo == 1, Comment(rawValue: o.out + o.err))
        #expect(o.out.contains("Tests  1 failed | 10 passed (11)"), Comment(rawValue: o.out + o.err))
    }
}

/// Pegada de memória do processo, lida do kernel. É o número que o jetsam do iPad olha.
private func pegada() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Devolve ao sistema as páginas livres do alocador, para a pegada de antes não esconder
/// o que a medida vai alocar.
private func devolverMemoriaLivre() {
    malloc_zone_pressure_relief(nil, 0)
}

/// CPU do processo inteiro (usuário + sistema), em segundos: inclui as threads do coletor.
private func cpuDoProcesso() -> Double {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
}

/// Lê a pegada a cada 5 ms numa thread própria e guarda o maior valor visto.
private final class AmostradorDePegada: Sendable {
    private let estado = Mutex<(ligado: Bool, pico: Int)>((true, 0))

    init() {
        Thread.detachNewThread { [self] in
            while estado.withLock({ $0.ligado }) {
                let agora = pegada()
                estado.withLock { $0.pico = max($0.pico, agora) }
                usleep(5000)
            }
        }
    }

    func parar() -> Int {
        estado.withLock {
            $0.ligado = false
            return max($0.pico, pegada())
        }
    }
}
