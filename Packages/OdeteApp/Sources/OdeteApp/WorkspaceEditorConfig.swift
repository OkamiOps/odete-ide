import Foundation
import OdeteEditor

/// Os `.editorconfig` do projeto já lidos, e a configuração que deu para cada arquivo.
struct CacheDeEditorConfig {
    /// Pasta (relativa à raiz) → conteúdo do `.editorconfig` dela, ou `nil` se não tem.
    var textos: [String: String?] = [:]
    var porArquivo: [String: ConfigDoArquivo] = [:]
}

/// O `.editorconfig` do projeto: recuo, quebra de linha, espaço no fim e quebra no fim
/// de cada arquivo.
extension WorkspaceModel {
    /// A configuração do `.editorconfig` para um arquivo — vazia se o projeto não tem um.
    ///
    /// O centro pergunta isto a cada redesenho do editor, então fica guardado; o que foi
    /// lido esquece quando a árvore é relida ou um `.editorconfig` é gravado.
    func configDoArquivo(_ path: String) -> ConfigDoArquivo {
        if let c = cacheDeEditorConfig.porArquivo[path] {
            return c
        }
        var partes = path.split(separator: "/").dropLast().map(String.init)
        var arquivos: [(pasta: String, texto: String)] = []
        while true {
            let pasta = partes.joined(separator: "/")
            if let texto = textoDoEditorConfig(pasta) {
                arquivos.append((pasta, texto))
            }
            if partes.isEmpty {
                break
            }
            partes.removeLast()
        }
        let c = arquivos.isEmpty ? ConfigDoArquivo() : EditorConfig.config(para: path, arquivos: arquivos)
        cacheDeEditorConfig.porArquivo[path] = c
        return c
    }

    private func textoDoEditorConfig(_ pasta: String) -> String? {
        if let guardado = cacheDeEditorConfig.textos[pasta] {
            return guardado
        }
        let caminho = pasta.isEmpty ? ".editorconfig" : "\(pasta)/.editorconfig"
        let texto = try? ops.read(caminho)
        cacheDeEditorConfig.textos[pasta] = .some(texto)
        return texto
    }

    func esquecerEditorConfig() {
        cacheDeEditorConfig = CacheDeEditorConfig()
    }
}
