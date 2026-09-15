import OdeteUI
import SwiftUI
import UIKit

/// O que aparece no lugar do editor quando o arquivo não é texto.
///
/// Antes um PNG abria como texto: o editor enchia de `\u{FFFD}`, porque a decodificação
/// trocava cada byte inválido por um losango em vez de recusar. Bastava uma tecla para o
/// salvamento gravar os losangos por cima — medido, 800 bytes de imagem viraram 1456 de
/// lixo, sem volta fora do git.
struct BinaryView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var path: String

    var body: some View {
        VStack(spacing: 14) {
            if let imagem {
                Image(uiImage: imagem)
                    .resizable().scaledToFit()
                    .frame(maxWidth: 420, maxHeight: 320)
                    .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(theme.border, lineWidth: 1)
                    )
                Text(dimensoes(imagem))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(theme.fgSubtle)
                Text(nome).font(.headline).foregroundStyle(theme.fg)
                Text("Não é texto em UTF-8 · \(medida)")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Abrir aqui estragaria o arquivo: o editor gravaria texto por cima dos bytes originais.")
                    .font(.caption).foregroundStyle(theme.fgSubtle)
                    .multilineTextAlignment(.center).frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    func dimensoes(_ img: UIImage) -> String {
        "\(Int(img.size.width)) × \(Int(img.size.height)) · \(medida)"
    }

    var nome: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var bytes: Int {
        (try? ws.ops.url(path)).flatMap {
            try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int
        } ?? 0
    }

    var medida: String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Imagem tem muito a ganhar em ser mostrada; o resto não.
    var imagem: UIImage? {
        guard let u = try? ws.ops.url(path), bytes < 20_000_000 else { return nil }
        return UIImage(contentsOfFile: u.path)
    }
}
