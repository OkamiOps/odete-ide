import OdeteCore
import Runestone
import UIKit

/// Um editor por aba aberta, guardado entre uma troca de aba e outra.
///
/// Trocar de aba chamava `setState` no mesmo `TextView`, e o Runestone, ao receber
/// estado novo, apaga a pilha de desfazer (`removeAllActions`) e analisa o arquivo
/// inteiro de novo. Quem editava um arquivo, olhava outro e voltava tinha perdido o ⌘Z —
/// e esperava a reanálise a cada troca. Aqui cada documento guarda o seu `TextView`, com
/// desfazer, cursor e rolagem dentro dele: trocar de aba é tirar um da tela e pôr outro.
///
/// A memória fica presa: só os `capacidade` documentos usados por último guardam editor.
/// O que sai da fila deixa anotado onde estavam o cursor e a rolagem, para reabrir no
/// mesmo ponto — o desfazer não sobrevive, porque morava no editor que foi embora.
@MainActor
public final class SessoesDoEditor {
    static let shared = SessoesDoEditor(capacidade: 6)

    /// O editor de um documento e o que foi preciso para montá-lo.
    final class Sessao {
        let documento: String
        let textView: OdeteTextView
        /// Barra acessória deste editor. Guardada aqui porque `inputAccessoryView` do
        /// Runestone devolve nulo enquanto o editor não está em edição.
        let barra: KeyboardBar
        /// Toque no texto (import sublinhado, onda de problema). O alvo muda com o dono.
        let toque: UITapGestureRecognizer
        /// Tema, fonte e linguagem com que o estado foi montado. Se mudar, refaz.
        var assinatura: AssinaturaDoTema
        /// Editor montado só para um host que perdeu o seu para outro (ver
        /// `Coordinator.perdeuSessao`). Não entra na fila e some ao sair da tela.
        let avulsa: Bool
        /// Onde estava a tela quando este documento foi despejado da última vez; aplicado
        /// quando o editor novo ganha tamanho.
        var rolagemPendente: CGPoint?
        weak var host: HostDoEditor?
        weak var coordenador: CodeEditorView.Coordinator?
        var usadoEm: UInt64 = 0
        /// A aba foi fechada com o editor na tela: quando ele sair, vai embora em vez de
        /// ficar guardado.
        var descartarAoSair = false
        /// O recuo e a quebra de linha que o próprio texto usa, lidos pelo Runestone ao
        /// montar o estado. Quebra `nil` é texto de uma linha só.
        var recuoDetectado: DetectedIndentStrategy = .unknown
        var quebraDetectada: LineEnding?

        init(
            documento: String,
            textView: OdeteTextView,
            barra: KeyboardBar,
            toque: UITapGestureRecognizer,
            assinatura: AssinaturaDoTema,
            avulsa: Bool
        ) {
            self.documento = documento
            self.textView = textView
            self.barra = barra
            self.toque = toque
            self.assinatura = assinatura
            self.avulsa = avulsa
        }
    }

    /// Onde o cursor e a rolagem estavam num documento cujo editor foi despejado.
    struct EstadoSalvo: Equatable {
        var selecao: NSRange
        var rolagem: CGPoint
    }

    /// O último pedido de substituir e de ir para uma linha que cada documento atendeu.
    struct PedidosAtendidos {
        var troca = -1
        var linha = -1
    }

    let capacidade: Int
    private(set) var sessoes: [String: Sessao] = [:]
    private(set) var estados: [String: EstadoSalvo] = [:]
    /// Por documento, e não por coordenador nem por editor: o coordenador nasce a cada
    /// host novo (troca de modo, lados do modo Dois) e o editor pode ser despejado e
    /// remontado, ou montado avulso. Cada um deles nascia sem lembrar de nada e refazia a
    /// última substituição e o último salto de linha.
    var atendidos: [String: PedidosAtendidos] = [:]
    private var relogio: UInt64 = 0
    /// Coordenadores com editor na tela, para os comandos do menu acharem o editor certo.
    private let coordenadores = NSHashTable<CodeEditorView.Coordinator>.weakObjects()

    init(capacidade: Int) {
        self.capacidade = max(capacidade, 1)
    }

    func sessao(_ documento: String) -> Sessao? {
        sessoes[documento]
    }

    /// Guarda uma sessão nova. Pode despejar a usada há mais tempo.
    func registrar(_ s: Sessao) {
        guard !s.avulsa else { return }
        sessoes[s.documento] = s
        tocar(s)
        despejar()
    }

    /// Marca a sessão como a usada por último.
    func tocar(_ s: Sessao) {
        relogio &+= 1
        s.usadoEm = relogio
    }

    /// Tirou o editor da tela. Fica guardado, a não ser que a aba já tenha fechado.
    func estacionar(_ s: Sessao) {
        s.host = nil
        s.coordenador = nil
        if s.avulsa {
            return
        }
        if s.descartarAoSair {
            remover(s.documento)
            return
        }
        tocar(s)
        despejar()
    }

    func estadoSalvo(_ documento: String) -> EstadoSalvo? {
        estados[documento]
    }

    /// Esquece o documento de vez: editor, cursor e rolagem.
    func remover(_ documento: String) {
        if let s = sessoes[documento], s.host != nil {
            s.descartarAoSair = true
            estados[documento] = nil
            return
        }
        sessoes[documento] = nil
        estados[documento] = nil
        atendidos[documento] = nil
    }

