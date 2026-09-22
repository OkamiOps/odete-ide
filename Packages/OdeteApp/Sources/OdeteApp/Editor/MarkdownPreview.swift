import OdeteCore
import OdeteI18n
import OdeteUI
import SwiftUI
import UIKit

/// Prévia de um `.md` do projeto, desenhada nativamente.
///
/// Acompanha a digitação com uma espera de 300 ms, e a leitura e a conversão do inline
/// rodam fora do ator principal: um README grande não trava o editor ao lado no modo
/// Split. Link para outro arquivo do projeto abre na aba; imagem só é mostrada quando
/// está no projeto — buscar imagem da internet a cada tecla seria um pedido de rede que
/// ninguém fez.
struct MarkdownPreview: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var path: String
    @State private var blocos: [BlocoPronto] = []
    /// O arquivo que está desenhado. Arquivo novo desenha de imediato, sem a espera.
    @State private var desenhado: String?

    struct Pedido: Equatable {
        let path: String
        let texto: String
    }

    var body: some View {
        let texto = ws.text(for: path)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if blocos.isEmpty, desenhado == path {
                    Text(tr("Arquivo vazio")).font(OdeteFont.ui(13)).foregroundStyle(theme.fgSubtle)
                }
                ForEach(blocos) { bloco($0) }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(theme.bg)
        .environment(\.openURL, OpenURLAction { abrir($0) })
        .task(id: Pedido(path: path, texto: texto)) {
            if desenhado == path {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled {
                    return
                }
            }
            let prontos = await Task.detached(priority: .userInitiated) { BlocoPronto.montar(texto) }.value
            guard !Task.isCancelled else { return }
            blocos = prontos
            desenhado = path
        }
    }

    // MARK: blocos

    @ViewBuilder func bloco(_ b: BlocoPronto) -> some View {
        switch b.tipo {
        case let .titulo(nivel, t):
            VStack(alignment: .leading, spacing: 6) {
                Text(t)
                    .font(.system(size: tamanhoDoTitulo(nivel), weight: nivel <= 2 ? .bold : .semibold))
                    .foregroundStyle(theme.fg)
                    .fixedSize(horizontal: false, vertical: true)
                if nivel <= 2 {
                    Rectangle().fill(theme.separator).frame(height: 0.5)
                }
            }
            .padding(.top, nivel <= 2 ? 8 : 4)
            .accessibilityAddTraits(.isHeader)
        case let .paragrafo(t):
            Text(t)
                .font(.system(size: 15))
                .lineSpacing(3)
                .foregroundStyle(theme.fg)
                .fixedSize(horizontal: false, vertical: true)
        case let .lista(ordenada, inicio, itens):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(itens.enumerated()), id: \.offset) { n, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        marcador(item, ordenada: ordenada, numero: inicio + n)
                        Text(item.texto)
                            .font(.system(size: 15))
                            .lineSpacing(2)
                            .foregroundStyle(theme.fg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.nivel) * 18)
                }
            }
        case let .citacao(t):
            HStack(alignment: .top, spacing: 10) {
                Capsule().fill(theme.accent.opacity(0.5)).frame(width: 3)
                Text(t).font(.system(size: 15)).foregroundStyle(theme.fgMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .regua:
            Rectangle().fill(theme.separator).frame(height: 1)
        case let .codigo(linguagem, codigo):
            blocoDeCodigo(linguagem, codigo)
        case let .imagem(alt, fonte):
            ImagemDoMarkdown(alt: alt, url: urlLocal(fonte), fonte: fonte)
        case let .tabela(cabecalho, linhas):
            tabela(cabecalho, linhas)
        case let .html(t):
            Text(t).font(OdeteFont.mono(12)).foregroundStyle(theme.fgSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    func tamanhoDoTitulo(_ nivel: Int) -> CGFloat {
        switch nivel {
        case 1: 28
        case 2: 22
        case 3: 18
        case 4: 16
        default: 15
        }
    }

    @ViewBuilder func marcador(_ item: BlocoPronto.Item, ordenada: Bool, numero: Int) -> some View {
        if let marcado = item.marcado {
            Image(systemName: marcado ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(marcado ? theme.accent : theme.fgMuted)
                .accessibilityLabel(marcado ? tr("feito") : tr("a fazer"))
        } else {
            Text(ordenada ? "\(numero)." : (item.nivel == 0 ? "•" : "◦"))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.accent)
                .frame(minWidth: ordenada ? 22 : 10, alignment: .leading)
        }
    }

    func blocoDeCodigo(_ linguagem: String, _ codigo: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(linguagem.isEmpty ? tr("código") : linguagem).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(tr("Copiar"), systemImage: "doc.on.doc") { UIPasteboard.general.string = codigo }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .tint(theme.fgMuted)
            }
            .padding(.leading, 12).padding(.trailing, 6).frame(height: 30)
            Rectangle().fill(theme.separator).frame(height: 0.5)
            ScrollPane(.horizontal, showsIndicators: false) {
                Text(codigo).font(OdeteFont.mono(12.5)).foregroundStyle(theme.fg)
                    .padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .background(theme.bgSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    func tabela(_ cabecalho: [AttributedString], _ linhas: [[AttributedString]]) -> some View {
        ScrollPane(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(cabecalho.enumerated()), id: \.offset) { _, c in
                        celula(c, cabecalho: true)
                    }
                }
                ForEach(Array(linhas.enumerated()), id: \.offset) { n, linha in
                    GridRow {
                        ForEach(Array(linha.enumerated()), id: \.offset) { _, c in
                            celula(c, cabecalho: false)
                        }
                    }
                    .background(n.isMultiple(of: 2) ? Color.clear : theme.bgSubtle.opacity(0.6))
                }
            }
            .overlay(Rectangle().stroke(theme.border, lineWidth: 1))
        }
    }

    func celula(_ t: AttributedString, cabecalho: Bool) -> some View {
        Text(t)
            .font(.system(size: 14, weight: cabecalho ? .semibold : .regular))
            .foregroundStyle(theme.fg)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(maxWidth: 320, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(theme.border).frame(height: cabecalho ? 1 : 0.5) }
    }

    // MARK: caminhos

    /// Resolve um caminho relativo ao `.md` (ou à raiz, se começa com `/`) para um
    /// caminho do projeto. Nulo quando sai do projeto.
    func resolver(_ relativo: String) -> String? {
        let limpo = (relativo.removingPercentEncoding ?? relativo)
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !limpo.isEmpty else { return nil }
        var partes: [Substring] = limpo.hasPrefix("/") ? [] : path.split(separator: "/").dropLast()
        for p in limpo.split(separator: "/") {
            if p == "." {
                continue
            }
            if p == ".." {
                guard !partes.isEmpty else { return nil }
                partes.removeLast()
            } else {
                partes.append(p)
            }
        }
        return partes.isEmpty ? nil : partes.joined(separator: "/")
    }

    /// Imagem do projeto; imagem da internet fica só com o texto alternativo.
    func urlLocal(_ fonte: String) -> URL? {
        if fonte.contains("://") || fonte.hasPrefix("data:") {
            return nil
        }
        return resolver(fonte).flatMap { try? ws.ops.url($0) }
    }

    /// Link da internet vai para o navegador; link para arquivo do projeto abre na aba.
    func abrir(_ url: URL) -> OpenURLAction.Result {
        if let esquema = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(esquema) {
            return .systemAction
        }
        if let alvo = resolver(url.relativeString), ws.filePaths.contains(alvo) {
            ws.openFile(alvo)
        }
        return .handled
    }
}

/// Imagem local do Markdown, lida e decodificada fora do ator principal.
struct ImagemDoMarkdown: View {
    @Environment(\.theme) private var theme
    let alt: String
    let url: URL?
    let fonte: String
    @State private var imagem: UIImage?
    @State private var falhou = false

    var body: some View {
        Group {
            if let imagem {
                Image(uiImage: imagem)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(imagem.size.width, 760))
                    .accessibilityLabel(alt)
            } else if url == nil || falhou {
                Label(alt.isEmpty ? fonte : alt, systemImage: "photo")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.fgSubtle)
            } else {
                Color.clear.frame(height: 40)
            }
        }
        .task(id: url) {
            guard let url else { return }
            let lida = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingForDisplay()
            }.value
            imagem = lida
            falhou = lida == nil
        }
    }
}
