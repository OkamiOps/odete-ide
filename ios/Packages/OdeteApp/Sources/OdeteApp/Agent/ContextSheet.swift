import OdeteAgent
import OdeteUI
import PhotosUI
import SwiftUI

/// Folha do "+": fontes de anexo em cartões grandes em cima, o resto em linhas,
/// no formato das folhas de contexto do app da Claude.
struct ContextSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Bindable var agent: AgentModel
    @Binding var photo: PhotosPickerItem?
    var temPreview: Bool
    @State private var detent: PresentationDetent = .large

    var body: some View {
        NavigationStack {
            ScrollPane {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        PhotosPicker(selection: $photo, matching: .images) {
                            Fonte(label: "Fotos", symbol: "photo")
                        }
                        .buttonStyle(.plain)
                        .onChange(of: photo) { _, novo in
                            if novo != nil {
                                dismiss()
                            }
                        }
                        Button {
                            agent.attachPreview(); dismiss()
                        } label: {
                            Fonte(label: "Preview", symbol: "camera.viewfinder")
                        }
                        .buttonStyle(.plain)
                        .disabled(!temPreview)
                        .opacity(temPreview ? 1 : 0.4)
                        Button {
                            inserir("@")
                        } label: {
                            Fonte(label: "Arquivo", symbol: "at")
                        }
                        .buttonStyle(.plain)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Atalhos")
                        CardList {
                            Button { inserir("/") } label: {
                                CardRow("Skill", symbol: "slash.circle", color: .purple, first: true) {
                                    chevron
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button { agent.newChat(); dismiss() } label: {
                                CardRow("Nova conversa", symbol: "square.and.pencil", color: .blue) { chevron }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle("Permissão")
                        CardList {
                            ForEach(Array(PermitMode.allCases.enumerated()), id: \.element) { i, p in
                                Button { agent.setPermit(p) } label: {
                                    CardRow(
                                        p.label,
                                        symbol: p.symbol,
                                        color: p == .full ? .orange : .teal,
                                        detail: p.hint,
                                        first: i == 0
                                    ) {
                                        if agent.permit == p {
                                            Image(systemName: "checkmark").font(.caption.bold())
                                                .foregroundStyle(theme.accent)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        CardNote("Vale para escrever arquivos e rodar comandos no terminal.")
                    }
                }
                .padding(16)
            }
            .background(theme.surface)
            .navigationTitle("Contexto")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(theme.fgMuted)
                        .accessibilityLabel("Fechar")
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $detent)
    }

    var chevron: some View {
        Image(systemName: "chevron.right").font(.caption2.bold()).foregroundStyle(theme.fgSubtle)
    }

    func inserir(_ s: String) {
        agent.draft += (agent.draft.isEmpty || agent.draft.hasSuffix(" ") ? "" : " ") + s
        agent.focusRequest += 1
        dismiss()
    }
}

/// Cartão grande de fonte de anexo, como Câmera/Fotos/Arquivos das folhas da Apple.
private struct Fonte: View {
    @Environment(\.theme) private var theme
    var label: String
    var symbol: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 20, weight: .regular))
            Text(label).font(.subheadline)
        }
        .foregroundStyle(theme.fg)
        .frame(maxWidth: .infinity)
        .frame(height: 86)
        .background(theme.fg.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
