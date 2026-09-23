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

    /// Anota o texto novo e invalida o cache de linhas.
    ///
    /// Todo lugar que troca o conteúdo do editor passa por aqui — fora daqui o
    /// coordenador seguiria decorando com o mapa de linhas do texto anterior. O índice de
    /// palavras do autocompletar também envelhece: o texto novo não veio de uma tecla
    /// numa linha só, então a conta por linha dele não vale.
    func anotarTexto(_ texto: String) {
        textoAtual = texto
        versaoDoTexto &+= 1
        pedirIndiceDePalavras(atraso: .zero)
    }

    /// O mapa de linhas do texto atual, refeito só quando o texto muda de versão.
    ///
    /// Só quem precisa do documento inteiro usa isto — mandar a seleção para o agente,
    /// centralizar uma linha. As decorações e o cursor perguntam ao Runestone, que já
    /// guarda as linhas numa árvore; ver `linhaDe(_:)`.
    func linhas() -> MapaDeLinhas {
        if versaoCacheada != versaoDoTexto {
            mapaCacheado = MapaDeLinhas(textoAtual)
            versaoCacheada = versaoDoTexto
        }
        return mapaCacheado
    }

    /// Linha (base zero) de um deslocamento UTF-16.
    ///
    /// É chamada a cada movimento do cursor. Pelo mapa, cada tecla remontava o mapa do
    /// documento inteiro — o texto mudou de versão — só para descobrir uma linha: medido,
    /// 2% do ator principal ao digitar num arquivo de 2000 linhas. O Runestone responde
    /// isso pela árvore de linhas dele, em tempo logarítmico e sem ler o texto.
    func linhaDe(_ offset: Int) -> Int {
        if let tv = textView, let l = tv.textLocation(at: offset) {
            return l.lineNumber
        }
        return linhas().linha(de: offset)
    }

    /// Começo (UTF-16) de uma linha base zero, ou `nil` se ela não existe.
    func inicioDaLinha(_ tv: TextView, _ linha: Int) -> Int? {
        tv.location(at: TextLocation(lineNumber: linha, column: 0))
    }

    /// Tamanho do documento em UTF-16, sem montar a `String` dele.
    func tamanhoDoDocumento(_ tv: TextView) -> Int {
        tv.offset(from: tv.beginningOfDocument, to: tv.endOfDocument)
    }

    /// Fim da linha (antes da quebra) e começo da próxima.
    func fimDaLinha(_ tv: TextView, _ linha: Int, tamanho: Int) -> (fim: Int, proxima: Int) {
        guard let proxima = inicioDaLinha(tv, linha + 1) else { return (tamanho, tamanho) }
        return (max(proxima - 1, 0), proxima)
    }

    /// A faixa do documento que vale decorar agora: a tela e uma tela de folga para cima e
    /// para baixo.
    ///
    /// As guias pediam `caretRect` para cada linha recuada do arquivo inteiro — até 4000 —,
    /// e cada uma obriga o Runestone a compor a linha, esteja ela na tela ou a mil linhas
    /// dali. As camadas tinham a altura do arquivo inteiro e eram redesenhadas por
    /// completo a cada passada. Decorar só o que se vê troca o custo do tamanho do arquivo
    /// pelo tamanho da tela; a folga é o que deixa rolar sem ver a decoração chegando.
    func faixaVisivel(_ tv: TextView) -> (y: ClosedRange<CGFloat>, linhas: ClosedRange<Int>) {
        let tamanho = tamanhoDoDocumento(tv)
        let ultimaDoArquivo = tv.textLocation(at: tamanho)?.lineNumber ?? 0
        let alturaMedia = max(tv.contentSize.height / CGFloat(ultimaDoArquivo + 1), 1)
        /// A linha num ponto da tela. O Runestone só sabe responder isso para linhas que já
        /// compôs; fora delas `closestPosition` devolve o fim do arquivo. Nesse caso a conta
        /// vai pela altura média das linhas, que sem quebra de linha é exata.
        func linha(em y: CGFloat) -> Int {
            let estimada = min(max(Int(y / alturaMedia), 0), ultimaDoArquivo)
            guard let p = tv.closestPosition(to: CGPoint(x: tv.gutterWidth + 4, y: y)) else { return estimada }
            let o = tv.offset(from: tv.beginningOfDocument, to: p)
            if o >= tamanho, y < tv.contentSize.height - alturaMedia * 2 {
                return estimada
            }
            return linhaDe(o)
        }
        let topoVisivel = tv.contentOffset.y
        let baseVisivel = tv.contentOffset.y + max(tv.bounds.height, 1)
        let primeiraVisivel = linha(em: topoVisivel + 1)
        let ultimaVisivel = max(primeiraVisivel, linha(em: baseVisivel - 1))
        // A folga é de uma tela para cada lado, contada em linhas.
        let folga = max(ultimaVisivel - primeiraVisivel + 1, 10)
        let primeira = max(0, primeiraVisivel - folga)
        let ultima = min(ultimaDoArquivo, ultimaVisivel + folga)
        func caret(_ l: Int) -> CGRect? {
            guard let o = inicioDaLinha(tv, l), let p = tv.position(from: tv.beginningOfDocument, offset: o)
            else { return nil }
            return tv.caretRect(for: p)
        }
        let topo = min(caret(primeira)?.minY ?? topoVisivel, max(0, topoVisivel))
        let base = max(caret(ultima)?.maxY ?? baseVisivel, baseVisivel, topo + 1)
        return (topo ... base, primeira ... ultima)
    }

    func layoutDecorations() {
        guard let tv = textView else { return }
        let faixa = faixaVisivel(tv)
        faixaDecorada = faixa.y
        let topo = faixa.y.lowerBound
        let tamanho = tamanhoDoDocumento(tv)
        var placed: [GutterOverlay.Placed] = []
        for m in marks where faixa.linhas.contains(m.line - 1) {
            guard let inicio = inicioDaLinha(tv, m.line - 1),
                  let pos = tv.position(from: tv.beginningOfDocument, offset: inicio) else { continue }
            let r = tv.caretRect(for: pos)
            placed.append(.init(y: r.minY - topo, h: r.height, mark: m))
        }
        overlay.placed = placed
        positionOverlay()
        overlay.setNeedsDisplay()
        layoutGuides(tv, faixa: faixa, tamanho: tamanho)

        var ranges: [HighlightedRange] = []
        marcarMudancas(tv, faixa: faixa, tamanho: tamanho, into: &ranges)
        marcarProblemas(tv, faixa: faixa, tamanho: tamanho, into: &ranges)
        marcarElos(tv, faixa: faixa)
        marcarBusca(into: &ranges)
        tv.highlightedRanges = ranges
    }

    /// A rolagem saiu da faixa decorada: refaz já, sem a espera de quem digita.
    ///
    /// Chamado de `positionOverlay`, que roda dentro do `layoutSubviews` do editor; por
    /// isso só agenda, e uma vez por volta do laço principal.
    func conferirFaixaDaRolagem(_ tv: TextView) {
        let visivel = tv.contentOffset.y ... (tv.contentOffset.y + tv.bounds.height)
        guard let f = faixaDecorada,
              visivel.lowerBound < f.lowerBound - 1 || visivel.upperBound > f.upperBound + 1
        else { return }
        guard !rolagemPendente else { return }
        rolagemPendente = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            rolagemPendente = false
            layoutDecorations()
        }
    }

    /// Problema no código: onda embaixo do trecho, fundo de leve na linha e a marca no
    /// minimapa, para dar para achar onde quebrou sem rolar o arquivo atrás.
    ///
    /// O fundo vai para todos os problemas — é o Runestone quem desenha, e ele só pinta o
    /// que está na tela. A onda, que pede a posição de cada ponta na tela, só para os que
    /// caem na faixa visível.
    func marcarProblemas(
        _ tv: TextView,
        faixa: (y: ClosedRange<CGFloat>, linhas: ClosedRange<Int>),
        tamanho: Int,
        into ranges: inout [HighlightedRange]
    ) {
        let cores = palette ?? parent.palette
        let topo = faixa.y.lowerBound
        var ondas: [ChangeMarks.Onda] = []
        for i in issues where i.line >= 1 {
            guard let inicioLinha = inicioDaLinha(tv, i.line - 1) else { continue }
            let fimLinha = fimDaLinha(tv, i.line - 1, tamanho: tamanho).fim
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
            guard faixa.linhas.contains(i.line - 1) else { continue }
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
                ondas.append(.init(x: r1.minX, w: largura, y: base - topo, cor: cor))
            }
        }
        changeMarks.ondas = ondas
        changeMarks.setNeedsDisplay()
        minimap.corErro = UIColor(hex: cores.danger)
        minimap.corAviso = UIColor(hex: cores.syntax.keyword)
        minimap.erros = issues.filter { $0.severity == .error }.map(\.line)
        minimap.avisos = issues.filter { $0.severity == .warning }.map(\.line)
    }

    /// O toque caiu em cima de um caminho de import? Então abre o arquivo. Numa onda de
    /// problema, mostra a mensagem dele.
    @objc func tocouNoTexto(_ g: UITapGestureRecognizer) {
        guard let tv = textView else { return }
        // Os retângulos dos links moram no sistema da camada de decoração, que cobre só a
        // faixa visível; as áreas dos problemas, no do próprio editor.
        let noElo = g.location(in: changeMarks)
        // Uma folga vertical pequena: o retângulo do cursor é mais baixo que a linha e
        // acertar o sublinhado com o dedo pede alguma margem.
        if let elo = changeMarks.elos.first(where: { $0.rect.insetBy(dx: -2, dy: -4).contains(noElo) }) {
            parent.onOpenLink(elo.destino)
            return
        }
        // Fora de link, o toque numa onda mostra o problema; fora de onda, fecha o balão
        // que estiver aberto.
        tocouEmProblema(g.location(in: tv))
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
    func marcarElos(_ tv: TextView, faixa: (y: ClosedRange<CGFloat>, linhas: ClosedRange<Int>)) {
        var elos: [ChangeMarks.Elo] = []
        let topo = faixa.y.lowerBound
        let tamanho = tamanhoDoDocumento(tv)
        // Os limites da faixa em deslocamento: import fora dela não precisa de retângulo,
        // e pedir o retângulo compõe a linha.
        let de0 = inicioDaLinha(tv, faixa.linhas.lowerBound) ?? 0
        let ate0 = inicioDaLinha(tv, faixa.linhas.upperBound + 1) ?? tamanho
        for l in links {
            let de = l.range.lowerBound, ate = l.range.upperBound
            guard de >= 0, ate <= tamanho, de < ate, de >= de0, de <= ate0,
                  let p1 = tv.position(from: tv.beginningOfDocument, offset: de),
                  let p2 = tv.position(from: tv.beginningOfDocument, offset: ate) else { continue }
            let r1 = tv.caretRect(for: p1), r2 = tv.caretRect(for: p2)
            // Caminho quebrado em duas linhas não recebe sublinhado: seria um risco
            // atravessando o editor inteiro.
            guard abs(r2.minY - r1.minY) < 1, r2.minX > r1.minX else { continue }
            let altura = min(r1.height, fontSize * 1.5)
            elos.append(.init(
                rect: CGRect(x: r1.minX, y: r1.minY - topo, width: r2.minX - r1.minX, height: altura),
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
    func marcarMudancas(
        _ tv: TextView,
        faixa: (y: ClosedRange<CGFloat>, linhas: ClosedRange<Int>),
        tamanho: Int,
        into ranges: inout [HighlightedRange]
    ) {
        let cores = palette ?? parent.palette
        let topo = faixa.y.lowerBound
        changeMarks.frame = CGRect(
            x: 0,
            y: topo,
            width: max(tv.contentSize.width, tv.bounds.width),
            height: faixa.y.upperBound - topo
        )
        var ys: [CGFloat] = []
        for c in changes where c.line >= 1 {
            switch c.kind {
            case .added:
                guard let loc = inicioDaLinha(tv, c.line - 1) else { continue }
                let fim = fimDaLinha(tv, c.line - 1, tamanho: tamanho).proxima
                ranges.append(HighlightedRange(
                    id: "patch-\(c.line)",
                    range: NSRange(location: loc, length: max(fim - loc, 1)),
                    color: UIColor(hex: cores.ok).withAlphaComponent(0.16),
                    cornerRadius: 0
                ))
            case .removed:
                // Linha removida depois da última: o fio vai no pé da última.
                let existe = inicioDaLinha(tv, c.line - 1) != nil
                var alvo = c.line - 1
                if !existe {
                    alvo = max(tv.textLocation(at: tamanho)?.lineNumber ?? 0, 0)
                }
                guard faixa.linhas.contains(alvo), let inicio = inicioDaLinha(tv, alvo),
                      let pos = tv.position(from: tv.beginningOfDocument, offset: inicio)
                else { continue }
                let r = tv.caretRect(for: pos)
                ys.append((existe ? r.minY : r.maxY) - topo)
            }
        }
        changeMarks.cor = UIColor(hex: cores.danger)
        changeMarks.ys = ys
    }

    /// Nível de recuo da linha que ocupa `faixa` em `texto`, ou `nil` se ela está em branco.
    private func nivel(_ texto: NSString, _ faixa: Range<Int>, largura: Int) -> Int? {
        var espacos = 0
        for p in faixa {
            switch texto.character(at: p) {
            case 32: espacos += 1
            case 9: espacos += largura
            case 10, 13: return nil
            default: return espacos / largura
            }
        }
        return nil
    }

    /// Nível de uma linha fora da faixa (a do cursor, quando ela saiu da tela). Linha em
    /// branco herda o da próxima com texto, procurando até um teto.
    private func nivelDaLinha(_ tv: TextView, _ linha: Int, tamanho: Int, largura: Int) -> Int {
        var l = linha
        while l < linha + 200, let inicio = inicioDaLinha(tv, l) {
            let fim = fimDaLinha(tv, l, tamanho: tamanho).proxima
            let texto = (tv.text(in: NSRange(location: inicio, length: max(fim - inicio, 0))) ?? "") as NSString
            if let n = nivel(texto, 0 ..< texto.length, largura: largura) {
                return n
            }
            l += 1
        }
        return 0
    }

    /// Onde a decoração foi montada por último, em coordenadas do conteúdo.
    ///
    /// Mora nas guias, e não no coordenador, porque é estado da camada: é a faixa que ela
    /// cobre.
    var faixaDecorada: ClosedRange<CGFloat>? {
        get { guides.faixa }
        set { guides.faixa = newValue }
    }

    private var rolagemPendente: Bool {
        get { guides.refazendoNaRolagem }
        set { guides.refazendoNaRolagem = newValue }
    }

    /// Guias de indentação: uma linha vertical por nível, na coluna do recuo — só nas
    /// linhas da faixa visível.
    ///
    /// Linha em branco herda o nível da próxima linha com texto, que pode estar abaixo da
    /// faixa: a busca continua além dela, com teto, em vez de ler o arquivo até o fim.
    func layoutGuides(_ tv: TextView, faixa: (y: ClosedRange<CGFloat>, linhas: ClosedRange<Int>), tamanho: Int) {
        let topo = faixa.y.lowerBound
        guides.frame = CGRect(
            x: 0,
            y: topo,
            width: max(tv.contentSize.width, tv.bounds.width),
            height: faixa.y.upperBound - topo
        )
        guard guidesOn else {
            guides.segments = []
            guides.setNeedsDisplay()
            return
        }
        let largura = max(tabWidth, 1)
        let alem = 200
        // Um recorte só com a faixa e a sobra, em vez de um pedido por linha.
        let primeira = faixa.linhas.lowerBound
        let ultimaLida = faixa.linhas.upperBound + alem
        guard let deOffset = inicioDaLinha(tv, primeira) else { return }
        let ateOffset = inicioDaLinha(tv, ultimaLida + 1) ?? tamanho
        let recorte = (tv.text(in: NSRange(location: deOffset, length: max(ateOffset - deOffset, 0))) ?? "") as NSString
        var inicios: [Int] = []
        var i = primeira
        while i <= ultimaLida, let s = inicioDaLinha(tv, i) {
            inicios.append(s - deOffset)
            i += 1
        }
        var niveis: [Int?] = inicios.indices.map { k in
            let fim = min(k + 1 < inicios.count ? inicios[k + 1] : recorte.length, recorte.length)
            return nivel(recorte, min(inicios[k], fim) ..< fim, largura: largura)
        }
        // linhas em branco herdam o nível da próxima linha não vazia
        var proximo = 0
        for k in stride(from: niveis.count - 1, through: 0, by: -1) {
            if let n = niveis[k] {
                proximo = n
            } else {
                niveis[k] = proximo
            }
        }
        // A guia acesa é a do nível do cursor em qualquer lugar da tela, como sempre foi —
        // mesmo com o cursor fora dela.
        let linhaDoCursor = linhaDe(tv.selectedRange.location)
        let k = linhaDoCursor - primeira
        let nivelDoCursor = k >= 0 && k < niveis.count
            ? (niveis[k] ?? 0)
            : nivelDaLinha(tv, linhaDoCursor, tamanho: tamanho, largura: largura)
        let charW = charWidth(tv)
        var segs: [IndentGuides.Segment] = []
        for k in niveis.indices where faixa.linhas.contains(primeira + k) {
            let n = niveis[k] ?? 0
            guard n > 0, let pos = tv.position(from: tv.beginningOfDocument, offset: deOffset + inicios[k])
            else { continue }
            let r = tv.caretRect(for: pos)
            for level in 0 ..< n {
                segs.append(.init(
                    x: r.minX + CGFloat(level * largura) * charW,
                    y: r.minY - topo,
                    h: r.height,
                    active: level == nivelDoCursor - 1
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

    func positionOverlay() {
        guard let tv = textView else { return }
        // A tira das marcas cobre a mesma faixa das guias; antes da primeira passada de
        // decoração, a tela.
        let faixa = faixaDecorada ?? (tv.contentOffset.y ... tv.contentOffset.y + tv.bounds.height)
        overlay.frame = CGRect(
            x: tv.contentOffset.x,
            y: faixa.lowerBound,
            width: tv.gutterWidth,
            height: max(faixa.upperBound - faixa.lowerBound, 1)
        )
        conferirFaixaDaRolagem(tv)
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
}

/// Busca e substituição dentro do arquivo aberto.
extension CodeEditorView.Coordinator {
    func consulta(_ f: EditorFind) -> SearchQuery {
        SearchQuery(
            text: f.texto,
            matchMethod: f.regex ? .regularExpression : .contains,
            isCaseSensitive: f.caseSensitive
        )
    }

    func buscar(_ tv: TextView) {
        guard let f = find, f.texto.count >= 1 else {
            buscaRanges = []
            parent.onFindResults(0)
            scheduleDecorations()
            return
        }
        let achados = tv.search(for: consulta(f)).map(\.range)
        // Só avisa a contagem quando ela muda: o retorno entra em `@State` da view que
        // nos desenha, e avisar a cada layout seria um ciclo de atualização.
        if achados.count != buscaRanges.count {
            parent.onFindResults(achados.count)
        }
        buscaRanges = achados
        if !achados.isEmpty {
            let i = min(max(f.indice, 0), achados.count - 1)
            tv.selectedRange = achados[i]
            tv.scrollRangeToVisible(achados[i])
        }
        scheduleDecorations()
    }

    func substituir(_ tv: TextView, _ r: EditorReplace) {
        guard let f = find, !f.texto.isEmpty else { return }
        let achados = tv.search(for: consulta(f), replacingMatchesWith: r.por)
        guard !achados.isEmpty else { return }
        // Nada de `replaceText(in: BatchReplaceSet)`: o desfazer que o Runestone registra
        // para ele fecha um grupo de desfazer de dentro do próprio desfazer, e o
        // `UndoManager` levanta exceção — o ⌘Z depois de substituir derrubava o app. A
        // edição comum (`replace`) registra o desfazer do jeito que a digitação registra.
        if r.todos {
            // Uma troca por ocorrência, de trás para frente para os índices dos achados
            // continuarem valendo, todas num passo só do desfazer. Trocar o documento
            // inteiro de uma vez passava o arquivo todo pela conversão de quebras do
            // Runestone — um arquivo CRLF virava LF inteiro — e jogava o cursor longe.
            let selecao = tv.selectedRange
            let trocas = DiferencaDeTexto.agrupar(
                achados.map { DiferencaDeTexto.Troca(faixa: $0.range, texto: $0.replacementText) },
                em: linhas().ns,
                maximo: 60
            )
            editarPorDentro(tv, avisar: true) {
                for t in trocas.reversed() {
                    trocarTrecho(tv, t.faixa, por: t.texto)
                }
                let total = tamanhoDoDocumento(tv)
                let de = min(DiferencaDeTexto.mapear(selecao.location, trocas), total)
                tv.selectedRange = NSRange(location: de, length: 0)
            }
        } else {
            let a = achados[min(max(f.indice, 0), achados.count - 1)]
            editarPorDentro(tv, avisar: true) { trocarTrecho(tv, a.range, por: a.replacementText) }
        }
        buscar(tv)
    }

    /// Pinta as ocorrências: todas de leve, a que está em foco por inteiro.
    func marcarBusca(into ranges: inout [HighlightedRange]) {
        guard !buscaRanges.isEmpty else { return }
        let cores = palette ?? parent.palette
        let atual = min(max(find?.indice ?? 0, 0), buscaRanges.count - 1)
        for (i, r) in buscaRanges.enumerated() {
            ranges.append(HighlightedRange(
                id: "busca-\(i)",
                range: r,
                color: UIColor(hex: cores.accent).withAlphaComponent(i == atual ? 0.45 : 0.18),
                cornerRadius: 3
            ))
        }
    }
}

extension CodeEditorView.Coordinator {
    /// Põe a linha a um terço do topo da área visível, quando há rolagem para isso.
    func centralizar(_ tv: TextView, linha: Int) {
        let starts = linhas().starts
        guard linha >= 1, linha <= starts.count,
              let pos = tv.position(from: tv.beginningOfDocument, offset: starts[linha - 1]) else { return }
        let r = tv.caretRect(for: pos)
        let alvo = r.minY - tv.bounds.height / 3
        let maximo = max(0, tv.contentSize.height - tv.bounds.height)
        tv.setContentOffset(CGPoint(x: tv.contentOffset.x, y: min(max(alvo, 0), maximo)), animated: true)
    }
}

/// Mandar um trecho do arquivo para o agente.
extension CodeEditorView.Coordinator {
    /// O que está selecionado; sem seleção, a linha do cursor.
    ///
    /// Descrever onde mexer é o que mais custa numa conversa com o agente. Selecionar as
    /// linhas e mandar resolve isso de uma vez, e sem seleção a linha do cursor é o
    /// palpite certo: é onde a pessoa está olhando.
    func mandarSelecao() {
        guard let tv = textView else { return }
        let mapa = linhas()
        let ns = mapa.ns
        let starts = mapa.starts
        var faixa = tv.selectedRange
        if faixa.length == 0 {
            // Linha inteira do cursor, sem a quebra no fim.
            let i = max(0, (starts.lastIndex { $0 <= faixa.location } ?? 0))
            let de = starts[i]
            let ate = i + 1 < starts.count ? starts[i + 1] - 1 : ns.length
            faixa = NSRange(location: de, length: max(ate - de, 0))
        }
        guard faixa.location >= 0, faixa.location + faixa.length <= ns.length else { return }
        let texto = ns.substring(with: faixa)
        let primeira = (starts.lastIndex { $0 <= faixa.location } ?? 0) + 1
        let ultima = (starts.lastIndex { $0 <= faixa.location + max(faixa.length - 1, 0) } ?? 0) + 1
        parent.onSendSelection(texto, primeira, ultima)
    }
}
