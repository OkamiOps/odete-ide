import OdeteCore
import Runestone
import UIKit

/// Pedidos de uso único (substituir, ir para a linha), recuo e quebra de linha do
/// arquivo, e as edições que o próprio editor faz no texto.
extension CodeEditorView.Coordinator {
    // MARK: - Pedidos de uso único

    /// Atende o pedido de substituição e o de ir para a linha, se forem novos para este
    /// documento.
    ///
    /// "Novo" é conferido por documento (`SessoesDoEditor.atendidos`), não no
    /// coordenador: o coordenador nasce a cada host novo — trocar de modo, o lado direito
    /// do modo Dois — e nascia achando que todo pedido guardado no modelo era novo.
    /// Depois de atender, avisa quem pediu, que esquece o pedido.
    func atenderPedidos(_ tv: TextView) {
        guard sessao != nil, !documentId.isEmpty else { return }
        let doc = documentId
        // Anotado antes de atender: o que a substituição dispara (o texto novo indo para
        // o modelo) não pode achar o mesmo pedido ainda como novo.
        if let r = parent.replace, sessoes.atendidos[doc, default: .init()].troca != r.token {
            sessoes.atendidos[doc, default: .init()].troca = r.token
            substituir(tv, r)
            let avisar = parent.aoConsumirTroca
            DispatchQueue.main.async { avisar(r.token) }
        }
        if let reveal = parent.reveal, sessoes.atendidos[doc, default: .init()].linha != reveal.token {
            sessoes.atendidos[doc, default: .init()].linha = reveal.token
            let avisar = parent.aoConsumirLinha
            DispatchQueue.main.async { [weak self] in
                _ = tv.goToLine(max(reveal.line - 1, 0), select: .line)
                tv.becomeFirstResponder()
                // O `goToLine` rola o mínimo, e a linha alvo acabava colada na borda de
                // baixo — chegar na definição e não vê-la não serve de nada. Um terço a
                // partir do topo deixa o contexto de cima e de baixo à vista.
                self?.centralizar(tv, linha: reveal.line)
                avisar(reveal.token)
            }
        }
    }

    // MARK: - Recuo e quebra de linha do arquivo

    /// O recuo que o Tab, o Enter e o ⇧Tab usam neste arquivo: o do `.editorconfig`; sem
    /// ele, o que o texto já usa; sem nada disso, o dos Ajustes.
    func estrategiaDeRecuo(_ prefs: EditorPrefs) -> IndentStrategy {
        let cfg = parent.config
        switch cfg?.recuo {
        case .tab:
            return .tab(length: cfg?.larguraDoTab ?? cfg?.tamanhoDoRecuo ?? prefs.tabWidth)
        case .espacos:
            return .space(length: cfg?.tamanhoDoRecuo ?? prefs.tabWidth)
        case nil:
            break
        }
        switch sessao?.recuoDetectado ?? .unknown {
        case .tab:
            return .tab(length: cfg?.larguraDoTab ?? prefs.tabWidth)
        case let .space(n) where n > 0:
            return .space(length: n)
        default:
            return .space(length: cfg?.tamanhoDoRecuo ?? prefs.tabWidth)
        }
    }

    /// A quebra que o Enter e o texto inserido usam: a que o arquivo já tem; em arquivo de
    /// uma linha só, a do `.editorconfig`; senão `\n`.
    ///
    /// O Runestone insere `\n` por padrão, e a quebra detectada ao abrir era jogada fora:
    /// cada Enter num arquivo CRLF misturava um `\n` no meio dele.
    func aplicarQuebra(_ tv: TextView) {
        let quebra = sessao?.quebraDetectada ?? parent.config?.fimDeLinha?.runestone ?? .lf
        if tv.lineEndings != quebra {
            tv.lineEndings = quebra
        }
    }

    /// Todo `setState` passa por aqui: guarda o recuo e a quebra que o texto novo usa e os
    /// aplica ao editor.
    func aplicarEstado(_ tv: TextView, _ estado: TextViewState, texto: String, desfazivel: Bool) {
        tv.setState(estado, addUndoAction: desfazivel)
        if let s = sessao, s.textView === tv {
            s.recuoDetectado = RecuoDoTexto.detectar(texto)
            s.quebraDetectada = estado.detectedLineEndings
        }
        aplicarQuebra(tv)
        aplicarRecuo(tv)
    }

