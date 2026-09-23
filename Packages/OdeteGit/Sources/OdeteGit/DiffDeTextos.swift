import Clibgit2
import Foundation

public extension FileDiff {
    /// Diff de dois conteúdos soltos, sem repositório — o histórico local compara uma
    /// versão guardada com o arquivo de agora. É o mesmo motor, e o mesmo formato, dos
    /// outros diffs do app: a lista de linhas do modo Diff desenha este sem saber de onde
    /// ele veio. Conteúdos iguais dão um diff sem hunks; binário vem marcado como tal.
    static func entre(_ antes: Data, _ depois: Data, caminho: String, contexto: Int = 3) -> FileDiff {
        Libgit2.start()
        var opts = git_diff_options()
        git_diff_options_init(&opts, UInt32(GIT_DIFF_OPTIONS_VERSION))
        opts.context_lines = UInt32(contexto)
        let coletor = DiffCollector()
        let payload = Unmanaged.passUnretained(coletor).toOpaque()
        antes.withUnsafeBytes { a in
            depois.withUnsafeBytes { d in
                _ = git_diff_buffers(
                    a.baseAddress, a.count, caminho,
                    d.baseAddress, d.count, caminho,
                    &opts, arquivoDeTexto, nil, trechoDeTexto, linhaDeTexto, payload
                )
            }
        }
        return coletor.files.first
            ?? FileDiff(path: caminho, oldPath: nil, change: .modified, isBinary: false, hunks: [])
    }
}

// Os mesmos três retornos de `Diff.swift`, que lá são privados do arquivo.

private let arquivoDeTexto: git_diff_file_cb = { delta, _, payload in
    guard let delta, let payload else { return 0 }
    Unmanaged<DiffCollector>.fromOpaque(payload).takeUnretainedValue().file(delta.pointee)
    return 0
}

private let trechoDeTexto: git_diff_hunk_cb = { _, hunk, payload in
    guard let hunk, let payload else { return 0 }
    Unmanaged<DiffCollector>.fromOpaque(payload).takeUnretainedValue().hunk(hunk.pointee)
    return 0
}

private let linhaDeTexto: git_diff_line_cb = { _, _, line, payload in
    guard let line, let payload else { return 0 }
    Unmanaged<DiffCollector>.fromOpaque(payload).takeUnretainedValue().line(line.pointee)
    return 0
}
