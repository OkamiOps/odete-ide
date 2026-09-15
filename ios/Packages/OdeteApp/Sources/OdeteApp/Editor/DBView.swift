import OdeteFiles
import OdeteUI
import SwiftUI

/// Um banco SQLite mostrado como tabela: lista de tabelas de um lado, linhas do outro.
///
/// Aberto só para leitura — ver o banco do projeto não pode ser um jeito de estragá-lo.
struct DBView: View {
    @Environment(\.theme) private var theme
    var url: URL
    var nome: String
    /// Quando vem de um `.sql`, é o dump que monta o banco em memória.
    var script: String?

    @State private var leitor: SQLiteReader?
    @State private var erro: String?
    @State private var tabelas: [DBTable] = []
    @State private var escolhida: String?
    @State private var pagina = DBPage()
    @State private var offset = 0
    private let porPagina = 200

    init(url: URL, nome: String, script: String? = nil) {
        self.url = url
        self.nome = nome
        self.script = script
    }

    var body: some View {
        Group {
            if let erro {
                EmptyState("exclamationmark.triangle", title: "Não deu para ler o banco", text: erro)
            } else if tabelas.isEmpty {
                EmptyState("tablecells", title: "Banco sem tabelas", text: "\(nome) abriu, mas não tem nenhuma tabela.")
            } else {
                HStack(spacing: 0) {
                    lista.frame(width: 190)
                    Rectangle().fill(theme.separator).frame(width: 0.5)
                    grade
                }
            }
        }
        .task(id: url) { abrir() }
    }

    // MARK: tabelas

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
                                Text("\(t.linhas) linha\(t.linhas == 1 ? "" : "s")")
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
                            linha(l, cabecalho: false, alterna: i.isMultiple(of: 2))
                        }
                    }
                }
                .padding(.bottom, 12)
            }
            rodape
        }
    }

    func linha(_ celulas: [String], cabecalho: Bool, alterna: Bool = false) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(celulas.enumerated()), id: \.offset) { _, c in
                Text(c.isEmpty && !cabecalho ? "NULL" : c)
                    .font(cabecalho ? OdeteFont.mono(11).weight(.semibold) : OdeteFont.mono(11))
                    .foregroundStyle(corDaCelula(c, cabecalho: cabecalho))
                    .lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(width: 168, alignment: .leading)
                    .overlay(alignment: .trailing) { Rectangle().fill(theme.separator).frame(width: 0.5) }
            }
        }
        .background(cabecalho ? theme.surface : (alterna ? theme.bgSubtle.opacity(0.4) : .clear))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
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
            Spacer(minLength: 0)
            Button { mover(-porPagina) } label: { Image(systemName: "chevron.left") }
                .disabled(offset == 0)
                .accessibilityLabel("Página anterior")
            Button { mover(porPagina) } label: { Image(systemName: "chevron.right") }
                .disabled(offset + porPagina >= pagina.total)
                .accessibilityLabel("Próxima página")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12).frame(height: 36)
        .background(theme.surface)
        .overlay(alignment: .top) { Rectangle().fill(theme.separator).frame(height: 0.5) }
    }

    var faixa: String {
        guard pagina.total > 0 else { return "sem linhas" }
        let ate = min(offset + pagina.linhas.count, pagina.total)
        return "\(offset + 1)–\(ate) de \(pagina.total)"
    }

    // MARK: dados

    func abrir() {
        do {
            let r = try script.map { try SQLiteReader(script: $0) } ?? SQLiteReader(arquivo: url)
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