    func aplicarRecuo(_ tv: TextView) {
        let recuo = estrategiaDeRecuo(parent.prefs)
        if tv.indentStrategy != recuo {
            tv.indentStrategy = recuo
        }
    }

    // MARK: - Tab

    /// Tab com o editor em foco (teclado físico ou a tecla da barra).
    ///
    /// Com seleção que atravessa linhas, recua as linhas — antes a seleção era trocada
    /// por um `\t` e o que estava selecionado sumia. Sem isso, num arquivo de espaços,
    /// insere espaços até a próxima parada de recuo em vez de um `\t` literal. Devolve
    /// falso quando o `\t` do teclado deve entrar como está (arquivo de tabs).
    @discardableResult
    func tabular(_ tv: TextView, faixa: NSRange) -> Bool {
        hidePopup()
        if faixa.length > 0, (tv.text(in: faixa) ?? "").contains(where: \.isNewline) {
            umPasso(tv) { tv.shiftRight() }
            return true
        }
        guard case let .space(n) = tv.indentStrategy, n > 0 else { return false }
        let inicio = inicioDaLinha(tv, linhaDe(faixa.location)) ?? faixa.location
        let coluna = max(faixa.location - inicio, 0)
        let espacos = String(repeating: " ", count: n - coluna % n)
        editarPorDentro(tv, avisar: true) {
            tv.replace(faixa, withText: espacos)
        }
        return true
    }

    /// A tecla ⇥ da barra acima do teclado: o mesmo que o Tab do teclado físico.
    func tabularPelaBarra() {
        guard let tv = textView else { return }
        if !tabular(tv, faixa: tv.selectedRange) {
            tv.insertText("\t")
        }
    }

    // MARK: - Edições do próprio editor

    /// Uma edição feita pelo editor — comando de linha, substituição, texto que mudou por
    /// fora —: um passo só no desfazer e sem passar pelas regras de tecla (Tab virar
    /// recuo, Enter aceitar sugestão). O texto é anotado uma vez, no fim; `avisar` manda
    /// o texto novo para quem é dono dele (não se o texto veio justamente de lá).
    ///
    /// A rolagem automática do Runestone fica desligada durante a edição: ele rola até o
    /// cursor a cada trecho trocado, e trocar vários trechos — de trás para a frente — fazia
    /// a tela pular por eles. E, para rolar, ele pede o retângulo do cursor numa linha que
    /// acabou de mudar e ainda não foi recomposta (fora da tela, ou com o editor ainda sem
    /// tamanho), o que derruba o app nos builds de depuração. `rolar` leva a tela até o
    /// cursor no fim, pelo caminho que recompõe as linhas antes de medir.
    func editarPorDentro(_ tv: TextView, avisar: Bool, rolar: Bool = true, _ corpo: () -> Void) {
        let antes = editandoPorDentro
        let rolagemAutomatica = tv.isAutomaticScrollEnabled
        editandoPorDentro = true
        tv.isAutomaticScrollEnabled = false
        umPasso(tv, corpo)
        tv.isAutomaticScrollEnabled = rolagemAutomatica
        editandoPorDentro = antes
        guard !antes else { return }
        anotarTexto(tv.text)
        if avisar {
            isEditing = true
            parent.text = textoAtual
            isEditing = false
        }
        if rolar, rolagemAutomatica, tv.window != nil, tv.bounds.width > 0 {
            tv.scrollRangeToVisible(NSRange(location: tv.selectedRange.location, length: 0))
        }
        scheduleDecorations()
        agendarMinimapa()
    }

    /// Troca um trecho sem deixar o Runestone mexer nas quebras do texto novo.
    ///
    /// Ele converte toda quebra do texto inserido para a do editor — e, num arquivo CRLF,
    /// estraga o que já vinha com `\r\n`. Entregando só `\n`, a conversão sai certa.
    func trocarTrecho(_ tv: TextView, _ faixa: NSRange, por texto: String) {
        tv.replace(faixa, withText: tv.lineEndings == .crlf ? QuebrasDeLinha.soLF(texto) : texto)
    }
}

extension IndentStrategy {
    /// Quantas colunas um nível de recuo ocupa.
    var largura: Int {
        switch self {
        case let .tab(n): n
        case let .space(n): n
        }
    }
}
