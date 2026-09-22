import CryptoKit
import Darwin
import Foundation
@testable import OdeteNpm
import Synchronization
import Testing

/// Pegada de memória do processo, lida do kernel. É o número que o jetsam do iPad olha.
func pegadaDoProcesso() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int(info.phys_footprint) : 0
}

/// Devolve ao sistema as páginas livres do alocador. Sem isto, o que a montagem do
/// cenário alocou e soltou fica guardado e é reaproveitado pelo install, e a pegada não
/// cresce por mais que ele aloque.
func devolverMemoriaLivre() {
    malloc_zone_pressure_relief(nil, 0)
}

/// Lê a pegada de tempos em tempos numa thread própria e guarda o maior valor visto.
final class Amostrador: Sendable {
    private let estado = Mutex<(ligado: Bool, pico: Int)>((true, 0))

    init() {
        Thread.detachNewThread { [self] in
            while estado.withLock({ $0.ligado }) {
                let agora = pegadaDoProcesso()
                estado.withLock { $0.pico = max($0.pico, agora) }
                usleep(1000)
            }
        }
    }

    func parar() -> Int {
        estado.withLock {
            $0.ligado = false
            return $0.pico
        }
    }
}

final class Marca: Sendable {
    let instante = Mutex<ContinuousClock.Instant?>(nil)
}

func ms(_ d: Duration) -> Int64 {
    d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
}

/// Conteúdo que comprime mais ou menos como código de verdade: palavras repetidas com
/// números no meio. Aleatório puro não comprime e texto repetido comprime demais.
func conteudo(_ bytes: Int, semente: UInt64) -> String {
    var x = semente &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    let palavras = ["function", "return", "const", "export", "module", "require", "value", "this", "=>", "{", "}"]
    var s = ""
    s.reserveCapacity(bytes + 16)
    while s.utf8.count < bytes {
        x = x &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        s += palavras[Int(x >> 60) % palavras.count]
        s += " v\(x >> 40 & 0xFFFF);\n"
    }
    return s
}

/// Resumo do que foi parar no disco: caminho, tamanho e hash de cada arquivo. Dois
/// installs que extraem os mesmos arquivos dão o mesmo resumo.
func resumoDoDisco(_ raiz: URL) -> (arquivos: Int, bytes: Int, hash: String) {
    let base = raiz.resolvingSymlinksInPath().path
    var linhas: [String] = []
    var bytes = 0
    let e = FileManager.default.enumerator(atPath: base)
    while let rel = e?.nextObject() as? String {
        let caminho = base + "/" + rel
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: caminho, isDirectory: &isDir), !isDir.boolValue,
              let d = FileManager.default.contents(atPath: caminho) else { continue }
        bytes += d.count
        let perm = ((try? FileManager.default.attributesOfItem(atPath: caminho))?[.posixPermissions] as? Int) ?? 0
        linhas.append("\(rel) \(d.count) \(String(perm, radix: 8)) \(SHA256.hash(data: d).description)")
    }
    let tudo = linhas.sorted().joined(separator: "\n")
    return (linhas.count, bytes, String(SHA256.hash(data: Data(tudo.utf8)).description.suffix(16)))
}

/// Mede o install num projeto grande de mentira: 120 pacotes com tarballs de 50 a 600 kB,
/// alguns aninhados por conflito de versão, e rede fake com latência variável.
///
/// Serve de referência para o pico de memória: antes do pipeline, todos os tarballs
/// ficavam na memória até o último chegar, e a extração ainda copiava o conteúdo três
/// vezes. O teste falha se o pico voltar a crescer com o tamanho da instalação.
@Suite(.serialized)
struct MedicaoTests {
    static let total = 120

    func registroGrande() -> (FakeRegistry, deps: [String: String], comprimido: Int) {
        let r = FakeRegistry()
        var deps = ["comum": "^2.0.0"]
        r.add("comum", "1.0.0", files: ["index.js": conteudo(20000, semente: 1)], latest: false)
        r.add("comum", "2.0.0", files: ["index.js": conteudo(20000, semente: 2)])
        for i in 0 ..< Self.total {
            let nome = String(format: "pkg-%03d", i)
            let tamanho = 50000 + (i * 7919) % 550_000
            r.add(
                nome,
                "1.0.\(i % 3)",
                deps: i % 10 == 0 ? ["comum": "^1.0.0"] : [:],
                files: [
                    "index.js": "module.exports = require('./lib/dados.js');",
                    "lib/dados.js": conteudo(tamanho, semente: UInt64(i + 10)),
                    "README.md": conteudo(2000, semente: UInt64(i + 1000)),
                ]
            )
            deps[nome] = "^1.0.0"
        }
        // Rede: de 2 a 40 ms por tarball, sempre o mesmo atraso para a mesma URL.
        r.latencia = { chave in
            var h: UInt64 = 1_469_598_103_934_665_603
            for b in chave.utf8 {
                h = (h ^ UInt64(b)) &* 1_099_511_628_211
            }
            return .milliseconds(chave.hasPrefix("fake://") ? 2 + Int(h % 39) : 3)
        }
        let comprimido = r.tarballs.values.reduce(0) { $0 + $1.count }
        return (r, deps, comprimido)
    }

