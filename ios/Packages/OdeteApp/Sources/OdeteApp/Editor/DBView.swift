import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// Um banco SQLite mostrado como tabela: lista de tabelas de um lado, linhas do outro.
///
/// Aberto só para leitura — ver o banco do projeto não pode ser um jeito de estragá-lo.
struct DBView: View {
    @Environment(\.theme) private var theme
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    var url: URL
    var nome: String
    /// Quando vem de um `.sql`, é o dump que monta o banco em memória.
    var script: String?
    /// Caminho do `.sql` no projeto: editar a tabela regrava o texto por lá.
    var sqlPath: String?

    @State private var leitor: SQLiteReader?
    @State private var erro: String?
    @State private var tabelas: [DBTable] = []
    @State private var escolhida: String?
    @State private var pagina = DBPage()
    @State private var offset = 0
    private let porPagina = 200

    init(url: URL, nome: String, script: String? = nil, sqlPath: String? = nil) {
        self.url = url
        self.nome = nome
        self.script = script
        self.sqlPath = sqlPath
    }

    @State private var editando: Celula?
    @State private var rascunho = ""
    @State private var novaColuna = false
    /// Largura do próprio painel: decide entre a coluna de tabelas e a fila de fichas.
    @State private var largura: CGFloat = 0
    @State private var nomeDaColuna = ""
    /// Sem foco programático o campo aparecia aberto e o teclado escrevia em outro lugar.
    @FocusState private var focoNaCelula: Bool
    /// Erro de uma edição. Fica numa tarja: trocar a tabela inteira por uma tela de erro
    /// perdia de vista os dados por causa de um `NOT NULL`.
    @State private var aviso: String?

    /// Uma célula em edição: linha na página, coluna, e o `rowid` para achar no banco.
    struct Celula: Identifiable, Hashable {
        var linha: Int
        var coluna: Int
        var rowid: Int64
        var id: String {
            "\(rowid):\(coluna)"
        }
    }

