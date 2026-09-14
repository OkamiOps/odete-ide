import OdeteCore
import OdeteUI
import SwiftUI
import UniformTypeIdentifiers

/// Árvore de arquivos com expandir, menu de contexto e arrastar para mover.
struct FileTreeView: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    @State private var renaming: String?
    @State private var newFolderAt: String?
    @State private var deleting: String?
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader("Arquivos", detail: ws.project.name) {
                HeaderButton("doc.badge.plus", label: "Novo arquivo") { ws.createFile(near: ws.selected) }
                HeaderButton("folder.badge.plus", label: "Nova pasta") { draft = ""; newFolderAt = ws.selected ?? "" }
                HeaderButton("arrow.clockwise", label: "Recarregar") { ws.reload() }
            }
            ScrollPane {
                LazyVStack(spacing: 0) {
                    ForEach(ws.tree.children ?? []) { node in
                        FileRow(
                            node: node,
                            depth: 0,
                            renaming: $renaming,
                            deleting: $deleting,
                            newFolderAt: $newFolderAt,
                            draft: $draft
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .dropDestination(for: String.self) { items, _ in
                for p in items {
                    ws.move(p, into: "")
                }
                return true
            }
        }
        .alert("Renomear", isPresented: Binding(get: { renaming != nil }, set: {
            if !$0 {
                renaming = nil
            }
        })) {
            TextField("Nome", text: $draft)
            Button("Renomear") {
                if let p = renaming {
                    ws.rename(p, to: draft)
                }; renaming = nil
            }
            Button("Cancelar", role: .cancel) { renaming = nil }
        }
        .alert("Nova pasta", isPresented: Binding(get: { newFolderAt != nil }, set: {
            if !$0 {
                newFolderAt = nil
            }
        })) {
            TextField("nome", text: $draft)
            Button("Criar") {
                if let at = newFolderAt {
                    ws.createFolder(near: at, name: draft)
                }; newFolderAt = nil
            }
            Button("Cancelar", role: .cancel) { newFolderAt = nil }
        }
        .confirmationDialog(
            "Apagar \"\(deleting ?? "")\"?",
            isPresented: Binding(get: { deleting != nil }, set: {
                if !$0 {
                    deleting = nil
                }
            }),
            titleVisibility: .visible
        ) {
            Button("Apagar", role: .destructive) {
                if let p = deleting {
                    ws.delete(p)
                }; deleting = nil
            }
            Button("Cancelar", role: .cancel) { deleting = nil }
        }
    }
}

struct FileRow: View {
    @Environment(WorkspaceModel.self) private var ws
    @Environment(\.theme) private var theme
    var node: FileNode
    var depth: Int
    @Binding var renaming: String?
    @Binding var deleting: String?
    @Binding var newFolderAt: String?
    @Binding var draft: String
    @State private var over = false

    var open: Bool {
        ws.expanded.contains(node.path)
    }

    var selected: Bool {
        ws.selected == node.path
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                if node.isDirectory {
                    ws.toggle(node.path); ws.selected = node.path
                } else {
                    ws.openFile(node.path)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.fgSubtle)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .opacity(node.isDirectory ? 1 : 0)
                        .frame(width: 12)
                    FileGlyph(path: node.path, isDirectory: node.isDirectory, expanded: open)
                    Text(node.name)
                        .font(OdeteFont.ui(13))
                        .foregroundStyle(selected ? theme.fg : theme.fg.opacity(0.88))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if ws.tabs.first(where: { $0.path == node.path })?.isDirty == true {
                        Circle().fill(theme.accent).frame(width: 6, height: 6).padding(.trailing, 10)
                    }
                }
                .padding(.leading, 10 + CGFloat(depth) * 16)
                .frame(height: Metrics.row - 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected ? theme.glassTint : (over ? theme.accent.opacity(0.12) : .clear),
                    in: RoundedRectangle(cornerRadius: Metrics.rControl, style: .continuous)
                )
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .draggable(node.path) {
                HStack(spacing: 6) {
                    FileGlyph(path: node.path, isDirectory: node.isDirectory); Text(node.name).font(OdeteFont.ui(13))
                }
                .padding(8)
                .background(theme.bgElevated, in: RoundedRectangle(cornerRadius: 8))
            }
            .dropDestination(for: String.self) { items, _ in
                guard node.isDirectory else { return false }
                for p in items {
                    ws.move(p, into: node.path)
                }
                return true
            } isTargeted: { over = $0 && node.isDirectory }
            .contextMenu {
                if node.isDirectory {
                    Button("Novo arquivo", systemImage: "doc.badge.plus") { ws.createFile(near: node.path) }
                    Button("Nova pasta", systemImage: "folder.badge.plus") { draft = ""; newFolderAt = node.path }
                    Divider()
                } else {
                    Button("Abrir", systemImage: "doc.text") { ws.openFile(node.path) }
                }
                Button("Renomear", systemImage: "pencil") { draft = node.name; renaming = node.path }
                Button("Copiar caminho", systemImage: "doc.on.doc") { UIPasteboard.general.string = node.path }
                if !node.isDirectory {
                    ShareLink(item: ws.root.appending(path: node.path)) { Label(
                        "Compartilhar",
                        systemImage: "square.and.arrow.up"
                    ) }
                }
                if !node.isDirectory, ws.git.isRepo {
                    Divider()
                    Button("Histórico", systemImage: "clock.arrow.circlepath") { ws.historyPath = node.path }
                    Button("Blame", systemImage: "person.text.rectangle") { ws.blamePath = node.path }
                }
                Divider()
                Button("Apagar", systemImage: "trash", role: .destructive) { deleting = node.path }
            }
            if node.isDirectory, open {
                ForEach(node.children ?? []) { child in
                    FileRow(
                        node: child,
                        depth: depth + 1,
                        renaming: $renaming,
                        deleting: $deleting,
                        newFolderAt: $newFolderAt,
                        draft: $draft
                    )
                }
            }
        }
    }
}
