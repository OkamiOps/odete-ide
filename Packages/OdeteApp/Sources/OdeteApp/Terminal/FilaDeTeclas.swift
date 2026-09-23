import Foundation
import SwiftUI

/// Põe o Tab do terminal na ordem das letras digitadas antes dele.
///
/// O `onKeyPress` dispara quando a tecla desce, antes do sistema de texto, e o sistema
/// insere as teclas numa fila própria, que pode estar atrasada — no compositor, "turno um"
/// + Enter chegou a enviar "Turno" com o "um" ainda na fila. No terminal, `npm ru` + Tab
/// digitados rápido completavam `npm r`, e o "u" caía depois, no fim do texto completado.
/// O Tab não pode ir pela fila do texto como o Enter do compositor foi: num `TextField` o
/// Tab de teclado físico muda o foco em vez de inserir "\t".
///
/// Então cada tecla que produz texto é anotada quando desce, e riscada quando o texto dela
/// chega ao campo (o `set` do binding, uma chamada por edição, na ordem). O Tab entra na
/// mesma fila: com nada pendente roda na hora, como antes; com letras a caminho, roda
/// assim que a última delas chega.
///
/// Uma anotação que não é riscada em `validade` sai da fila: tecla que não mexeu no texto
/// (apagar sem nada antes do cursor, tecla morta). Sem prazo, ela seguraria o Tab para
/// sempre; com ele, o pior caso é o Tab esperar esse tanto.
@MainActor
final class FilaDeTeclas {
    enum Entrada {
        case texto(desceuEm: TimeInterval)
        case acao(() -> Void)
    }

    private(set) var fila: [Entrada] = []
    var relogio: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Quem acorda a fila quando o prazo das anotações vence, para um Tab à espera não
    /// depender de outra tecla chegar. Os testes trocam por nada e chamam `drenar`.
    var agendar: (TimeInterval, @escaping @MainActor () -> Void) -> Void = { atraso, bloco in
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(atraso))
            bloco()
        }
    }

    /// A fila de teclas anda em milissegundos; meio segundo sem chegar é tecla que não vai
    /// chegar.
    static let validade: TimeInterval = 0.5

    var pendentes: Int {
        fila.count(where: { if case .texto = $0 { true } else { false } })
    }

    /// A tecla que desceu vai virar texto no campo? Letras, números, pontuação, espaço e
    /// apagar (se há o que apagar). Não: Tab, Enter, Esc, setas e teclas de função (os
    /// caracteres de uso privado do UIKit), nem atalhos com command ou control.
    nonisolated static func produzTexto(caracteres: String, modificadores: EventModifiers, temTexto: Bool) -> Bool {
        guard !caracteres.isEmpty, modificadores.isDisjoint(with: [.command, .control]) else { return false }
        if caracteres == "\u{7F}" || caracteres == "\u{8}" {
            return temTexto
        }
        return caracteres.unicodeScalars.allSatisfy { s in
            s.value >= 0x20 && s.value != 0x7F && !(0xF700 ... 0xF8FF).contains(s.value)
        }
    }

    func desceuTexto() {
        fila.append(.texto(desceuEm: relogio()))
    }

    /// Chegou ao campo o texto de uma tecla: risca a mais antiga e roda o que esperava por ela.
    func chegouTexto() {
        if let i = fila.firstIndex(where: { if case .texto = $0 { true } else { false } }) {
            fila.remove(at: i)
        }
        drenar()
    }

    /// Roda `acao` depois do texto de todas as teclas que desceram antes dela — na hora,
    /// se não há nenhuma a caminho.
    func depoisDoTexto(_ acao: @escaping () -> Void) {
        // Primeiro o que já podia ter rodado: um Tab de antes, preso atrás de uma tecla que
        // acabou de vencer, vem antes deste.
        drenar()
        guard !fila.isEmpty else {
            acao()
            return
        }
        fila.append(.acao(acao))
        agendar(Self.validade) { [weak self] in self?.drenar() }
    }

    /// Roda as ações da frente da fila até a próxima tecla ainda a caminho.
    func drenar() {
        descartarVencidas()
        while case let .acao(acao)? = fila.first {
            fila.removeFirst()
            acao()
            descartarVencidas()
        }
    }

    private func descartarVencidas() {
        let agora = relogio()
        fila.removeAll { e in
            if case let .texto(t) = e {
                return agora - t >= Self.validade
            }
            return false
        }
    }
}
