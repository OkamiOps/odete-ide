import OdeteEditor
import OdeteI18n
import OdeteUI
import SwiftUI

/// Estado da busca dentro do arquivo aberto: uma barra que aparece em cima do editor e
/// some quando fecha.
@Observable
public final class BuscaLocal {
    public init() {}
    var aberta = false
    var texto = ""
    var caseSensitive = false
    var regex = false
    var indice = 0
    var total = 0
    /// Substituir só aparece quando pedido: na maior parte das vezes a pessoa só quer achar.
    var mostrarTroca = false
    var troca = ""
    /// O arquivo em que se procura. `nil` é o arquivo ativo. No modo Dois a busca é de um
    /// lado só: antes os dois editores recebiam a mesma busca e a mesma substituição, e
    /// "Todos" trocava nos dois arquivos.
    var caminho: String?
    /// O pedido de substituição ainda não atendido. Some quando o editor avisa que
    /// substituiu — ver `EditorReplace`.
    private(set) var pedidoDeTroca: EditorReplace?

    public var find: EditorFind? {
        aberta && !texto.isEmpty
            ? EditorFind(texto: texto, caseSensitive: caseSensitive, regex: regex, indice: indice)
            : nil
    }

    public var replace: EditorReplace? {
        pedidoDeTroca
    }

    func trocar(todos: Bool) {
        pedidoDeTroca = EditorReplace(por: troca, todos: todos, token: TokensDoEditor.proximo())
    }

    /// O editor substituiu: o pedido não vale mais.
    public func trocaFeita(_ token: Int) {
        if pedidoDeTroca?.token == token {
            pedidoDeTroca = nil
        }
    }

    /// Em que arquivo a busca vale, entre os que estão na tela (`visiveis`): o escolhido,
    /// se ainda está à vista; senão o ativo.
    public func alvo(visiveis: [String], ativo: String?) -> String? {
        if let caminho, visiveis.contains(caminho) {
            return caminho
        }
        return ativo
    }

    func proximo() {
        guard total > 0 else { return }
        indice = (indice + 1) % total
    }

    func anterior() {
        guard total > 0 else { return }
        indice = (indice - 1 + total) % total
    }

    /// Resultado novo: volta para o primeiro, senão o foco fica num índice que já não
    /// existe e a barra diz "7 de 3".
    public func contagem(_ n: Int) {
        total = n
        if indice >= n {
            indice = 0
        }
    }

    /// Abre a barra para `caminho` — o lado do modo Dois cuja lupa foi tocada. Sem
    /// caminho (⌘F, menu), vale o arquivo ativo.
    public func abrir(_ caminho: String? = nil) {
        if caminho != self.caminho {
            total = 0
            indice = 0
        }
        self.caminho = caminho
        aberta = true
    }

    func fechar() {
        aberta = false
        texto = ""
        total = 0
        indice = 0
        mostrarTroca = false
        caminho = nil
        pedidoDeTroca = nil
    }
}

/// Barra de localizar do arquivo: campo, contagem, anterior/próximo e, se pedido,
/// substituir.
struct FindBar: View {
    @Environment(\.theme) private var theme
    @Bindable var busca: BuscaLocal
    @FocusState private var focado: Bool

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                campo
                contagem
                Button { busca.anterior() } label: { Image(systemName: "chevron.up") }
                    .disabled(busca.total == 0)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .accessibilityLabel(tr("Anterior"))
                Button { busca.proximo() } label: { Image(systemName: "chevron.down") }
                    .disabled(busca.total == 0)
                    .keyboardShortcut("g", modifiers: .command)
                    .accessibilityLabel(tr("Próximo"))
                opcoes
                Button { busca.fechar() } label: { Image(systemName: "xmark") }
                    .keyboardShortcut(.escape, modifiers: [])
                    .accessibilityLabel(tr("Fechar busca"))
            }
            if busca.mostrarTroca {
                HStack(spacing: 8) {
                    TextField(tr("Substituir por"), text: $busca.troca)
                        .textFieldStyle(.plain)
                        .font(OdeteFont.mono(12))
                        .padding(.horizontal, 8)
                        .frame(height: 28)
                        .background(theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(tr("Este")) { busca.trocar(todos: false) }
                        .disabled(busca.total == 0)
                    Button(tr("Todos")) { busca.trocar(todos: true) }
                        .disabled(busca.total == 0)
                }
                .font(.caption)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(theme.surface)
        .overlay(alignment: .bottom) { Rectangle().fill(theme.separator).frame(height: 0.5) }
        .onAppear { focado = true }
    }

    var campo: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.fgSubtle)
            TextField(tr("Localizar no arquivo"), text: $busca.texto)
                .textFieldStyle(.plain)
                .font(OdeteFont.mono(12))
                .focused($focado)
                .submitLabel(.next)
                .onSubmit { busca.proximo() }
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(theme.bg, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// "3 de 12", ou o aviso de que não achou nada — sem isso a única pista de busca sem
    /// resultado é o código continuar igual.
    var contagem: some View {
        Text(rotulo)
            .font(.caption).monospacedDigit()
            .foregroundStyle(busca.texto.isEmpty || busca.total > 0 ? theme.fgMuted : theme.danger)
            .lineLimit(1).fixedSize()
    }

    var rotulo: String {
        if busca.texto.isEmpty {
            return ""
        }
        return busca.total == 0 ? "nada" : "\(busca.indice + 1) de \(busca.total)"
    }

    var opcoes: some View {
        Menu {
            Toggle(tr("Diferenciar maiúsculas"), isOn: $busca.caseSensitive)
            Toggle(tr("Expressão regular"), isOn: $busca.regex)
            Divider()
            Toggle(tr("Substituir"), isOn: $busca.mostrarTroca)
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(tr("Opções da busca"))
    }
}
