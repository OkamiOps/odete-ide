import OdeteCore
import Runestone
import SwiftUI
import UIKit

/// Editor de código nativo. Envolve `Runestone.TextView`.
///
/// Cada documento tem o seu `TextView`, guardado em `SessoesDoEditor`: quando
/// `documentId` muda, o editor da aba anterior sai de cena inteiro — com o desfazer, o
/// cursor e a rolagem — e o da aba nova entra. Recriar o estado a cada troca, como era,
/// apagava o ⌘Z e reanalisava o arquivo.
public struct CodeEditorView: UIViewRepresentable {
    @Binding public var text: String
    public var documentId: String
    public var language: Language
    public var palette: ThemePalette
    public var prefs: EditorPrefs
    /// Linha (1-based) a revelar; muda o `token` para revelar de novo a mesma linha.
    public var reveal: (line: Int, token: Int)?
    public var marks: [EditorGutterMark]
    public var issues: [EditorIssue]
    /// Linhas do patch pendente do agente, para ele aparecer dentro do código.
    public var changes: [EditorLineChange]
    /// Caminhos de import que apontam para arquivos do projeto.
    public var links: [EditorLink]
    /// Busca dentro deste arquivo.
    public var find: EditorFind?
    /// Pedido de substituição, disparado pelo `token`.
    public var replace: EditorReplace?
    public var completion: CompletionSource?
    public var onSave: () -> Void
    public var onFind: () -> Void
    public var onGutterLongPress: (Int) -> Void
    public var onCursor: (Int) -> Void
    /// Tocou num caminho de import sublinhado.
    public var onOpenLink: (String) -> Void
    /// Quantas ocorrências a busca do arquivo achou.
    public var onFindResults: (Int) -> Void
    /// Pediu para ir à definição do nome sob o cursor.
    public var onDefinition: () -> Void
    /// Mandar para o agente: o texto escolhido e as linhas (1-based) de onde ele veio.
    public var onSendSelection: (String, Int, Int) -> Void
    /// ⌃Tab e ⌃⇧Tab com o cursor no editor: a aba seguinte (+1) ou a anterior (−1).
    /// Vem por aqui, e não só pelo menu, porque a navegação de foco do sistema pega o
    /// ⌃Tab antes do menu quando há texto em edição.
    public var onTrocarAba: (Int) -> Void
    /// O que o `.editorconfig` do projeto diz deste arquivo: recuo e quebra de linha.
    public var config: ConfigDoArquivo?
    /// O pedido de substituição (`replace`) com este `token` foi atendido: quem pediu pode
    /// esquecê-lo. Chega fora da atualização da view.
    public var aoConsumirTroca: (Int) -> Void
    /// O mesmo para o pedido de ir à linha (`reveal`).
    public var aoConsumirLinha: (Int) -> Void

    public init(
        text: Binding<String>,
        documentId: String,
        language: Language,
        palette: ThemePalette,
        prefs: EditorPrefs,
        reveal: (line: Int, token: Int)? = nil,
        marks: [EditorGutterMark] = [],
        issues: [EditorIssue] = [],
        changes: [EditorLineChange] = [],
        links: [EditorLink] = [],
        find: EditorFind? = nil,
        replace: EditorReplace? = nil,
        completion: CompletionSource? = nil,
        config: ConfigDoArquivo? = nil,
        onSave: @escaping () -> Void = {},
        onFind: @escaping () -> Void = {},
        onGutterLongPress: @escaping (Int) -> Void = { _ in },
        onCursor: @escaping (Int) -> Void = { _ in },
        onOpenLink: @escaping (String) -> Void = { _ in },
        onFindResults: @escaping (Int) -> Void = { _ in },
        onDefinition: @escaping () -> Void = {},
        onSendSelection: @escaping (String, Int, Int) -> Void = { _, _, _ in },
        onTrocarAba: @escaping (Int) -> Void = { _ in },
        aoConsumirTroca: @escaping (Int) -> Void = { _ in },
        aoConsumirLinha: @escaping (Int) -> Void = { _ in }
    ) {
        _text = text
        self.documentId = documentId
        self.language = language
        self.palette = palette
        self.prefs = prefs
        self.reveal = reveal
        self.marks = marks
        self.issues = issues
        self.changes = changes
        self.links = links
        self.find = find
        self.replace = replace
        self.completion = completion
        self.onSave = onSave
        self.onFind = onFind
        self.onGutterLongPress = onGutterLongPress
        self.onCursor = onCursor
        self.onOpenLink = onOpenLink
        self.onFindResults = onFindResults
        self.onDefinition = onDefinition
        self.onSendSelection = onSendSelection
        self.onTrocarAba = onTrocarAba
        self.config = config
        self.aoConsumirTroca = aoConsumirTroca
        self.aoConsumirLinha = aoConsumirLinha
    }

