import Runestone
import UIKit

/// As camadas desenhadas por cima do texto: marcas do git no gutter, patch do agente,
/// guias de recuo e o posicionamento de tudo isso enquanto a pessoa rola.
extension CodeEditorView.Coordinator {
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
        marcarMudancas(tv, ns: ns, starts: starts, into: &ranges)
        marcarProblemas(tv, ns: ns, starts: starts, into: &ranges)
        marcarElos(tv, ns: ns)
        tv.highlightedRanges = ranges
    }

    /// Problema no código: onda embaixo do trecho, fundo de leve na linha e a marca no
    /// minimapa, para dar para achar onde quebrou sem rolar o arquivo atrás.
    func marcarProblemas(_ tv: TextView, ns: NSString, starts: [Int], into ranges: inout [HighlightedRange]) {
        let cores = palette ?? parent.palette
        var ondas: [ChangeMarks.Onda] = []
        for i in issues where i.line >= 1 && i.line <= starts.count {
            let inicioLinha = starts[i.line - 1]
            let fimLinha = i.line < starts.count ? starts[i.line] - 1 : ns.length
            let de = min(inicioLinha + max(i.column - 1, 0), fimLinha)
            // esbuild costuma apontar um caractere só; a onda vai desse ponto até o fim
            // da linha, senão fica um risco de 6 pt que ninguém vê.
            let ate = max(min(de + max(i.length, 1), fimLinha), de + 1)
            let cor = switch i.severity {
            case .error: UIColor(hex: cores.danger)
            case .warning: UIColor(hex: cores.syntax.keyword)
            case .info: UIColor(hex: cores.fgMuted)
            }
            ranges.append(HighlightedRange(
                id: i.id,
                range: NSRange(location: de, length: max(ate - de, 1)),
                color: cor.withAlphaComponent(0.18),
                cornerRadius: 3
            ))
            if let p1 = tv.position(from: tv.beginningOfDocument, offset: de),
               let p2 = tv.position(from: tv.beginningOfDocument, offset: max(ate, fimLinha))
            {
                let r1 = tv.caretRect(for: p1)
                let r2 = tv.caretRect(for: p2)
                // A onda fica logo abaixo do texto, não no pé do retângulo do cursor: com
                // entrelinha aumentada esse pé cai dentro da linha de baixo, e a onda
                // aparecia sublinhando a linha errada.
                let base = min(r1.minY + fontSize * 1.35, r1.maxY - 1)
                // Linha quebrada: o fim dela está numa altura diferente, então a onda vai
                // só até a borda do texto visível.
                let mesmaLinha = abs(r2.minY - r1.minY) < 1
                let largura = mesmaLinha ? max(r2.minX - r1.minX, 12) : max(tv.bounds.width - r1.minX - 40, 12)
                ondas.append(.init(x: r1.minX, w: largura, y: base, cor: cor))
            }
        }
        changeMarks.ondas = ondas
        changeMarks.setNeedsDisplay()
        minimap.corErro = UIColor(hex: cores.danger)
        minimap.corAviso = UIColor(hex: cores.syntax.keyword)
        minimap.erros = issues.filter { $0.severity == .error }.map(\.line)
        minimap.avisos = issues.filter { $0.severity == .warning }.map(\.line)
    }

    /// O toque caiu em cima de um caminho de import? Então abre o arquivo.
    @objc func tocouNoTexto(_ g: UITapGestureRecognizer) {
        guard !changeMarks.elos.isEmpty, let tv = textView else { return }
        let p = g.location(in: tv)
        // Uma folga vertical pequena: o retângulo do cursor é mais baixo que a linha e
        // acertar o sublinhado com o dedo pede alguma margem.
        guard let elo = changeMarks.elos.first(where: { $0.rect.insetBy(dx: -2, dy: -4).contains(p) })
        else { return }
        parent.onOpenLink(elo.destino)
    }

    /// Convive com o reconhecedor do próprio Runestone: o toque precisa continuar levando
    /// o cursor, senão volta o editor que "não deixa editar".
    public func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    ) -> Bool {
        true
    }

    /// Sublinha os caminhos de import que apontam para um arquivo do projeto.
    ///
    /// O sublinhado é o que avisa que aquilo abre; o retângulo guardado é o que o toque
    /// consulta depois, para não abrir arquivo quando a pessoa toca no vazio à direita da
    /// linha — `closestPosition` devolveria o fim do import ali também.
    func marcarElos(_ tv: TextView, ns: NSString) {
        var elos: [ChangeMarks.Elo] = []
        for l in links {
            let de = l.range.lowerBound, ate = l.range.upperBound
            guard de >= 0, ate <= ns.length, de < ate,
                  let p1 = tv.position(from: tv.beginningOfDocument, offset: de),
                  let p2 = tv.position(from: tv.beginningOfDocument, offset: ate) else { continue }
            let r1 = tv.caretRect(for: p1), r2 = tv.caretRect(for: p2)
            // Caminho quebrado em duas linhas não recebe sublinhado: seria um risco
            // atravessando o editor inteiro.
            guard abs(r2.minY - r1.minY) < 1, r2.minX > r1.minX else { continue }
            let altura = min(r1.height, fontSize * 1.5)
            elos.append(.init(
                rect: CGRect(x: r1.minX, y: r1.minY, width: r2.minX - r1.minX, height: altura),
                destino: l.destino
            ))
        }
        changeMarks.corElo = UIColor(hex: (palette ?? parent.palette).accent)
        changeMarks.elos = elos
        changeMarks.isHidden = changeMarks.ys.isEmpty && changeMarks.ondas.isEmpty && elos.isEmpty
        changeMarks.setNeedsDisplay()
    }

    /// O patch pendente dentro do código: linha que entrou pintada de verde, e um fio
    /// vermelho onde linhas saíram. Nada aqui trava o texto — dá para editar por cima.
    func marcarMudancas(_ tv: TextView, ns: NSString, starts: [Int], into ranges: inout [HighlightedRange]) {
        let cores = palette ?? parent.palette
        changeMarks.frame = CGRect(
            x: 0,
            y: 0,
            width: max(tv.contentSize.width, tv.bounds.width),
            height: max(tv.contentSize.height, tv.bounds.height)
        )
        var ys: [CGFloat] = []
        for c in changes where c.line >= 1 {
            switch c.kind {
            case .added:
                guard c.line <= starts.count else { continue }
                let loc = starts[c.line - 1]
                let fim = c.line < starts.count ? starts[c.line] : ns.length
                ranges.append(HighlightedRange(
                    id: "patch-\(c.line)",
                    range: NSRange(location: loc, length: max(fim - loc, 1)),
                    color: UIColor(hex: cores.ok).withAlphaComponent(0.16),
                    cornerRadius: 0
                ))
            case .removed:
                let alvo = min(max(c.line, 1), starts.count)
                guard let pos = tv.position(from: tv.beginningOfDocument, offset: starts[alvo - 1])
                else { continue }
                let r = tv.caretRect(for: pos)
                ys.append(c.line > starts.count ? r.maxY : r.minY)
            }
        }
        changeMarks.cor = UIColor(hex: cores.danger)
        changeMarks.ys = ys
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
        // Sem `bringSubviewToFront` aqui: esta função agora roda dentro do
        // layoutSubviews da TextView, e reordenar subviews ali pede novo layout.
        // A ordem das camadas já é garantida no próprio layoutSubviews.
        let larguraMapa = MinimapView.largura(minimapSize)
        minimap.isHidden = minimapSize == .off || tv.bounds.width < larguraMapa * 3
        if !minimap.isHidden {
            minimap.frame = CGRect(
                x: tv.contentOffset.x + tv.bounds.width - larguraMapa,
                y: tv.contentOffset.y,
                width: larguraMapa,
                height: tv.bounds.height
            )
            let rolavel = max(1, tv.contentSize.height - tv.bounds.height)
            minimap.fracao = min(1, max(0, tv.contentOffset.y / rolavel))
            minimap.visivel = min(1, tv.bounds.height / max(1, tv.contentSize.height))
            minimap.setNeedsDisplay()
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
}
