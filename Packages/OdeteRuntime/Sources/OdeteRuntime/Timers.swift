import Foundation

/// Os timers JS de um runtime (setTimeout, setInterval, setImmediate) num único DispatchSource.
///
/// Antes cada timer tinha o seu DispatchSource, sem folga: criar e cancelar um por `setTimeout`
/// custa registro no kernel, e `setInterval(fn, 0)` virava uma repetição de 0 ns que prendia a
/// fila. Aqui os prazos ficam num heap e um só relógio é armado para o mais próximo, com uma
/// folga proporcional ao atraso (o sistema junta despertares). A ordem é a do Node: prazo menor
/// primeiro e, no empate, quem foi criado antes; o que é criado durante uma rodada de disparos
/// fica para a próxima. Tudo roda na fila do runtime.
final class AgendaDeTimers {
    private struct Timer {
        var ordem: Int
        var intervalo: UInt64 // ns; 0 = setImmediate
        var repete: Bool
    }

    /// (prazo, ordem, id). Entradas de timers cancelados ficam até vencer ou até a faxina.
    private struct Entrada {
        var prazo: UInt64
        var ordem: Int
        var id: Int
        func antes(de o: Entrada) -> Bool {
            prazo != o.prazo ? prazo < o.prazo : ordem < o.ordem
        }
    }

    private let queue: DispatchQueue
    private var timers: [Int: Timer] = [:]
    private var heap: [Entrada] = []
    private var relogio: DispatchSourceTimer?
    private var armadoPara: UInt64 = .max
    private var disparando = false
    private var proximoId = 1
    private var proximaOrdem = 0

    /// Chamado para cada timer vencido, na ordem; `terminou` diz se era o último disparo dele.
    var aoDisparar: ((_ id: Int, _ terminou: Bool) -> Void)?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    var vivos: Int {
        timers.count
    }

    /// O timer ainda está agendado (não disparou por último nem foi cancelado)?
    func existe(_ id: Int) -> Bool {
        timers[id] != nil
    }

    /// Agenda um timer. `ms <= 0` (setImmediate, setTimeout de 0) roda na próxima volta da fila,
    /// na ordem de criação; um intervalo nunca repete em menos de 1 ms.
    func agendar(ms: Double, repete: Bool) -> Int {
        let id = proximoId
        proximoId += 1
        var atraso = ms.isFinite && ms > 0 ? UInt64(ms * 1_000_000) : 0
        if repete {
            atraso = max(atraso, 1_000_000)
        }
        let ordem = proximaOrdem
        proximaOrdem += 1
        timers[id] = Timer(ordem: ordem, intervalo: atraso, repete: repete)
        empurra(Entrada(prazo: DispatchTime.now().uptimeNanoseconds + atraso, ordem: ordem, id: id))
        if !disparando {
            rearmar()
        }
        return id
    }

    /// Cancela; devolve se o timer existia (quem chama equilibra o trabalho pendente).
    func cancelar(_ id: Int) -> Bool {
        guard timers.removeValue(forKey: id) != nil else { return false }
        // Heap cheio de cancelados (debounce, timeouts de requisição): refaz só com os vivos.
        if heap.count > 64, heap.count > 2 * timers.count {
            let vivas = heap.filter { timers[$0.id]?.ordem == $0.ordem }
            heap = []
            vivas.forEach(empurra)
        }
        return true
    }

    func cancelarTodos() {
        timers.removeAll()
        heap.removeAll()
        relogio?.cancel()
        relogio = nil
        armadoPara = .max
    }

    // MARK: disparo

    private func disparar() {
        armadoPara = .max
        disparando = true
        let agora = DispatchTime.now().uptimeNanoseconds
        // Só roda quem já existia ao entrar: setImmediate criado dentro de um callback fica para
        // a próxima volta, e um intervalo reagendado aqui não roda duas vezes seguidas.
        let limite = proximaOrdem
        while let topo = heap.first, topo.prazo <= agora {
            guard var t = timers[topo.id], t.ordem == topo.ordem else {
                tiraTopo() // cancelado ou já reagendado
                continue
            }
            if t.ordem >= limite {
                break // criado nesta volta; o que vence junto com ele também foi
            }
            tiraTopo()
            if t.repete {
                t.ordem = proximaOrdem
                proximaOrdem += 1
                timers[topo.id] = t
                empurra(Entrada(prazo: agora + t.intervalo, ordem: t.ordem, id: topo.id))
            } else {
                timers[topo.id] = nil
            }
            aoDisparar?(topo.id, !t.repete)
        }
        disparando = false
        rearmar()
    }

    private func rearmar() {
        // Descarta do topo o que já foi cancelado, para não acordar à toa.
        while let topo = heap.first, timers[topo.id]?.ordem != topo.ordem {
            tiraTopo()
        }
        guard let topo = heap.first else { return }
        if topo.prazo >= armadoPara {
            return
        }
        armadoPara = topo.prazo
        let r = relogio ?? criarRelogio()
        // Folga de 10% do atraso, até 50 ms: dá ao sistema margem para juntar despertares sem
        // atrasar de forma perceptível timers curtos (1 ms ganha 0,1 ms).
        let intervalo = timers[topo.id]?.intervalo ?? 0
        let folga = min(intervalo / 10, 50_000_000)
        r.schedule(
            deadline: DispatchTime(uptimeNanoseconds: topo.prazo),
            repeating: .never,
            leeway: .nanoseconds(Int(folga))
        )
    }

    private func criarRelogio() -> DispatchSourceTimer {
        let r = DispatchSource.makeTimerSource(queue: queue)
        r.setEventHandler { [weak self] in self?.disparar() }
        r.resume()
        relogio = r
        return r
    }

    // MARK: heap binário mínimo

    private func empurra(_ e: Entrada) {
        heap.append(e)
        var i = heap.count - 1
        while i > 0 {
            let pai = (i - 1) / 2
            guard heap[i].antes(de: heap[pai]) else { break }
            heap.swapAt(i, pai)
            i = pai
        }
    }

    private func tiraTopo() {
        let ultimo = heap.removeLast()
        guard !heap.isEmpty else { return }
        heap[0] = ultimo
        var i = 0
        while true {
            let e = 2 * i + 1, d = e + 1
            var menor = i
            if e < heap.count, heap[e].antes(de: heap[menor]) {
                menor = e
            }
            if d < heap.count, heap[d].antes(de: heap[menor]) {
                menor = d
            }
            if menor == i {
                break
            }
            heap.swapAt(i, menor)
            i = menor
        }
    }
}
