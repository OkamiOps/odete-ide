import Observation
import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// O banco aberto na tela e a edição em curso — tudo o que a `DBView` desenha e muda.
///
/// Mora fora da view para as regras da edição poderem ser testadas sem tela. E as regras
/// são o motivo de existir: a célula em edição guardava só a posição (linha, coluna) e
/// gravava na tabela *escolhida na hora de gravar*. Trocar de tabela com uma célula
/// aberta gravava o texto na tabela nova, direto no `.sqlite`, e a coluna pela posição
/// podia nem existir lá — o app caía. Tocar em outra célula jogava fora o que se estava
/// digitando. Agora a célula leva o nome da tabela e da coluna, e todo movimento (outra
/// célula, outra tabela, outra página) grava antes o que estava aberto.
@MainActor
@Observable
final class EdicaoDoBanco {
    /// Uma célula em edição: onde ela está, e com que valor ela abriu.
    struct Celula: Identifiable, Hashable {
        var tabela: String
        var coluna: String
        var rowid: Int64
        /// Posição na página, só para desenhar.
        var linha: Int
        var indiceDaColuna: Int
        var original: String
        var id: String {
            "\(tabela):\(rowid):\(coluna)"
        }
    }

    private(set) var leitor: SQLiteReader?
    /// O banco não abriu. Só isso troca a tabela pela tela de erro.
    private(set) var erro: String?
    private(set) var tabelas: [DBTable] = []
    private(set) var escolhida: String?
    private(set) var pagina = DBPage()
    private(set) var offset = 0
    let porPagina = 200

    private(set) var editando: Celula?
    var rascunho = ""
    /// O que o banco recusou numa edição. Fica numa tarja: trocar a tabela inteira por
    /// uma tela de erro perdia de vista os dados — e, com eles, o que se estava editando.
    var aviso: String?

    /// Veio de um `.sql`: o banco é montado em memória a partir do texto, e editar
    /// regrava o arquivo inteiro como dump — comentários e formatação vão embora. Por
    /// isso começa só para leitura e edita só depois de a pessoa confirmar.
    private(set) var deSQL = false
    private(set) var edicaoDoSQLConfirmada = false
    /// Recebe o dump novo depois de cada edição num `.sql`.
    @ObservationIgnored var regravarSQL: ((String) -> Void)?

    // MARK: abrir

    func abrir(url: URL, script: String?) {
        // Outro banco no lugar deste: o que estava aberto grava antes de ir embora.
        gravarPendente()
        deSQL = script != nil
        edicaoDoSQLConfirmada = false
        editando = nil
        aviso = nil
        do {
            let r = try script.map { try SQLiteReader(script: $0) } ?? SQLiteReader(arquivo: url, escrita: true)
            leitor = r
            erro = nil
            tabelas = r.tabelas()
            escolhida = nil
            if let primeira = tabelas.first?.nome {
                escolher(primeira)
            }
        } catch {
            leitor = nil
            erro = error.localizedDescription
            tabelas = []
        }
    }

    // MARK: navegar

    func escolher(_ nome: String) {
        guard gravarPendente() else { return }
        escolhida = nome
        offset = 0
        recarregar()
    }

    func mover(_ delta: Int) {
        guard gravarPendente() else { return }
        offset = max(0, offset + delta)
        recarregar()
    }

    func recarregar() {
        guard let leitor, let escolhida else { return }
        pagina = leitor.pagina(escolhida, limite: porPagina, offset: offset)
    }

    // MARK: editar

    /// Editar precisa de banco aberto para escrita, de `rowid` para achar a linha e, num
    /// `.sql`, da confirmação de que o arquivo pode ser regravado.
    var podeEditar: Bool {
        (leitor?.editavel ?? false) && pagina.editavel && (!deSQL || edicaoDoSQLConfirmada)
    }

    /// Um `.sql` que só falta confirmar para editar.
    var precisaConfirmarSQL: Bool {
        deSQL && !edicaoDoSQLConfirmada && (leitor?.editavel ?? false)
    }

