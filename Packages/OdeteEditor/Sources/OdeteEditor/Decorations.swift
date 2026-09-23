import OdeteCore
import Runestone
import UIKit

/// Marca de git no gutter (linha 1-based).
public struct EditorGutterMark: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case added, modified, deleted }
    public var line: Int
    public var kind: Kind
    public var id: String {
        "\(line):\(kind)"
    }

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// Linha que o agente mexeu, para o patch pendente aparecer dentro do código.
/// `.added` é uma linha que está no texto; `.removed` é o lugar onde linhas sumiram.
public struct EditorLineChange: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable { case added, removed }
    public var line: Int
    public var kind: Kind
    public var id: String {
        "\(line):\(kind)"
    }

    public init(line: Int, kind: Kind) {
        self.line = line
        self.kind = kind
    }
}

/// Problema a sublinhar (linha/coluna 1-based, em Characters).
public struct EditorIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable { case error, warning, info }
    public var line: Int
    public var column: Int
    public var length: Int
    public var severity: Severity
    public var message: String
    /// De onde veio o aviso (a regra do lint, "sintaxe"), mostrado no balão da mensagem.
    public var fonte: String?
    public var id: String {
        "\(line):\(column):\(message)"
    }

    public init(line: Int, column: Int, length: Int, severity: Severity, message: String, fonte: String? = nil) {
        self.line = line
        self.column = column
        self.length = length
        self.severity = severity
        self.message = message
        self.fonte = fonte
    }
}

/// Caminho de import que aponta para um arquivo do projeto: o editor sublinha e abre
/// com um toque.
public struct EditorLink: Sendable, Hashable {
    /// Posição do caminho no texto, em caracteres, sem as aspas.
    public var range: Range<Int>
    /// Arquivo do projeto para onde ele aponta.
    public var destino: String

    public init(range: Range<Int>, destino: String) {
        self.range = range
        self.destino = destino
    }
}

/// Fonte do autocompletar: caminhos do projeto e o arquivo aberto.
public struct CompletionSource: Sendable, Hashable {
    public var files: [String]
    /// Pacotes instalados, para completar `from "…"`.
    public var packages: [String]
    public var path: String
    public init(files: [String], packages: [String] = [], path: String) {
        self.files = files
        self.packages = packages
        self.path = path
    }
}

