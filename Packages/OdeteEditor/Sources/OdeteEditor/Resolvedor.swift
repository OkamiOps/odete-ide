import Foundation
import OdeteCore
import OdeteI18n
import TreeSitter

/// Nome usado que não existe — em qualquer linguagem cujo perfil esteja escrito.
///
/// Um motor só, e por linguagem apenas **dados**: quais nós da árvore ligam um nome,
/// quais posições não são referência, o que a linguagem já traz de embutido, e até onde
/// um nome declarado é visível. Escrever a próxima linguagem é preencher um `Perfil`,
/// não escrever outro resolvedor.
///
/// O que decide se isto serve não é quantos erros acha, é quantos inventa. Toda escolha
/// aqui é pelo lado de calar: se a linguagem tem um jeito de trazer nomes que a Odete
/// não consegue enxergar (`import *`, wildcard de Java), a checagem se desliga para
/// aquele arquivo inteiro.
public enum Resolvedor {
    public static let teto = 30

    /// Até onde um nome declarado no projeto é visível de outro arquivo.
    public enum Alcance: Sendable {
        /// Só o próprio arquivo. Python: o módulo é a unidade.
        case arquivo
        /// Os arquivos da mesma pasta. Go: pacote é diretório.
        case pasta
        /// O projeto inteiro. Java, onde a classe é achada pelo nome com import.
        case projeto
    }

    /// Como um nó da árvore liga nomes.
    public enum Ligacao: Sendable {
        /// Um campo do nó, pelo nome do campo.
        case campo(String)
        /// Todo identificador abaixo do nó, sem entrar em acesso a membro.
        case tudoAbaixo
        /// Os identificadores dos filhos diretos.
        case filhosDiretos
    }

    public struct Perfil: Sendable {
        /// Nó → o que dele liga nome.
        public var ligacoes: [String: Ligacao]
        /// Nó cuja leitura de referência é parcial: só o campo citado é nome daqui.
        /// `a.b` em quase toda linguagem: `a` é nome, `b` é membro de `a`.
        public var referenciaParcial: [String: String]
        /// O contrário: tudo no nó é referência **menos** o campo citado. `obj.faz(x)` em
        /// Java — `faz` é membro de `obj`, mas `x` é um nome daqui como qualquer outro.
        /// Ler estes como `referenciaParcial` faria o resolvedor nunca olhar dentro de uma
        /// chamada de método, que é onde mora metade do código.
        public var semOCampo: [String: String]
        /// Nós que não contêm referência nenhuma — linha de import, rótulo, declaração
        /// de campo de struct.
        public var semReferencias: Set<String>
        /// Nós que não contêm referência **quando** têm o campo citado. `export { a }` fala
        /// de um nome daqui; `export { a } from './b'` fala de um nome que nem passa por
        /// este arquivo.
        public var semReferenciasComCampo: [String: String]
        /// Nós cujo campo `name` conta como uso e nunca como acusação. `<div>` em TSX é um
        /// identificador na árvore igual a `<Botao>`: acusar `div` seria ridículo, e ignorar
        /// o nome faria um componente importado só para o JSX virar "import sem uso".
        public var nomeSoUsa: Set<String>
        /// Fichas que contam como uso e nada mais — `{ foo }` abreviado de `{ foo: foo }`.
        public var tokensSoUsam: Set<String>
        /// Nós de import, lidos à parte.
        public var imports: Set<String>
        /// Vendo este nó, desiste do arquivo: entraram nomes que não dá para enxergar.
        public var desligam: Set<String>
        /// Nomes que a linguagem já traz.
        public var embutidos: Set<String>
        /// Nós cujo nome vira declaração visível fora do arquivo.
        public var declaracoesDoTopo: Set<String>
        public var alcance: Alcance

