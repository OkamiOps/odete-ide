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
        changeMarks.isHidden = ys.isEmpty
        changeMarks.setNeedsDisplay()
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
