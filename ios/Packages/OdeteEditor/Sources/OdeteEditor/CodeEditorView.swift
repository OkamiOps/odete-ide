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
    public var completion: CompletionSource?
    public var onSave: () -> Void
    public var onFind: () -> Void
    public var onGutterTap: (Int) -> Void
    public var onCursor: (Int) -> Void

    public init(
        text: Binding<String>,
        documentId: String,
        language: Language,
        palette: ThemePalette,
        prefs: EditorPrefs,
        reveal: (line: Int, token: Int)? = nil,
        marks: [EditorGutterMark] = [],
        issues: [EditorIssue] = [],
        completion: CompletionSource? = nil,
        onSave: @escaping () -> Void = {},
        onFind: @escaping () -> Void = {},
        onGutterTap: @escaping (Int) -> Void = { _ in },
        onCursor: @escaping (Int) -> Void = { _ in }
    ) {
        _text = text
        self.documentId = documentId
        self.language = language
        self.palette = palette
        self.prefs = prefs
        self.reveal = reveal
        self.marks = marks
        self.issues = issues
        self.completion = completion
        self.onSave = onSave
        self.onFind = onFind
        self.onGutterTap = onGutterTap
        self.onCursor = onCursor
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
        tv.gutterLeadingPadding = 8
        tv.gutterTrailingPadding = 12
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 200, right: 8)
        tv.lineSelectionDisplayType = .line
        tv.characterPairs = Self.pairs
        tv.inputAccessoryView = KeyboardBar(textView: tv, onSave: onSave, onFind: onFind)
        let c = context.coordinator
        c.textView = tv
        c.overlay.onTap = { [weak c] line in c?.parent.onGutterTap(line) }
        tv.addSubview(c.guides)
        tv.addSubview(c.overlay)
        tv.floating = [c.guides, c.overlay, c.popup]
        c.popup.onPick = { [weak c] item in c?.accept(item) }
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
        (tv.inputAccessoryView as? KeyboardBar)?.onSave = onSave
        (tv.inputAccessoryView as? KeyboardBar)?.onFind = onFind
        if c.marks != marks || c.issues != issues || docChanged {
            c.marks = marks
            c.issues = issues
            c.scheduleDecorations()
        }
        if let reveal, c.revealToken != reveal.token {
            c.revealToken = reveal.token
            DispatchQueue.main.async {
                _ = tv.goToLine(max(reveal.line - 1, 0), select: .line)
                tv.becomeFirstResponder()
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
    public final class Coordinator: NSObject, @preconcurrency TextViewDelegate {
        var parent: CodeEditorView
        weak var textView: TextView?
        var documentId = ""
        var palette: ThemePalette?
        var fontSize: Double = 0
        var isEditing = false
        var revealToken = -1
        var marks: [EditorGutterMark] = []
        var issues: [EditorIssue] = []
        let overlay = GutterOverlay(frame: .zero)
        let guides = IndentGuides(frame: .zero)
        let popup = CompletionPopup(frame: .zero)
        var lineHeight: Double = 0
        var guidesOn = true
        var tabWidth = 2
        var offsetObservation: NSKeyValueObservation?
        private var decorationTask: Task<Void, Never>?
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

        // MARK: - Decorações

        func scheduleDecorations() {
            decorationTask?.cancel()
            decorationTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self?.layoutDecorations()
            }
        }

        func layoutDecorations() {
            guard let tv = textView else { return }
            let ns = tv.text as NSString
            let starts = lineStarts(ns)
            var placed: [GutterOverlay.Placed] = []
            for m in marks where m.line >= 1 && m.line <= starts.count {
                guard let pos = tv.position(from: tv.beginningOfDocument, offset: starts[m.line - 1]) else { continue }
                let r = tv.caretRect(for: pos)
                placed.append(.init(y: r.minY, h: r.height, mark: m))
            }
            overlay.placed = placed
            positionOverlay()
            overlay.setNeedsDisplay()
            layoutGuides(tv, ns: ns, starts: starts)

            var ranges: [HighlightedRange] = []
            for i in issues where i.line >= 1 && i.line <= starts.count {
                let lineStart = starts[i.line - 1]
                let lineEnd = i.line < starts.count ? starts[i.line] - 1 : ns.length
                let loc = min(lineStart + max(i.column - 1, 0), lineEnd)
                let len = max(min(i.length, lineEnd - loc), 1)
                let color: UIColor = switch i.severity {
                case .error: overlay.deletedColor
                case .warning: UIColor.systemOrange
                case .info: overlay.modifiedColor
                }
                ranges.append(HighlightedRange(
                    id: i.id,
                    range: NSRange(location: loc, length: len),
                    color: color.withAlphaComponent(0.22),
                    cornerRadius: 3
                ))
            }
            tv.highlightedRanges = ranges
        }

        /// Guias de indentação: uma linha vertical por nível, na coluna do recuo.
        func layoutGuides(_ tv: TextView, ns: NSString, starts: [Int]) {
            guides.frame = CGRect(
                x: 0,
                y: 0,
                width: max(tv.contentSize.width, tv.bounds.width),
                height: max(tv.contentSize.height, tv.bounds.height)
            )
            guard guidesOn, starts.count <= 4000 else {
                guides.segments = []
                guides.setNeedsDisplay()
                return
            }
            let width = max(tabWidth, 1)
            var levels: [Int] = []
            for (i, start) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1] : ns.length
                var spaces = 0
                var p = start
                var blank = true
                while p < end {
                    let ch = ns.character(at: p)
                    if ch == 32 {
                        spaces += 1
                    } else if ch == 9 {
                        spaces += width
                    } else if ch == 10 || ch == 13 {
                        break
                    } else {
                        blank = false
                        break
                    }
                    p += 1
                }
                levels.append(blank ? -1 : spaces / width)
            }
            // linhas em branco herdam o nível da próxima linha não vazia
            var next = 0
            for i in stride(from: levels.count - 1, through: 0, by: -1) {
                if levels[i] < 0 {
                    levels[i] = next
                } else {
                    next = levels[i]
                }
            }
            let cursorLine = lineIndex(of: tv.selectedRange.location, starts: starts)
            let cursorLevel = cursorLine < levels.count ? levels[cursorLine] : 0
            let charW = charWidth(tv)
            var segs: [IndentGuides.Segment] = []
            for (i, start) in starts.enumerated() where levels[i] > 0 {
                guard let pos = tv.position(from: tv.beginningOfDocument, offset: start) else { continue }
                let r = tv.caretRect(for: pos)
                for level in 0 ..< levels[i] {
                    segs.append(.init(
                        x: r.minX + CGFloat(level * width) * charW,
                        y: r.minY,
                        h: r.height,
                        active: level == cursorLevel - 1
                    ))
                }
            }
            guides.segments = segs
            guides.setNeedsDisplay()
        }

        /// Largura de um caractere da fonte mono (mede o avanço de "0").
        private func charWidth(_ tv: TextView) -> CGFloat {
            let font = tv.theme.font
            return ("0" as NSString).size(withAttributes: [.font: font]).width
        }

        private func lineIndex(of offset: Int, starts: [Int]) -> Int {
            var lo = 0, hi = starts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if starts[mid] <= offset {
                    lo = mid
                } else {
                    hi = mid - 1
                }
            }
            return max(lo, 0)
        }

        func positionOverlay() {
            guard let tv = textView else { return }
            overlay.frame = CGRect(
                x: tv.contentOffset.x,
                y: 0,
                width: tv.gutterWidth,
                height: max(tv.contentSize.height, tv.bounds.height)
            )
            tv.bringSubviewToFront(overlay)
            if !popup.isHidden {
                tv.bringSubviewToFront(popup)
            }
        }

        private func lineStarts(_ ns: NSString) -> [Int] {
            var out = [0]
            var i = 0
            let n = ns.length
            while i < n {
                let r = ns.lineRange(for: NSRange(location: i, length: 0))
                i = r.location + r.length
                if i < n || (i == n && ns.character(at: n - 1) == 10) {
                    out.append(i)
                }
                if r.length == 0 {
                    break
                }
            }
            return out
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
                currentPath: source.path
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
    override func layoutSubviews() {
        super.layoutSubviews()
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
