import OdeteI18n
import OdeteUI
import SwiftUI

/// O painel de git antes de existir repositório.
///
/// Era um `EmptyState` genérico — ícone cinza, duas linhas e um botão — espremido numa
/// coluna de 230 pt, que é a largura em que este painel mais vive. Aqui o espaço é usado
/// para dizer o que se ganha ao iniciar, com o nome do projeto na frente, e o botão fica
/// no fim como conclusão em vez de enfeite no meio do vazio.
struct GitEmpty: View {
    @Environment(\.theme) private var theme
    @Environment(WorkspaceModel.self) private var ws
    var largura: CGFloat

    /// Abaixo disso não cabe explicação nenhuma sem virar sopa de letras.
    var apertado: Bool {
        largura < 200
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            marca
            VStack(alignment: .leading, spacing: 5) {
                Text(tr("Versionar %1$@", "\(ws.project.name)"))
                    .font(.headline).foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                Text(tr("Um repositório guarda cada passo e deixa desfazer sem medo."))
                    .font(.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !apertado {
                VStack(alignment: .leading, spacing: 10) {
                    ganho("clock.arrow.circlepath", tr("Histórico"), tr("Volte a qualquer ponto do arquivo."))
                    ganho("arrow.triangle.branch", "Branches", tr("Teste uma ideia sem estragar o que funciona."))
                    ganho("arrow.up.circle", "GitHub", tr("Suba o projeto e abra pull requests daqui."))
                }
            }
            Button { ws.git.initRepository() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text(apertado ? "Iniciar" : tr("Iniciar repositório"))
                        .lineLimit(1).minimumScaleFactor(0.85)
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accentFg)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(theme.accent, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .hoverEffect(.highlight)
            Text(tr("Cria um `.git` na pasta do projeto. Nada é enviado para fora do iPad."))
                .font(.caption2).foregroundStyle(theme.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Um galho desenhado, não o ícone cinza do sistema: é a única imagem do painel e
    /// vale ela parecer parte do app.
    var marca: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(theme.accent.opacity(0.14))
                .frame(width: 44, height: 44)
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(theme.accent)
        }
    }

    func ganho(_ simbolo: String, _ titulo: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: simbolo)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(width: 16, height: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(titulo).font(.subheadline.weight(.medium)).foregroundStyle(theme.fg)
                Text(texto).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