    public func makeUIView(context: Context) -> HostDoEditor {
        let host = HostDoEditor(frame: .zero)
        let c = context.coordinator
        c.overlay.onLongPress = { [weak c] line in c?.parent.onGutterLongPress(line) }
        c.minimap.aoNavegar = { [weak c] f in
            guard let tv = c?.textView else { return }
            let maximo = max(0, tv.contentSize.height - tv.bounds.height)
            tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: maximo * f), animated: false)
        }
        c.popup.onPick = { [weak c] item in c?.accept(item) }
        c.exibir(em: host)
        c.conferirTema()
        return host
    }

    public func updateUIView(_ host: HostDoEditor, context: Context) {
        let c = context.coordinator
        c.parent = self
        // Trocou de aba: sai o editor da anterior, entra o desta — cada um com o seu
        // desfazer, cursor e rolagem. Ver `SessoesDoEditor`.
        let docChanged = c.exibir(em: host)
        guard let tv = c.textView else { return }
        // A família da fonte entra aqui: trocar de fonte é refazer o tema, não um ajuste
        // solto — o destaque de sintaxe carrega a fonte em cada faixa colorida.
        c.conferirTema()
        if !c.isEditing, c.textoAtual != text {
            // O texto mudou por fora (disco, salvar arrumando, agente) — só nesta aba.
            c.aplicarTextoDeFora(text, em: tv)
            c.scheduleDecorations()
        }
        applyPrefs(tv, context: context)
        c.agendarMinimapa()
        if docChanged {
            DispatchQueue.main.async { c.positionOverlay() }
        }
        let barra = c.sessao?.barra
        barra?.onSave = onSave
        barra?.onFind = onFind
        barra?.onDefinition = onDefinition
        barra?.onSendSelection = { [weak c] in c?.mandarSelecao() }
        barra?.onComentar = { [weak c] in c?.executar(.alternarComentario) }
        barra?.onTab = { [weak c] in c?.tabularPelaBarra() }
        barra?.onDesindentar = { [weak c] in c?.executar(.desindentar) }
        if c.marks != marks || c.issues != issues || c.changes != changes || c.links != links || docChanged {
            c.marks = marks
            c.issues = issues
            c.changes = changes
            c.links = links
            c.scheduleDecorations()
        }
        if c.find != find || docChanged {
            c.find = find
            c.buscar(tv)
        }
        c.atenderPedidos(tv)
    }

    public static func dismantleUIView(_: HostDoEditor, coordinator: Coordinator) {
        coordinator.desmontar()
    }

    private func applyPrefs(_ tv: TextView, context: Context) {
        let c = context.coordinator
        tv.showLineNumbers = prefs.lineNumbers
        tv.isLineWrappingEnabled = prefs.wrap
        // O recuo é do arquivo, não dos Ajustes: o `.editorconfig`, senão o que o texto já
        // usa, e só por último o padrão. Forçar espaços dos Ajustes em todo arquivo fazia o
        // Tab e o Enter recuarem com espaços num arquivo de tabs.
        let recuo = c.estrategiaDeRecuo(prefs)
        if tv.indentStrategy != recuo {
            tv.indentStrategy = recuo
        }
        c.aplicarQuebra(tv)
        tv.showSpaces = prefs.showWhitespace
        tv.showTabs = prefs.showWhitespace
        tv.showNonBreakingSpaces = prefs.showWhitespace
        tv.showLineBreaks = prefs.showLineBreaks
        tv.showSoftLineBreaks = prefs.showLineBreaks && prefs.wrap
        tv.showPageGuide = prefs.pageGuide > 0
        tv.pageGuideColumn = max(prefs.pageGuide, 1)
        tv.lineSelectionDisplayType = prefs.highlightLine ? .line : .disabled
        tv.kern = prefs.kern
        tv.lineBreakMode = .byWordWrapping
        // Espaço depois da última linha. Sem ele, quem está editando o fim do arquivo
        // digita colado na borda de baixo, com o teclado logo abaixo.
        let fundo: CGFloat = prefs.scrollPastEnd ? 200 : 24
        if tv.textContainerInset.bottom != fundo {
            tv.textContainerInset.bottom = fundo
        }
        tv.characterPairs = prefs.autoClosePairs ? Self.pairs : []
        // Comparado com o do próprio editor, e não com o último aplicado: cada aba tem o
        // seu `TextView`, e o que acabou de entrar pode ter vindo com o padrão.
        if tv.lineHeightMultiplier != CGFloat(prefs.lineHeight) {
            c.lineHeight = prefs.lineHeight
            tv.lineHeightMultiplier = prefs.lineHeight
        }
        // As guias e o minimapa contam o recuo na mesma unidade que o Tab insere.
        let largura = max(recuo.largura, 1)
        if c.guidesOn != prefs.indentGuides || c.tabWidth != largura {
            c.guidesOn = prefs.indentGuides
            c.tabWidth = largura
            c.minimapTexto = ""
            c.scheduleDecorations()
        }
        if c.minimapSize != prefs.minimap {
            c.minimapSize = prefs.minimap
            c.minimap.tamanho = prefs.minimap
            c.minimapTexto = ""
            c.agendarMinimapa()
        }
        c.positionOverlay()
        // O texto não pode correr por baixo do mapa.
        let reservado = MinimapView.largura(prefs.minimap)
        if tv.textContainerInset.right != reservado + 8 {
            tv.textContainerInset.right = reservado + 8
        }
    }

    static let pairs: [CharacterPair] = [
        Pair("(", ")"),
        Pair("[", "]"),
        Pair("{", "}"),
        Pair("\"", "\""),
        Pair("'", "'"),
        Pair("`", "`"),
    ]

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency TextViewDelegate,
        @preconcurrency UIGestureRecognizerDelegate
    {
        var parent: CodeEditorView
        weak var textView: TextView?
        var documentId = ""
        var palette: ThemePalette?
        var fontSize: Double = 0
        var fontFamily: EditorFont = .plex
        var isEditing = false
        /// Uma edição do próprio editor está em curso (comando, substituição, texto que
        /// chegou de fora) — ver `editarPorDentro`.
        var editandoPorDentro = false
        var marks: [EditorGutterMark] = []
        var issues: [EditorIssue] = []
        var changes: [EditorLineChange] = []
        var links: [EditorLink] = []
        var find: EditorFind?
        /// Onde estão as ocorrências da busca no arquivo.
        var buscaRanges: [NSRange] = []
        let overlay = GutterOverlay(frame: .zero)
        let guides = IndentGuides(frame: .zero)
        let changeMarks = ChangeMarks(frame: .zero)
        let popup = CompletionPopup(frame: .zero)
        let minimap = MinimapView(frame: .zero)
        /// A mensagem do problema tocado, logo abaixo da onda.
        let balao = BalaoDeProblema(frame: .zero)
        /// Versão do texto quando o balão abriu; mudou, ele fecha.
        var versaoDoBalao = -1
        var minimapSize: MinimapSize = .off
        var minimapTexto = ""
        var lineHeight: Double = 0
        var guidesOn = true
        var tabWidth = 2
        var offsetObservation: NSKeyValueObservation?
        var decorationTask: Task<Void, Never>?
        var minimapTask: Task<Void, Never>?
        /// O texto do documento como o coordenador o conhece.
        ///
        /// `tv.text` parece um campo e não é: cada leitura remonta a String inteira a
        /// partir da estrutura interna do Runestone, e custa o tamanho do arquivo.
        /// Medido no simulador, uma tecla num arquivo de 2000 linhas gastava 84 ms de
        /// CPU — porque o documento era remontado quatro vezes por tecla: no delegate,
        /// duas em `updateUIView` e mais uma na decoração. Guardar aqui troca quatro
        /// varreduras por uma.
        var textoAtual = ""
        /// Sobe a cada mudança do texto. É o que invalida o cache de início de linha.
        var versaoDoTexto = 0
        /// O mapa de linhas do texto atual, guardado por versão — ver `linhas()`.
        var mapaCacheado = MapaDeLinhas("")
        var versaoCacheada = -1
        /// Em que linha o cursor estava da última vez, para não refazer decoração
        /// quando ele só anda dentro da mesma.
        var ultimaLinhaDoCursor = -1
        /// Onde os editores de cada documento ficam guardados entre uma aba e outra.
        let sessoes: SessoesDoEditor
        /// O documento na tela agora e o editor dele.
        var sessao: SessoesDoEditor.Sessao?
        weak var host: HostDoEditor?
        /// SwiftUI já desmontou este editor: não adianta mais pedir um `TextView`.
        var desmontado = false
        /// O contexto da lista aberta: onde começa o prefixo que a escolha substitui.
        var popupContext: CompletionContext?
        /// As palavras do documento, montadas fora do ator principal — ver `IndiceDePalavras`.
        var indicePalavras = IndiceDePalavras.vazio
        var indiceTask: Task<Void, Never>?
        /// Sobe a cada pedido de índice; resposta de pedido velho que chega depois é jogada fora.
        var pedidoDoIndice = 0
        /// Começo da linha do cursor no último pedido, para a troca de linha não pedir de
        /// novo o que já está a caminho.
        var linhaDoPedido = -1
        /// A última mudança de texto passou por `shouldChangeTextIn`, e ficou dentro de uma
        /// linha só? Então o índice continua valendo — a conta por linha cobre a diferença.
        var mudancaAnunciada = false
        var mudancaNaLinha = false

        init(parent: CodeEditorView, sessoes: SessoesDoEditor = .shared) {
            self.parent = parent
            self.sessoes = sessoes
        }

        public func textViewDidChange(_ textView: TextView) {
            // Edição do próprio editor: quem a fez anota o texto uma vez no fim, em vez de
            // remontar o documento a cada trecho trocado — ver `editarPorDentro`.
            if editandoPorDentro {
                return
            }
            isEditing = true
            textoAtual = textView.text
            versaoDoTexto &+= 1
            parent.text = textoAtual
            isEditing = false
            scheduleDecorations()
            offerCompletions()
            agendarMinimapa()
        }

        /// O minimapa mede cada linha do arquivo para desenhar. Fazer isso a cada tecla
        /// é medir 2000 linhas para mostrar uma mudança de um caractere; esperar a
        /// pessoa parar de digitar mostra o mesmo desenho pelo preço de uma medição.
        func agendarMinimapa() {
            guard minimapSize != .off else { return }
            minimapTask?.cancel()
            minimapTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self else { return }
                atualizarMinimapa(textoAtual)
            }
        }

        func atualizarMinimapa(_ texto: String) {
            guard minimapSize != .off, texto != minimapTexto else { return }
            minimapTexto = texto
            minimap.linhas = MinimapView.medir(texto, tabWidth: tabWidth)
        }

        public func textViewDidChangeSelection(_ textView: TextView) {
            parent.onCursor(textView.selectedRange.location)
            // A guia de recuo marca a linha do cursor, então só muda quando o cursor
            // muda de linha. Refazer a decoração a cada seta para o lado era redesenhar
            // o arquivo inteiro para nada.
            if guidesOn {
                let linha = linhaDe(textView.selectedRange.location)
                if linha != ultimaLinhaDoCursor {
                    ultimaLinhaDoCursor = linha
                    scheduleDecorations()
                }
            }
            if popupContext != nil, !popup.isHidden {
                // Cursor saiu da palavra: fecha.
                let ctx = contextoNoCursor(textView)?.ctx
                if ctx?.inicioUTF16 != popupContext?.inicioUTF16 {
                    hidePopup()
                }
            }
            conferirLinhaDoIndice(textView)
        }

        public func textViewDidChangeGutterWidth(_: TextView) {
            scheduleDecorations()
        }

        public func textView(_ tv: TextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            // Edição do próprio editor não é tecla: nem Tab vira recuo, nem Enter aceita
            // sugestão.
            if editandoPorDentro {
                return true
            }
            // Num arquivo CRLF o Runestone estraga o texto que já chega com `\r\n` (colar,
            // envolver a seleção em parênteses): ver `QuebrasDeLinha.desfazerPreparoCRLF`.
            // O texto volta ao que era e entra de novo, agora preparado uma vez só.
            if tv.lineEndings == .crlf, text.contains("\r\r\n") {
                tv.replace(range, withText: QuebrasDeLinha.desfazerPreparoCRLF(text))
                return false
            }
            // Num arquivo CRLF o Enter chega como `\r\n`.
            let enter = text == "\n" || text == "\r\n" || text == "\r"
            if !popup.isHidden, let escolhida = popup.itemSelecionado, text == "\t" || enter {
                accept(escolhida)
                return false
            }
            if enter || text == " " {
                hidePopup()
            }
            if text == "\t", tabular(tv, faixa: range) {
                return false
            }
            // Tecla dentro de uma linha não muda o resto do documento: o índice de palavras
            // segue valendo. Quebra de linha no texto novo ou no trecho trocado, não.
            mudancaAnunciada = true
            mudancaNaLinha = !text.contains(where: \.isNewline)
                && (range.length == 0 || !(tv.text(in: range) ?? "\n").contains(where: \.isNewline))
            return true
        }

        public func textViewDidEndEditing(_: TextView) {
            hidePopup()
        }

        // MARK: - Autocompletar

        // `offerCompletions`, `accept`, o contexto por janela, o índice de palavras e as
        // teclas da lista moram numa extensão em `Decorations.swift`, junto da lista.
    }
}

/// O Runestone traz o gutter para a frente a cada layout; as decorações da Odete vêm depois dele.
final class OdeteTextView: TextViewComSugestoes {
    var floating: [UIView] = []
    /// Chamado a cada passagem de layout: é aqui que as camadas flutuantes se
    /// reposicionam. Sem isto elas só se mexiam quando o conteúdo rolava.
    var aoLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        aoLayout?()
        for v in floating where v.superview === self {
            bringSubviewToFront(v)
        }
    }
}

private struct Pair: CharacterPair {
    let leading: String
    let trailing: String
    init(_ l: String, _ t: String) {
        leading = l
        trailing = t
    }
}
