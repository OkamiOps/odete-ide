import OdeteCore
import Runestone
import UIKit

/// Tirar um documento da tela e pôr outro, sem recriar o estado de nenhum dos dois.
extension CodeEditorView.Coordinator {
    /// As camadas desenhadas por cima do texto. São do coordenador, não do editor: na
    /// troca de aba elas mudam de `TextView` junto com ele.
    var camadas: [UIView] {
        [guides, changeMarks, overlay, minimap, popup, balao]
    }

    var assinaturaAtual: AssinaturaDoTema {
        AssinaturaDoTema(
            palette: parent.palette,
            fontSize: parent.prefs.fontSize,
            familia: parent.prefs.fontFamily,
            linguagem: parent.language
        )
    }

    /// Põe na tela o editor de `parent.documentId`. Devolve verdadeiro quando houve troca.
    ///
    /// O editor que sai não é destruído: fica guardado com o desfazer, o cursor e a
    /// rolagem, e volta inteiro quando a aba voltar. `avulsa` monta um editor fora da
    /// fila — só para quando o guardado está na tela em outro lugar (ver
    /// `perdeuSessao`).
    @discardableResult
    func exibir(em host: HostDoEditor, avulsa: Bool = false) -> Bool {
        self.host = host
        host.coordenador = self
        let doc = parent.documentId
        if let s = sessao, s.documento == doc, s.textView.superview === host {
            return false
        }
        let anterior = sessao
        let tinhaFoco = anterior?.textView.isEditing == true
        let s: SessoesDoEditor.Sessao
        if !avulsa, let guardada = sessoes.sessao(doc) {
            // Outro host mostrava este documento (troca de modo, lados trocados no modo
            // Dois): quem pede por último leva o editor.
            if let dono = guardada.coordenador, dono !== self {
                dono.perdeuSessao(guardada)
            }
            s = guardada
            s.host = host
        } else {
            s = novaSessao(doc, avulsa: avulsa)
            s.host = host
            sessoes.registrar(s)
        }
        documentId = doc
        sessao = s
        textView = s.textView
        s.coordenador = self
        sessoes.tocar(s)
        sessoes.entrouNaTela(self)
        let tv = s.textView
        tv.frame = host.bounds
        tv.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(tv)
        ligar(s)
        // Recuo e quebra são do documento que entrou, não do que saiu.
        aplicarRecuo(tv)
        aplicarQuebra(tv)
        // Quem estava digitando e trocou de aba pelo teclado continua digitando. O foco
        // passa antes de o editor antigo sair da tela, senão o teclado de tela desce e
        // sobe de novo.
        if tinhaFoco {
            tv.becomeFirstResponder()
        }
        if let anterior, anterior !== s {
            soltar(anterior)
        }
        anotarTexto(tv.text)
        ultimaLinhaDoCursor = -1
        minimapTexto = ""
        hidePopup()
        esconderProblema()
        if let r = s.rolagemPendente {
            s.rolagemPendente = nil
            rolar(tv, para: r)
            // De novo depois do layout: aqui o host ainda pode estar sem tamanho.
            Task { @MainActor [weak self, weak tv] in
                guard let self, let tv else { return }
                rolar(tv, para: r)
            }
        }
        scheduleDecorations()
        return true
    }

    /// Um `TextView` novo para o documento, já com texto, tema e gramática.
    func novaSessao(_ doc: String, avulsa: Bool) -> SessoesDoEditor.Sessao {
        let tv = OdeteTextView()
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
        tv.characterPairs = CodeEditorView.pairs
        let barra = KeyboardBar(
            textView: tv,
            onSave: parent.onSave,
            onFind: parent.onFind,
            onDefinition: parent.onDefinition,
            onSendSelection: { [weak self] in self?.mandarSelecao() },
            onComentar: { [weak self] in self?.executar(.alternarComentario) },
            onTab: { [weak self] in self?.tabularPelaBarra() },
            onDesindentar: { [weak self] in self?.executar(.desindentar) }
        )
        tv.inputAccessoryView = barra
        // Toque no caminho do import ou na onda de um problema. Não cancela o toque
        // original: o cursor continua indo para onde a pessoa tocou.
        let toque = UITapGestureRecognizer()
        toque.cancelsTouchesInView = false
        tv.addGestureRecognizer(toque)
        let a = assinaturaAtual
        tv.backgroundColor = UIColor(hex: a.palette.bg)
        let inicial = estado(texto: parent.text, a)
        tv.setState(inicial)
        let s = SessoesDoEditor.Sessao(
            documento: doc,
            textView: tv,
            barra: barra,
            toque: toque,
            assinatura: a,
            avulsa: avulsa
        )
        // O recuo e a quebra que o arquivo já usa. A quebra detectada era jogada fora e o
        // Runestone ficava no `\n` padrão: Enter num arquivo CRLF misturava quebras.
        s.recuoDetectado = RecuoDoTexto.detectar(parent.text)
        s.quebraDetectada = inicial.detectedLineEndings
        tv.lineEndings = inicial.detectedLineEndings ?? parent.config?.fimDeLinha?.runestone ?? .lf
        // Documento que já teve editor e foi despejado da fila: volta com o cursor e a
        // rolagem onde estavam.
        if let salvo = sessoes.estadoSalvo(doc) {
            let n = (parent.text as NSString).length
            let de = min(max(salvo.selecao.location, 0), n)
            tv.selectedRange = NSRange(location: de, length: min(max(salvo.selecao.length, 0), n - de))
            s.rolagemPendente = salvo.rolagem
        }
        return s
    }

