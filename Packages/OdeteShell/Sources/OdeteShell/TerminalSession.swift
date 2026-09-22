import Foundation
import Observation
import OdeteI18n

public struct TermLine: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable { case input, out, err, ok, system }
    public var id: Int
    public var kind: Kind
    public var text: String
}

/// Saída do shell que chegou e ainda não foi para a tela.
///
/// O shell entrega a saída em pedaços, de qualquer fila, e cada pedaço virava uma `Task`
/// no ator principal — um `npm install` manda milhares. Cada uma dessas tarefas mexia em
/// `lines`, e cada mexida refazia a lista do terminal (até 5000 linhas), rolava até o fim
/// e varria a rolagem inteira atrás de um comando digitado. Aqui os pedaços se acumulam
/// sob uma trava, na ordem em que chegaram, e o primeiro de um lote agenda uma entrega só.
final class LoteDeSaida: @unchecked Sendable {
    private let trava = NSLock()
    private var pedacos: [(TermLine.Kind, String)] = []

    /// Guarda um pedaço. Devolve `true` quando ele abriu um lote novo — é quem chamou que
    /// agenda a entrega; os seguintes pegam carona nela.
    func por(_ kind: TermLine.Kind, _ text: String) -> Bool {
        trava.lock()
        defer { trava.unlock() }
        pedacos.append((kind, text))
        return pedacos.count == 1
    }

    /// Tira tudo o que está guardado, na ordem de chegada.
    func tirar() -> [(TermLine.Kind, String)] {
        trava.lock()
        defer { trava.unlock() }
        let tudo = pedacos
        pedacos = []
        return tudo
    }
}

/// Uma aba de terminal: linhas na tela, prompt, entrada, histórico e o comando em execução.
@MainActor
@Observable
public final class TerminalSession: Identifiable {
    public let id = UUID()
    public let shell: Shell
    public private(set) var lines: [TermLine] = []
    /// Sobe a cada vez que linhas entram na tela.
    ///
    /// A tela rolava para o fim quando `lines.count` mudava. No teto de 5000 linhas cada
    /// linha nova tira uma velha, a contagem para de mudar e a rolagem parava junto, em
    /// silêncio, bem quando a saída é longa. Um contador que só sobe não tem esse teto.
    public private(set) var versao = 0
    /// Há algum comando digitado na rolagem? O botão de mandar o último comando para o
    /// agente depende disto, e a barra do terminal fazia `lines.contains` na rolagem
    /// inteira a cada linha que chegava.
    public var temEntrada: Bool {
        entradas > 0
    }

    public var input = ""
    public private(set) var running: String?
    public private(set) var jobs: [Job] = []
    private var entradas = 0
    @ObservationIgnored private var seq = 0
    @ObservationIgnored private var histIndex: Int?
    private nonisolated let lote = LoteDeSaida()
    public var title: String {
        running ?? shell.prompt
    }

    /// Quanto a saída espera para ir à tela: um quadro, o suficiente para juntar a rajada
    /// e pouco para se perceber.
    static let intervaloDoLote: Duration = .milliseconds(16)
    /// Linhas guardadas na rolagem.
    public static let teto = 5000

    /// Avisado sempre que a lista de jobs muda, para quem está acima poder recolher as
    /// portas que morreram.
    public var aoMudarJobs: (@MainActor () -> Void)?

    public init(shell: Shell, banner: Bool = true) {
        self.shell = shell
        shell.onJobsChanged = { [weak self] in
            Task { @MainActor in
                self?.jobs = shell.jobs
                self?.aoMudarJobs?()
            }
        }
        if banner {
            append(.system, tr("Odete · shell no iPad. Digite help."))
        }
    }

    public func append(_ kind: TermLine.Kind, _ text: String) {
        acrescentar([(kind, text)])
    }

    /// Saída que chega do shell, de qualquer fila. Vai para a tela em lotes — ver
    /// `LoteDeSaida`.
    nonisolated func receber(_ kind: TermLine.Kind, _ text: String) {
        guard lote.por(kind, text) else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.intervaloDoLote)
            self?.descarregar()
        }
    }

    /// Põe na tela o que o lote juntou.
    func descarregar() {
        let pedacos = lote.tirar()
        guard !pedacos.isEmpty else { return }
        acrescentar(pedacos)
    }

    /// Acrescenta vários pedaços de uma vez: uma mudança só na lista, um aviso só.
    private func acrescentar(_ pedacos: [(TermLine.Kind, String)]) {
        var novas: [TermLine] = []
        for (kind, text) in pedacos {
            if text == "\u{1B}[clear]" {
                novas.removeAll()
                if !lines.isEmpty {
                    lines.removeAll()
                }
                entradas = 0
                continue
            }
            for part in text.split(separator: "\n", omittingEmptySubsequences: false) {
                seq += 1
                novas.append(TermLine(id: seq, kind: kind, text: String(part)))
            }
        }
        guard !novas.isEmpty else { return }
        let digitadas = novas.count(where: { $0.kind == .input })
        lines.append(contentsOf: novas)
        var saem = 0
        if lines.count > Self.teto {
            let sobra = lines.count - Self.teto
            saem = lines[..<sobra].count(where: { $0.kind == .input })
            lines.removeFirst(sobra)
        }
        if digitadas != saem {
            entradas += digitadas - saem
        }
        versao &+= 1
    }

    public var prompt: String {
        "odete \(shell.prompt) %"
    }

    public func submit() {
        let line = input
        input = ""
        histIndex = nil
        append(.input, "\(prompt) \(line)")
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        run(line)
    }

    public func run(_ line: String) {
        running = line
        let receber: @Sendable (TermLine.Kind, String) -> Void = { [weak self] kind, text in
            self?.receber(kind, text)
        }
        Task { [shell] in
            let code = await shell.run(line) { kind, text in
                receber(kind == .out ? .out : .err, text)
            }
            await MainActor.run {
                // O que ainda está no lote vem antes do código de saída, na ordem.
                self.descarregar()
                if code != 0, code != 130 {
                    self.append(.err, "exit \(code)")
                }
                self.running = nil
                self.jobs = shell.jobs
            }
        }
    }

    public func cancel() {
        shell.cancel()
        if running == nil, let j = shell.jobs.last {
            j.kill(); jobs = shell.jobs; aoMudarJobs?(); append(.system, "^C job \(j.id) parado")
        } else {
            append(
                .system,
                "^C"
            )
        }
    }

    public func historyUp() {
        let h = shell.history
        guard !h.isEmpty else { return }
        let i = (histIndex ?? h.count) - 1
        guard i >= 0 else { return }
        histIndex = i
        input = h[i]
    }

    public func historyDown() {
        let h = shell.history
        guard let i = histIndex else { return }
        if i + 1 < h.count {
            histIndex = i + 1; input = h[i + 1]
        } else {
            histIndex = nil; input = ""
        }
    }

    public func tab() {
        let parts = input.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard let last = parts.last else { return }
        let opts = shell.complete(last)
        if opts.count == 1 {
            input = (parts.dropLast() + [opts[0]]).joined(separator: " ")
        } else if opts.count > 1 {
            let common = opts.reduce(opts[0]) { String(zip($0, $1).prefix { $0 == $1 }.map(\.0)) }
            if common.count > last.count {
                input = (parts.dropLast() + [common]).joined(separator: " ")
            } else {
                append(
                    .system,
                    opts.joined(separator: "  ")
                )
            }
        }
    }

    public func clear() {
        lines.removeAll()
        entradas = 0
        versao &+= 1
    }
}
