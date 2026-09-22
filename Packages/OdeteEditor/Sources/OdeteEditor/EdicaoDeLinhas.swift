import Foundation
import OdeteCore

/// Como a linguagem comenta uma linha.
public enum EstiloDeComentario: Equatable, Sendable {
    /// Marca no começo da linha: `//`, `#`, `--`.
    case linha(String)
    /// Abre e fecha em volta do trecho: `<!-- -->`, `/* */`. É o que sobra para quem
    /// não tem comentário de linha, como HTML e CSS.
    case bloco(String, String)
}

/// Uma troca de texto pronta para aplicar: onde, pelo quê, e onde a seleção fica depois
/// (já nas posições do texto novo).
struct EdicaoDeTexto: Equatable {
    var faixa: NSRange
    var texto: String
    var selecao: NSRange
}

/// As operações de linha dos atalhos do editor, como contas puras sobre o texto.
///
/// Cada uma devolve uma troca só, de um trecho contínuo. É isso que faz o ⌘Z desfazer o
/// comando inteiro de uma vez, em vez de uma linha por vez.
enum EdicaoDeLinhas {
    /// As linhas inteiras (com a quebra do fim) que a seleção toca.
    ///
    /// Seleção que termina logo no começo de uma linha não leva essa linha junto: é o que
    /// acontece ao selecionar linhas inteiras arrastando, e o VS Code faz igual.
    static func bloco(_ ns: NSString, selecao: NSRange) -> NSRange {
        let inicio = ns.lineRange(for: NSRange(location: min(selecao.location, ns.length), length: 0)).location
        let ultimo = selecao.length > 0 ? selecao.location + selecao.length - 1 : selecao.location
        let fim = NSMaxRange(ns.lineRange(for: NSRange(location: min(max(ultimo, 0), ns.length), length: 0)))
        return NSRange(location: inicio, length: max(fim - inicio, 0))
    }

    /// Uma linha do bloco: onde começa, o conteúdo e a quebra que a termina.
    struct Linha {
        var inicio: Int
        var conteudo: String
        var quebra: String

        /// Espaços e tabs do começo, em unidades UTF-16.
        var recuo: Int {
            (conteudo.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
        }

        var vazia: Bool {
            conteudo.allSatisfy { $0 == " " || $0 == "\t" }
        }

        /// O que vem depois do recuo.
        var corpo: Substring {
            conteudo.drop { $0 == " " || $0 == "\t" }
        }
    }

    static func linhas(_ ns: NSString, em bloco: NSRange) -> [Linha] {
        var out: [Linha] = []
        var i = bloco.location
        let fim = NSMaxRange(bloco)
        while i < fim {
            var inicioLinha = 0, fimConteudo = 0, fimLinha = 0
            ns.getLineStart(
                &inicioLinha,
                end: &fimLinha,
                contentsEnd: &fimConteudo,
                for: NSRange(location: i, length: 0)
            )
            let conteudo = ns.substring(with: NSRange(location: i, length: fimConteudo - i))
            let quebra = ns.substring(with: NSRange(location: fimConteudo, length: min(fimLinha, fim) - fimConteudo))
            out.append(Linha(inicio: i, conteudo: conteudo, quebra: quebra))
            if fimLinha <= i {
                break
            }
            i = fimLinha
        }
        if out.isEmpty {
            // Documento vazio, ou cursor na última linha vazia depois da quebra final.
            out.append(Linha(inicio: bloco.location, conteudo: "", quebra: ""))
        }
        return out
    }

    // MARK: - Comentar

    /// Mudança de posição causada pela troca: inserção ou remoção em `onde`, nas posições
    /// do texto antigo. É o que leva a seleção junto com o texto.
    enum Passo {
        case insercao(onde: Int, tamanho: Int)
        case remocao(onde: Int, tamanho: Int)
    }

