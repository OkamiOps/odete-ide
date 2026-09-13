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
    public var onSave: () -> Void
    public var onFind: () -> Void

    public init(
        text: Binding<String>,
        documentId: String,
        language: Language,
        palette: ThemePalette,
        prefs: EditorPrefs,
        reveal: (line: Int, token: Int)? = nil,
        onSave: @escaping () -> Void = {},
        onFind: @escaping () -> Void = {}
    ) {
        _text = text
        self.documentId = documentId
        self.language = language
        self.palette = palette
        self.prefs = prefs
        self.reveal = reveal
        self.onSave = onSave
        self.onFind = onFind
    }

    public func makeUIView(context: Context) -> TextView {
        let tv = TextView()
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
        tv.gutterTrailingPadding = 10
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 200, right: 8)
        tv.lineSelectionDisplayType = .line
        tv.characterPairs = [
            Pair("(", ")"),
            Pair("[", "]"),
            Pair("{", "}"),
            Pair("\"", "\""),
            Pair("'", "'"),
            Pair("`", "`"),
        ]
        tv.inputAccessoryView = KeyboardBar(textView: tv, onSave: onSave, onFind: onFind)
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
        }
        tv.showLineNumbers = prefs.lineNumbers
        tv.isLineWrappingEnabled = prefs.wrap
        tv.indentStrategy = .space(length: prefs.tabWidth)
        (tv.inputAccessoryView as? KeyboardBar)?.onSave = onSave
        (tv.inputAccessoryView as? KeyboardBar)?.onFind = onFind
        if let reveal, c.revealToken != reveal.token {
            c.revealToken = reveal.token
            DispatchQueue.main.async {
                _ = tv.goToLine(max(reveal.line - 1, 0), select: .line)
                tv.becomeFirstResponder()
            }
        }
    }

    private func apply(to tv: TextView, context: Context, fullReset: Bool) {
        let c = context.coordinator
        c.documentId = documentId
        c.palette = palette
        c.fontSize = prefs.fontSize
        c.parent = self
        let theme = EditorTheme(palette: palette, fontSize: prefs.fontSize)
        tv.backgroundColor = UIColor(hex: palette.bg)
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
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    public final class Coordinator: NSObject, @preconcurrency TextViewDelegate {
        var parent: CodeEditorView
        var documentId = ""
        var palette: ThemePalette?
        var fontSize: Double = 0
        var isEditing = false
        var revealToken = -1

        init(parent: CodeEditorView) {
            self.parent = parent
        }

        public func textViewDidChange(_ textView: TextView) {
            isEditing = true
            parent.text = textView.text
            isEditing = false
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
