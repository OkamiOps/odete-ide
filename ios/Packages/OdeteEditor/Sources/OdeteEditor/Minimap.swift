import OdeteCore
import OdeteI18n
import UIKit

/// Minimapa do arquivo, colado na borda direita do editor.
///
/// Desenha uma barra por linha, com largura proporcional ao tamanho da linha e recuo
/// proporcional à indentação, mais um retângulo mostrando o pedaço que está na tela.
/// Tocar ou arrastar leva o editor para aquele ponto.
final class MinimapView: UIView {
    struct Linha {
        var recuo: Int
        var tamanho: Int
        var comentario: Bool
    }

    var linhas: [Linha] = [] {
        didSet { setNeedsDisplay() }
    }

    var corCodigo: UIColor = .gray {
        didSet { setNeedsDisplay() }
    }

    var corComentario: UIColor = .darkGray {
        didSet { setNeedsDisplay() }
    }

    /// Linhas (1-based) com erro e com aviso. É o que responde "onde foi que quebrou"
    /// sem precisar rolar o arquivo inteiro atrás da linha vermelha.
    var erros: [Int] = [] {
        didSet { setNeedsDisplay() }
    }

    var avisos: [Int] = [] {
        didSet { setNeedsDisplay() }
    }

    var corErro: UIColor = .systemRed {
        didSet { setNeedsDisplay() }
    }

    var corAviso: UIColor = .systemOrange {
        didSet { setNeedsDisplay() }
    }

    var corJanela: UIColor = .white {
        didSet { setNeedsDisplay() }
    }

    var corFundo: UIColor = .clear {
        didSet { setNeedsDisplay() }
    }

    var tamanho: MinimapSize = .m {
        didSet { setNeedsDisplay() }
    }

    /// Fração do rolamento do editor, de 0 a 1, e quanto dele está visível.
    var fracao: CGFloat = 0
    var visivel: CGFloat = 1
    /// Chamado com a fração de destino quando a pessoa toca ou arrasta.
    var aoNavegar: ((CGFloat) -> Void)?

    static func largura(_ t: MinimapSize) -> CGFloat {
        switch t {
        case .off: 0
        case .s: 44
        case .m: 68
        case .l: 96
        }
    }

    private var alturaLinha: CGFloat {
        let maxima: CGFloat = switch tamanho {
        case .l: 4
        case .m: 3
        default: 2
        }
        guard !linhas.isEmpty else { return maxima }
        return min(maxima, max(0.6, bounds.height / CGFloat(linhas.count)))
    }

    /// Altura do mapa inteiro, que pode passar da altura da view.
    private var alturaMapa: CGFloat {
        alturaLinha * CGFloat(max(linhas.count, 1))
    }

    private var deslocamento: CGFloat {
        max(0, (alturaMapa - bounds.height) * fracao)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        let toque = UITapGestureRecognizer(target: self, action: #selector(tocou))
        let arraste = UIPanGestureRecognizer(target: self, action: #selector(arrastou))
        addGestureRecognizer(toque)
        addGestureRecognizer(arraste)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError(tr("sem storyboard"))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !linhas.isEmpty else { return }
        corFundo.setFill()
        ctx.fill(rect)
        let h = alturaLinha
        let desl = deslocamento
        let larguraColuna = max(0.6, (bounds.width - 8) / 90)
        let primeira = max(0, Int(desl / h) - 1)
        let ultima = min(linhas.count - 1, Int((desl + bounds.height) / h) + 1)
        guard primeira <= ultima else { return }
        for i in primeira ... ultima {
            let l = linhas[i]
            guard l.tamanho > 0 else { continue }
            let x = 4 + CGFloat(min(l.recuo, 60)) * larguraColuna
            let w = min(CGFloat(min(l.tamanho, 90)) * larguraColuna, bounds.width - 4 - x)
            guard w > 0 else { continue }
            (l.comentario ? corComentario : corCodigo).setFill()
            ctx.fill(CGRect(x: x, y: CGFloat(i) * h - desl, width: w, height: max(0.8, h - 0.6)))
        }
        // Problemas por cima do código, da borda à borda, para aparecerem mesmo numa
        // linha curta.
        for (linhas, cor) in [(avisos, corAviso), (erros, corErro)] {
            cor.withAlphaComponent(0.85).setFill()
            for n in linhas where n >= 1 && n <= self.linhas.count {
                let y = CGFloat(n - 1) * h - desl
                guard y > -4, y < bounds.height + 4 else { continue }
                ctx.fill(CGRect(x: 0, y: y - 0.5, width: bounds.width, height: max(1.5, h)))
            }
        }
        // Janela visível. Quando o arquivo inteiro cabe na tela ela cobriria tudo, então
        // não vale a pena desenhar.
        guard visivel < 0.999 else { return }
        let alturaJanela = max(18, alturaMapa * visivel)
        let topo = (alturaMapa - alturaJanela) * fracao - desl
        corJanela.setFill()
        ctx.fill(CGRect(x: 0, y: topo, width: bounds.width, height: alturaJanela))
    }

    @objc private func tocou(_ g: UITapGestureRecognizer) {
        navegar(para: g.location(in: self).y)
    }

    @objc private func arrastou(_ g: UIPanGestureRecognizer) {
        navegar(para: g.location(in: self).y)
    }

    private func navegar(para y: CGFloat) {
        let alturaJanela = max(18, alturaMapa * visivel)
        let alvo = y + deslocamento - alturaJanela / 2
        let total = max(1, alturaMapa - alturaJanela)
        aoNavegar?(min(1, max(0, alvo / total)))
    }

    /// Lê o texto uma vez e guarda só o que o desenho precisa.
    static func medir(_ texto: String, tabWidth: Int) -> [Linha] {
        var out: [Linha] = []
        out.reserveCapacity(1024)
        for linha in texto.split(separator: "\n", omittingEmptySubsequences: false) {
            var recuo = 0
            var i = linha.startIndex
            while i < linha.endIndex, linha[i] == " " || linha[i] == "\t" {
                recuo += linha[i] == "\t" ? tabWidth : 1
                i = linha.index(after: i)
            }
            let resto = linha[i...]
            out.append(Linha(
                recuo: recuo,
                tamanho: resto.count,
                comentario: resto.hasPrefix("//") || resto.hasPrefix("/*") || resto.hasPrefix("*")
                    || resto.hasPrefix("#") || resto.hasPrefix("<!--")
            ))
        }
        return out
    }
}