    /// Onde uma posição do texto antigo foi parar. `inicio` diz de que lado da inserção
    /// ela fica quando cai exatamente em cima dela: o começo de uma seleção fica antes do
    /// `// `, para ele entrar na seleção; o cursor e o fim da seleção andam junto.
    static func mapear(_ pos: Int, _ passos: [Passo], inicio: Bool) -> Int {
        var delta = 0
        for p in passos {
            switch p {
            case let .insercao(onde, tamanho):
                if pos > onde || (pos == onde && !inicio) {
                    delta += tamanho
                }
            case let .remocao(onde, tamanho):
                if pos >= onde + tamanho {
                    delta -= tamanho
                } else if pos > onde {
                    delta -= pos - onde
                }
            }
        }
        return pos + delta
    }

    /// Comenta ou descomenta as linhas da seleção, como o ⌘/ do VS Code.
    ///
    /// Se alguma linha com conteúdo ainda não está comentada, comenta todas; só quando
    /// todas estão é que descomenta. A marca de linha entra na coluna do menor recuo do
    /// trecho, e as linhas em branco ficam como estão — senão um bloco comentado viraria
    /// uma escada de `//` soltos.
    static func alternarComentario(_ ns: NSString, selecao: NSRange, estilo: EstiloDeComentario) -> EdicaoDeTexto {
        let faixa = bloco(ns, selecao: selecao)
        let todas = linhas(ns, em: faixa)
        let comConteudo = todas.indices.filter { !todas[$0].vazia }
        // Só linhas em branco: comenta assim mesmo, que é o que a pessoa pediu.
        let alvos = Set(comConteudo.isEmpty ? Array(todas.indices) : comConteudo)
        let jaComentadas = alvos.allSatisfy { comentada(todas[$0], estilo) }
        let coluna = alvos.map { todas[$0].recuo }.min() ?? 0
        var texto = ""
        var passos: [Passo] = []
        for (i, l) in todas.enumerated() {
            guard alvos.contains(i) else {
                texto += l.conteudo + l.quebra
                continue
            }
            // O de linha entra na coluna comum, para os `//` ficarem alinhados; o de bloco
            // abre no recuo de cada linha, senão o recuo ficaria dentro do comentário.
            let onde = if case .bloco = estilo {
                l.recuo
            } else {
                coluna
            }
            let (novo, ps) = jaComentadas ? descomentar(l, estilo) : comentar(l, estilo, coluna: onde)
            texto += novo + l.quebra
            passos += ps
        }
        let novaSelecao: NSRange
        if selecao.length == 0 {
            let p = mapear(selecao.location, passos, inicio: false)
            novaSelecao = NSRange(location: p, length: 0)
        } else {
            let de = mapear(selecao.location, passos, inicio: true)
            let ate = mapear(NSMaxRange(selecao), passos, inicio: false)
            novaSelecao = NSRange(location: de, length: max(ate - de, 0))
        }
        return EdicaoDeTexto(faixa: faixa, texto: texto, selecao: novaSelecao)
    }

    static func comentada(_ l: Linha, _ estilo: EstiloDeComentario) -> Bool {
        let corpo = l.corpo
        switch estilo {
        case let .linha(marca):
            return corpo.hasPrefix(marca)
        case let .bloco(abre, fecha):
            let semFim = corpo.reversed().drop { $0 == " " || $0 == "\t" }
            let aparado = String(semFim.reversed())
            return aparado.count >= abre.count + fecha.count && aparado.hasPrefix(abre) && aparado.hasSuffix(fecha)
        }
    }