    func confirmarEdicaoDoSQL() {
        edicaoDoSQLConfirmada = true
    }

    /// Abre a célula para editar. Se outra estava aberta, grava a outra antes; se o banco
    /// recusar, a outra continua aberta, com o que foi digitado.
    @discardableResult
    func abrirCelula(linha: Int, coluna: Int) -> Bool {
        guard podeEditar, let tabela = escolhida, linha >= 0, linha < pagina.ids.count, linha < pagina.linhas.count,
              coluna >= 0, coluna < pagina.colunas.count, coluna < pagina.linhas[linha].count else { return false }
        let nova = Celula(
            tabela: tabela,
            coluna: pagina.colunas[coluna],
            rowid: pagina.ids[linha],
            linha: linha,
            indiceDaColuna: coluna,
            original: pagina.linhas[linha][coluna]
        )
        if nova.id == editando?.id {
            return true
        }
        guard gravarPendente() else { return false }
        rascunho = nova.original
        editando = nova
        return true
    }

    /// Grava a célula aberta, se houver. `false` quando o banco recusou — a célula fica
    /// aberta e o aviso diz por quê.
    @discardableResult
    func gravarPendente() -> Bool {
        guard let c = editando else { return true }
        // Nada mudou: não grava (num `.sql`, gravar é regravar o arquivo inteiro).
        if rascunho == c.original {
            editando = nil
            return true
        }
        guard let leitor else {
            editando = nil
            return true
        }
        let falhou = leitor.executar(
            "UPDATE \(leitor.citarNome(c.tabela)) SET \(leitor.citarNome(c.coluna)) = ? WHERE rowid = ?",
            [rascunho.isEmpty ? nil : rascunho, String(c.rowid)]
        )
        if let falhou {
            aviso = falhou
            return false
        }
        editando = nil
        depoisDeEditar()
        return true
    }

    /// Larga a célula sem gravar.
    func descartarEdicao() {
        editando = nil
    }

    func novaLinha() {
        guard podeEditar, gravarPendente(), let leitor, let tabela = escolhida else { return }
        // `DEFAULT VALUES` respeita NOT NULL com padrão; quando não dá, o erro aparece.
        if let falhou = leitor.inserirLinha(tabela) {
            aviso = falhou
            return
        }
        depoisDeEditar()
        // A linha nova está no fim: vai para a última página para ela ficar à vista.
        offset = max(0, (pagina.total - 1) / porPagina) * porPagina
        recarregar()
    }

    func criarColuna(_ nome: String) {
        guard podeEditar, !nome.isEmpty, gravarPendente(), let leitor, let tabela = escolhida else { return }
        if let falhou = leitor
            .executar("ALTER TABLE \(leitor.citarNome(tabela)) ADD COLUMN \(leitor.citarNome(nome)) TEXT")
        {
            aviso = falhou
            return
        }
        depoisDeEditar()
    }

    func apagarLinha(_ i: Int) {
        guard podeEditar, gravarPendente(), let leitor, let tabela = escolhida, i >= 0, i < pagina.ids.count
        else { return }
        if let falhou = leitor.executar(
            "DELETE FROM \(leitor.citarNome(tabela)) WHERE rowid = ?",
            [String(pagina.ids[i])]
        ) {
            aviso = falhou
            return
        }
        depoisDeEditar()
    }

    /// Recarrega a página e, num `.sql`, manda o dump para regravar o texto do arquivo.
    private func depoisDeEditar() {
        tabelas = leitor?.tabelas() ?? []
        recarregar()
        if deSQL, edicaoDoSQLConfirmada, let leitor {
            regravarSQL?(leitor.dump())
        }
    }
}

