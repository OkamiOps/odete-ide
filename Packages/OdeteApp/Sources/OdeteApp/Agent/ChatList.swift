import OdeteAgent
import OdeteI18n
import OdeteUI
import SwiftUI

/// A conversa: agrupa ferramentas seguidas e rola para o fim.
struct ChatList: View {
    @Environment(\.theme) private var theme
    let agent: AgentModel
    /// A pessoa está no fim da conversa? Só aí a lista acompanha o que chega: quem subiu
    /// para reler alguma coisa não é puxado de volta a cada lote da resposta.
    @State private var colado = true
    /// O dedo (ou o trackpad) está mexendo na lista. É o que separa "a pessoa subiu" de "a
    /// resposta cresceu e empurrou o fim para baixo" — os dois tiram a tela do fim.
    @State private var rolandoAMao = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollPane {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if agent.items.isEmpty {
                        starters
                    }
                    ForEach(grouped(agent.items)) { g in
                        switch g {
                        case let .single(item): ChatRow(agent: agent, item: item).id(item.id)
                        case let .tools(id, list): ToolGroup(items: list).id(id)
                        }
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            // No iPhone o teclado tapa a barra de abas, e sem isto não havia como sair
            // da tela do agente: arrastar a conversa para baixo agora fecha o teclado.
            .scrollDismissesKeyboard(.interactively)
            .onScrollPhaseChange { _, fase in
                rolandoAMao = fase == .tracking || fase == .interacting || fase == .decelerating
            }
            .onScrollGeometryChange(for: Bool.self) { g in
                g.contentOffset.y + g.containerSize.height >= g.contentSize.height - 80
            } action: { _, noFim in
                // Só a mão da pessoa descola; voltar ao fim, por qualquer caminho, cola.
                if rolandoAMao || noFim {
                    colado = noFim
                }
            }
            .onChange(of: agent.items.count) {
                // Pergunta nova da pessoa: vai para o fim, esteja a lista onde estiver.
                if case .user = agent.items.last {
                    colado = true
                }
                guard colado else { return }
                withAnimation(.snappy(duration: 0.15)) { proxy.scrollTo("end", anchor: .bottom) }
            }
            // A resposta crescendo. Era `onChange(of: items.last)`: comparava a resposta
            // inteira com a anterior e rolava a cada ficha, estivesse a pessoa onde estivesse.
            .onChange(of: agent.versaoDosItens) {
                if colado {
                    proxy.scrollTo("end", anchor: .bottom)
                }
            }
            // Ao abrir o app, ou ao trocar de conversa, a lista nascia no topo e a
            // pessoa tinha que rolar até o fim para ver a última resposta.
            .task(id: agent.thread.id) {
                colado = true
                await irParaOFim(proxy)
            }
        }
    }

    /// A lista é preguiçosa: no primeiro quadro o fim ainda não existe, então vale
    /// insistir algumas vezes enquanto o conteúdo termina de nascer.
    @MainActor
    func irParaOFim(_ proxy: ScrollViewProxy) async {
        guard !agent.items.isEmpty else { return }
        for espera in [0, 50, 200, 500] {
            if espera > 0 {
                try? await Task.sleep(for: .milliseconds(espera))
            }
            guard !Task.isCancelled else { return }
            proxy.scrollTo("end", anchor: .bottom)
        }
    }

    /// Uma cor por assunto, como nos grupos dos Ajustes: entender, rodar, criar, revisar.
    static var sugestoes: [(symbol: String, color: Color, text: String)] {
        [
            ("text.magnifyingglass", .blue, tr("Explica a estrutura deste projeto")),
            ("play.circle", .green, tr("Roda npm run dev e me diz se subiu")),
            ("plus.square.on.square", .indigo, tr("Cria um componente de header em src/")),
            ("checkmark.seal", .teal, tr("/review no arquivo aberto")),
        ]
    }

