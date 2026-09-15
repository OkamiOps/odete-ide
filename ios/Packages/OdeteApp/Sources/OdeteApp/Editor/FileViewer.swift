import OdeteFiles
import OdeteI18n
import OdeteUI
import PDFKit
import SwiftUI
import UIKit

/// O que aparece no lugar do editor quando o arquivo não é texto.
///
/// Antes um PNG abria como texto: a decodificação trocava cada byte inválido por `\u{FFFD}`
/// em vez de recusar, e bastava uma tecla para o salvamento gravar os losangos por cima —
/// medido, 800 bytes de imagem viraram 1456 de lixo. Recusar resolveu o estrago, mas
/// deixava a pessoa sem ver o arquivo. Aqui cada formato é mostrado do jeito dele.
struct FileViewer: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var path: String

    var body: some View {
        Group {
            switch tipo {
            case .imagem: ImagemView(url: url, medida: medida)
            case .pdf: PDFVista(url: url)
            case .banco: DBView(url: url, nome: nome)
            case .outro: HexView(url: url, nome: nome, medida: medida)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.bg)
    }

    enum Tipo { case imagem, pdf, banco, outro }

    /// Pela extensão, que é barato e acerta na prática; o `DBView` confirma o banco ao abrir.
    var tipo: Tipo {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tiff", "ico": .imagem
        case "pdf": .pdf
        case "sqlite", "sqlite3", "db": .banco
        default: .outro
        }
    }

    var url: URL {
        (try? ws.ops.url(path)) ?? URL(filePath: "/dev/null")
    }

    var nome: String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    var medida: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes ?? 0), countStyle: .file)
    }
}

// MARK: imagem

struct ImagemView: View {
    @Environment(\.theme) private var theme
    var url: URL
    var medida: String
    @State private var zoom: CGFloat = 1

    var body: some View {
        VStack(spacing: 12) {
            if let img = UIImage(contentsOfFile: url.path) {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .frame(width: img.size.width * zoom, height: img.size.height * zoom)
                        .background(Xadrez())
                        .overlay(Rectangle().stroke(theme.border, lineWidth: 1))
                        .padding(24)
                }
                HStack(spacing: 12) {
                    Text("\(Int(img.size.width)) × \(Int(img.size.height)) · \(medida)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Slider(value: $zoom, in: 0.25 ... 4).frame(width: 180)
                    Button("100%") { zoom = 1 }.font(.caption).buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.bottom, 12)
            } else {
                EmptyState(
                    "photo",
                    title: tr("Não deu para abrir"),
                    text: tr("O arquivo tem extensão de imagem mas não decodifica.")
                )
            }
        }
    }
}

/// Fundo quadriculado, para enxergar transparência em PNG.
struct Xadrez: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Canvas { ctx, size in
            let n = 10.0
            for y in stride(from: 0.0, to: size.height, by: n) {
                for x in stride(from: 0.0, to: size.width, by: n) {
                    let par = (Int(x / n) + Int(y / n)).isMultiple(of: 2)
                    ctx.fill(
                        Path(CGRect(x: x, y: y, width: n, height: n)),
                        with: .color(par ? theme.bgSubtle : theme.bg)
                    )
                }
            }
        }
    }
}

// MARK: pdf

struct PDFVista: UIViewRepresentable {
    var url: URL

    func makeUIView(context _: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displayDirection = .vertical
        v.backgroundColor = .clear
        v.document = PDFDocument(url: url)
        return v
    }

    func updateUIView(_ v: PDFView, context _: Context) {
        if v.document?.documentURL != url {
            v.document = PDFDocument(url: url)
        }
    }
}

// MARK: hexadecimal

/// Último recurso: os bytes em hexadecimal com o texto ao lado, como em qualquer editor
/// hex. Melhor do que "não dá para abrir" e sem risco nenhum de escrever de volta.
struct HexView: View {
    @Environment(\.theme) private var theme
    var url: URL
    var nome: String
    var medida: String
    /// Um pedaço só: nenhum arquivo precisa ser inteiramente lido para se ter uma ideia.
    static let teto = 64 * 1024

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape").foregroundStyle(theme.fgSubtle)
                Text(nome).font(.subheadline.weight(.medium)).foregroundStyle(theme.fg)
                Text(tr("binário · %1$@", "\(medida)")).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if dados.count >= Self.teto {
                    Text(tr("primeiros 64 KB")).font(.caption2).foregroundStyle(theme.fgSubtle)
                }
            }
            .padding(.horizontal, 14).frame(height: 40)
            .background(theme.surface)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            ScrollPane {
                Text(hex).font(OdeteFont.mono(11)).foregroundStyle(theme.fg)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        }
    }

    var dados: Data {
        (try? FileHandle(forReadingFrom: url).read(upToCount: Self.teto)) as? Data ?? Data()
    }

    var hex: String {
        var out = ""
        let bytes = [UInt8](dados)
        for inicio in stride(from: 0, to: bytes.count, by: 16) {
            let fim = min(inicio + 16, bytes.count)
            let fatia = bytes[inicio ..< fim]
            let col = fatia.map { String(format: "%02x", $0) }.joined(separator: " ")
            let texto = fatia.map { $0 >= 32 && $0 < 127 ? String(UnicodeScalar($0)) : "." }.joined()
            out += String(format: "%08x  %-47s  %@\n", inicio, (col as NSString).utf8String!, texto)
        }
        return out
    }
}
