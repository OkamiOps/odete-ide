import Foundation
import Observation
import OdeteCore
import OdeteFiles
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// Quais folhas do histórico local estão abertas. Mora no `WorkspaceModel` porque quem
/// abre são lugares que só enxergam o modelo: a árvore, a aba, a paleta, o menu do arquivo.
@MainActor
@Observable
public final class HistoricoLocalEstado {
    /// Arquivo com a folha "Histórico local" aberta.
    public var arquivo: String?
    /// Pasta cuja lista de apagados está aberta ("" é o projeto todo).
    public var apagadosEm: String?

    public init() {}

    public func abrir(_ caminho: String) {
        arquivo = caminho
    }

    public func abrirApagados(em pasta: String = "") {
        apagadosEm = pasta
    }
}

extension WorkspaceModel {
    /// O histórico onde este projeto guarda as versões — o mesmo que o `FileOps` usa.
    var historico: HistoricoLocal {
        ops.historico ?? .compartilhado
    }

    /// Guarda o texto da aba antes de ele ser trocado pelo que está no disco.
    ///
    /// Com a aba limpa o texto é o conteúdo de antes da mudança, que quem mudou em geral
    /// já guardou (o igual não duplica); com a aba suja é o que a pessoa digitou e ainda
    /// não salvou, e que só existia ali.
    func guardarBuffer(_ path: String, antesDe novo: String, origem: OrigemDaVersao) {
        guard let texto = buffers[path], texto != novo, let u = try? ops.url(path) else { return }
        historico.guardar(texto: texto, de: u, raiz: root, origem: origem)
    }
}

// MARK: rótulos

extension OrigemDaVersao {
    /// Como a versão aparece na lista: o que veio depois dela.
    var rotulo: String {
        switch self {
        case .voce: tr("Antes de salvar")
        case .agente: tr("Antes do agente")
        case .patchRejeitado: tr("Antes de desfazer o agente")
        case .git: tr("Antes do git")
        case .restauracao: tr("Antes de restaurar")
        case .apagar: tr("Antes de apagar")
        case .externo: tr("Antes de mudar por fora")
        case .trocarTudo: tr("Antes de trocar tudo")
        case .recarregar: tr("Antes de recarregar do disco")
        case .terminal: tr("Antes do terminal")
        }
    }

    var simbolo: String {
        switch self {
        case .voce: "pencil"
        case .agente: "sparkles"
        case .patchRejeitado: "arrow.uturn.backward"
        case .git: "arrow.triangle.branch"
        case .restauracao: "clock.arrow.circlepath"
        case .apagar: "trash"
        case .externo: "arrow.down.doc"
        case .trocarTudo: "text.magnifyingglass"
        case .recarregar: "arrow.clockwise"
        case .terminal: "terminal"
        }
    }
}

// MARK: onde se abre

/// Os dois comandos da paleta. Ficam aqui para a paleta só somar a lista e repassar o id.
enum ComandosDoHistorico {
    static let arquivo = ">historico.arquivo"
    static let apagados = ">historico.apagados"

    static var itens: [PaletteItem] {
        [
            PaletteItem(
                id: arquivo,
                kind: .command,
                title: tr("Histórico local do arquivo"),
                detail: tr("versões guardadas neste aparelho"),
                symbol: "clock",
                shortcut: nil
            ),
            PaletteItem(
                id: apagados,
                kind: .command,
                title: tr("Arquivos apagados"),
                detail: tr("restaurar do histórico local"),
                symbol: "trash.slash",
                shortcut: nil
            ),
        ]
    }

    @MainActor
    static func executar(_ id: String, ws: WorkspaceModel) {
        switch id {
        case arquivo:
            if let p = ws.active {
                ws.historicoLocal.abrir(p)
            }
        case apagados: ws.historicoLocal.abrirApagados()
        default: break
        }
    }
}

/// Menu de toque longo de uma aba.
@MainActor
func menuDaAba(_ ws: WorkspaceModel) -> @MainActor (String) -> AnyView {
    { path in
        AnyView(Group {
            Button(tr("Histórico local"), systemImage: "clock") { ws.historicoLocal.abrir(path) }
            Button(tr("Copiar caminho"), systemImage: "doc.on.doc") { UIPasteboard.general.string = path }
            Divider()
            Button(tr("Fechar aba"), systemImage: "xmark") { ws.closeTab(path) }
        })
    }
}

/// O item do histórico no menu da árvore: o histórico do arquivo, ou os apagados que
/// estavam dentro da pasta.
struct BotaoDoHistoricoLocal: View {
    @Environment(WorkspaceModel.self) private var ws
    var caminho: String
    var pasta: Bool

    var body: some View {
        if pasta {
            Button(tr("Arquivos apagados aqui"), systemImage: "trash.slash") {
                ws.historicoLocal.abrirApagados(em: caminho)
            }
        } else {
            Button(tr("Histórico local"), systemImage: "clock") { ws.historicoLocal.abrir(caminho) }
        }
    }
}

/// As duas folhas, penduradas uma vez no espaço de trabalho — valem no iPad e no iPhone.
struct FolhasDoHistoricoLocal: ViewModifier {
    @Environment(WorkspaceModel.self) private var ws

    func body(content: Content) -> some View {
        let estado = ws.historicoLocal
        content
            .sheet(item: Binding(
                get: { estado.arquivo.map { PathRef(path: $0) } },
                set: { estado.arquivo = $0?.path }
            )) { r in
                NavigationStack {
                    HistoricoLocalView(caminho: r.path)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(tr("Fechar")) { estado.arquivo = nil }
                            }
                        }
                }
                .environment(ws)
                .presentationDetents([.large])
                .presentationSizing(.page)
            }
            .sheet(item: Binding(
                get: { estado.apagadosEm.map { PathRef(path: $0) } },
                set: { estado.apagadosEm = $0?.path }
            )) { r in
                ArquivosApagadosView(pasta: r.path)
                    .environment(ws)
                    .presentationDetents([.large])
                    .presentationSizing(.page)
            }
    }
}

extension View {
    func folhasDoHistoricoLocal() -> some View {
        modifier(FolhasDoHistoricoLocal())
    }
}