    private static func comentar(_ l: Linha, _ estilo: EstiloDeComentario, coluna: Int) -> (String, [Passo]) {
        let ns = l.conteudo as NSString
        let antes = ns.substring(to: coluna)
        let depois = ns.substring(from: coluna)
        switch estilo {
        case let .linha(marca):
            let marca = marca + " "
            return (antes + marca + depois, [.insercao(onde: l.inicio + coluna, tamanho: marca.utf16.count)])
        case let .bloco(abre, fecha):
            // O fecho vai logo depois do último caractere visível; espaço sobrando no fim
            // da linha sai junto, senão ficaria preso dentro do comentário.
            let semFim = String(String(depois.reversed().drop { $0 == " " || $0 == "\t" }).reversed())
            let sobra = (depois as NSString).length - (semFim as NSString).length
            let abertura = abre + " ", fechamento = " " + fecha
            let fimConteudo = l.inicio + coluna + (semFim as NSString).length
            var passos: [Passo] = [.insercao(onde: l.inicio + coluna, tamanho: abertura.utf16.count)]
            if sobra > 0 {
                passos.append(.remocao(onde: fimConteudo, tamanho: sobra))
            }
            passos.append(.insercao(onde: fimConteudo, tamanho: fechamento.utf16.count))
            return (antes + abertura + semFim + fechamento, passos)
        }
    }

    private static func descomentar(_ l: Linha, _ estilo: EstiloDeComentario) -> (String, [Passo]) {
        let recuo = l.recuo
        let ns = l.conteudo as NSString
        let indent = ns.substring(to: recuo)
        var resto = ns.substring(from: recuo)
        switch estilo {
        case let .linha(marca):
            var tira = marca.utf16.count
            resto = String(resto.dropFirst(marca.count))
            if resto.hasPrefix(" ") {
                resto.removeFirst()
                tira += 1
            }
            return (indent + resto, [.remocao(onde: l.inicio + recuo, tamanho: tira)])
        case let .bloco(abre, fecha):
            var tiraInicio = abre.utf16.count
            resto = String(resto.dropFirst(abre.count))
            if resto.hasPrefix(" ") {
                resto.removeFirst()
                tiraInicio += 1
            }
            // O fecho é o último pedaço visível; o que houver de espaço depois dele fica.
            let semFim = String(String(resto.reversed().drop { $0 == " " || $0 == "\t" }).reversed())
            let cauda = String(resto.dropFirst(semFim.count))
            var miolo = String(semFim.dropLast(fecha.count))
            var tiraFim = fecha.utf16.count
            if miolo.hasSuffix(" ") {
                miolo.removeLast()
                tiraFim += 1
            }
            let ondeFim = l.inicio + recuo + tiraInicio + (miolo as NSString).length
            return (
                indent + miolo + cauda,
                [.remocao(onde: l.inicio + recuo, tamanho: tiraInicio), .remocao(onde: ondeFim, tamanho: tiraFim)]
            )
        }
    }

    // MARK: - Duplicar e apagar

    /// Copia as linhas da seleção logo abaixo delas, e a seleção vai para a cópia — é o
    /// que permite apertar de novo e seguir descendo.
    static func duplicar(_ ns: NSString, selecao: NSRange) -> EdicaoDeTexto {
        let faixa = bloco(ns, selecao: selecao)
        let trecho = ns.substring(with: faixa)
        // Olhando a unidade UTF-16, e não o `Character`: "\r\n" é um caractere só em Swift
        // e `hasSuffix("\n")` diria que não termina em quebra.
        let inserir = terminaSemQuebra(ns, faixa) ? "\n" + trecho : trecho
        let desloca = (inserir as NSString).length
        return EdicaoDeTexto(
            faixa: NSRange(location: NSMaxRange(faixa), length: 0),
            texto: inserir,
            selecao: NSRange(location: selecao.location + desloca, length: selecao.length)
        )
    }