        public init(
            ligacoes: [String: Ligacao],
            referenciaParcial: [String: String] = [:],
            semOCampo: [String: String] = [:],
            semReferencias: Set<String> = [],
            semReferenciasComCampo: [String: String] = [:],
            nomeSoUsa: Set<String> = [],
            tokensSoUsam: Set<String> = [],
            imports: Set<String> = [],
            desligam: Set<String> = [],
            embutidos: Set<String>,
            declaracoesDoTopo: Set<String> = [],
            alcance: Alcance
        ) {
            self.ligacoes = ligacoes
            self.referenciaParcial = referenciaParcial
            self.semOCampo = semOCampo
            self.semReferencias = semReferencias
            self.semReferenciasComCampo = semReferenciasComCampo
            self.nomeSoUsa = nomeSoUsa
            self.tokensSoUsam = tokensSoUsam
            self.imports = imports
            self.desligam = desligam
            self.embutidos = embutidos
            self.declaracoesDoTopo = declaracoesDoTopo
            self.alcance = alcance
        }
    }

    public nonisolated static func perfil(_ language: Language) -> Perfil? {
        switch language {
        case .python: Perfis.python
        case .go: Perfis.go
        case .java: Perfis.java
        case .typescript, .tsx: Perfis.typescript
        case .javascript, .jsx: Perfis.javascript
        // As outras não entram porque a conta não fecharia: em C e C++ o `#include`
        // traz nomes de cabeçalhos que a Odete não lê, e em Rust boa parte vem de crates
        // externas. Acusar ali seria inventar a cada linha.
        default: nil
        }
    }

    public nonisolated static func temResolvedor(_ language: Language) -> Bool {
        perfil(language) != nil
    }

    /// Se ler o projeto inteiro muda alguma resposta nesta linguagem.
    ///
    /// Em Python e em TypeScript não muda: o que vem de outro arquivo vem por `import`, e o
    /// `import` já liga o nome. Ler seiscentos arquivos para não usar nada seria só um
    /// engasgo a cada arquivo aberto.
    public nonisolated static func usaIndice(_ language: Language) -> Bool {
        !(perfil(language)?.declaracoesDoTopo.isEmpty ?? true)
    }

    // MARK: - índice do projeto

    /// O que cada arquivo declara para fora.
    ///
    /// Sem isto, `NovaTela` declarada em `tela.go` seria "não declarada" em `main.go` —
    /// e um resolvedor que acusa arquivo vizinho é pior que resolvedor nenhum.
    public struct Indice: Sendable {
        /// Nome → pastas onde ele foi declarado. A pasta é o que Go chama de pacote.
        var porNome: [String: Set<String>] = [:]

        public init() {}

        public init(arquivos: [(caminho: String, texto: String)]) {
            absorve(arquivos)
        }

        /// O mesmo índice mais o que estes arquivos declaram.
        ///
        /// Existe porque o que está aberto no editor ainda não está no disco: quem acabou
        /// de escrever `func NovaTela()` no arquivo ao lado não pode ver o nome acusado
        /// no arquivo atual só porque ainda não salvou.
        public func somando(arquivos: [(caminho: String, texto: String)]) -> Indice {
            var copia = self
            copia.absorve(arquivos)
            return copia
        }

        mutating func absorve(_ arquivos: [(caminho: String, texto: String)]) {
            for (caminho, texto) in arquivos {
                let lang = Language.detect(path: caminho)
                guard let p = perfil(lang), !p.declaracoesDoTopo.isEmpty else { continue }
                let pasta = (caminho as NSString).deletingLastPathComponent
                for nome in declaracoes(texto: texto, language: lang, perfil: p) {
                    porNome[nome, default: []].insert(pasta)
                }
            }
        }

        func conhece(_ nome: String, pasta: String, alcance: Alcance) -> Bool {
            guard let pastas = porNome[nome] else { return false }
            switch alcance {
            case .arquivo: return false
            case .pasta: return pastas.contains(pasta)
            case .projeto: return true
            }
        }
    }