    var starters: some View {
        VStack(alignment: .leading, spacing: 10) {
            Wordmark(height: 22).opacity(0.6)
            Text(tr("Peça em português. O agente lê o projeto, roda no terminal e edita com patches que você aceita."))
                .font(.subheadline).foregroundStyle(theme.fgMuted)
                .fixedSize(horizontal: false, vertical: true)
            CardList {
                ForEach(Array(Self.sugestoes.enumerated()), id: \.offset) { i, s in
                    Button { agent.draft = s.text } label: {
                        CardRow(s.text, symbol: s.symbol, color: s.color, first: i == 0, lines: 2) {
                            Image(systemName: "arrow.up.left").font(.caption2.bold())
                                .foregroundStyle(theme.fgSubtle)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.top, 8)
    }

    enum Group: Identifiable {
        case single(ChatItem), tools(String, [ChatItem])
        var id: String {
            switch self {
            case let .single(i): i.id
            case let .tools(id, _): id
            }
        }
    }

    /// Ferramentas seguidas viram um grupo só. O grupo cresce no lugar: refazer a lista
    /// dele a cada ferramenta nova era copiar o grupo inteiro de novo.
    func grouped(_ items: [ChatItem]) -> [Group] {
        var out: [Group] = []
        var aberto: (id: String, lista: [ChatItem])?
        for it in items {
            let isTool: Bool = switch it {
            case .tool: true
            case let .permit(_, _, _, s): s != .pending
            default: false
            }
            if isTool {
                if aberto == nil {
                    aberto = ("g-" + it.id, [])
                }
                aberto?.lista.append(it)
            } else {
                if let g = aberto {
                    out.append(.tools(g.id, g.lista))
                    aberto = nil
                }
                out.append(.single(it))
            }
        }
        if let g = aberto {
            out.append(.tools(g.id, g.lista))
        }
        return out
    }
}

struct ChatRow: View {
    /// Traduz o erro do provedor numa frase que diz o que fazer.
    ///
    /// O que chega é `HTTP 404: chatgpt.com {"detail":"Not Found"}`, que não ajuda
    /// ninguém a descobrir que o modelo escolhido não existe naquela conta.
    nonisolated static func dica(_ texto: String) -> String? {
        let t = texto.lowercased()
        if t.contains("404") {
            return tr("O modelo escolhido não existe nessa conta. Troque o modelo no rodapé do compositor.")
        }
        if t.contains("unsupported parameter") || t.contains("400") {
            return tr("A conta recusou um parâmetro do pedido. Troque o modelo ou baixe o esforço.")
        }
        if t.contains("401") || t.contains("403") || t.contains("unauthorized") {
            return tr("A sessão da conta caiu. Reconecte em Ajustes → Contas.")
        }
        if t.contains("429") || t.contains("rate limit") {
            return tr("Limite de uso batido. Espere um pouco ou use outra conta.")
        }
        if t.contains("offline") || t.contains("internet") || t.contains("network") {
            return tr("Sem rede. Confira a conexão e mande de novo.")
        }
        return nil
    }

    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let agent: AgentModel
    let item: ChatItem
    @State private var open = false

    var body: some View {
        switch item {
        case let .user(_, text, images):
            VStack(alignment: .trailing, spacing: 6) {
                if let images, !images.isEmpty {
                    HStack(spacing: 6) { ForEach(images.indices, id: \.self) { i in thumb(images[i]) } }
                }
                // Balão neutro, como o de mensagem enviada do Mensagens. A tinta de
                // destaque fica reservada para ações, não para blocos de texto.
                Text(text).font(.subheadline).foregroundStyle(theme.fg).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(
                        theme.fg.opacity(theme.dark ? 0.10 : 0.06),
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 28)
        case let .assistant(_, text):
            MarkdownText(text: text).frame(maxWidth: .infinity, alignment: .leading)
        case let .think(_, text, live):
            // Nasce recolhido: o raciocínio é contexto, não a resposta.
            // Mesmo formato da linha de ferramentas: as duas são contexto do turno e
            // precisam começar no mesmo recuo.
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                    HStack(spacing: 7) {
                        if live {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "brain").font(.system(size: 10))
                        }
                        Text(live ? "pensando…" : "pensou").font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        if !live {
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                    }
                    .foregroundStyle(theme.fgSubtle)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(live)
                if open, !live {
                    Text(text).font(.caption).foregroundStyle(theme.fgMuted).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 10)
                        .overlay(alignment: .top) {
                            Rectangle().fill(theme.separator).frame(height: 0.5).padding(.horizontal, 10)
                        }
                }
            }
            .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case let .permit(id, name, detail, status):
            PermitCard(name: name, detail: detail, status: status) { agent.approve(id, $0) }
        case let .tool(_, name, detail):
            ToolGroup(items: [.tool(id: item.id, name: name, detail: detail)])
        case let .compactado(_, resumo, antes, depois):
            CompactacaoCard(resumo: resumo, antes: antes, depois: depois)
        case let .error(id, text):
            // Parar e desfazer são avisos, não falhas: cartão neutro, sem "Tentar de novo".
            // E os avisos do laço (compactação), que também não são falha.
            let desfeito = AgentModel.ehAvisoDoDesfazer(id)
            let aviso = AgentModel.ehAviso(id) && text != "parado"
            let parado = text == "parado" || aviso
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: desfeito ? "arrow.uturn.backward.circle"
                        : aviso ? "info.circle" : parado ? "stop.circle" : "exclamationmark.triangle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(parado ? theme.fgSubtle : theme.danger)
                    VStack(alignment: .leading, spacing: 3) {
                        // O resultado do desfazer é para ler inteiro: o que ficou e por quê.
                        Text(text).font(.footnote).foregroundStyle(parado && !aviso ? theme.fgMuted : theme.fg)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        // O texto cru do provedor é um HTTP com JSON dentro: sozinho não
                        // diz o que fazer.
                        if let dica = Self.dica(text) {
                            Text(dica).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if !parado, agent.items.last?.id == id, agent.podeTentarDeNovo {
                    Button(tr("Tentar de novo"), systemImage: "arrow.clockwise") { agent.tentarDeNovo() }
                        .font(.caption.weight(.medium))
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(theme.danger)
                } else if !parado, agent.items.last?.id == id, agent.podeTrocarDeModelo {
                    // O modelo da Apple não está no aparelho: repetir não adianta, trocar sim.
                    Button(tr("Trocar de modelo"), systemImage: "arrow.left.arrow.right") {
                        agent.pedidoDeTrocarModelo += 1
                    }
                    .font(.caption.weight(.medium))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(theme.danger)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                parado ? theme.fg.opacity(0.05) : theme.danger.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        case let .patch(_, patchId, path):
            if let p = agent.porId[patchId] {
                PatchCard(agent: agent, patch: p)
            } else {
                // Patch resolvido some do armazenamento quando o app reabre: fica o
                // registro na conversa, sem o diff. Em vez de uma linha cinza solta,
                // vale pelo menos abrir o arquivo.
                Button { ws.openFile(path) } label: {
                    HStack(spacing: 6) {
                        FileGlyph(path: path, size: 11)
                        Text(path).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted)
                            .lineLimit(1).truncationMode(.middle)
                        Text(tr("patch já resolvido")).font(.caption2).foregroundStyle(theme.fgSubtle)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    func thumb(_ img: AgentImage) -> some View {
        if let d = Data(base64Encoded: img.data), let ui = UIImage(data: d) {
            Image(uiImage: ui).resizable().scaledToFill().frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// A conversa foi compactada: quanto ocupava, quanto ficou, e o resumo que entrou no
/// lugar do começo — recolhido, como o raciocínio, porque é contexto e não resposta.
struct CompactacaoCard: View {
    @Environment(\.theme) private var theme
    let resumo: String
    let antes: Int
    let depois: Int
    @State private var aberto = false

    /// Ainda resumindo: o laço manda o cartão vazio antes do pedido ao modelo.
    var andando: Bool {
        resumo.isEmpty && depois == 0
    }

    var titulo: String {
        if andando {
            return tr("Compactando a conversa…")
        }
        return resumo.isEmpty ? tr("Saídas antigas de ferramenta apagadas") : tr("Conversa compactada")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { aberto.toggle() } } label: {
                HStack(spacing: 7) {
                    if andando {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "rectangle.compress.vertical").font(.system(size: 10))
                    }
                    Text(titulo).font(.caption.weight(.medium)).lineLimit(1)
                    if !andando {
                        Text("\(fmtTok(antes)) → \(fmtTok(depois))").font(.caption2).monospacedDigit()
                            .foregroundStyle(theme.fgSubtle).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if !resumo.isEmpty {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(aberto ? 90 : 0))
                    }
                }
                .foregroundStyle(theme.fgMuted)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(resumo.isEmpty)
            .accessibilityLabel(andando ? titulo : tr(
                "%1$@: de %2$@ para %3$@ tokens",
                titulo,
                fmtTok(antes),
                fmtTok(depois)
            ))
            if aberto, !resumo.isEmpty {
                MarkdownText(text: resumo)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .overlay(alignment: .top) {
                        Rectangle().fill(theme.separator).frame(height: 0.5).padding(.horizontal, 10)
                    }
            }
        }
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.accent.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        )
    }
}

/// Ferramentas usadas no turno. Nasce recolhida numa linha só; expandindo, mostra cada
/// chamada com o nome e o alvo.
struct ToolGroup: View {
    @Environment(\.theme) private var theme
    let items: [ChatItem]
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.snappy(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "wrench.and.screwdriver").font(.system(size: 10))
                    Text(summary).font(.caption).lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .foregroundStyle(theme.fgSubtle)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                        HStack(alignment: .top, spacing: 7) {
                            Text(name(it)).font(OdeteFont.mono(10.5, weight: .medium))
                                .foregroundStyle(theme.accent)
                            Text(detail(it)).font(OdeteFont.mono(10.5)).foregroundStyle(theme.fgMuted)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .overlay(alignment: .top) {
                            if i > 0 {
                                Rectangle().fill(theme.separator).frame(height: 0.5)
                            }
                        }
                    }
                }
            }
        }
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func name(_ it: ChatItem) -> String {
        switch it {
        case let .tool(_, n, _): n
        case let .permit(_, n, _, _): n
        default: ""
        }
    }

    func detail(_ it: ChatItem) -> String {
        switch it {
        case let .tool(_, _, d): d
        case let .permit(_, _, d, s): d + (s == .no ? " (recusado)" : "")
        default: ""
        }
    }

    var summary: String {
        if items.count == 1 {
            return name(items[0]) + " " + detail(items[0])
        }
        let nomes = Set(items.map { name($0) }).sorted().prefix(3).joined(separator: ", ")
        return "\(items.count) ferramentas · \(nomes)"
    }
}

struct PermitCard: View {
    @Environment(\.theme) private var theme
    let name: String
    let detail: String
    let status: ChatItem.PermitStatus
    let answer: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(
                    systemName: status == .pending ? "hand.raised" : status == .ok ? "checkmark.circle" : "xmark.circle"
                )
                .font(.system(size: 14))
                .foregroundStyle(status == .no ? theme.danger : theme.accent)
                .frame(width: 16, alignment: .center)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(OdeteFont.mono(12, weight: .medium)).foregroundStyle(theme.fg)
                    Text(detail).font(OdeteFont.mono(11)).foregroundStyle(theme.fgMuted).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            // Os botões numa linha só deles. Ao lado do texto, no painel de 290 pt, sobrava
            // uns 60 pt para cada um e o rótulo quebrava no meio da palavra: "Re-cusar",
            // "Aprov ar". Embaixo eles cabem inteiros e ficam com tamanho de botão.
            if status == .pending {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(tr("Recusar")) { answer(false) }.buttonStyle(.glass)
                    Button(tr("Aprovar")) { answer(true) }.buttonStyle(.glassProminent)
                }
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            }
        }
        .padding(12)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(theme.accent.opacity(status == .pending ? 0.7 : 0), lineWidth: 1))
    }
}

/// Markdown do agente. Além de parágrafo e bloco de código, entende título, lista com
/// marcador, lista numerada, citação e régua. Texto corrido cansa de ler; a lista não.
struct MarkdownText: View {
    @Environment(\.theme) private var theme
    let text: String
    /// Guarda o que já foi lido, para o próximo lote da resposta não reler tudo.
    @State private var leitor = LeitorDoChat()

    enum Block: Identifiable, Hashable {
        case code(Int, String, String)
        case para(Int, String)
        case heading(Int, Int, String)
        case list(Int, Bool, [String])
        case quote(Int, String)
        case rule(Int)

        var id: Int {
            switch self {
            case let .code(i, _, _), let .para(i, _), let .heading(i, _, _),
                 let .list(i, _, _), let .quote(i, _), let .rule(i): i
            }
        }
    }

    /// A leitura inteira, de uma vez. A tela usa o `leitor`, que chega ao mesmo resultado
    /// relendo só a cauda enquanto a resposta chega — ver `LeitorDoChat`.
    var blocks: [Block] {
        Self.ler(Substring(text)).blocos
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(leitor.blocos(text)) { b in
                switch b {
                case let .heading(_, level, t):
                    Text(t)
                        .font(level <= 1 ? .headline : .subheadline.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .padding(.top, 2)
                case let .para(_, t):
                    Text(inline(t))
                        .font(.subheadline)
                        .lineSpacing(2)
                        .foregroundStyle(theme.fg)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case let .list(_, ordered, items):
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(items.enumerated()), id: \.offset) { n, item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(ordered ? "\(n + 1)." : "•")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(theme.accent)
                                    .frame(minWidth: ordered ? 18 : 10, alignment: .leading)
                                Text(inline(item))
                                    .font(.subheadline)
                                    .lineSpacing(2)
                                    .foregroundStyle(theme.fg)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                case let .quote(_, t):
                    HStack(alignment: .top, spacing: 10) {
                        Capsule().fill(theme.accent.opacity(0.5)).frame(width: 3)
                        Text(inline(t)).font(.subheadline).foregroundStyle(theme.fgMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Rectangle().fill(theme.separator).frame(height: 0.5)
                case let .code(_, lang, c):
                    codeBlock(lang: lang, code: c)
                }
            }
        }
    }

    func codeBlock(lang: String, code c: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(lang.isEmpty ? tr("código") : lang).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Copiar"), systemImage: "doc.on.doc") { UIPasteboard.general.string = c }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(theme.fgMuted)
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 30)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            ScrollPane(.horizontal, showsIndicators: false) {
                Text(c).font(OdeteFont.mono(11.5)).foregroundStyle(theme.fg).textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func inline(_ t: String) -> AttributedString {
        leitor.inline(t, Self.interpretar)
    }

    nonisolated static func interpretar(_ t: String) -> AttributedString {
        (try? AttributedString(markdown: t, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ??
            AttributedString(t)
    }
}
