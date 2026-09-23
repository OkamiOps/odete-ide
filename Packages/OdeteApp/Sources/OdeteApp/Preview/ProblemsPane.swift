import OdeteBundler
import OdeteCore
import OdeteI18n
import OdetePreview
import OdeteSwift
import OdeteUI
import SwiftUI
import UIKit

/// Problemas: diagnósticos do esbuild (dev server) e erros do preview. Toque abre o arquivo na linha.
struct ProblemsPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme

    var body: some View {
        let diags = ws.run.diagnostics
        let swift = ws.swiftDiagnostics
        // Só os erros da página que está no preview agora: o console guarda a história,
        // e um erro já consertado não é mais problema.
        let errors = ws.preview.errosDaPagina
        let lint = ws.allLint
        let total = diags.count + errors.count + swift.count + lint.count
        VStack(spacing: 0) {
            PaneHeader(
                tr("Problemas"),
                detail: total == 0 ? tr("tudo limpo") : "\(total)"
            ) {
                HeaderButton("arrow.clockwise", label: tr("Rebuild")) { ws.run.active?.shell.devServer?.invalidate() }
            }
            if total == 0 {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(theme.ok)
                    Text(tr("Nenhum problema")).font(OdeteFont.ui(13, weight: .medium)).foregroundStyle(theme.fg)
                    Text(ws.run.servers
                        .isEmpty ? tr("Erros do build aparecem aqui quando o dev server estiver rodando.") :
                        tr("O build e o preview estão sem erros."))
                        .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !lint.isEmpty {
                        Section {
                            ForEach(lint, id: \.issue.id) { item in
                                Button { ws.open(item.path, line: item.issue.line) } label: { row(
                                    item.issue.severity == .error ? "xmark.octagon" : item.issue
                                        .severity == .warning ? "exclamationmark.triangle" : "info.circle",
                                    item.issue.severity == .error ? theme.danger : item.issue
                                        .severity == .warning ? theme.accent : theme.fgMuted,
                                    item.issue.message,
                                    "\(item.path):\(item.issue.line):\(item.issue.column)",
                                    nil
                                ) }
                                .buttonStyle(.plain)
                            }
                        } header: { label("Editor · lint") }
                    }
                    if !diags.isEmpty {
                        Section {
                            ForEach(diags) { d in
                                let alvo = arquivo(d.file)
                                Button {
                                    if let alvo {
                                        ws.open(alvo, line: d.line ?? 1)
                                    }
                                } label: { row(
                                    d.kind == .error ? "xmark.octagon" : "exclamationmark.triangle",
                                    d.kind == .error ? theme.danger : theme.accent,
                                    d.text,
                                    alvo.map { "\($0):\(d.line ?? 0)" },
                                    d.lineText
                                ) }
                                .buttonStyle(.plain)
                                .allowsHitTesting(alvo != nil)
                                .contextMenu { Button(tr("Copiar erro"), systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = d.text
                                } }
                            }
                        } header: { label("Build · esbuild") }
                    }
                    if !swift.isEmpty {
                        Section {
                            ForEach(swift) { d in
                                Button { ws.open(d.file, line: d.line) } label: { row(
                                    d.kind == .error ? "xmark.octagon" : "exclamationmark.triangle",
                                    d.kind == .error ? theme.danger : theme.accent,
                                    d.message,
                                    "\(d.file):\(d.line)",
                                    nil
                                ) }
                                .buttonStyle(.plain)
                            }
                        } header: { label("Swift · preview") }
                    }
                    if !errors.isEmpty {
                        Section {
                            ForEach(errors) { e in
                                let alvo = arquivo(e.file)
                                Button {
                                    if let alvo {
                                        ws.open(alvo, line: e.line ?? 1)
                                    }
                                } label: { row(
                                    "xmark.octagon",
                                    theme.danger,
                                    e.text,
                                    alvo.map { "\($0):\(e.line ?? 0)" },
                                    nil
                                ) }
                                .buttonStyle(.plain)
                                // Erro sem arquivo no projeto não leva a lugar nenhum; tocar
                                // nele abria uma aba em branco.
                                .allowsHitTesting(alvo != nil)
                                .contextMenu { Button(tr("Copiar erro"), systemImage: "doc.on.doc") {
                                    UIPasteboard.general.string = e.text
                                } }
                            }
                        } header: { label("Preview · runtime") }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(theme.bgElevated)
    }

    /// Caminho dentro do projeto, ou nada quando o erro veio de um módulo remoto,
    /// de um caminho vazio ou de um arquivo que não existe aqui.
    func arquivo(_ f: String?) -> String? {
        guard let f, !f.isEmpty else { return nil }
        if f.hasPrefix("http://") || f.hasPrefix("https://"), !f.contains("/@odete/") {
            return nil
        }
        let p = rel(f)
        guard !p.isEmpty, !p.hasPrefix("http") else { return nil }
        guard FileManager.default.fileExists(atPath: ws.root.appending(path: p).path) else { return nil }
        return p
    }

    func rel(_ f: String) -> String {
        var p = f.replacingOccurrences(of: ws.root.path + "/", with: "").replacingOccurrences(
            of: "/@odete/js/",
            with: ""
        ).replacingOccurrences(of: "/@odete/css/", with: "")
        if p.hasPrefix("/") {
            p.removeFirst()
        }
        return p
    }

    func label(_ s: String) -> some View {
        Text(s.uppercased()).font(OdeteFont.label).tracking(1).foregroundStyle(theme.fgSubtle)
    }

    func row(_ sym: String, _ c: Color, _ text: String, _ loc: String?, _ lineText: String?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: sym).font(.system(size: 12)).foregroundStyle(c).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(text).font(OdeteFont.ui(12)).foregroundStyle(theme.fg).fixedSize(horizontal: false, vertical: true)
                if let loc {
                    Text(loc).font(OdeteFont.mono(10)).foregroundStyle(theme.fgSubtle)
                }
                if let lineText,
                   !lineText
                   .isEmpty
                {
                    Text(lineText.trimmingCharacters(in: .whitespaces)).font(OdeteFont.mono(10))
                        .foregroundStyle(theme.fgMuted).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(theme.bgElevated)
    }
}
