import Foundation
import Observation
import OdeteBundler
import OdeteCore
import OdeteEditor
import OdeteGit

// MARK: análise por arquivo

/// Esboço, lint, sintaxe, elos, marcas do git e do patch, por arquivo aberto.
///
/// São reescritos a cada pausa na digitação, e quase sempre com o mesmo conteúdo — mexer
/// uma letra raramente muda o esboço ou os problemas. A escrita por índice
/// (`lint[caminho] = …`) não compara nada: o `@Observable` avisava a cada uma, e cada aviso
/// redesenhava o centro, a barra de status e o rail. Cada propriedade aqui guarda o valor
/// fora da observação (`guardado…`) e só avisa quando o novo é diferente.
public extension WorkspaceModel {
    /// Análise do editor por arquivo aberto: esboço, lint e marcas do git.
    var outlines: [String: [OutlineItem]] {
        get {
            access(keyPath: \.outlines)
            return guardadoOutlines
        }
        set { gravarSeMudou(\.outlines, \.guardadoOutlines, newValue) }
    }

    /// Caminhos de import que apontam para arquivos do projeto, por arquivo aberto.
    var links: [String: [EditorLink]] {
        get {
            access(keyPath: \.links)
            return guardadoLinks
        }
        set { gravarSeMudou(\.links, \.guardadoLinks, newValue) }
    }

    /// Linhas que o patch pendente do agente mexeu, por arquivo aberto.
    var patchChanges: [String: [EditorLineChange]] {
        get {
            access(keyPath: \.patchChanges)
            return guardadoPatchChanges
        }
        set { gravarSeMudou(\.patchChanges, \.guardadoPatchChanges, newValue) }
    }

    var lint: [String: [LintIssue]] {
        get {
            access(keyPath: \.lint)
            return guardadoLint
        }
        set { gravarSeMudou(\.lint, \.guardadoLint, newValue) }
    }

    var syntax: [String: [Diagnostic]] {
        get {
            access(keyPath: \.syntax)
            return guardadoSyntax
        }
        set { gravarSeMudou(\.syntax, \.guardadoSyntax, newValue) }
    }

    var gutter: [String: [GutterMark]] {
        get {
            access(keyPath: \.gutter)
            return guardadoGutter
        }
        set { gravarSeMudou(\.gutter, \.guardadoGutter, newValue) }
    }

    var gutterFiles: [String: FileDiff] {
        get {
            access(keyPath: \.gutterFiles)
            return guardadoGutterFiles
        }
        set { gravarSeMudou(\.gutterFiles, \.guardadoGutterFiles, newValue) }
    }

    /// Problemas de todas as fontes: build, Swift, lint do editor e erros do preview.
    /// A barra de status e a barra lateral leem daqui, para contarem a mesma coisa.
    var problemCounts: (errors: Int, warnings: Int) {
        (contagemDeProblemas.erros, contagemDeProblemas.avisos)
    }
}

extension WorkspaceModel {
    /// Troca o valor guardado e avisa quem observa — só quando o valor novo é diferente.
    ///
    /// Atribuir a propriedade inteira já compara (o `@Observable` faz isso para tipos
    /// `Equatable`); é a escrita por índice que não compara, e é ela que a análise usa.
    /// A comparação custa o tamanho do dicionário, que é o de poucos arquivos abertos.
    ///
    /// O guardado chega como caminho, não como `inout`, e só é escrito dentro do closure do
    /// `withMutation` — o mesmo que o `@Observable` faz. Um `inout` deixava o acesso de
    /// escrita aberto durante todo o `withMutation`; o `willSet` faz o SwiftUI refazer o
    /// corpo ali mesmo (a escrita acontece dentro de um ciclo de atualização), o corpo lê o
    /// getter, o getter lê o guardado, e a leitura batia no acesso aberto: "Fatal access
    /// conflict detected", também em Release. Era o crash de aprovar um patch com o editor
    /// aberto. Ver `EscritaDaAnaliseTests`.
    func gravarSeMudou<T: Equatable>(
        _ chave: KeyPath<WorkspaceModel, T>,
        _ guardado: ReferenceWritableKeyPath<WorkspaceModel, T>,
        _ novo: T
    ) {
        guard self[keyPath: guardado] != novo else { return }
        withMutation(keyPath: chave) { self[keyPath: guardado] = novo }
    }

    // MARK: problemas

    /// Refaz a contagem quando uma das fontes muda, e escreve só se o número mudou.
    ///
    /// A contagem era calculada no corpo das views: lia o console do preview (até mil
    /// linhas), o build, o Swift e o lint de cada aba, e a raiz do layout e a barra de
    /// status a faziam — a barra três vezes, uma por versão. Pior, lendo o console no
    /// corpo, cada `console.log` do app do usuário redesenhava a raiz do layout. Aqui a
    /// conta roda uma vez quando alguma fonte muda, e só avisa quem mostra o número quando
    /// ele muda. `withObservationTracking` avisa uma vez, na primeira mudança; a volta
    /// seguinte acontece numa `Task`, então uma rajada de linhas no console vira uma conta.
    func vigiarProblemas() {
        let nova = withObservationTracking {
            contarProblemas()
        } onChange: { [weak self] in
            Task { @MainActor in self?.vigiarProblemas() }
        }
        if nova != contagemDeProblemas {
            contagemDeProblemas = nova
        }
    }

