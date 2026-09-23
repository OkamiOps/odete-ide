import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI

/// No lugar da grade enquanto o iCloud não diz onde estão os projetos.
///
/// A lista vazia de boas-vindas, aqui, diria que não há projeto nenhum — e é justamente
/// o que alguém com tudo no iCloud não pode ler na abertura do app.
struct ProcurandoProjetos: View {
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(tr("Procurando os projetos no iCloud Drive…"))
                .font(OdeteFont.ui(13)).foregroundStyle(theme.fgMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 160)
    }
}

/// Um projeto de fora cuja pasta não se acha mais: fica à vista, apagado, com o caminho
/// de volta. Antes ele sumia do hub sem aviso.
struct CartaoIndisponivel: View {
    @Environment(AppModel.self) private var app
    var project: Project
    /// Abre o seletor para apontar a pasta nova.
    var reapontar: () -> Void

    var body: some View {
        ProjectCard(project: project, dados: nil, indisponivel: true)
            .onTapGesture(perform: reapontar)
            .contextMenu {
                Button(tr("Apontar para a pasta…"), systemImage: "folder", action: reapontar)
                Button(tr("Remover do hub"), systemImage: "minus.circle", role: .destructive) {
                    app.delete(project)
                }
            }
    }
}