    @Test func picoDeMemoriaNaoCresceComOTamanhoDaInstalacao() async throws {
        let (reg, deps, comprimido) = registroGrande()
        let dir = try project(deps)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Marca a hora em que a resolução acaba: é quando o install anuncia os downloads.
        let fimDaResolucao = Marca()
        var inst = Installer(project: dir, registry: reg) { linha in
            if linha.hasPrefix("baixando") {
                fimDaResolucao.instante.withLock { $0 = .now }
            }
        }
        let medidor = MedidorDeMemoria()
        inst.medidor = medidor
        devolverMemoriaLivre()
        let antes = pegadaDoProcesso()
        let amostrador = Amostrador()
        let inicio = ContinuousClock.now
        let rep = try await inst.install()
        let tempo = ContinuousClock.now - inicio
        let resolucao = (fimDaResolucao.instante.withLock { $0 } ?? inicio) - inicio
        let picoProcesso = amostrador.parar() - antes
        #expect(rep.failed.isEmpty, "\(rep.failed)")
        #expect(rep.installed.count == Self.total + 1 + Self.total / 10)
        let disco = resumoDoDisco(dir.appending(path: "node_modules"))
        let maior = reg.tarballs.values.map(\.count).max() ?? 0
        print(
            "MEDICAO pacotes=\(rep.installed.count) comprimido=\(comprimido) descompactado=\(disco.bytes)",
            "arquivos=\(disco.arquivos) resumo=\(disco.hash) maiorTarball=\(maior)"
        )
        print(
            "MEDICAO picoMedidor=\(medidor.pico) picoProcesso=\(picoProcesso)",
            "tempoMs=\(ms(tempo)) resolucaoMs=\(ms(resolucao)) packuments=\(reg.hits.withLock { $0 })",
            "buscasSimultaneas=\(reg.simultaneas.withLock { $0.pico })"
        )
        let lock = try #require(Lockfile.load(dir.appending(path: "package-lock.json")))
        #expect(lock.packages["node_modules/pkg-010/node_modules/comum"]?.version == "1.0.0")
        #expect(lock.packages["node_modules/comum"]?.version == "2.0.0")
        // O que importa: o pico acompanha os poucos pacotes em voo, não a instalação
        // inteira. Seis em voo com folga para o buffer de descompressão de cada um.
        #expect(medidor.pico <= inst.concurrency * (maior + Tar.tamanhoDoPedaco))
        #expect(medidor.pico < comprimido / 3)
        #expect(medidor.atual == 0)
    }

    /// O pipeline novo contra a cópia do antigo, no mesmo processo e na mesma hora,
    /// alternando quem vai primeiro. Com a máquina carregada, é a única comparação de
    /// tempo que vale. De quebra, confere que os dois deixam os mesmos arquivos no disco.
    @Test func pipelineNovoContraOAntigo() async throws {
        let (reg, deps, _) = registroGrande()
        let base = try project(deps)
        defer { try? FileManager.default.removeItem(at: base) }
        var relatorio = Installer.Report()
        let arvore = try await Installer(project: base, registry: reg).resolve(
            pkg: PackageJSON(url: base.appending(path: "package.json")),
            lock: nil,
            pinned: [:],
            report: &relatorio
        )
        let trabalho = arvore.sorted { $0.key < $1.key }.map { (key: $0.key, url: $0.value.entry.resolved ?? "") }
        var tempos: (antigo: [Int64], novo: [Int64]) = ([], [])
        var medidores: (antigo: [Int], novo: [Int]) = ([], [])
        var pegadas: (antigo: [Int], novo: [Int]) = ([], [])
        var resumos = Set<String>()
        for rodada in 0 ..< 3 {
            for novo in rodada % 2 == 0 ? [false, true] : [true, false] {
                let dir = try project(deps)
                defer { try? FileManager.default.removeItem(at: dir) }
                let medidor = MedidorDeMemoria()
                devolverMemoriaLivre()
                let antes = pegadaDoProcesso()
                let amostrador = Amostrador()
                let inicio = ContinuousClock.now
                if novo {
                    var inst = Installer(project: dir, registry: reg)
                    inst.medidor = medidor
                    var rep = Installer.Report()
                    try await inst.materialize(arvore, report: &rep)
                    #expect(rep.failed.isEmpty, "\(rep.failed)")
                } else {
                    await ReferenciaAntiga.materializar(trabalho, projeto: dir, registro: reg, medidor: medidor)
                }
                let tempo = ms(ContinuousClock.now - inicio)
                let pegada = amostrador.parar() - antes
                if novo {
                    tempos.novo.append(tempo); medidores.novo.append(medidor.pico); pegadas.novo.append(pegada)
                } else {
                    tempos.antigo.append(tempo); medidores.antigo.append(medidor.pico); pegadas.antigo.append(pegada)
                }
                resumos.insert(resumoDoDisco(dir.appending(path: "node_modules")).hash)
            }
        }
        func mediana(_ v: [some BinaryInteger]) -> Int {
            Int(v.sorted()[v.count / 2])
        }
        print(
            "MEDICAO AB antigo: tempoMs=\(tempos.antigo) medidor=\(mediana(medidores.antigo))",
            "pegada=\(pegadas.antigo)"
        )
        print(
            "MEDICAO AB novo:   tempoMs=\(tempos.novo) medidor=\(mediana(medidores.novo))",
            "pegada=\(pegadas.novo)"
        )
        // Os mesmos arquivos, com o mesmo conteúdo e as mesmas permissões.
        #expect(resumos.count == 1, "\(resumos)")
        #expect(mediana(medidores.novo) * 3 < mediana(medidores.antigo))
    }
}