/// Um banco SQLite mostrado como tabela: lista de tabelas de um lado, linhas do outro.
///
/// Um `.sqlite` abre para editar direto no arquivo; um `.sql` abre só para ver, e edita
/// depois de a pessoa aceitar que o arquivo volte como dump — ver `EdicaoDoBanco`.
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

    @State private var banco = EdicaoDoBanco()

    init(url: URL, nome: String, script: String? = nil, sqlPath: String? = nil) {
        self.url = url
        self.nome = nome
        self.script = script
        self.sqlPath = sqlPath
    }

    @State private var novaColuna = false
    @State private var confirmandoSQL = false
    /// Largura do próprio painel: decide entre a coluna de tabelas e a fila de fichas.
    @State private var largura: CGFloat = 0
    @State private var nomeDaColuna = ""
    /// Sem foco programático o campo aparecia aberto e o teclado escrevia em outro lugar.
    /// O valor é o id da célula: ao passar de uma célula para outra, só a que perdeu o
    /// foco grava — com um `Bool` a célula nova recebia a perda de foco da velha e fechava.
    @FocusState private var foco: String?

    var body: some View {
        Group {
            if let erro = banco.erro {
                EmptyState("exclamationmark.triangle", title: tr("Não deu para ler o banco"), text: erro)
            } else if banco.tabelas.isEmpty {
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
        // Fechar a aba com uma célula aberta também grava o que foi digitado.
        .onDisappear { banco.gravarPendente() }
        .alert(tr("Nova coluna"), isPresented: $novaColuna) {
            TextField(tr("nome"), text: $nomeDaColuna)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button(tr("Criar")) { banco.criarColuna(nomeDaColuna); nomeDaColuna = "" }
            Button(tr("Cancelar"), role: .cancel) { nomeDaColuna = "" }
        } message: {
            Text(tr("Entra como TEXT no fim da tabela, vazia em todas as linhas."))
        }
        .confirmationDialog(
            tr("Editar a tabela regrava o .sql inteiro"),
            isPresented: $confirmandoSQL,
            titleVisibility: .visible
        ) {
            Button(tr("Editar e regravar")) { banco.confirmarEdicaoDoSQL() }
            Button(tr("Cancelar"), role: .cancel) {}
        } message: {
            Text(tr("O arquivo volta como um dump do banco: comentários e formatação se perdem."))
        }
    }

    // MARK: tabelas

    /// A lista de tabelas quando não cabe uma coluna ao lado.
    var fichas: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(banco.tabelas) { t in
                    let atual = banco.escolhida == t.nome
                    Button { banco.escolher(t.nome) } label: {
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
                ForEach(banco.tabelas) { t in
                    Button { banco.escolher(t.nome) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "tablecells")
                                .font(.system(size: 12))
                                .foregroundStyle(banco.escolhida == t.nome ? theme.accent : theme.fgSubtle)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.nome).font(.subheadline).foregroundStyle(theme.fg).lineLimit(1)
                                Text(tr("%1$@ linha%2$@", "\(t.linhas)", "\(t.linhas == 1 ? "" : "s")"))
                                    .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(
                            banco.escolhida == t.nome ? theme.accent.opacity(0.14) : .clear,
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
        if let aviso = banco.aviso {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption)
                Text(aviso).font(.caption).lineLimit(2)
                Spacer(minLength: 0)
                Button { banco.aviso = nil } label: { Image(systemName: "xmark").font(.caption2) }
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
                        linha(banco.pagina.colunas, cabecalho: true)
                        ForEach(Array(banco.pagina.linhas.enumerated()), id: \.offset) { i, l in
                            linha(l, cabecalho: false, alterna: i.isMultiple(of: 2), indice: i)
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            rodape
        }
        // Sair da célula grava, como em qualquer planilha.
        .onChange(of: foco) { antigo, novo in
            if novo == nil, let e = banco.editando, antigo == e.id {
                banco.gravarPendente()
            }
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
        let emEdicao = !cabecalho && banco.editando?.tabela == banco.escolhida
            && banco.editando?.linha == linha && banco.editando?.indiceDaColuna == coluna
        Group {
            if emEdicao {
                TextField("", text: $banco.rascunho)
                    .font(OdeteFont.mono(11))
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .foregroundStyle(theme.fg)
                    .focused($foco, equals: banco.editando?.id ?? "")
                    .submitLabel(.done)
                    .onSubmit { banco.gravarPendente() }
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
        .onTapGesture { tocar(linha: linha, coluna: coluna, cabecalho: cabecalho) }
        .contextMenu {
            if !cabecalho, linha >= 0 {
                Button(tr("Copiar célula"), systemImage: "doc.on.doc") { UIPasteboard.general.string = c }
                menuDaLinha(linha)
            }
        }
    }

    func tocar(linha: Int, coluna: Int, cabecalho: Bool) {
        guard !cabecalho, linha >= 0 else { return }
        if banco.precisaConfirmarSQL {
            confirmandoSQL = true
            return
        }
        if banco.abrirCelula(linha: linha, coluna: coluna) {
            // O campo só existe no quadro seguinte; pedir foco antes disso não pega.
            DispatchQueue.main.async { foco = banco.editando?.id }
        }
    }

    @ViewBuilder
    func menuDaLinha(_ i: Int) -> some View {
        let linhas = banco.pagina.linhas
        if i < linhas.count {
            Button(tr("Copiar linha"), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = linhas[i].joined(separator: "\t")
            }
            Button(tr("Copiar como CSV"), systemImage: "tablecells") {
                UIPasteboard.general.string = csv(linhas[i])
            }
            Button(tr("Copiar como INSERT"), systemImage: "curlybraces") {
                UIPasteboard.general.string = insert(linhas[i])
            }
            Button(tr("Enviar para a Odete"), systemImage: "sparkles") {
                ws.agent.anexarTrecho(
                    origem: "\(nome) · \(banco.escolhida ?? "")",
                    texto: ([banco.pagina.colunas.joined(separator: " | ")] + [linhas[i].joined(separator: " | ")])
                        .joined(separator: "\n")
                )
                chrome.snapshot.agentVisible = true
            }
            if banco.podeEditar {
                Divider()
                Button(tr("Apagar linha"), systemImage: "trash", role: .destructive) { banco.apagarLinha(i) }
            }
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
        return "INSERT INTO \(banco.escolhida ?? "tabela") VALUES(\(v.joined(separator: ", ")));"
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
            if banco.podeEditar {
                // Um menu só: dois botões com rótulo truncavam para "Colu…" na largura
                // normal do painel.
                Menu {
                    Button(tr("Nova linha"), systemImage: "plus.rectangle") { banco.novaLinha() }
                    Button(tr("Nova coluna"), systemImage: "plus.rectangle.portrait") { novaColuna = true }
                } label: {
                    Image(systemName: "plus")
                }
                .menuIndicator(.hidden)
                .accessibilityLabel(tr("Adicionar"))
            } else if banco.precisaConfirmarSQL {
                Button(tr("Editar tabela"), systemImage: "pencil") { confirmandoSQL = true }
            }
            Spacer(minLength: 0)
            Button { banco.mover(-banco.porPagina) } label: { Image(systemName: "chevron.left") }
                .disabled(banco.offset == 0)
                .accessibilityLabel(tr("Página anterior"))
            Button { banco.mover(banco.porPagina) } label: { Image(systemName: "chevron.right") }
                .disabled(banco.offset + banco.porPagina >= banco.pagina.total)
                .accessibilityLabel(tr("Próxima página"))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 36)
        .background(theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    var faixa: String {
        let p = banco.pagina
        guard p.total > 0 else { return tr("sem linhas") }
        let ate = min(banco.offset + p.linhas.count, p.total)
        return tr("%1$@–%2$@ de %3$@", "\(banco.offset + 1)", "\(ate)", "\(p.total)")
    }

    // MARK: dados

    func abrir() {
        banco.abrir(url: url, script: script)
        banco.regravarSQL = { [ws, sqlPath] dump in
            guard let sqlPath else { return }
            ws.setText(dump, for: sqlPath)
            ws.save(sqlPath)
        }
    }
}
