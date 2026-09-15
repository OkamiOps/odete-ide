import OdeteCore
import Runestone
import SwiftUI
import UIKit

/// Editor de código nativo. Envolve `Runestone.TextView`.
/// `documentId` muda quando o arquivo aberto muda; aí o estado é recriado com a linguagem certa.
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
        onSave: @escaping () -> Void = {},
        onFind: @escaping () -> Void = {},
        onGutterLongPress: @escaping (Int) -> Void = { _ in },
        onCursor: @escaping (Int) -> Void = { _ in },
        onOpenLink: @escaping (String) -> Void = { _ in },
        onFindResults: @escaping (Int) -> Void = { _ in },
        onDefinition: @escaping () -> Void = {}
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
    }

    public func makeUIView(context: Context) -> TextView {
        let tv = OdeteTextView()
        tv.editorDelegate = context.coordinator
        tv.backgroundColor = UIColor(hex: palette.bg)
        tv.autocorrectionType = .no
        tv.autocapitalizationType = .none
        tv.smartQuotesType = .no
        tv.smartDashesType = .no
        tv.smartInsertDeleteType = .no
        tv.spellCheckingType = .no
        tv.keyboardType = .asciiCapable
        tv.alwaysBounceVertical = true
        // Trackpad e Magic Mouse mandam scroll contínuo; sem isto o editor só rola
        // com o dedo ou clicando e arrastando.
        tv.panGestureRecognizer.allowedScrollTypesMask = .all
        tv.gutterLeadingPadding = 8
        tv.gutterTrailingPadding = 12
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 200, right: 8)
        tv.lineSelectionDisplayType = .line
        tv.characterPairs = Self.pairs
        tv.inputAccessoryView = KeyboardBar(
            textView: tv,
            onSave: onSave,
            onFind: onFind,
            onDefinition: onDefinition
        )
        let c = context.coordinator
        c.textView = tv
        c.overlay.onLongPress = { [weak c] line in c?.parent.onGutterLongPress(line) }
        tv.addSubview(c.guides)
        tv.addSubview(c.changeMarks)
        tv.addSubview(c.overlay)
        tv.addSubview(c.minimap)
        tv.floating = [c.guides, c.changeMarks, c.overlay, c.minimap, c.popup]
        tv.aoLayout = { [weak c] in c?.positionOverlay() }
        c.minimap.aoNavegar = { [weak tv] f in
            guard let tv else { return }
            let maximo = max(0, tv.contentSize.height - tv.bounds.height)
            tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: maximo * f), animated: false)
        }
        c.popup.onPick = { [weak c] item in c?.accept(item) }
        // Toque no caminho do import. Não cancela o toque original: o cursor continua
        // indo para onde a pessoa tocou, e só quando o ponto cai dentro do sublinhado é
        // que o arquivo abre.
        let toque = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tocouNoTexto(_:)))
        toque.cancelsTouchesInView = false
        toque.delegate = c
        tv.addGestureRecognizer(toque)
        c.offsetObservation = tv.observe(\.contentOffset, options: [.new]) { [weak c] _, _ in
            Task { @MainActor in c?.positionOverlay() }
        }
        apply(to: tv, context: context, fullReset: true)
        return tv
    }

    public func updateUIView(_ tv: TextView, context: Context) {
        let c = context.coordinator
        let docChanged = c.documentId != documentId
        let themeChanged = c.palette != palette || c.fontSize != prefs.fontSize
        if docChanged || themeChanged {
            apply(to: tv, context: context, fullReset: true)
        } else if !c.isEditing, tv.text != text {
            tv.text = text
            c.scheduleDecorations()
        }
        c.parent = self
        applyPrefs(tv, context: context)
        c.atualizarMinimapa(tv.text)
        if docChanged {
            DispatchQueue.main.async { c.positionOverlay() }
        }
        (tv.inputAccessoryView as? KeyboardBar)?.onSave = onSave
        (tv.inputAccessoryView as? KeyboardBar)?.onFind = onFind
        (tv.inputAccessoryView as? KeyboardBar)?.onDefinition = onDefinition
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
        if let replace, c.replaceToken != replace.token {
            c.replaceToken = replace.token
            c.substituir(tv, replace)
        }
        if let reveal, c.revealToken != reveal.token {
            c.revealToken = reveal.token
            DispatchQueue.main.async {
                _ = tv.goToLine(max(reveal.line - 1, 0), select: .line)
                tv.becomeFirstResponder()
                // O `goToLine` rola o mínimo, e a linha alvo acabava colada na borda de
                // baixo — chegar na definição e não vê-la não serve de nada. Um terço a
                // partir do topo deixa o contexto de cima e de baixo à vista.
                c.centralizar(tv, linha: reveal.line)
            }
        }
    }

    private func applyPrefs(_ tv: TextView, context: Context) {
        let c = context.coordinator
        tv.showLineNumbers = prefs.lineNumbers
        tv.isLineWrappingEnabled = prefs.wrap
        tv.indentStrategy = .space(length: prefs.tabWidth)
        tv.showSpaces = prefs.showWhitespace
        tv.showTabs = prefs.showWhitespace
        tv.showNonBreakingSpaces = prefs.showWhitespace
        tv.showLineBreaks = prefs.showLineBreaks
        tv.showSoftLineBreaks = prefs.showLineBreaks && prefs.wrap
        tv.showPageGuide = prefs.pageGuide > 0
        tv.pageGuideColumn = max(prefs.pageGuide, 1)
        tv.lineSelectionDisplayType = prefs.highlightLine ? .line : .disabled
        tv.characterPairs = prefs.autoClosePairs ? Self.pairs : []
        if c.lineHeight != prefs.lineHeight {
            c.lineHeight = prefs.lineHeight
            tv.lineHeightMultiplier = prefs.lineHeight
        }
        if c.guidesOn != prefs.indentGuides || c.tabWidth != prefs.tabWidth {
            c.guidesOn = prefs.indentGuides
            c.tabWidth = prefs.tabWidth
            c.scheduleDecorations()
        }
        if c.minimapSize != prefs.minimap {
            c.minimapSize = prefs.minimap
            c.minimap.tamanho = prefs.minimap
            c.minimapTexto = ""
            c.atualizarMinimapa(tv.text)
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

    private func apply(to tv: TextView, context: Context, fullReset: Bool) {
        let c = context.coordinator
        c.documentId = documentId
        c.palette = palette
        c.fontSize = prefs.fontSize
        c.parent = self
        c.hidePopup()
        let theme = EditorTheme(palette: palette, fontSize: prefs.fontSize)
        tv.backgroundColor = UIColor(hex: palette.bg)
        c.overlay.addedColor = UIColor(hex: palette.ok)
        c.overlay.modifiedColor = UIColor(hex: palette.syntax.keyword)
        c.overlay.deletedColor = UIColor(hex: palette.danger)
        c.minimap.corCodigo = UIColor(hex: palette.fg).withAlphaComponent(palette.dark ? 0.45 : 0.40)
        c.minimap.corComentario = UIColor(hex: palette.fgSubtle).withAlphaComponent(0.45)
        c.minimap.corJanela = UIColor(hex: palette.fg).withAlphaComponent(palette.dark ? 0.10 : 0.09)
        c.minimap.corFundo = UIColor(hex: palette.bg).withAlphaComponent(0.6)
        c.guides.color = UIColor(hex: palette.fg).withAlphaComponent(palette.dark ? 0.09 : 0.12)
        c.guides.activeColor = UIColor(hex: palette.accent).withAlphaComponent(0.45)
        c.popup.fg = UIColor(hex: palette.fg)
        c.popup.muted = UIColor(hex: palette.fgMuted)
        c.popup.accent = UIColor(hex: palette.accent)
        if let lang = LanguageMode.treeSitter(for: language) {
            tv.setState(TextViewState(
                text: text,
                theme: theme,
                language: lang,
                languageProvider: LanguageMode.provider
            ))
        } else {
            tv.setState(TextViewState(text: text, theme: theme))
        }
        c.scheduleDecorations()
    }

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
        var isEditing = false
        var revealToken = -1
        var marks: [EditorGutterMark] = []
        var issues: [EditorIssue] = []
        var changes: [EditorLineChange] = []
        var links: [EditorLink] = []
        var find: EditorFind?
        var replaceToken = -1
        /// Onde estão as ocorrências da busca no arquivo.
        var buscaRanges: [NSRange] = []
        let overlay = GutterOverlay(frame: .zero)
        let guides = IndentGuides(frame: .zero)
        let changeMarks = ChangeMarks(frame: .zero)
        let popup = CompletionPopup(frame: .zero)
        let minimap = MinimapView(frame: .zero)
        var minimapSize: MinimapSize = .off
        var minimapTexto = ""
        var lineHeight: Double = 0
        var guidesOn = true
        var tabWidth = 2
        var offsetObservation: NSKeyValueObservation?
        var decorationTask: Task<Void, Never>?
        private var popupContext: CompletionContext?

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        public func textViewDidChange(_ textView: TextView) {
            isEditing = true
            parent.text = textView.text
            isEditing = false
            scheduleDecorations()
            offerCompletions()
            atualizarMinimapa(textView.text)
        }

        func atualizarMinimapa(_ texto: String) {
            guard minimapSize != .off, texto != minimapTexto else { return }
            minimapTexto = texto
            minimap.linhas = MinimapView.medir(texto, tabWidth: tabWidth)
        }

        public func textViewDidChangeSelection(_ textView: TextView) {
            parent.onCursor(textView.selectedRange.location)
            if guidesOn {
                scheduleDecorations()
            }
            if popupContext != nil, !popup.isHidden {
                // Cursor saiu da palavra: fecha.
                let ctx = Complete.context(
                    text: textView.text,
                    cursor: charOffset(textView.selectedRange.location, in: textView.text)
                )
                if ctx?.start != popupContext?.start {
                    hidePopup()
                }
            }
        }

        public func textViewDidChangeGutterWidth(_: TextView) {
            scheduleDecorations()
        }

        public func textView(_: TextView, shouldChangeTextIn _: NSRange, replacementText text: String) -> Bool {
            if !popup.isHidden, let first = popup.items.first, text == "\t" || text == "\n" {
                accept(first)
                return false
            }
            if text == "\n" || text == " " {
                hidePopup()
            }
            return true
        }

        public func textViewDidEndEditing(_: TextView) {
            hidePopup()
        }

        // MARK: - Autocompletar

        func offerCompletions() {
            guard let tv = textView, let source = parent.completion, tv.selectedRange.length == 0 else {
                hidePopup()
                return
            }
            let text = tv.text
            let cursor = charOffset(tv.selectedRange.location, in: text)
            guard let ctx = Complete.context(text: text, cursor: cursor) else {
                hidePopup()
                return
            }
            let items = Complete.suggestions(
                text: text,
                cursor: cursor,
                language: parent.language,
                files: source.files,
                currentPath: source.path,
                packages: source.packages
            )
            guard !items.isEmpty else {
                hidePopup()
                return
            }
            popupContext = ctx
            popup.items = items
            if popup.superview == nil {
                tv.addSubview(popup)
            }
            popup.isHidden = false
            let caret = tv.caretRect(for: tv.selectedTextRange?.start ?? tv.endOfDocument)
            let width: CGFloat = 280
            let maxX = tv.contentOffset.x + tv.bounds.width - width - 8
            popup.frame = CGRect(
                x: max(min(caret.minX, maxX), tv.gutterWidth + 4),
                y: caret.maxY + 4,
                width: width,
                height: popup.preferredHeight
            )
            tv.bringSubviewToFront(popup)
        }

        func hidePopup() {
            popup.isHidden = true
            popupContext = nil
        }

        func accept(_ item: Completion) {
            guard let tv = textView, let ctx = popupContext else { return }
            let text = tv.text
            let startUTF16 = utf16Offset(ctx.start, in: text)
            let cursor = tv.selectedRange.location
            var insert = item.insert
            // Indenta linhas seguintes do snippet com o recuo da linha atual.
            let ns = text as NSString
            let lineRange = ns.lineRange(for: NSRange(location: startUTF16, length: 0))
            let lineText = ns.substring(with: lineRange)
            let indent = String(lineText.prefix { $0 == " " || $0 == "\t" })
            if !indent.isEmpty {
                insert = insert.replacingOccurrences(of: "\n", with: "\n" + indent)
            }
            var caretOffset = (insert as NSString).length
            if let r = insert.range(of: "$0") {
                caretOffset = (String(insert[..<r.lowerBound]) as NSString).length
                insert.removeSubrange(r)
            }
            hidePopup()
            tv.replace(NSRange(location: startUTF16, length: max(cursor - startUTF16, 0)), withText: insert)
            tv.selectedRange = NSRange(location: startUTF16 + caretOffset, length: 0)
        }

        private func charOffset(_ utf16: Int, in text: String) -> Int {
            let u = text.utf16
            guard let idx = u.index(u.startIndex, offsetBy: min(utf16, u.count), limitedBy: u.endIndex)
            else { return text.count }
            return text.distance(from: text.startIndex, to: idx)
        }

        private func utf16Offset(_ chars: Int, in text: String) -> Int {
            guard let idx = text.index(text.startIndex, offsetBy: min(chars, text.count), limitedBy: text.endIndex)
            else { return (text as NSString).length }
            return text.utf16.distance(from: text.utf16.startIndex, to: idx)
        }
    }
}

/// O Runestone traz o gutter para a frente a cada layout; as decorações da Odete vêm depois dele.
final class OdeteTextView: TextView {
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
