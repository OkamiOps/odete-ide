import OdeteAgent
import OdeteUI
import SwiftUI

/// Conversas guardadas deste projeto: agrupadas por dia, com o começo da última mensagem
/// embaixo do título, para dar para reconhecer a conversa sem abrir uma por uma.
struct HistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let agent: AgentModel
    @State private var busca = ""

    var body: some View {
        NavigationStack {
            Group {
                if agent.threads.isEmpty {
                    EmptyState(
                        "bubble.left.and.bubble.right",
                        title: "Nenhuma conversa",
                        text: "O que você perguntar à Odete fica guardado aqui, por projeto."
                    )
                } else {
                    lista
                }
            }
            .background(theme.bg)
            .navigationTitle("Conversas")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fechar") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button { agent.newChat(); dismiss() } label: { Label("Nova", systemImage: "square.and.pencil") }
                        .disabled(agent.thread.isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .presentationSizing(.form)
        .pointerScrolling()
    }

    var lista: some View {
        ScrollPane {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if agent.threads.count > 6 {
                    campo
                }
                ForEach(grupos, id: \.titulo) { g in
                    Section {
                        VStack(spacing: 0) {
                            ForEach(Array(g.threads.enumerated()), id: \.element.id) { i, t in
                                linha(t, primeira: i == 0)
                            }
                        }
                        .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                    } header: {
                        cabecalho(g.titulo)
                    }
                }
                if grupos.isEmpty {
                    Text("Nada com \"\(busca)\"").font(.footnote).foregroundStyle(.secondary).padding(20)
                }
            }
            .padding(.bottom, 20)
        }
    }

    var campo: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.fgSubtle)
            TextField("Buscar nas conversas", text: $busca)
                .textFieldStyle(.plain).font(.subheadline).foregroundStyle(theme.fg)
                .autocorrectionDisabled()
            if !busca.isEmpty {
                Button { busca = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(theme.fgSubtle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Limpar busca")
            }
        }
        .padding(.horizontal, 10).frame(height: 34)
        .background(theme.fg.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14).padding(.bottom, 10)
    }

    func cabecalho(_ texto: String) -> some View {
        Text(texto.uppercased())
            .font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
            .padding(.horizontal, 18).frame(height: 28, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.bg)
    }

    func linha(_ t: ChatThread, primeira: Bool) -> some View {
        let atual = t.id == agent.thread.id
        return Button { agent.open(t); dismiss() } label: {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(atual ? theme.accent : theme.fgSubtle.opacity(0.35))
                    .frame(width: 7, height: 7).padding(.top, 6)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(t.title).font(.subheadline.weight(atual ? .semibold : .regular))
                            .foregroundStyle(theme.fg).lineLimit(1)
                        if atual {
                            Text("aberta").font(.caption2.weight(.medium)).foregroundStyle(theme.accent)
                                .padding(.horizontal, 5).frame(height: 15)
                                .background(theme.accent.opacity(0.14), in: Capsule())
                        }
                    }
                    if let p = previa(t) {
                        Text(p).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(rodape(t)).font(.caption2).foregroundStyle(theme.fgSubtle)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption2.bold())
                    .foregroundStyle(theme.fgSubtle).padding(.top, 4)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) {
            if !primeira {
                Rectangle().fill(theme.separator).frame(height: 0.5).padding(.leading, 29)
            }
        }
        .contextMenu {
            Button("Abrir", systemImage: "bubble.left") { agent.open(t); dismiss() }
            Button("Apagar", systemImage: "trash", role: .destructive) { agent.remove(t) }
        }
    }

    /// Começo da última mensagem de verdade da conversa.
    func previa(_ t: ChatThread) -> String? {
        guard let m = t.messages.last(where: { ($0.role == .assistant || $0.role == .user) && !$0.content.isEmpty })
        else { return nil }
        // Sem a marcação: a prévia vinha com "## ", "- " e "**" no meio, que no tamanho de
        // uma linha só atrapalha a leitura.
        var texto = m.content
        for marca in ["**", "`", "#", ">"] {
            texto = texto.replacingOccurrences(of: marca, with: "")
        }
        texto = texto.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { linha in
                var l = linha
                for marca in ["- ", "* ", "+ "] where l.hasPrefix(marca) {
                    l.removeFirst(2)
                }
                return l
            }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let prefixo = m.role == .user ? "você: " : ""
        return prefixo + String(texto.prefix(120))
    }

    func rodape(_ t: ChatThread) -> String {
        let trocas = t.messages.count { $0.role == .user }
        let tokens = t.usage.input + t.usage.output
        var partes = [t.updated.formatted(date: .omitted, time: .shortened)]
        partes.append(trocas == 1 ? "1 pergunta" : "\(trocas) perguntas")
        if tokens > 0 {
            partes.append("\(fmtTok(tokens)) tokens")
        }
        return partes.joined(separator: " · ")
    }

    var grupos: [(titulo: String, threads: [ChatThread])] {
        let alvo = busca.lowercased()
        let lista = alvo.isEmpty ? agent.threads : agent.threads.filter {
            $0.title.lowercased().contains(alvo) || $0.messages.contains { $0.content.lowercased().contains(alvo) }
        }
        var out: [(String, [ChatThread])] = []
        for t in lista {
            let d = dia(t.updated)
            if out.last?.0 == d {
                out[out.count - 1].1.append(t)
            } else {
                out.append((d, [t]))
            }
        }
        return out
    }

    func dia(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            return "Hoje"
        }
        if cal.isDateInYesterday(d) {
            return "Ontem"
        }
        return d.formatted(.dateTime.day().month(.wide).year())
    }
}