    var body: some View {
        Group {
            if let erro {
                EmptyState("exclamationmark.triangle", title: tr("Não deu para ler o banco"), text: erro)
            } else if tabelas.isEmpty {
                EmptyState(
                    "tablecells",
                    title: tr("Banco sem tabelas"),
                    text: tr("%1$@ abriu, mas não tem nenhuma tabela.", "\(nome)")
                )
            } else if largura > 0, largura < 520 {
                // Numa janela estreita a coluna de 190 pt comia metade da largura e
                // sobravam duas colunas de dados. As tabelas viram uma fila de fichas em
                // cima, que rola sozinha e devolve a largura inteira para os dados.
                VStack(spacing: 0) {
                    fichas
                    Rectangle().fill(theme.separator).frame(height: 0.5)
                    grade.overlay(alignment: .top) { tarja }
                }
            } else {
                HStack(spacing: 0) {
                    lista.frame(width: 190)
                    Rectangle().fill(theme.separator).frame(width: 0.5)
                    grade.overlay(alignment: .top) { tarja }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { largura = $0 }
        .task(id: url) { abrir() }
        .alert(tr("Nova coluna"), isPresented: $novaColuna) {
            TextField(tr("nome"), text: $nomeDaColuna)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(tr("Criar")) { criarColuna(nomeDaColuna); nomeDaColuna = "" }
            Button(tr("Cancelar"), role: .cancel) { nomeDaColuna = "" }
        } message: {
            Text(tr("Entra como TEXT no fim da tabela, vazia em todas as linhas."))
        }
    }

    // MARK: tabelas

    /// A lista de tabelas quando não cabe uma coluna ao lado.
    var fichas: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabelas) { t in
                    let atual = escolhida == t.nome
                    Button { escolher(t.nome) } label: {
                        HStack(spacing: 6) {
                            Text(t.nome).font(.subheadline).foregroundStyle(atual ? theme.accent : theme.fg)
                            Text("\(t.linhas)").font(.caption2).monospacedDigit()
                                .foregroundStyle(atual ? theme.accent.opacity(0.8) : theme.fgSubtle)
                        }
                        .lineLimit(1)
                        .padding(.horizontal, 11).frame(height: 30)
                        .background(atual ? theme.accent.opacity(0.16) : theme.bgSubtle, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
        }
        .background(theme.surface)
    }

    var lista: some View {
        ScrollPane {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(tabelas) { t in
                    Button { escolher(t.nome) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tablecells")
                                .font(.system(size: 12))
                                .foregroundStyle(escolhida == t.nome ? theme.accent : theme.fgSubtle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.nome).font(.subheadline).foregroundStyle(theme.fg).lineLimit(1)
                                Text(tr("%1$@ linha%2$@", "\(t.linhas)", "\(t.linhas == 1 ? "" : "s")"))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            escolhida == t.nome ? theme.accent.opacity(0.14) : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .background(theme.surface)
    }

    /// O que o banco recusou, sem tirar a tabela da frente.
    @ViewBuilder var tarja: some View {
        if let aviso {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                Text(aviso).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                Button { self.aviso = nil } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tr("Fechar aviso"))
            }
            .foregroundStyle(theme.danger)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(theme.danger.opacity(0.14))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: linhas

    var grade: some View {
        VStack(spacing: 0) {
            // Vertical por fora, horizontal por dentro: uma `ScrollView` de dois eixos
            // centraliza conteúdo menor que ela, e a tabela curta ficava boiando no meio
            // da área. Assim o cabeçalho e as linhas continuam rolando juntos de lado.
            ScrollPane(.vertical) {
                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        linha(pagina.colunas, cabecalho: true)
                        ForEach(Array(pagina.linhas.enumerated()), id: \.offset) { i, l in
                            linha(l, cabecalho: false, alterna: i.isMultiple(of: 2), indice: i)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            rodape
        }
    }

    func linha(_ celulas: [String], cabecalho: Bool, alterna: Bool = false, indice: Int = -1) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(celulas.enumerated()), id: \.offset) { col, c in
                celula(c, cabecalho: cabecalho, linha: indice, coluna: col)
            }
        }
        .background(cabecalho ? theme.surface : (alterna ? theme.bgSubtle.opacity(0.4) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    @ViewBuilder
    func celula(_ c: String, cabecalho: Bool, linha: Int, coluna: Int) -> some View {
        let emEdicao = editando?.linha == linha && editando?.coluna == coluna
        Group {
            if emEdicao {
                TextField("", text: $rascunho)
                    .font(OdeteFont.mono(11))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(theme.fg)
                    .focused($focoNaCelula)
                    .submitLabel(.done)
                    .onSubmit { gravarCelula() }
                    // Sair da célula grava, como em qualquer planilha.
                    .onChange(of: focoNaCelula) { _, temFoco in
                        if !temFoco, editando != nil {
                            gravarCelula()
                        }
                    }
            } else {
                Text(c.isEmpty && !cabecalho ? "NULL" : c)
                    .font(cabecalho ? OdeteFont.mono(11).weight(.semibold) : OdeteFont.mono(11))
                    .foregroundStyle(corDaCelula(c, cabecalho: cabecalho))
                    .lineLimit(1).truncationMode(.middle)
                    // Selecionável: copiar um valor era impossível, só dava para olhar.
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: 168, alignment: .leading)
        .background(emEdicao ? theme.accent.opacity(0.12) : .clear)
        .overlay(alignment: .trailing) { Rectangle().fill(theme.separator).frame(width: 0.5) }
        .contentShape(Rectangle())
        // Toque simples abre para editar, que é o gesto direto no dedo; copiar e enviar
        // ficam no toque longo, junto com as ações da linha inteira.
        .onTapGesture { abrirCelula(linha: linha, coluna: coluna, valor: c, cabecalho: cabecalho) }
        .contextMenu {
            if !cabecalho, linha >= 0 {
                Button(tr("Copiar célula"), systemImage: "doc.on.doc") { UIPasteboard.general.string = c }
                menuDaLinha(linha)
            }
        }
    }

    @ViewBuilder
    func menuDaLinha(_ i: Int) -> some View {
        Button(tr("Copiar linha"), systemImage: "doc.on.doc") {
            UIPasteboard.general.string = pagina.linhas[i].joined(separator: "\t")
        }
        Button(tr("Copiar como CSV"), systemImage: "tablecells") {
            UIPasteboard.general.string = csv(pagina.linhas[i])
        }
        Button(tr("Copiar como INSERT"), systemImage: "curlybraces") {
            UIPasteboard.general.string = insert(pagina.linhas[i])
        }
        Button(tr("Enviar para a Odete"), systemImage: "sparkles") {
            ws.agent.anexarTrecho(
                origem: "\(nome) · \(escolhida ?? "")",
                texto: ([pagina.colunas.joined(separator: " | ")] + [pagina.linhas[i].joined(separator: " | ")])
                    .joined(separator: "\n")
            )
            chrome.snapshot.agentVisible = true
        }
        if podeEditar {
            Divider()
            Button(tr("Apagar linha"), systemImage: "trash", role: .destructive) { apagarLinha(i) }
        }
    }

    func csv(_ l: [String]) -> String {
        l
            .map { c in
                c.contains(",") || c.contains("\"") ? "\"" + c.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : c
            }
            .joined(separator: ",")
    }

    func insert(_ l: [String]) -> String {
        let v = l.map { $0.isEmpty ? "NULL" : "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        return "INSERT INTO \(escolhida ?? "tabela") VALUES(\(v.joined(separator: ", ")));"
    }

    /// `NULL` não é dado: fica apagado para não se confundir com a palavra escrita numa célula.
    func corDaCelula(_ c: String, cabecalho: Bool) -> Color {
        if cabecalho {
            return theme.fg
        }
        return c.isEmpty ? theme.fgSubtle : theme.fg
    }

    var rodape: some View {
        HStack(spacing: 10) {
            Text(faixa).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if podeEditar {
                // Um menu só: dois botões com rótulo truncavam para "Colu…" na largura
                // normal do painel.
                Menu {
                    Button(tr("Nova linha"), systemImage: "plus.rectangle") { novaLinha() }
                    Button(tr("Nova coluna"), systemImage: "plus.rectangle.portrait") { novaColuna = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(tr("Adicionar"))
            }
            Spacer(minLength: 0)
            Button { mover(-porPagina) } label: { Image(systemName: "chevron.left") }
                .disabled(offset == 0)
                .accessibilityLabel(tr("Página anterior"))
            Button { mover(porPagina) } label: { Image(systemName: "chevron.right") }
                .disabled(offset + porPagina >= pagina.total)
                .accessibilityLabel(tr("Próxima página"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 36)
        .background(theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    var faixa: String {
        guard pagina.total > 0 else { return tr("sem linhas") }
        let ate = min(offset + pagina.linhas.count, pagina.total)
        return tr("%1$@–%2$@ de %3$@", "\(offset + 1)", "\(ate)", "\(pagina.total)")
    }

    // MARK: editar

    /// Editar precisa de banco aberto para escrita e de `rowid` para achar a linha.
    var podeEditar: Bool {
        (leitor?.editavel ?? false) && pagina.editavel
    }

    func abrirCelula(linha: Int, coluna: Int, valor: String, cabecalho: Bool) {
        guard !cabecalho, podeEditar, linha >= 0, linha < pagina.ids.count else { return }
        rascunho = valor
        editando = Celula(linha: linha, coluna: coluna, rowid: pagina.ids[linha])
        // O campo só existe no quadro seguinte; pedir foco antes disso não pega.
        DispatchQueue.main.async { focoNaCelula = true }
    }

    func gravarCelula() {
        guard let c = editando, let leitor, let tabela = escolhida else { return }
        let coluna = pagina.colunas[c.coluna]
        let erro = leitor.executar(
            "UPDATE \(leitor.citarNome(tabela)) SET \(leitor.citarNome(coluna)) = ? WHERE rowid = ?",
            [rascunho.isEmpty ? nil : rascunho, String(c.rowid)]
        )
        editando = nil
        if let erro {
            self.erro = erro; return
        }
        depoisDeEditar()
    }

    func novaLinha() {
        guard let leitor, let tabela = escolhida else { return }
        // `DEFAULT VALUES` respeita NOT NULL com padrão; quando não dá, o erro aparece.
        if let erro = leitor.inserirLinha(tabela) {
            aviso = erro
            return
        }
        depoisDeEditar()
        // A linha nova está no fim: vai para a última página para ela ficar à vista.
        offset = max(0, (pagina.total - 1) / porPagina) * porPagina
        recarregar()
    }

    func criarColuna(_ nome: String) {
        guard let leitor, let tabela = escolhida, !nome.isEmpty else { return }
        if let erro = leitor
            .executar("ALTER TABLE \(leitor.citarNome(tabela)) ADD COLUMN \(leitor.citarNome(nome)) TEXT")
        {
            self.erro = erro
            return
        }
        depoisDeEditar()
    }

    func apagarLinha(_ i: Int) {
        guard let leitor, let tabela = escolhida, i < pagina.ids.count else { return }
        if let erro = leitor.executar(
            "DELETE FROM \(leitor.citarNome(tabela)) WHERE rowid = ?",
            [String(pagina.ids[i])]
        ) {
            self.erro = erro
            return
        }
        depoisDeEditar()
    }

    /// Recarrega a página e, quando a origem é um `.sql`, regrava o texto do arquivo.
    ///
    /// No dump o banco é só um meio: a fonte da verdade é o texto, e ele precisa refletir
    /// a edição para o arquivo não mentir sobre o próprio conteúdo.
    func depoisDeEditar() {
        tabelas = leitor?.tabelas() ?? []
        recarregar()
        if let sqlPath, let leitor {
            ws.setText(leitor.dump(), for: sqlPath)
            ws.save(sqlPath)
        }
    }

    // MARK: dados

    func abrir() {
        do {
            let r = try script.map { try SQLiteReader(script: $0) } ?? SQLiteReader(arquivo: url, escrita: true)
            leitor = r
            erro = nil
            tabelas = r.tabelas()
            if let primeira = tabelas.first?.nome {
                escolher(primeira)
            }
        } catch {
            erro = error.localizedDescription
            tabelas = []
        }
    }

    func escolher(_ nome: String) {
        escolhida = nome
        offset = 0
        recarregar()
    }

    func mover(_ delta: Int) {
        offset = max(0, offset + delta)
        recarregar()
    }

    func recarregar() {
        guard let leitor, let escolhida else { return }
        pagina = leitor.pagina(escolhida, limite: porPagina, offset: offset)
    }
}
