import Synchronization

/// Conta quantos bytes o install segura ao mesmo tempo.
///
/// Não é a memória do processo — essa depende de alocador, de cache do sistema, de quem
/// mais roda junto. É a parte que o install controla: tarball baixado esperando vez,
/// buffer de descompressão. Justamente a que derrubava o app num `npm install` grande,
/// quando todos os tarballs ficavam na memória antes de o primeiro ser extraído. Com o
/// pico medido, o teste consegue dizer se isso voltou a acontecer.
final class MedidorDeMemoria: Sendable {
    private let estado = Mutex<(atual: Int, pico: Int)>((0, 0))

    func segurar(_ bytes: Int) {
        estado.withLock {
            $0.atual += bytes
            $0.pico = max($0.pico, $0.atual)
        }
    }

    func soltar(_ bytes: Int) {
        estado.withLock { $0.atual -= bytes }
    }

    var pico: Int {
        estado.withLock { $0.pico }
    }

    var atual: Int {
        estado.withLock { $0.atual }
    }
}
