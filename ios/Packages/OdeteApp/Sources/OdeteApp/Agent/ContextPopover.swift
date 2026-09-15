import OdeteAgent
import OdeteI18n
import OdeteUI
import SwiftUI

/// Barra de segmentos: cada pedaço é uma fatia do que ocupa a janela, e o resto
/// fica cinza. É a mesma leitura do detalhamento de contexto do app da Claude.
struct SegmentBar: View {
    @Environment(\.theme) private var theme
    var total: Int
    var fatias: [(label: String, valor: Int, cor: Color)]

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(Array(fatias.enumerated()), id: \.offset) { _, f in
                    if f.valor > 0 {
                        Capsule().fill(f.cor)
                            .frame(width: max(2, g.size.width * Double(f.valor) / Double(max(1, total))))
                    }
                }
                Capsule().fill(theme.fg.opacity(0.12))
            }
        }
        .frame(height: 6)
    }
}

/// Detalhamento da janela de contexto, aberto pelo indicador na barra de digitação.
struct ContextPopover: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel

    var usado: Int {
        max(agent.thread.lastInput, agent.estimatedTokens)
    }

    var pct: Int {
        Int((Double(usado) / Double(max(1, agent.contextWindow)) * 100).rounded())
    }

    var uso: TokenUse {
        agent.thread.usage
    }

    var body: some View {
        ScrollPane {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(tr("Janela de contexto")).font(.subheadline.weight(.semibold))
                            .foregroundStyle(theme.fg)
                        Spacer(minLength: 8)
                        Text("\(fmtTok(usado)) / \(fmtTok(agent.contextWindow)) (\(pct)%)")
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    SegmentBar(total: agent.contextWindow, fatias: [
                        ("Conversa", max(0, usado - uso.cache), theme.accent),
                        ("Cache", min(uso.cache, usado), .purple),
                    ])
                    Text(agent.contextWindow > 0
                        ? tr("Quando encher, os turnos mais antigos saem da conversa.")
                        : tr("Conecte uma conta para saber o tamanho da janela."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(tr("Esta conversa"))
                    CardList {
                        linha("Entrada", symbol: "arrow.down.to.line", cor: .blue, valor: uso.input, first: true)
                        linha(tr("Saída"), symbol: "arrow.up.to.line", cor: .green, valor: uso.output)
                        linha("Cache", symbol: "bolt.horizontal", cor: .purple, valor: uso.cache)
                        if uso.reasoning > 0 {
                            linha(tr("Raciocínio"), symbol: "brain", cor: .orange, valor: uso.reasoning)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(tr("Último turno"))
                    CardList {
                        linha(
                            "Entrada",
                            symbol: "arrow.down.to.line",
                            cor: .blue,
                            valor: agent.lastTurnUse.input,
                            first: true
                        )
                        linha(tr("Saída"), symbol: "arrow.up.to.line", cor: .green, valor: agent.lastTurnUse.output)
                    }
                }
            }
            .padding(16)
        }
        .frame(idealWidth: 320, idealHeight: 470)
        .background(theme.surface)
    }

    func linha(_ label: String, symbol: String, cor: Color, valor: Int, first: Bool = false) -> some View {
        CardRow(label, symbol: symbol, color: cor, first: first) {
            Text(fmtTok(valor)).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        }
    }
}

/// Indicador de contexto: anel preenchido e o percentual, como o da barra de digitação
/// da Claude. Toque abre o detalhamento.
struct ContextGauge: View {
    @Environment(\.theme) private var theme
    var fracao: Double
    var mostrarTexto = true

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(theme.fg.opacity(0.16), lineWidth: 2.5)
                Circle().trim(from: 0, to: max(0.02, min(1, fracao)))
                    .stroke(
                        fracao > 0.85 ? theme.danger : theme.accent,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
            if mostrarTexto {
                Text(tr("%1$@%%", "\(Int((fracao * 100).rounded()))"))
                    .font(.caption).monospacedDigit().foregroundStyle(theme.fgMuted)
            }
        }
        .contentShape(Rectangle())
    }
}