/// Desenha as marcas do git sobre o gutter do Runestone. Vive dentro do `TextView` (que é um
/// `UIScrollView`), então acompanha o conteúdo; o `x` segue o `contentOffset` para ficar colado à esquerda.
@MainActor
final class GutterOverlay: UIView {
    struct Placed { let y: CGFloat; let h: CGFloat; let mark: EditorGutterMark }
    var placed: [Placed] = []
    /// Toque longo, não toque simples: com marca em quase toda linha, o toque simples
    /// roubava o toque que devia levar o cursor para a linha e o editor parecia travado.
    var onLongPress: ((Int) -> Void)?
    var addedColor = UIColor.systemGreen
    var modifiedColor = UIColor.systemBlue
    var deletedColor = UIColor.systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        let g = UILongPressGestureRecognizer(target: self, action: #selector(pressionado(_:)))
        g.minimumPressDuration = 0.45
        addGestureRecognizer(g)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func point(inside point: CGPoint, with _: UIEvent?) -> Bool {
        // A tira das marcas e nada mais. O limite da direita é o que faltava: sem ele
        // `x >= bounds.width - 10` aceitava qualquer ponto do editor à direita do gutter,
        // e esta view, que tem 42 pt de largura e a altura inteira do arquivo, engolia o
        // toque no meio do código em toda linha que tivesse marca do git. Era isso que
        // deixava o cursor preso: "só vai em determinadas linhas" eram as linhas sem marca.
        guard point.x >= bounds.width - 12, point.x <= bounds.width else { return false }
        return placed.contains { point.y >= $0.y && point.y <= $0.y + $0.h }
    }

    @objc private func pressionado(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let p = g.location(in: self)
        if let hit = placed.first(where: { p.y >= $0.y - 2 && p.y <= $0.y + $0.h + 2 }) {
            onLongPress?(hit.mark.line)
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let x = bounds.width - 6
        for p in placed where p.y + p.h + 4 >= rect.minY && p.y - 4 <= rect.maxY {
            switch p.mark.kind {
            case .added, .modified:
                ctx.setFillColor((p.mark.kind == .added ? addedColor : modifiedColor).cgColor)
                ctx.addPath(UIBezierPath(
                    roundedRect: CGRect(x: x, y: p.y + 1, width: 3, height: max(p.h - 2, 4)),
                    cornerRadius: 1.5
                ).cgPath)
                ctx.fillPath()
            case .deleted:
                ctx.setFillColor(deletedColor.cgColor)
                ctx.move(to: CGPoint(x: x - 1, y: p.y - 4))
                ctx.addLine(to: CGPoint(x: x + 5, y: p.y))
                ctx.addLine(to: CGPoint(x: x - 1, y: p.y + 4))
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }
}

/// Guias de indentação desenhadas atrás do texto (uma por nível); a do bloco do cursor fica em destaque.
///
/// A camada cobre só a faixa visível do editor (a tela e uma tela de folga), não o arquivo
/// inteiro: com a altura do arquivo, um de 2000 linhas pedia uma camada de dezenas de
/// milhares de pontos redesenhada por completo a cada passada.
@MainActor
final class IndentGuides: UIView {
    struct Segment { let x: CGFloat; let y: CGFloat; let h: CGFloat; let active: Bool }
    var segments: [Segment] = []
    var color = UIColor.gray.withAlphaComponent(0.1)
    var activeColor = UIColor.systemOrange.withAlphaComponent(0.4)
    /// A faixa do conteúdo que a decoração cobre agora; a rolagem que sair dela refaz.
    var faixa: ClosedRange<CGFloat>?
    /// Já há uma passada de decoração agendada pela rolagem.
    var refazendoNaRolagem = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setLineWidth(1)
        for s in segments where s.y + s.h >= rect.minY && s.y <= rect.maxY {
            ctx.setStrokeColor((s.active ? activeColor : color).cgColor)
            ctx.move(to: CGPoint(x: s.x + 0.5, y: s.y))
            ctx.addLine(to: CGPoint(x: s.x + 0.5, y: s.y + s.h))
            ctx.strokePath()
        }
    }
}

/// Marca de linha apagada pelo agente: um fio vermelho na altura em que o texto sumiu.
/// A linha adicionada é pintada pelo próprio `highlightedRanges` do Runestone, mas a que
/// foi embora não está no texto e não tem onde ser pintada.
@MainActor
final class ChangeMarks: UIView {
    /// Onde linhas foram apagadas pelo agente.
    var ys: [CGFloat] = []
    /// Sublinhado ondulado de problema: começo, largura, base e cor.
    struct Onda { let x: CGFloat; let w: CGFloat; let y: CGFloat; let cor: UIColor }
    var ondas: [Onda] = []
    /// Sublinhado reto dos caminhos de import que apontam para um arquivo do projeto:
    /// é o que avisa que aquilo ali abre com um toque.
    struct Elo { let rect: CGRect; let destino: String }
    var elos: [Elo] = []
    var corElo = UIColor.systemBlue
    var cor = UIColor.systemRed

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    override func draw(_: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(cor.withAlphaComponent(0.55).cgColor)
        for y in ys {
            ctx.fill(CGRect(x: 0, y: y - 1, width: bounds.width, height: 2))
            ctx.move(to: CGPoint(x: 0, y: y - 5))
            ctx.addLine(to: CGPoint(x: 8, y: y))
            ctx.addLine(to: CGPoint(x: 0, y: y + 5))
            ctx.closePath()
            ctx.fillPath()
        }
        // Onda embaixo do trecho com problema. Um fundo colorido de um caractere só,
        // que era o que existia, não se vê no meio do código.
        ctx.setLineWidth(1.6)
        ctx.setLineJoin(.round)
        for o in ondas {
            ctx.setStrokeColor(o.cor.cgColor)
            var x = o.x
            var cima = true
            ctx.move(to: CGPoint(x: x, y: o.y))
            while x < o.x + o.w {
                x += 2.5
                ctx.addLine(to: CGPoint(x: min(x, o.x + o.w), y: o.y + (cima ? -2 : 2)))
                cima.toggle()
            }
            ctx.strokePath()
        }
        // Sublinhado reto no caminho do import que abre.
        ctx.setFillColor(corElo.withAlphaComponent(0.6).cgColor)
        for e in elos {
            ctx.fill(CGRect(x: e.rect.minX, y: e.rect.maxY - 1, width: e.rect.width, height: 1))
        }
    }
}

/// As teclas da lista de sugestões com teclado físico.
///
/// Mora numa classe entre o `TextView` do Runestone e o `OdeteTextView`, e não nele, para
/// os atalhos do editor (que vivem lá) e estes não disputarem o mesmo `keyCommands`: quem
/// sobrescreve lá só precisa somar `super.keyCommands`. Com a lista fechada nada muda — as
/// setas continuam andando no texto.
class TextViewComSugestoes: TextView {
    enum TeclaDaLista { case acima, abaixo, fechar }

    /// A lista está na tela?
    var listaAberta: () -> Bool = { false }
    var naLista: (TeclaDaLista) -> Void = { _ in }

    override var keyCommands: [UIKeyCommand]? {
        let base = super.keyCommands ?? []
        guard listaAberta() else { return base }
        let teclas: [(String, Selector)] = [
            (UIKeyCommand.inputUpArrow, #selector(listaAcima)),
            (UIKeyCommand.inputDownArrow, #selector(listaAbaixo)),
            (UIKeyCommand.inputEscape, #selector(listaFechar)),
        ]
        return base + teclas.map { input, acao in
            let c = UIKeyCommand(input: input, modifierFlags: [], action: acao)
            // Sem prioridade a seta vai para o texto, e o cursor anda antes de a lista ver.
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
    }

    @objc func listaAcima() {
        naLista(.acima)
    }

    @objc func listaAbaixo() {
        naLista(.abaixo)
    }

    @objc func listaFechar() {
        naLista(.fechar)
    }
}

/// Lista flutuante de sugestões, ancorada abaixo do cursor.
///
/// Com teclado físico, ↑ e ↓ andam pela lista, Return e Tab aceitam a escolhida e Esc
/// fecha — ver `TextViewComSugestoes`. Antes Return e Tab aceitavam sempre a primeira,
/// e para chegar na terceira só tirando a mão do teclado.
@MainActor
final class CompletionPopup: UIView {
    var items: [Completion] = [] {
        didSet {
            selecionado = 0
            rebuild()
        }
    }

    /// A sugestão que Return e Tab aceitam.
    private(set) var selecionado = 0

    var itemSelecionado: Completion? {
        items.indices.contains(selecionado) ? items[selecionado] : items.first
    }

    var onPick: ((Completion) -> Void)?
    var fg = UIColor.label
    var muted = UIColor.secondaryLabel
    var accent = UIColor.tintColor
    private let stack = UIStackView()
    private let glass = UIVisualEffectView(effect: UIGlassEffect())

    /// Anda na lista, dando a volta nas pontas como toda lista de sugestões.
    func mover(_ passo: Int) {
        guard !items.isEmpty else { return }
        selecionado = (selecionado + passo + items.count) % items.count
        pintar()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        clipsToBounds = true
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(glass)
        stack.axis = .vertical
        stack.spacing = 0
        stack.frame = bounds
        stack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.contentView.addSubview(stack)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 10
        layer.shadowOffset = CGSize(width: 0, height: 4)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        nil
    }

    private func rebuild() {
        for v in stack.arrangedSubviews {
            v.removeFromSuperview()
        }
        for item in items {
            let b = UIButton(configuration: .plain())
            b.contentHorizontalAlignment = .leading
            b.addAction(UIAction { [weak self] _ in self?.onPick?(item) }, for: .touchUpInside)
            stack.addArrangedSubview(b)
        }
        pintar()
    }

    /// Desenha cada linha, com a escolhida em destaque. Trocar a escolha só repinta: os
    /// botões continuam os mesmos.
    private func pintar() {
        for (i, v) in stack.arrangedSubviews.enumerated() {
            guard let b = v as? UIButton, items.indices.contains(i) else { continue }
            let item = items[i]
            let on = i == selecionado
            var cfg = UIButton.Configuration.plain()
            cfg.image = UIImage(systemName: item.kind.symbol)?.applyingSymbolConfiguration(.init(
                pointSize: 11,
                weight: .medium
            ))
            cfg.imagePadding = 8
            cfg.baseForegroundColor = on ? accent : fg
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
            cfg.background.backgroundColor = on ? accent.withAlphaComponent(0.14) : .clear
            cfg.background.cornerRadius = 8
            let title = NSMutableAttributedString(string: item.label, attributes: [
                .font: UIFont.monospacedSystemFont(ofSize: 12.5, weight: on ? .semibold : .regular),
                .foregroundColor: on ? accent : fg,
            ])
            if let d = item.detail {
                title.append(NSAttributedString(string: "  \(d)", attributes: [
                    .font: UIFont.systemFont(ofSize: 11), .foregroundColor: muted,
                ]))
            }
            cfg.attributedTitle = AttributedString(title)
            b.configuration = cfg
            b.accessibilityTraits = on ? [.button, .selected] : .button
        }
    }

    var preferredHeight: CGFloat {
        CGFloat(items.count) * 30
    }
}

/// Autocompletar do coordenador: oferecer e aceitar, o contexto por janela, o índice de
/// palavras e as teclas da lista.
extension CodeEditorView.Coordinator {
    /// Linha acima disso fica fora da conta de palavras por linha: é arquivo minificado,
    /// e ler a linha inteira a cada tecla seria ler o arquivo.
    static let tetoDaLinha = 10000

    func offerCompletions() {
        guard let tv = textView, let source = parent.completion else {
            hidePopup()
            return
        }
        // Mudança que não coube numa linha — colar várias linhas, Enter, desfazer —
        // deixa o índice de palavras velho demais para a conta por linha.
        if !(mudancaAnunciada && mudancaNaLinha) {
            pedirIndiceDePalavras(atraso: .zero)
        }
        mudancaAnunciada = false
        guard tv.selectedRange.length == 0, let lugar = contextoNoCursor(tv), let ctx = lugar.ctx else {
            hidePopup()
            return
        }
        let items = Complete.sugestoes(
            para: ctx,
            indice: indicePalavras,
            linha: LinhaDoCursor(
                texto: lugar.linha,
                inicio: lugar.inicioDaLinha,
                cursor: lugar.cursor - lugar.inicioDaLinha
            ),
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
        let startUTF16 = ctx.inicioUTF16
        let cursor = tv.selectedRange.location
        var insert = item.insert
        // Indenta linhas seguintes do snippet com o recuo da linha atual — lido do
        // começo da linha até o prefixo, não do documento inteiro.
        let coluna = tv.textLocation(at: startUTF16)?.column ?? 0
        let antes = tv.text(in: NSRange(location: startUTF16 - coluna, length: coluna)) ?? ""
        let indent = String(antes.prefix { $0 == " " || $0 == "\t" })
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

    /// ↑ e ↓ andam na lista, Esc fecha. Só chega aqui com a lista aberta.
    func teclaNaLista(_ tecla: TextViewComSugestoes.TeclaDaLista) {
        switch tecla {
        case .acima: popup.mover(-1)
        case .abaixo: popup.mover(1)
        case .fechar: hidePopup()
        }
    }

    /// O contexto do autocompletar e a linha do cursor, lidos do Runestone em recortes.
    ///
    /// Nada aqui passa pelo documento inteiro: o começo da linha vem da árvore de linhas
    /// do Runestone e o texto, de recortes da linha. Antes o cursor era convertido para
    /// Characters contando desde o começo do arquivo, e o contexto copiava o arquivo num
    /// array — duas vezes por tecla, três com a lista aberta.
    func contextoNoCursor(
        _ tv: TextView
    ) -> (ctx: CompletionContext?, linha: String, inicioDaLinha: Int, cursor: Int)? {
        let cursor = tv.selectedRange.location
        guard let pos = tv.textLocation(at: cursor) else { return nil }
        let inicio = cursor - pos.column
        let ini = Complete.inicioDaJanela(cursor: cursor, inicioDaLinha: inicio)
        let janela = tv.text(in: NSRange(location: ini, length: cursor - ini)) ?? ""
        let ctx = Complete.contexto(janela: janela, inicioDaJanela: ini)
        let fim = inicioDaLinha(tv, pos.lineNumber + 1) ?? tamanhoDoDocumento(tv)
        guard fim - inicio <= Self.tetoDaLinha else { return (ctx, "", -1, cursor) }
        let linha = tv.text(in: NSRange(location: inicio, length: fim - inicio)) ?? ""
        return (ctx, linha, inicio, cursor)
    }

    /// Remonta o índice de palavras fora do ator principal.
    ///
    /// O índice guarda também a linha do cursor de agora, que é a que a conta de
    /// `Complete.palavras` troca pela versão do momento da tecla.
    func pedirIndiceDePalavras(atraso: Duration) {
        guard parent.completion != nil, let tv = textView else { return }
        indiceTask?.cancel()
        pedidoDoIndice &+= 1
        let pedido = pedidoDoIndice
        let texto = textoAtual
        let cursor = tv.selectedRange.location
        var linha: NSRange?
        if let pos = tv.textLocation(at: cursor) {
            let inicio = cursor - pos.column
            let fim = inicioDaLinha(tv, pos.lineNumber + 1) ?? tamanhoDoDocumento(tv)
            linha = NSRange(location: inicio, length: max(fim - inicio, 0))
        }
        linhaDoPedido = linha?.location ?? -1
        let faixa = linha
        indiceTask = Task { [weak self] in
            if atraso > .zero {
                try? await Task.sleep(for: atraso)
            }
            guard !Task.isCancelled else { return }
            let novo = await Task.detached(priority: .userInitiated) {
                IndiceDePalavras(texto: texto, linhaDoCursor: faixa)
            }.value
            guard let self, !Task.isCancelled, pedido == pedidoDoIndice else { return }
            indicePalavras = novo
        }
    }

    /// O cursor mudou de linha sem o texto mudar: o índice passa a descontar a linha
    /// errada, então é remontado — com uma pausa, para segurar a seta não virar uma
    /// varredura por linha percorrida.
    func conferirLinhaDoIndice(_ tv: TextView) {
        guard parent.completion != nil, let pos = tv.textLocation(at: tv.selectedRange.location) else { return }
        let inicio = tv.selectedRange.location - pos.column
        if let l = indicePalavras.linha, l.inicio != inicio, linhaDoPedido != inicio {
            pedirIndiceDePalavras(atraso: .milliseconds(150))
        }
    }
}
