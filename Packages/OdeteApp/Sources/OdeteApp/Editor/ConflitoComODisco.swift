import OdeteAgent
import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// Faixa em cima do editor quando o arquivo mudou no disco e a aba tem alteração não
/// salva.
///
/// Antes não havia escolha nenhuma: o salvamento (automático ou não) gravava o texto da
/// aba por cima do que o agente, o terminal ou o git tinham escrito, e ninguém ficava
/// sabendo. Agora nada é gravado até a pessoa decidir aqui.
struct FaixaDeConflito: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme
    let path: String
    @State private var vendoDiferenca = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.danger)
            Text(tr("O arquivo mudou no disco, e esta aba tem alterações não salvas."))
                .font(OdeteFont.ui(12)).foregroundStyle(theme.fg)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(tr("Ver diferença")) { vendoDiferenca = true }
                .buttonStyle(.plain).font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted)
            Button(tr("Recarregar do disco")) { ws.recarregarDoDisco(path) }
                .buttonStyle(.glass).font(OdeteFont.ui(12))
            Button(tr("Manter o meu")) { ws.manterOMeu(path) }
                .buttonStyle(.glassProminent).font(OdeteFont.ui(12))
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .frame(minHeight: 38)
        .background(theme.danger.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: 1) }
        .sheet(isPresented: $vendoDiferenca) {
            NavigationStack {
                DiferencaDoDisco(path: path)
                    .background(theme.bg)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(tr("Fechar")) { vendoDiferenca = false }
                        }
                        ToolbarItem(placement: .principal) {
                            Titulo(path: path, detalhe: tr("Disco → esta aba"))
                        }
                        ToolbarItemGroup(placement: .primaryAction) {
                            Button(tr("Recarregar do disco")) {
                                ws.recarregarDoDisco(path)
                                vendoDiferenca = false
                            }
                            Button(tr("Manter o meu")) {
                                ws.manterOMeu(path)
                                vendoDiferenca = false
                            }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationSizing(.page)
            .odeteTheme(Theme(chrome.palette, seguirSistema: chrome.snapshot.themeAuto))
        }
    }
}

/// O que difere entre o disco (antes, em vermelho) e o texto da aba (depois, em verde).
///
/// A `FileDiffView` do painel Git não serve aqui: ela desenha um `FileDiff` do git, e esse
/// tipo não se monta fora do pacote do git. As linhas vêm do mesmo `LineDiff` que desenha
/// os patches do agente, com a mesma cara das linhas do diff.
struct DiferencaDoDisco: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    let path: String

    var body: some View {
        let disco = (try? ws.ops.read(path)) ?? ""
        let hunks = LineDiff.hunks(disco, ws.text(for: path), context: 3)
        ScrollView([.vertical, .horizontal]) {
            if hunks.isEmpty {
                Text(tr("sem diferenças")).font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted)
                    .padding(24)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(hunks) { h in
                        Text("@@ −\(h.beforeStart) +\(h.afterStart)").font(OdeteFont.mono(11))
                            .foregroundStyle(theme.accent)
                            .padding(.horizontal, 10).frame(height: 28, alignment: .leading)
                        ForEach(Array(linhas(h).enumerated()), id: \.offset) { _, l in
                            linha(l)
                        }
                    }
                }
                .padding(12)
            }
        }
    }

    struct Linha {
        var antes: Int?
        var depois: Int?
        var sinal: String
        var texto: String
    }

    /// As linhas do trecho com o número de cada lado.
    func linhas(_ h: OdeteAgent.Hunk) -> [Linha] {
        var a = h.beforeStart, d = h.afterStart
        return h.lines.map { l in
            switch l {
            case let .context(s):
                defer { a += 1; d += 1 }
                return Linha(antes: a, depois: d, sinal: " ", texto: s)
            case let .removed(s):
                defer { a += 1 }
                return Linha(antes: a, depois: nil, sinal: "−", texto: s)
            case let .added(s):
                defer { d += 1 }
                return Linha(antes: nil, depois: d, sinal: "+", texto: s)
            }
        }
    }

    func linha(_ l: Linha) -> some View {
        let cor: Color = l.sinal == "+" ? theme.ok : l.sinal == "−" ? theme.danger : theme.fgMuted
        return HStack(spacing: 0) {
            Text(l.antes.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
                .foregroundStyle(theme.fgSubtle)
            Text(l.depois.map(String.init) ?? "").frame(width: 38, alignment: .trailing)
                .foregroundStyle(theme.fgSubtle)
            Text(" \(l.sinal) ").foregroundStyle(cor)
            Text(l.texto).foregroundStyle(l.sinal == " " ? theme.fg : cor)
                .fixedSize()
        }
        .font(OdeteFont.mono(11))
        .frame(minHeight: 18, alignment: .leading)
        .background(l.sinal == "+" ? theme.ok.opacity(0.10) : l.sinal == "−" ? theme.danger.opacity(0.10) : .clear)
    }
}

/// A pergunta de quem fecha uma aba com alteração não salva sem salvamento automático
/// (ou com o disco em conflito) — ver `WorkspaceModel.closeTab`.
struct PerguntaAoFecharAba: ViewModifier {
    @Environment(WorkspaceModel.self) private var ws

    func body(content: Content) -> some View {
        let path = ws.abasParaFechar.first
        let nome = path.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? ""
        content.confirmationDialog(
            tr("Salvar as alterações de %1$@?", nome),
            isPresented: Binding(get: { path != nil }, set: { aberto in
                if !aberto, let path, ws.abasParaFechar.first == path {
                    ws.decidirFechamento(path, .cancelar)
                }
            }),
            titleVisibility: .visible
        ) {
            if let path {
                Button(tr("Salvar")) { ws.decidirFechamento(path, .salvar) }
                Button(tr("Não salvar"), role: .destructive) { ws.decidirFechamento(path, .descartar) }
                Button(tr("Cancelar"), role: .cancel) { ws.decidirFechamento(path, .cancelar) }
            }
        } message: {
            if let path, ws.conflitos.contains(path) {
                Text(tr("O arquivo também mudou no disco. Salvar grava o texto desta aba por cima."))
            } else {
                Text(tr("Se não salvar, o que foi digitado desde o último salvamento se perde."))
            }
        }
    }
}

extension View {
    func perguntaAoFecharAba() -> some View {
        modifier(PerguntaAoFecharAba())
    }
}