    /// Os nomes que este arquivo declara para fora.
    public nonisolated static func declaracoes(text: String, language: Language) -> [String] {
        guard let p = perfil(language) else { return [] }
        return declaracoes(texto: text, language: language, perfil: p)
    }

    private nonisolated static func declaracoes(texto: String, language: Language, perfil p: Perfil) -> [String] {
        comArvore(texto, language) { raiz, bytes in
            var out: [String] = []
            percorre(raiz) { node in
                guard p.declaracoesDoTopo.contains(Arvore.tipo(node)),
                      let nome = Arvore.campo(node, "name")
                else { return true }
                out.append(Arvore.texto(nome, bytes))
                return true
            }
            return out
        } ?? []
    }

    // MARK: - a checagem

    public nonisolated static func problemas(
        text: String,
        language: Language,
        path: String = "",
        indice: Indice = Indice()
    ) -> [LintIssue] {
        guard let p = perfil(language) else { return [] }
        let pasta = (path as NSString).deletingLastPathComponent
        return comArvore(text, language) { raiz, bytes in
            // Com erro de sintaxe a árvore é um chute: os nomes saem trocados e o recado
            // viraria ruído em cima de um erro que a pessoa já está vendo.
            guard !ts_node_has_error(raiz) else { return [] }
            var estado = Estado(bytes: bytes, perfil: p)
            liga(raiz, &estado)
            guard !estado.desligou else { return [] }
            usa(raiz, &estado)

            var out = estado.achados.filter { issue in
                !indice.conhece(issue.nome, pasta: pasta, alcance: p.alcance)
            }.map(\.issue)
            for i in estado.importados where !estado.usados.contains(i.nome) {
                out.append(LintIssue(
                    rule: "import-sem-uso",
                    message: tr("`%1$@` é importado e não é usado", i.nome),
                    severity: .warning,
                    line: i.linha,
                    column: i.coluna,
                    length: i.nome.count
                ))
            }
            return Array(out.sorted { ($0.line, $0.column) < ($1.line, $1.column) }.prefix(teto))
        } ?? []
    }

    struct Achado {
        var nome: String
        var issue: LintIssue
    }

    struct Importado {
        var nome: String
        var linha: Int
        var coluna: Int
    }

    struct Estado {
        var bytes: [UInt8]
        var perfil: Perfil
        var ligados = Set<String>()
        var posicoes = Set<UInt32>()
        var importados: [Importado] = []
        var usados = Set<String>()
        var achados: [Achado] = []
        var desligou = false
    }

    // MARK: - passagem 1: o que liga nome

    private nonisolated static func liga(_ node: TSNode, _ e: inout Estado) {
        let t = Arvore.tipo(node)
        if e.perfil.desligam.contains(t) {
            e.desligou = true
            return
        }
        if e.perfil.imports.contains(t) {
            ligaImport(node, &e)
            return
        }
        if let regra = e.perfil.ligacoes[t] {
            aplica(regra, node, &e)
        }
        for i in 0 ..< ts_node_child_count(node) {
            liga(ts_node_child(node, i), &e)
            if e.desligou { return }
        }
    }

    private nonisolated static func aplica(_ regra: Ligacao, _ node: TSNode, _ e: inout Estado) {
        switch regra {
        case let .campo(nome):
            if let alvo = Arvore.campo(node, nome) {
                marca(alvo, &e)
            } else if nome == "name", ts_node_child_count(node) > 0 {
                // Alguns nós não dão o campo `name` (parâmetro com `*`): o identificador
                // está lá dentro de qualquer jeito.
                marca(node, &e)
            }
        case .tudoAbaixo:
            marca(node, &e)
        case .filhosDiretos:
            for i in 0 ..< ts_node_child_count(node) {
                marca(ts_node_child(node, i), &e)
            }
        }
    }