    func estado(texto: String, _ a: AssinaturaDoTema) -> TextViewState {
        let theme = EditorTheme(palette: a.palette, fontSize: a.fontSize, familia: a.familia)
        if let lang = LanguageMode.treeSitter(for: a.linguagem) {
            return TextViewState(text: texto, theme: theme, language: lang, languageProvider: LanguageMode.provider)
        }
        return TextViewState(text: texto, theme: theme)
    }

    /// Faz do coordenador o dono do editor: delegate, camadas, toque e rolagem.
    func ligar(_ s: SessoesDoEditor.Sessao) {
        let tv = s.textView
        tv.editorDelegate = self
        for v in camadas {
            tv.addSubview(v)
        }
        tv.floating = camadas
        tv.aoLayout = { [weak self] in
            self?.positionOverlay()
            self?.conferirBalao()
        }
        s.toque.removeTarget(nil, action: nil)
        s.toque.addTarget(self, action: #selector(tocouNoTexto(_:)))
        s.toque.delegate = self
        // ↑/↓/Esc vão para a lista de sugestões enquanto ela está aberta — ver
        // `TextViewComSugestoes`. Cada aba tem o seu editor, então o gancho vai junto.
        if let comLista = tv as? TextViewComSugestoes {
            comLista.listaAberta = { [weak self] in self?.popup.isHidden == false }
            comLista.naLista = { [weak self] tecla in self?.teclaNaLista(tecla) }
        }
        s.barra.onSave = parent.onSave
        s.barra.onFind = parent.onFind
        s.barra.onDefinition = parent.onDefinition
        s.barra.onSendSelection = { [weak self] in self?.mandarSelecao() }
        s.barra.onComentar = { [weak self] in self?.executar(.alternarComentario) }
        s.barra.onTab = { [weak self] in self?.tabularPelaBarra() }
        s.barra.onDesindentar = { [weak self] in self?.executar(.desindentar) }
        offsetObservation?.invalidate()
        offsetObservation = tv.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.positionOverlay() }
        }
    }

    /// Desfaz `ligar` sem tirar o editor da tela (quem tira é quem chamou).
    private func desligar(_ s: SessoesDoEditor.Sessao) {
        let tv = s.textView
        for v in camadas where v.superview === tv {
            v.removeFromSuperview()
        }
        tv.floating = []
        tv.aoLayout = nil
        s.toque.removeTarget(self, action: nil)
        if let comLista = tv as? TextViewComSugestoes {
            comLista.listaAberta = { false }
            comLista.naLista = { _ in }
        }
    }

    /// Tira o editor da tela e o devolve à fila.
    func soltar(_ s: SessoesDoEditor.Sessao) {
        desligar(s)
        let tv = s.textView
        tv.editorDelegate = nil
        // As ações da barra vêm do centro e seguram o workspace; guardado fora da tela,
        // o editor não pode manter vivo um projeto que já fechou.
        s.barra.onSave = {}
        s.barra.onFind = {}
        s.barra.onDefinition = {}
        tv.removeFromSuperview()
        sessoes.estacionar(s)
    }

    /// Outro host levou o editor deste documento.
    ///
    /// Acontece na troca de modo (Código → Split): o host novo nasce antes de o velho ir
    /// embora e pede o mesmo documento. Se este host seguir na tela depois da transição,
    /// ganha um editor avulso; se for desmontado, não faz nada.
    func perdeuSessao(_ s: SessoesDoEditor.Sessao) {
        guard sessao === s else { return }
        desligar(s)
        offsetObservation?.invalidate()
        offsetObservation = nil
        sessao = nil
        textView = nil
        documentId = ""
        sessoes.saiuDaTela(self)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.recuperar()
        }
    }

    private func recuperar() {
        guard !desmontado, sessao == nil, let host, host.window != nil else { return }
        // O guardado ainda está na tela noutro host? Então um avulso; senão, o guardado.
        let ocupado = sessoes.sessao(parent.documentId)?.host != nil
        exibir(em: host, avulsa: ocupado)
        conferirTema()
        if let tv = textView, textoAtual != parent.text {
            aplicarTextoDeFora(parent.text, em: tv)
        }
    }

    /// SwiftUI tirou o editor da hierarquia: o `TextView` volta para a fila.
    func desmontar() {
        desmontado = true
        decorationTask?.cancel()
        minimapTask?.cancel()
        offsetObservation?.invalidate()
        offsetObservation = nil
        if let s = sessao {
            soltar(s)
        }
        sessao = nil
        textView = nil
        sessoes.saiuDaTela(self)
    }

    /// Tema, fonte e gramática do editor da vez conferidos com os pedidos.
    ///
    /// Remonta com `setState(_, addUndoAction: true)` e o mesmo texto: o Runestone só
    /// mexe na pilha de desfazer quando o texto muda, então trocar de tema não apaga
    /// mais o ⌘Z. Editores guardados fora da tela são conferidos quando voltam.
    func conferirTema() {
        guard let s = sessao else { return }
        let a = assinaturaAtual
        if s.assinatura != a {
            s.assinatura = a
            hidePopup()
            s.textView.backgroundColor = UIColor(hex: a.palette.bg)
            aplicarEstado(s.textView, estado(texto: textoAtual, a), texto: textoAtual, desfazivel: true)
        }
        if palette != a.palette {
            aplicarCores(a.palette)
        }
        palette = a.palette
        fontSize = a.fontSize
        fontFamily = a.familia
    }

    func aplicarCores(_ palette: ThemePalette) {
        host?.backgroundColor = UIColor(hex: palette.bg)
        overlay.addedColor = UIColor(hex: palette.ok)
        overlay.modifiedColor = UIColor(hex: palette.syntax.keyword)
        overlay.deletedColor = UIColor(hex: palette.danger)
        minimap.corCodigo = UIColor(hex: palette.fg).withAlphaComponent(palette.dark ? 0.45 : 0.40)
        minimap.corComentario = UIColor(hex: palette.fgSubtle).withAlphaComponent(0.45)
        minimap.corJanela = UIColor(hex: palette.fg).withAlphaComponent(palette.dark ? 0.10 : 0.09)
        minimap.corFundo = UIColor(hex: palette.bg).withAlphaComponent(0.6)
        guides.color = UIColor(hex: palette.fg).withAlphaComponent(palette.dark ? 0.09 : 0.12)
        guides.activeColor = UIColor(hex: palette.accent).withAlphaComponent(0.45)
        popup.fg = UIColor(hex: palette.fg)
        popup.muted = UIColor(hex: palette.fgMuted)
        popup.accent = UIColor(hex: palette.accent)
    }

    /// Texto que mudou por fora do editor (disco, salvar arrumando o arquivo).
    ///
    /// Era `tv.text = texto`, e o Runestone apaga a pilha de desfazer ao receber texto
    /// assim. `setState(_, addUndoAction: true)` com o texto novo entra no desfazer como
    /// um passo comum de troca de texto: o ⌘Z anterior continua lá, e dá para voltar ao
    /// texto de antes da mudança de fora. Não passa pelo delegate, então nada volta
    /// para o binding.
    ///
    /// A troca em lote (`replaceText(in: BatchReplaceSet)`) parecia o caminho óbvio e
    /// não serve: desfazê-la derruba o app — o Runestone fecha, no meio do desfazer, o
    /// grupo que o próprio `UndoManager` abriu (`endUndoGrouping called with no
    /// matching begin`).
    ///
    /// Quando dá, entra só o que mudou (`DiferencaDeTexto`), como edição comum num passo
    /// de desfazer: o cursor e a rolagem ficam onde estavam e o Runestone analisa só o
    /// trecho. Era isto que fazia o salvamento automático com "remover espaços no fim"
    /// jogar o cursor longe a cada pausa. O texto inteiro volta por `setState` quando a
    /// troca é grande demais ou traz quebras que o editor converteria.
    func aplicarTextoDeFora(_ texto: String, em tv: TextView) {
        hidePopup()
        let trocas = DiferencaDeTexto.trocas(de: textoAtual, para: texto)
        let cabem = !trocas.isEmpty && trocas.count <= 200
            && trocas.allSatisfy { QuebrasDeLinha.inalterado($0.texto, por: tv.lineEndings) }
        if cabem, tv.text == textoAtual {
            let selecao = tv.selectedRange
            let rolagem = tv.contentOffset
            editarPorDentro(tv, avisar: false, rolar: false) {
                for t in trocas.reversed() {
                    trocarTrecho(tv, t.faixa, por: t.texto)
                }
                let total = tamanhoDoDocumento(tv)
                let nova = DiferencaDeTexto.mapear(selecao, trocas)
                let de = min(nova.location, total)
                tv.selectedRange = NSRange(location: de, length: min(nova.length, total - de))
            }
            tv.contentOffset = rolagem
        }
        // Não coube, ou por algum motivo as trocas não chegaram ao texto pedido: o texto
        // inteiro, como sempre foi.
        if textoAtual != texto {
            aplicarEstado(tv, estado(texto: texto, sessao?.assinatura ?? assinaturaAtual), texto: texto, desfazivel: true)
            anotarTexto(texto)
        }
    }

    /// Rola até `ponto`, preso ao que o conteúdo permite.
    func rolar(_ tv: TextView, para ponto: CGPoint) {
        tv.layoutIfNeeded()
        let maxY = max(0, tv.contentSize.height + tv.adjustedContentInset.bottom - tv.bounds.height)
        let maxX = max(0, tv.contentSize.width - tv.bounds.width)
        tv.contentOffset = CGPoint(x: min(max(ponto.x, 0), maxX), y: min(max(ponto.y, 0), maxY))
    }
}
