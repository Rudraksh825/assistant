import SwiftUI
import StewardKit

/// The markdown files the agent keeps about the user: browse, read, edit, add, delete.
struct SettingsMemoryPane: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var files: [MemoryFile] = []
    @State private var loaded = false
    @State private var selected: String?
    /// The file's content as last read from or written to disk.
    @State private var saved = ""
    @State private var draft = ""
    @State private var preview = false
    @State private var notice: (text: String, color: Color)?
    @State private var newPath: String?
    @State private var confirmingDelete = false

    private var dirty: Bool { draft != saved }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("What the agent remembers about you, as plain markdown files. It reads these before it acts, so anything you correct or delete here changes what it knows.")
                .font(Typo.body).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 720, alignment: .leading)
            if let notice { InlineNotice(text: notice.text, icon: "info.circle", color: notice.color) }
            HStack(alignment: .top, spacing: Space.m) {
                list.frame(width: 232)
                editor
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, Space.l)
        .task(id: store.connection.isOnline) { await reload() }
        .onAppear { if model.scenario["settings.memory"] == "preview" { preview = true } }
    }

    // MARK: List

    private var list: some View {
        let folders = Dictionary(grouping: files) { $0.path.contains("/") ? String($0.path.split(separator: "/").first ?? "") : "" }
        return VStack(alignment: .leading, spacing: Space.s) {
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if files.isEmpty {
                        Text(loaded ? "Nothing remembered yet. The agent writes here as it learns how you work." : "Loading…")
                            .font(Typo.caption).foregroundStyle(Palette.textFaint).padding(Space.s).fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(folders.keys.sorted(), id: \.self) { folder in
                        if !folder.isEmpty { SectionLabel(folder).padding(.horizontal, Space.s).padding(.top, Space.s).padding(.bottom, 2) }
                        ForEach(folders[folder] ?? []) { file in
                            Button { open(file.path) } label: {
                                HStack(spacing: Space.s) {
                                    Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(selected == file.path ? Palette.accent : Palette.textFaint).frame(width: 14)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(file.path.split(separator: "/").last.map(String.init) ?? file.path).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                                        Text("\(file.size.formatted(.byteCount(style: .file))) · \(Fmt.since(file.updatedAt)) ago").font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Space.s)
                                .padding(.vertical, 5)
                                .rowSurface(selected: selected == file.path)
                            }
                            .buttonStyle(.pressable(.bare, haptic: false))
                        }
                    }
                }
                .padding(Space.xs)
            }
            Rectangle().fill(Palette.stroke).frame(height: 1)
            Group {
                if let path = newPath {
                    CaptureField("people/name.md", icon: "doc.badge.plus") { create($0) }
                        .help("Path inside memory/, ending in .md")
                        .id(path)
                } else {
                    Button("New file", systemImage: "plus") { newPath = "" }.buttonStyle(.pressable(.ghost)).labelStyle(.titleAndIcon).fixedSize()
                        .disabled(!store.connection.isOnline)
                }
            }
            .padding(.horizontal, Space.xs)
            .padding(.bottom, Space.s)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .cardSurface(radius: Radius.l)
    }

    // MARK: Editor

    @ViewBuilder private var editor: some View {
        if let selected {
            VStack(spacing: 0) {
                HStack(spacing: Space.s) {
                    Text(selected).font(Typo.mono).foregroundStyle(Palette.text).lineLimit(1)
                    if dirty { Circle().fill(Palette.accent).frame(width: 6, height: 6).help("Unsaved changes") }
                    Spacer(minLength: Space.s)
                    Segmented([(false, "Edit", "pencil"), (true, "Preview", "eye")], selection: $preview)
                    if confirmingDelete {
                        Text("Delete this file?").font(Typo.caption).foregroundStyle(Palette.textDim)
                        Button("Cancel") { withAnimation(Motion.snappy) { confirmingDelete = false } }.buttonStyle(.pressable(.ghost)).fixedSize()
                        Button("Delete", action: delete).buttonStyle(.pressable(.danger)).fixedSize()
                    } else {
                        if dirty { Button("Revert") { draft = saved }.buttonStyle(.pressable(.ghost)).fixedSize() }
                        Button { save() } label: {
                            HStack(spacing: 5) {
                                Text("Save")
                                KeyHint("⌘", "S")
                            }
                        }
                        .buttonStyle(.pressable(dirty ? .primary : .secondary)).fixedSize()
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(!dirty)
                        IconButton(icon: "trash", help: "Delete file") { withAnimation(Motion.snappy) { confirmingDelete = true } }
                    }
                }
                .padding(.horizontal, Space.m)
                .frame(height: 44)
                Rectangle().fill(Palette.stroke).frame(height: 1)
                if preview {
                    ScrollView {
                        MarkdownView(text: draft, document: true).padding(Space.l).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    TextEditor(text: $draft)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(Palette.text)
                        .lineSpacing(3)
                        .scrollContentBackground(.hidden)
                        .padding(Space.m)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .cardSurface(radius: Radius.l)
        } else {
            EmptyState(icon: "brain", title: files.isEmpty ? "No memory files" : "Pick a file",
                       message: files.isEmpty ? "Create one to tell the agent something up front, such as how you like updates written." : nil)
                .cardSurface(radius: Radius.l)
        }
    }

    // MARK: Actions

    private func reload() async {
        guard store.connection.isOnline else { return }
        do {
            files = try await store.client.memoryFiles()
            loaded = true
            if selected == nil || !files.contains(where: { $0.path == selected }) {
                selected = nil
                if let first = files.first { open(first.path) }
            }
        } catch {
            notice = (error.brief, Palette.danger)
        }
    }

    private func open(_ path: String) {
        // Unsaved edits are kept rather than thrown away by a stray click.
        guard !dirty || path == selected else {
            notice = ("Save or revert \(selected ?? "this file") before opening another.", Palette.warn)
            return
        }
        confirmingDelete = false
        Task {
            do {
                let content = try await store.client.memoryFile(path)
                withAnimation(Motion.snappy) { selected = path }
                saved = content
                draft = content
                notice = nil
            } catch {
                notice = (error.brief, Palette.danger)
            }
        }
    }

    private func save() {
        guard let selected, dirty else { return }
        let content = draft
        Task {
            do {
                try await store.client.putMemory(selected, content: content)
                saved = content
                notice = nil
                Haptics.tick()
                files = (try? await store.client.memoryFiles()) ?? files
            } catch {
                notice = (error.brief, Palette.danger)
            }
        }
    }

    private func create(_ raw: String) {
        let path = raw.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard path.hasSuffix(".md"), !path.contains(".."), path.count > 3 else {
            notice = ("A memory file needs a path ending in .md, for example people/name.md.", Palette.warn)
            return
        }
        guard !dirty else {
            notice = ("Save or revert \(selected ?? "this file") before creating another.", Palette.warn)
            return
        }
        guard !files.contains(where: { $0.path == path }) else {
            newPath = nil
            return open(path)
        }
        let title = (path.split(separator: "/").last ?? "").dropLast(3).replacingOccurrences(of: "-", with: " ").capitalized
        Task {
            do {
                try await store.client.putMemory(path, content: "# \(title)\n\n")
                newPath = nil
                files = try await store.client.memoryFiles()
                open(path)
            } catch {
                notice = (error.brief, Palette.danger)
            }
        }
    }

    private func delete() {
        guard let path = selected else { return }
        confirmingDelete = false
        Task {
            do {
                try await store.client.deleteMemory(path)
                selected = nil
                saved = ""
                draft = ""
                notice = nil
                await reload()
            } catch {
                notice = (error.brief, Palette.danger)
            }
        }
    }
}
