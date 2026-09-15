import Foundation
import OdeteCore

/// Índice dos símbolos do projeto inteiro.
///
/// O esboço já existia, mas só do arquivo aberto: procurar onde um componente é
/// declarado era busca de texto, e a paleta só achava símbolo do que estava na tela.
extension WorkspaceModel {
    /// Arquivos grandes demais não entram: o índice é para navegar, e um bundle de 2 MB
    /// só faria a varredura demorar.
    nonisolated static let limiteDoArquivo = Limites.arquivoGrande
    /// Teto de arquivos varridos, para projeto grande não travar o iPad.
    nonisolated static let limiteDeArquivos = 600

    func indexarSimbolos() {
        indexTask?.cancel()
        let caminhos = filePaths
        let raiz = root
        indexTask = Task.detached(priority: .background) { [weak self] in
            let achados = Self.varrer(caminhos, root: raiz)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in self?.simbolos = achados }
        }
    }

    nonisolated static func varrer(_ caminhos: [String], root: URL) -> [ProjectSymbol] {
        var out: [ProjectSymbol] = []
        for caminho in caminhos.prefix(limiteDeArquivos) {
            if Task.isCancelled {
                return out
            }
            let lang = Language.detect(path: caminho)
            switch lang {
            case .javascript, .jsx, .typescript, .tsx, .swift, .css, .markdown: break
            default: continue
            }
            let url = root.appending(path: caminho)
            guard let atributos = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  (atributos.fileSize ?? 0) <= limiteDoArquivo,
                  let texto = try? String(contentsOf: url, encoding: .utf8) else { continue }
            // Só o primeiro nível: o que se procura por nome é o componente, a função
            // exportada, o seletor — não cada propriedade de cada objeto.
            for item in Outline.items(text: texto, language: lang) where item.level == 0 {
                out.append(ProjectSymbol(name: item.name, kind: item.kind, path: caminho, line: item.line))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Vai para onde o nome sob o cursor é declarado.
    ///
    /// Um lugar só: abre direto. Vários: abre a paleta já filtrada, que é melhor do que
    /// escolher por conta própria e cair no arquivo errado.
    func irParaDefinicao() {
        guard let path = active, let texto = buffers[path],
              let nome = ProjectSymbol.palavra(em: texto, offset: cursorOffset) else { return }
        let achados = ProjectSymbol.procurar(nome, em: simbolos)
        // Declarado no próprio arquivo tem precedência: é o caso mais comum e evita
        // pular para um homônimo de outro módulo.
        if let aqui = achados.first(where: { $0.path == path }), achados.count > 1 {
            open(aqui.path, line: aqui.line)
            return
        }
        // Um só: abre direto. Nenhum ou vários: a paleta já filtrada pelo nome, que
        // mostra o que existe em vez de um aviso sem saída.
        if achados.count == 1 {
            open(achados[0].path, line: achados[0].line)
        } else {
            paletteQuery = "#\(nome)"
            paletteOpen = true
        }
    }
}
