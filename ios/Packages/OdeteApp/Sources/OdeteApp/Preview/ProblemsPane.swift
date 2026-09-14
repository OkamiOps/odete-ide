import OdeteBundler
import OdeteCore
import OdetePreview
import OdeteUI
import SwiftUI

/// Problemas: diagnósticos do esbuild (dev server) e erros do preview. Toque abre o arquivo na linha.
struct ProblemsPane: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(ChromeState.self) private var chrome
    @Environment(\.theme) private var theme

    var body: some View {
        let diags = ws.run.diagnostics
        let errors = ws.preview.console.filter { $0.level == .error }
        VStack(spacing: 0) {
            PaneHeader(
                "Problemas",
                detail: diags.isEmpty && errors.isEmpty ? "tudo limpo" : "\(diags.count + errors.count)"
            ) {
                HeaderButton("arrow.clockwise", label: "Rebuild") { ws.run.active?.shell.devServer?.invalidate() }
            }
            if diags.isEmpty, errors.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal").font(.system(size: 30)).foregroundStyle(theme.ok)
                    Text("Nenhum problema").font(OdeteFont.ui(13, weight: .medium)).foregroundStyle(theme.fg)
                    Text(ws.run.servers
                        .isEmpty ? "Erros do build aparecem aqui quando o dev server estiver rodando." :
                        "O build e o preview estão sem erros.")
                        .font(OdeteFont.ui(12)).foregroundStyle(theme.fgMuted).multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !diags.isEmpty {
                        Section {
                            ForEach(diags) { d in
                                Button {
                                    if let f = d.file {
                                        ws.open(rel(f), line: d.line ?? 1)
                                    }
                                } label: { row(
                                    d.kind == .error ? "xmark.octagon" : "exclamationmark.triangle",
                                    d.kind == .error ? theme.danger : theme.accent,
                                    d.text,
                                    d.file.map { "\(rel($0)):\(d.line ?? 0)" },
                                    d.lineText
                                ) }
                                .buttonStyle(.plain)
                            }
                        } header: { label("Build · esbuild") }
                    }
                    if !errors.isEmpty {
                        Section {
                            ForEach(errors) { e in
                                Button {
                                    if let f = e.file {
                                        ws.open(rel(f), line: e.line ?? 1)
                                    }
                                } label: { row(
                                    "xmark.octagon",
                                    theme.danger,
                                    e.text,
                                    e.file.map { "\(rel($0)):\(e.line ?? 0)" },
                                    nil
                                ) }
                                .buttonStyle(.plain)
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
