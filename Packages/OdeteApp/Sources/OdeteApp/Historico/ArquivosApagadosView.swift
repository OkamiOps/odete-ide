import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI

/// Arquivos que sumiram do projeto e têm versões no histórico local — apagados pela
/// árvore, pelo `rm`, pelo git ou pelo agente —, cada um com Restaurar.
///
/// A lixeira do projeto guarda o que a árvore apagou por sete dias; esta lista vale para
/// o que sumiu por qualquer caminho, pelo tempo do histórico.
struct ArquivosApagadosView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    /// Só o que estava dentro desta pasta; "" é o projeto todo.
    var pasta: String
    @State private var itens: [HistoricoLocal.ArquivoApagado] = []
    @State private var carregando = true
    @State private var restaurado: String?
    @State private var falha: String?
    @State private var aberto: PathRef?

    var body: some View {
        NavigationStack {
            Group {
                if carregando {
                    ProgressView()
                } else if itens.isEmpty, restaurado == nil {
                    EmptyState(
                        "trash.slash",
                        title: tr("Nenhum arquivo apagado"),
                        text: tr("Quando um arquivo com versões guardadas some do projeto, ele aparece aqui para voltar.")
                    )
                } else {
                    lista
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.bg)
            .navigationTitle(tr("Arquivos apagados"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(tr("Fechar")) { dismiss() } }
            }
            .navigationDestination(item: $aberto) { r in
                HistoricoLocalView(caminho: r.path)
            }
            .task { await carregar() }
            // Voltando das versões de um arquivo: ele pode ter sido restaurado lá.
            .onChange(of: aberto) { _, novo in
                if novo == nil {
                    Task { await carregar() }
                }
            }
        }
    }

    var lista: some View {
        ScrollPane {
            VStack(alignment: .leading, spacing: 12) {
                if let restaurado {
                    HStack(spacing: 10) {
                        Label(
                            tr("%1$@ voltou para o projeto", "\(nome(restaurado))"),
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.subheadline).foregroundStyle(theme.ok).lineLimit(1)
                        Spacer(minLength: 8)
                        Button(tr("Abrir")) {
                            ws.openFile(restaurado)
                            dismiss()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(12)
                    .background(theme.ok.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if let falha {
                    Text(falha).font(.footnote).foregroundStyle(theme.danger)
                }
                if !pasta.isEmpty {
                    Label(pasta, systemImage: "folder").font(.footnote).foregroundStyle(.secondary)
                }
                if !itens.isEmpty {
                    CardList {
                        ForEach(Array(itens.enumerated()), id: \.element.id) { i, item in
                            linha(item, primeira: i == 0)
                        }
                    }
                }
            }
            .padding(Metrics.s3)
        }
    }

    func linha(_ item: HistoricoLocal.ArquivoApagado, primeira: Bool) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                FileGlyph(path: item.caminho, size: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nome(item.caminho)).font(.subheadline.weight(.medium)).foregroundStyle(theme.fg)
                        .lineLimit(1)
                    Text(detalhe(item)).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture { aberto = PathRef(path: item.caminho) }
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(tr("Mostra as versões guardadas"))
            Button(tr("Restaurar")) { restaurar(item) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .overlay(alignment: .top) {
            if !primeira {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 36)
            }
        }
    }

    func nome(_ caminho: String) -> String {
        caminho.split(separator: "/").last.map(String.init) ?? caminho
    }

    /// Pasta de onde saiu e quando. A data é a da última versão, que é a de logo antes de
    /// apagar quando quem apagou avisou; se não avisou, é o que se sabe.
    func detalhe(_ item: HistoricoLocal.ArquivoApagado) -> String {
        let quando = item.ultima.data.noIdioma(.relative(presentation: .named))
        let frase = item.ultima.origem == .apagar || item.ultima.origem == .terminal
            ? tr("apagado %1$@", "\(quando)")
            : tr("última versão %1$@", "\(quando)")
        let pai = item.caminho.split(separator: "/").dropLast().joined(separator: "/")
        return pai.isEmpty ? frase : "\(pai) · \(frase)"
    }

    func carregar() async {
        let h = ws.historico, raiz = ws.root, p = pasta
        itens = await Task.detached { h.apagados(raiz: raiz, em: p) }.value
        carregando = false
    }

    /// Volta a versão mais nova — a de logo antes de sumir.
    func restaurar(_ item: HistoricoLocal.ArquivoApagado) {
        do {
            try ws.historico.restaurar(item.ultima, caminho: item.caminho, raiz: ws.root)
            falha = nil
            restaurado = item.caminho
            itens.removeAll { $0.id == item.id }
            ws.reload()
        } catch {
            falha = error.localizedDescription
        }
    }
}
