import Foundation
import Synchronization

/// Segura o texto que chega ficha a ficha e entrega no máximo umas dezesseis vezes por
/// segundo.
///
/// O laço mandava a resposta inteira a cada pedacinho que o provedor soltava. Cada envio
/// copiava o texto acumulado, a conversa trocava o item, a lista refazia os grupos, rolava
/// até o fim e o Markdown reinterpretava a mensagem toda — tudo isso por ficha. Numa
/// resposta de dez mil caracteres são milhares de cópias do tamanho da resposta: trabalho
/// quadrático, e uma tela que engasga justamente quando o agente está escrevendo.
///
/// Aqui cada item pendente guarda só *como* gerar o que vai para a tela; o texto é lido
/// na hora de entregar. Entre uma entrega e outra, o acúmulo cresce no lugar, sem cópia.
final class Vazao: @unchecked Sendable {
    let intervalo: Duration
    private let emitir: @Sendable (LoopEvent) -> Void
    private struct Estado {
        var pendentes: [(id: String, gerar: @Sendable () -> ChatItem)] = []
        var ultima: ContinuousClock.Instant?
    }

    private let estado = Mutex(Estado())

    init(intervalo: Duration = .milliseconds(60), emitir: @escaping @Sendable (LoopEvent) -> Void) {
        self.intervalo = intervalo
        self.emitir = emitir
    }

    /// Anota que o item `id` mudou. Se já faz tempo desde a última entrega, entrega agora
    /// — é o caso da primeira ficha, que aparece sem esperar.
    func marcar(_ id: String, _ gerar: @escaping @Sendable () -> ChatItem) {
        estado.withLock { st in
            if let i = st.pendentes.firstIndex(where: { $0.id == id }) {
                st.pendentes[i].gerar = gerar
            } else {
                st.pendentes.append((id, gerar))
            }
            let agora = ContinuousClock.now
            if st.ultima.map({ agora - $0 >= intervalo }) ?? true {
                entregar(&st, agora)
            }
        }
    }

    /// Chamado pelo relógio: entrega o que estiver pendente há tempo suficiente. Sem isto,
    /// a última frase antes de uma pausa longa — o modelo escrevendo os argumentos de uma
    /// ferramenta, por exemplo — ficaria presa até a próxima ficha.
    func tique() {
        estado.withLock { st in
            let agora = ContinuousClock.now
            if !st.pendentes.isEmpty, st.ultima.map({ agora - $0 >= intervalo }) ?? true {
                entregar(&st, agora)
            }
        }
    }

    /// Entrega tudo o que falta, já. Depois disto quem manda na ordem é o laço de novo.
    func esvaziar() {
        estado.withLock { st in
            entregar(&st, .now)
        }
    }

    /// Entrega sob a trava: o relógio e o `esvaziar` nunca intercalam, e o que sai por
    /// último é sempre o texto mais novo.
    private func entregar(_ st: inout Estado, _ agora: ContinuousClock.Instant) {
        for p in st.pendentes {
            emitir(.item(p.gerar()))
        }
        st.pendentes.removeAll()
        st.ultima = agora
    }
}
