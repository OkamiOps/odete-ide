import CryptoKit
import Foundation

/// A saída do esbuild para cada módulo ES/TS, guardada em disco entre um `node` e outro.
///
/// Sem JIT, transformar 30 módulos pequenos custava de 2 a 2,9 s em todo `node main.js`,
/// mesmo sem mudar uma linha. A chave é o caminho, o `mtime` (em ns), o tamanho, o tipo de
/// transformação (a de sempre ou a do módulo de entrada) e a versão do transformador — que
/// quem injeta o transformador diz qual é (versão do esbuild e build do app). Arquivo
/// mudado muda o `mtime`; esbuild ou app novos mudam a versão; nada precisa ser apagado à mão.
enum CacheDeTransformacao {
    /// Onde guardar. Nil desliga o cache (o padrão nos testes que não pedem).
    nonisolated(unsafe) static var pasta: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        .first?.appending(path: "odete-transformacoes", directoryHint: .isDirectory)

    /// Muda quando o que se guarda aqui muda de formato.
    static let formato = "2"

    static func chave(caminho: String, tipo: String, versao: String) -> String? {
        var st = stat()
        guard stat(caminho, &st) == 0 else { return nil }
        let texto = [
            formato, versao, tipo, caminho, "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)", "\(st.st_size)",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(texto.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func obter(_ chave: String) -> String? {
        guard let pasta else { return nil }
        let u = pasta.appending(path: String(chave.prefix(2))).appending(path: chave + ".js")
        let (buf, n, _) = HostBytes.lerTudo(u.path)
        guard let buf else { return nil }
        defer { free(buf) }
        return String(decoding: UnsafeRawBufferPointer(start: buf, count: n), as: UTF8.self)
    }

    /// Grava por arquivo temporário + `rename`: dois processos ao mesmo tempo nunca leem
    /// metade de uma saída.
    static func guardar(_ chave: String, _ codigo: String) {
        guard let pasta else { return }
        let dir = pasta.appending(path: String(chave.prefix(2)))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let final = dir.appending(path: chave + ".js")
        let temp = dir.appending(path: chave + ".\(UUID().uuidString.prefix(8)).tmp")
        var texto = codigo
        let r = texto.withUTF8 { HostBytes.escreverTudo(temp.path, UnsafeRawBufferPointer($0), anexar: false) }
        if r != 0 || Darwin.rename(temp.path, final.path) != 0 {
            unlink(temp.path)
        }
    }

    /// Transforma usando o cache quando dá.
    static func transformar(
        _ fonte: String,
        caminho: String,
        tipo: String,
        versao: String?,
        _ t: (String, String) throws -> String
    ) throws -> String {
        guard let versao, let k = chave(caminho: caminho, tipo: tipo, versao: versao) else {
            return try t(fonte, caminho)
        }
        if let guardado = obter(k) {
            return guardado
        }
        let saida = try t(fonte, caminho)
        guardar(k, saida)
        return saida
    }
}