    /// Todo identificador abaixo, sem entrar em acesso a membro: `obj.attr = 1` e
    /// `xs[0] = 1` não ligam nome novo.
    private nonisolated static func marca(_ node: TSNode, _ e: inout Estado) {
        let t = Arvore.tipo(node)
        if t == "identifier" || t == "field_identifier" || t == "type_identifier"
            || t == "shorthand_property_identifier_pattern" || t == "property_identifier" {
            e.ligados.insert(Arvore.texto(node, e.bytes))
            e.posicoes.insert(ts_node_start_byte(node))
            return
        }
        if e.perfil.referenciaParcial[t] != nil || t == "subscript" || t == "index_expression" {
            return
        }
        for i in 0 ..< ts_node_child_count(node) {
            marca(ts_node_child(node, i), &e)
        }
    }

    /// A linha de import liga o que ela traz e não usa nada: `from pathlib import Path`
    /// fala de um pacote lá fora, não de um nome deste arquivo.
    private nonisolated static func ligaImport(_ node: TSNode, _ e: inout Estado) {
        let deOnde = Arvore.campo(node, "module_name")
        var candidatos: [TSNode] = []
        percorre(node) { filho in
            let t = Arvore.tipo(filho)
            if e.perfil.desligam.contains(t) {
                e.desligou = true
                return false
            }
            if let deOnde, ts_node_eq(filho, deOnde) { return false }
            switch t {
            case "aliased_import", "package_identifier":
                if let alias = Arvore.campo(filho, "alias") ?? Arvore.campo(filho, "name") {
                    candidatos.append(alias)
                } else {
                    candidatos.append(filho)
                }
                return false
            case "dotted_name":
                // `import a.b` liga `a`; `import a.b.C` em Java liga `C`.
                let i = e.perfil.alcance == .arquivo ? 0 : ts_node_named_child_count(filho) - 1
                if ts_node_named_child_count(filho) > 0 {
                    candidatos.append(ts_node_named_child(filho, UInt32(max(0, i))))
                }
                return false
            case "identifier", "type_identifier":
                candidatos.append(filho)
                return false
            case "interpreted_string_literal", "raw_string_literal":
                // Go: `import "net/http"` liga `http`, o último pedaço do caminho.
                let aspas = CharacterSet(charactersIn: #""`"#)
                let cru = Arvore.texto(filho, e.bytes).trimmingCharacters(in: aspas)
                let nome = cru.split(separator: "/").last.map(String.init) ?? cru
                guard !nome.isEmpty else { return false }
                e.ligados.insert(nome)
                let p = ts_node_start_point(filho)
                e.importados.append(Importado(nome: nome, linha: Int(p.row) + 1, coluna: Int(p.column) + 1))
                return false
            default:
                return true
            }
        }
        for c in candidatos {
            let nome = Arvore.texto(c, e.bytes)
            guard !nome.isEmpty else { continue }
            e.ligados.insert(nome)
            e.posicoes.insert(ts_node_start_byte(c))
            let p = ts_node_start_point(c)
            e.importados.append(Importado(nome: nome, linha: Int(p.row) + 1, coluna: Int(p.column) + 1))
        }
    }

    // MARK: - passagem 2: o que usa nome

    private nonisolated static func usa(_ node: TSNode, _ e: inout Estado) {
        let t = Arvore.tipo(node)
        if e.perfil.imports.contains(t) || e.perfil.semReferencias.contains(t) { return }
        if let campo = e.perfil.semReferenciasComCampo[t], Arvore.campo(node, campo) != nil { return }
        if e.perfil.tokensSoUsam.contains(t) {
            e.usados.insert(Arvore.texto(node, e.bytes))
            return
        }
        if e.perfil.nomeSoUsa.contains(t) {
            let nome = Arvore.campo(node, "name")
            if let nome { registraUso(nome, &e) }
            for i in 0 ..< ts_node_child_count(node) {
                let filho = ts_node_child(node, i)
                if let nome, ts_node_eq(filho, nome) { continue }
                usa(filho, &e)
            }
            return
        }
        if let campo = e.perfil.referenciaParcial[t] {
            if let alvo = Arvore.campo(node, campo) { usa(alvo, &e) }
            return
        }
        if let campo = e.perfil.semOCampo[t] {
            let pular = Arvore.campo(node, campo)
            for i in 0 ..< ts_node_child_count(node) {
                let filho = ts_node_child(node, i)
                if let pular, ts_node_eq(filho, pular) { continue }
                usa(filho, &e)
            }
            return
        }
        if t == "identifier" || t == "type_identifier" {
            let nome = Arvore.texto(node, e.bytes)
            e.usados.insert(nome)
            guard !e.posicoes.contains(ts_node_start_byte(node)),
                  !e.ligados.contains(nome),
                  !e.perfil.embutidos.contains(nome)
            else { return }
            let p = ts_node_start_point(node)
            e.achados.append(Achado(nome: nome, issue: LintIssue(
                rule: "nome-nao-declarado",
                message: tr("`%1$@` não foi declarado", nome),
                severity: .error,
                line: Int(p.row) + 1,
                column: Int(p.column) + 1,
                length: nome.count
            )))
            return
        }
        for i in 0 ..< ts_node_child_count(node) {
            usa(ts_node_child(node, i), &e)
        }
    }

    /// Conta como uso todo identificador abaixo, sem acusar nenhum.
    private nonisolated static func registraUso(_ node: TSNode, _ e: inout Estado) {
        let t = Arvore.tipo(node)
        if t == "identifier" || t == "type_identifier" || t == "property_identifier" {
            e.usados.insert(Arvore.texto(node, e.bytes))
            return
        }
        for i in 0 ..< ts_node_child_count(node) {
            registraUso(ts_node_child(node, i), &e)
        }
    }

    // MARK: - árvore

    private nonisolated static func comArvore<T>(
        _ texto: String,
        _ language: Language,
        _ corpo: (TSNode, [UInt8]) -> T
    ) -> T? {
        guard let lang = ParserErros.gramatica(language), let parser = ts_parser_new() else { return nil }
        defer { ts_parser_delete(parser) }
        guard ts_parser_set_language(parser, lang) else { return nil }
        let bytes = Array(texto.utf8)
        guard !bytes.isEmpty else { return nil }
        let arvore = bytes.withUnsafeBufferPointer { buf in
            buf.baseAddress.flatMap { base in
                base.withMemoryRebound(to: CChar.self, capacity: buf.count) { c in
                    ts_parser_parse_string(parser, nil, c, UInt32(buf.count))
                }
            }
        }
        guard let arvore else { return nil }
        defer { ts_tree_delete(arvore) }
        return corpo(ts_tree_root_node(arvore), bytes)
    }

    /// Visita a árvore; devolver `false` no bloco corta a descida naquele ramo.
    private nonisolated static func percorre(_ node: TSNode, _ visita: (TSNode) -> Bool) {
        guard visita(node) else { return }
        for i in 0 ..< ts_node_child_count(node) {
            percorre(ts_node_child(node, i), visita)
        }
    }
}

/// Acesso enxuto à árvore, para o resolvedor não repetir ponteiro em toda linha.
enum Arvore {
    static func tipo(_ node: TSNode) -> String {
        ts_node_type(node).map { String(cString: $0) } ?? ""
    }

    static func texto(_ node: TSNode, _ bytes: [UInt8]) -> String {
        let ini = Int(ts_node_start_byte(node)), fim = Int(ts_node_end_byte(node))
        guard ini < fim, fim <= bytes.count else { return "" }
        return String(decoding: bytes[ini ..< fim], as: UTF8.self)
    }

    static func campo(_ node: TSNode, _ nome: String) -> TSNode? {
        let filho = nome.withCString { ts_node_child_by_field_name(node, $0, UInt32(nome.utf8.count)) }
        return ts_node_is_null(filho) ? nil : filho
    }
}