    /// Apaga as linhas da seleção. O cursor fica na mesma coluna da linha que sobe para
    /// o lugar delas (ou da anterior, quando eram as últimas do arquivo).
    static func apagar(_ ns: NSString, selecao: NSRange) -> EdicaoDeTexto? {
        guard ns.length > 0 else { return nil }
        let faixa = bloco(ns, selecao: selecao)
        let inicioDaLinha = ns.lineRange(for: NSRange(location: min(selecao.location, ns.length), length: 0)).location
        let coluna = selecao.location - inicioDaLinha
        let fim = NSMaxRange(faixa)
        if fim < ns.length || (fim == ns.length && faixa.location == 0) || !terminaSemQuebra(ns, faixa) {
            // Há linha depois: ela sobe para o lugar do bloco.
            let proxima = fim < ns.length ? tamanhoDoConteudo(ns, em: fim) : 0
            return EdicaoDeTexto(
                faixa: faixa,
                texto: "",
                selecao: NSRange(location: faixa.location + min(coluna, proxima), length: 0)
            )
        }
        // Eram as últimas linhas, sem quebra no fim: sai também a quebra da linha de
        // cima, senão sobraria uma linha vazia no fim do arquivo.
        let apagar = NSRange(location: faixa.location - 1, length: faixa.length + 1)
        let anterior = ns.lineRange(for: NSRange(location: faixa.location - 1, length: 0))
        let tamanhoAnterior = tamanhoDoConteudo(ns, em: anterior.location)
        return EdicaoDeTexto(
            faixa: apagar,
            texto: "",
            selecao: NSRange(location: anterior.location + min(coluna, tamanhoAnterior), length: 0)
        )
    }

    private static func terminaSemQuebra(_ ns: NSString, _ faixa: NSRange) -> Bool {
        guard faixa.length > 0 else { return true }
        let ultimo = ns.character(at: NSMaxRange(faixa) - 1)
        return ultimo != 10 && ultimo != 13
    }

    /// Tamanho da linha que começa em `inicio`, sem a quebra.
    private static func tamanhoDoConteudo(_ ns: NSString, em inicio: Int) -> Int {
        var a = 0, fim = 0, conteudo = 0
        ns.getLineStart(&a, end: &fim, contentsEnd: &conteudo, for: NSRange(location: inicio, length: 0))
        return conteudo - inicio
    }
}

/// Destino do "ir para a linha": `12` ou `12:5` (linha e coluna, contadas a partir de 1).
public struct AlvoDeLinha: Equatable, Sendable {
    public var linha: Int
    public var coluna: Int?

    public init(linha: Int, coluna: Int? = nil) {
        self.linha = linha
        self.coluna = coluna
    }

    /// Lê o que a pessoa digitou. Aceita `:` ou `,` entre linha e coluna, com espaços em
    /// volta, e um `:` na frente (o prefixo da paleta). Número negativo ou texto é nulo.
    public init?(_ texto: String) {
        var t = texto.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix(":") {
            t.removeFirst()
        }
        let partes = t.split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let primeira = partes.first, let l = Int(primeira), l >= 0, partes.count <= 2 else { return nil }
        var c: Int?
        if partes.count == 2 {
            // "12:" ainda está sendo digitado: vale como só a linha.
            if !partes[1].isEmpty {
                guard let n = Int(partes[1]), n >= 0 else { return nil }
                c = n
            }
        }
        linha = l
        coluna = c
    }

    /// A linha presa ao que o arquivo tem: zero vira a primeira, além do fim vira a última.
    public func linhaPresa(total: Int) -> Int {
        min(max(linha, 1), max(total, 1))
    }

    /// Posição, em UTF-16, onde o cursor deve ficar. Linha e coluna fora do arquivo são
    /// presas ao que existe, em vez de o comando não fazer nada.
    func deslocamento(em mapa: MapaDeLinhas) -> Int {
        let n = linhaPresa(total: mapa.quantidade)
        let inicio = mapa.starts[n - 1]
        var fim = n < mapa.quantidade ? mapa.starts[n] : mapa.ns.length
        // Sem a quebra do fim: a última coluna é logo depois do último caractere.
        while fim > inicio, [10, 13].contains(mapa.ns.character(at: fim - 1)) {
            fim -= 1
        }
        let col = min(max(coluna ?? 1, 1), fim - inicio + 1)
        return inicio + col - 1
    }
}