    func contarProblemas() -> ContagemDeProblemas {
        var c = ContagemDeProblemas()
        for d in run.diagnostics {
            d.kind == .error ? (c.erros += 1) : (c.avisos += 1)
        }
        for d in swiftDiagnostics {
            d.kind == .error ? (c.erros += 1) : (c.avisos += 1)
        }
        for item in allLint {
            item.issue.severity == .error ? (c.erros += 1) : (c.avisos += 1)
        }
        // Do console, os erros da página de agora — os mesmos que o painel lista.
        c.erros += preview.errosDaPagina.count
        return c
    }

    // MARK: cursor

    /// Linha e coluna (base um) do cursor no arquivo.
    ///
    /// A barra de status contava isto varrendo o texto do começo até o cursor, três vezes
    /// por atualização (uma por versão da barra), e procurava `"\r\n"` no texto inteiro com
    /// a busca de Characters. Agora o mapa de linhas é feito uma vez por versão do texto,
    /// numa passada pelos bytes, e a posição sai dele por busca binária — mover o cursor
    /// sem digitar não relê nada.
    public func posicaoDoCursor(em path: String) -> PosicaoDoCursor {
        mapaDeLinhas(path).posicao(de: cursorOffset)
    }

    /// O arquivo usa CRLF? Sai do mesmo mapa da posição.
    public func usaCRLF(_ path: String) -> Bool {
        mapaDeLinhas(path).crlf
    }

    /// O problema da linha do cursor que a barra de status mostra: o primeiro erro, ou,
    /// sem erro, o primeiro aviso. Os mesmos que o editor sublinha.
    public func problemaNaLinhaDoCursor(em path: String) -> LintIssue? {
        let linha = posicaoDoCursor(em: path).linha
        let daLinha = issues(for: path).filter { $0.line == linha }
        return daLinha.first { $0.severity == .error } ?? daLinha.first { $0.severity == .warning }
    }

    private func mapaDeLinhas(_ path: String) -> LinhasDoTexto {
        let texto = text(for: path)
        // Texto igual ao guardado sai na hora: a `String` guardada e a do buffer dividem
        // o mesmo armazenamento, e a comparação para no primeiro teste.
        if let m = mapaDoCursor, m.caminho == path, m.texto == texto {
            return m.mapa
        }
        let mapa = LinhasDoTexto(texto)
        mapaDoCursor = (path, texto, mapa)
        return mapa
    }
}

/// Erros e avisos somados de todas as fontes.
public struct ContagemDeProblemas: Equatable, Sendable {
    public var erros = 0
    public var avisos = 0
    public init(erros: Int = 0, avisos: Int = 0) {
        self.erros = erros
        self.avisos = avisos
    }
}

/// Linha e coluna do cursor, base um. A coluna conta unidades UTF-16, como sempre contou.
public struct PosicaoDoCursor: Equatable, Sendable {
    public var linha: Int
    public var coluna: Int
}

/// Onde cada linha começa e se o texto usa CRLF, numa passada só pelos bytes.
///
/// É a conta da barra de status. Passar pelos bytes UTF-8 da `String` é o caminho rápido
/// dela; o deslocamento em UTF-16 (a medida do editor) sai contando os bytes que começam
/// um caractere, e os de quatro bytes valem dois.
struct LinhasDoTexto: Sendable {
    /// Deslocamento UTF-16 do começo de cada linha. A primeira começa em zero.
    let inicios: [Int]
    let crlf: Bool
    let tamanho: Int

    init(_ texto: String) {
        var inicios = [0]
        var crlf = false
        var u16 = 0
        var anteriorCR = false
        for b in texto.utf8 {
            if b & 0xC0 != 0x80 {
                u16 += b >= 0xF0 ? 2 : 1
            }
            if b == 10 {
                inicios.append(u16)
                if anteriorCR {
                    crlf = true
                }
            }
            anteriorCR = b == 13
        }
        self.inicios = inicios
        self.crlf = crlf
        tamanho = u16
    }

    /// Linha e coluna de um deslocamento UTF-16, com o deslocamento preso ao texto.
    func posicao(de offset: Int) -> PosicaoDoCursor {
        let o = min(max(offset, 0), tamanho)
        var baixo = 0
        var alto = inicios.count - 1
        while baixo < alto {
            let meio = (baixo + alto + 1) / 2
            if inicios[meio] <= o {
                baixo = meio
            } else {
                alto = meio - 1
            }
        }
        return PosicaoDoCursor(linha: baixo + 1, coluna: o - inicios[baixo] + 1)
    }
}
