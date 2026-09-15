import OdeteAccounts
import OdeteCore
import OdeteUI
import SwiftUI

/// A folha do GitHub quando o projeto ainda não tem repositório lá.
///
/// Antes o gatinho do cabeçalho só aparecia depois que existia um `origin` no GitHub —
/// ou seja, sumia exatamente quando havia algo a fazer. Aqui ele leva ao que falta:
/// conectar a conta, publicar o projeto ou apontar um remoto que já existe.
struct GhStart: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var nome = ""
    @State private var privado = true
    @State private var publicando = false
    @State private var erro: String?
    @State private var contas = false
    @State private var remoteURL = ""
    @State private var askingRemote = false

    var git: GitModel {
        ws.git
    }

    var temConta: Bool {
        git.githubToken != nil
    }

    var body: some View {
        NavigationStack {
            ScrollPane {
                VStack(alignment: .leading, spacing: 18) {
                    marca
                    if temConta {
                        publicar
                    } else {
                        conectar
                    }
                    outro
                    if let erro {
                        CardNote(erro)
                    }
                }
                .padding(16)
            }
            .background(theme.surface)
            .navigationTitle("GitHub")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } } }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $contas) {
            NavigationStack {
                ScrollPane { AccountsSettings().padding(16) }
                    .background(theme.surface)
                    .navigationTitle("Contas")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("OK") { contas = false } }
                    }
            }
        }
        .alert("Remoto origin", isPresented: $askingRemote) {
            TextField("https://github.com/usuario/repo.git", text: $remoteURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Adicionar") {
                git.addRemote(url: remoteURL.trimmingCharacters(in: .whitespaces))
                dismiss()
            }
            Button("Cancelar", role: .cancel) {}
        }
        .task {
            if nome.isEmpty {
                nome = Slug.repo(ws.project.name)
            }
        }
    }

    var marca: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accent.opacity(0.14)).frame(width: 44, height: 44)
                Image(systemName: "cat").font(.system(size: 20, weight: .medium))
                    .foregroundStyle(theme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("\(ws.project.name) ainda não está no GitHub")
                    .font(.headline).foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Depois de subir, os pull requests, as issues e o Actions aparecem aqui dentro.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var conectar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Conta")
            CardNote("Para criar o repositório e dar push, a Odete precisa de uma conta do GitHub.")
            Button { contas = true } label: {
                Text("Conectar conta do GitHub")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(theme.accentFg)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
        }
    }

    var publicar: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Publicar", detail: ws.git.current?.name ?? ws.git.headName)
            CardList {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nome do repositório").font(.caption).foregroundStyle(theme.fgMuted)
                        TextField("meu-projeto", text: $nome)
                            .textFieldStyle(.plain).font(OdeteFont.mono(13)).foregroundStyle(theme.fg)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(.horizontal, 10).frame(height: 36)
                            .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    Toggle(isOn: $privado) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Privado").font(.subheadline).foregroundStyle(theme.fg)
                            Text("Só você e quem você convidar veem o código.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Button(action: subir) {
                        HStack(spacing: 7) {
                            if publicando {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up.circle.fill").font(.system(size: 13, weight: .bold))
                            }
                            Text(publicando ? "Publicando…" : "Criar e dar push")
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(theme.accentFg)
                        .frame(maxWidth: .infinity).frame(height: 40)
                        .background(
                            podeSubir ? theme.accent : theme.fgSubtle.opacity(0.3),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!podeSubir)
                }
                .padding(12)
            }
            Text("Cria o repositório na sua conta e sobe a branch atual. Nada é enviado antes disso.")
                .font(.caption2).foregroundStyle(theme.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var outro: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Já existe lá fora")
            CardList {
                Button { askingRemote = true } label: {
                    CardRow(
                        "Apontar para um repositório existente",
                        symbol: "link",
                        color: .teal,
                        detail: "Cola a URL e vira o `origin` deste projeto",
                        first: true
                    ) {
                        Image(systemName: "chevron.right").font(.caption2.bold())
                            .foregroundStyle(theme.fgSubtle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    var podeSubir: Bool {
        !publicando && !git.busy && !nome.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func subir() {
        let limpo = Slug.repo(nome)
        publicando = true
        erro = nil
        Task {
            defer { publicando = false }
            do {
                let repo = try await GitHubAPI(token: git.githubToken).createRepo(name: limpo, isPrivate: privado)
                git.publish(url: repo.cloneUrl)
                dismiss()
            } catch {
                erro = error.localizedDescription
            }
        }
    }
}
