import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI

/// O bloco do histórico local nos Ajustes: quanto ocupa, até quanto pode ocupar, e o
/// botão de jogar tudo fora.
struct HistoricoLocalAjustes: View {
    @State private var usado: Int?
    @State private var teto = HistoricoLocal.compartilhado.teto
    @State private var confirmando = false

    static let tetos = [100_000_000, 300_000_000, 1_000_000_000]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(tr("Histórico local"))
            CardList {
                CardRow(tr("Espaço usado"), symbol: "clock", color: .indigo, first: true) {
                    if let usado {
                        Text(Tamanho.arquivo(usado)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                CardRow(tr("Limite"), symbol: "internaldrive", color: .indigo) {
                    Picker("", selection: $teto) {
                        ForEach(Self.tetos, id: \.self) { Text(Tamanho.arquivo($0)).tag($0) }
                    }
                    .labelsHidden()
                    .onChange(of: teto) { _, novo in
                        HistoricoLocal.compartilhado.teto = novo
                        Task { await medir() }
                    }
                }
                CardRow(tr("Limpar histórico"), symbol: "trash", color: .red) {
                    Button(tr("Limpar"), role: .destructive) { confirmando = true }
                        .disabled(usado == 0)
                }
            }
            CardNote(tr(
                // swiftlint:disable:next line_length
                "Antes de um arquivo ser salvo por cima, mudado pelo agente, pelo git ou pelo terminal, ou apagado, a Odete guarda como ele estava: até 50 versões por arquivo, por 30 dias. Fica só neste aparelho, fora do projeto — não vai para o iCloud nem para o git. Para ver, toque e segure a aba ou o arquivo na árvore."
            ))
        }
        .task { await medir() }
        .confirmationDialog(
            tr("Apagar todas as versões guardadas de todos os projetos?"),
            isPresented: $confirmando,
            titleVisibility: .visible
        ) {
            Button(tr("Limpar histórico"), role: .destructive) {
                HistoricoLocal.compartilhado.limpar()
                usado = 0
            }
        }
    }

    func medir() async {
        usado = await Task.detached { HistoricoLocal.compartilhado.tamanhoUsado() }.value
    }
}