    /// Solta os editores dos documentos do projeto que não estão mais em aba nenhuma.
    ///
    /// `prefixo` é o começo do identificador de documento do projeto: outro projeto
    /// aberto noutra janela não tem seus editores mexidos.
    func manter(prefixo: String, abertos: Set<String>) {
        let fechados = Set(sessoes.keys).union(estados.keys)
            .filter { $0.hasPrefix(prefixo) && !abertos.contains($0) }
        for d in fechados {
            remover(d)
        }
    }

    /// Enquanto houver mais editores que a capacidade, o usado há mais tempo que não está
    /// na tela vai embora — deixando anotado onde estavam o cursor e a rolagem.
    private func despejar() {
        while sessoes.count > capacidade {
            let fora = sessoes.values.filter { $0.host == nil }
            guard let velha = fora.min(by: { $0.usadoEm < $1.usadoEm }) else { return }
            estados[velha.documento] = EstadoSalvo(
                selecao: velha.textView.selectedRange,
                rolagem: velha.textView.contentOffset
            )
            velha.textView.editorDelegate = nil
            velha.textView.removeFromSuperview()
            sessoes[velha.documento] = nil
        }
    }

    // MARK: - Quem está na tela

    func entrouNaTela(_ c: CodeEditorView.Coordinator) {
        coordenadores.add(c)
    }

    func saiuDaTela(_ c: CodeEditorView.Coordinator) {
        coordenadores.remove(c)
    }

    /// O editor que deve receber um comando: o que está com o foco; sem foco em nenhum,
    /// o que mostra `documento`.
    func alvo(documento: String?) -> CodeEditorView.Coordinator? {
        let visiveis = coordenadores.allObjects.filter { $0.textView != nil }
        if let focado = visiveis.first(where: { $0.textView?.isEditing == true }) {
            return focado
        }
        guard let documento else { return nil }
        return visiveis.first { $0.documentId == documento }
    }

    // MARK: - API pública

    /// Fechou aba: o editor do documento vai embora e não conta mais na fila.
    ///
    /// `prefixo` identifica o projeto (o começo do `documentId`); `documentos` são os
    /// identificadores das abas que continuam abertas nele.
    public static func manterAbertos(prefixo: String, documentos: Set<String>) {
        shared.manter(prefixo: prefixo, abertos: documentos)
    }
}

/// O que decide se o estado do editor precisa ser remontado: mudou a cor, a fonte ou a
/// gramática, refaz; o resto (recuo, quebra de linha) é ajuste solto.
struct AssinaturaDoTema: Equatable {
    var palette: ThemePalette
    var fontSize: Double
    var familia: EditorFont
    var linguagem: Language
}

/// Onde o editor aparece. Os editores de cada aba entram e saem daqui.
///
/// Também é o elo da cadeia de respondedores logo acima do editor: os atalhos que
/// disputam tecla com o próprio sistema de texto (⌥↑, ⌥↓, ⌃Tab) moram aqui, com
/// prioridade sobre o comportamento padrão — pelo menu eles perderiam para a navegação
/// de texto, que o iPadOS atende primeiro.
public final class HostDoEditor: UIView {
    weak var coordenador: CodeEditorView.Coordinator?

    override public init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        nil
    }

    override public var keyCommands: [UIKeyCommand]? {
        var lista = [
            comando(UIKeyCommand.inputUpArrow, [.alternate], #selector(subirLinhas)),
            comando(UIKeyCommand.inputDownArrow, [.alternate], #selector(descerLinhas)),
            comando(UIKeyCommand.inputDownArrow, [.alternate, .shift], #selector(duplicarLinhas)),
            comando("\t", [.control], #selector(proximaAba)),
            comando("\t", [.control, .shift], #selector(abaAnterior)),
            // ⇧Tab desindenta, como em todo editor de código. Sem isto a tecla não fazia
            // nada — ou tirava o foco do editor.
            comando("\t", [.shift], #selector(desindentar)),
        ]
        if coordenador?.problemaVisivel == true {
            lista.append(comando(UIKeyCommand.inputEscape, [], #selector(esconderProblema)))
        }
        return (super.keyCommands ?? []) + lista
    }

    /// Sem título de propósito: o menu Editar já lista os mesmos atalhos, e com título
    /// eles apareceriam duas vezes no painel do ⌘.
    private func comando(_ tecla: String, _ mods: UIKeyModifierFlags, _ acao: Selector) -> UIKeyCommand {
        let c = UIKeyCommand(input: tecla, modifierFlags: mods, action: acao)
        c.wantsPriorityOverSystemBehavior = true
        return c
    }

    @objc private func subirLinhas() {
        coordenador?.executar(.subirLinhas)
    }

    @objc private func descerLinhas() {
        coordenador?.executar(.descerLinhas)
    }

    @objc private func duplicarLinhas() {
        coordenador?.executar(.duplicarLinhas)
    }

    @objc private func desindentar() {
        coordenador?.executar(.desindentar)
    }

    @objc private func proximaAba() {
        coordenador?.parent.onTrocarAba(1)
    }

    @objc private func abaAnterior() {
        coordenador?.parent.onTrocarAba(-1)
    }

    @objc private func esconderProblema() {
        coordenador?.esconderProblema()
    }
}
