import SwiftUI
import StewardKit

enum NoteStyle {
    static let kinds: [NoteKind] = [.brief, .meeting, .live, .dump, .journal]

    static func title(_ kind: NoteKind) -> String {
        switch kind {
        case .brief: "Brief"
        case .meeting: "Meeting"
        case .live: "Live"
        case .dump: "Dump"
        case .journal: "Journal"
        case .unknown: "Note"
        }
    }

    static func icon(_ kind: NoteKind) -> String {
        switch kind {
        case .brief: "text.alignleft"
        case .meeting: "person.2"
        case .live: "dot.radiowaves.left.and.right"
        case .dump: "bolt"
        case .journal: "book.closed"
        case .unknown: "note.text"
        }
    }

    static func color(_ kind: NoteKind) -> Color {
        switch kind {
        case .brief: Palette.violet
        case .meeting: Palette.info
        case .live: Palette.accent
        case .dump: Palette.warn
        case .journal: Palette.ok
        case .unknown: Palette.textDim
        }
    }

    /// Briefs and meeting notes are written to be read; the rest are written to be typed into.
    static func readsAsDocument(_ kind: NoteKind) -> Bool { kind == .brief || kind == .meeting }

    /// First line of prose, without markdown markers. Headings only count when there is nothing else.
    static func excerpt(_ body: String) -> String {
        var heading = ""
        for line in body.split(separator: "\n") {
            let text = line.trimmingCharacters(in: CharacterSet(charactersIn: " #>-*|`\t")).replacingOccurrences(of: "**", with: "")
            if text.isEmpty { continue }
            if !line.hasPrefix("#") { return text }
            if heading.isEmpty { heading = text }
        }
        return heading
    }

    /// The body without a leading heading that only repeats the note's title (the header already shows it).
    static func document(_ note: Note) -> String {
        let lines = note.body.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.hasPrefix("#"),
              first.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).caseInsensitiveCompare(note.title) == .orderedSame else { return note.body }
        return lines.dropFirst().joined(separator: "\n")
    }
}

/// Notes of every kind: list on the left, the selected one on the right as a document or an editor.
struct NotesScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var search = ""
    @State private var kind: NoteKind?
    @State private var selection: String?
    /// Per-note override of the default mode (documents read, everything else edits).
    @State private var editing: [String: Bool] = [:]
    @State private var error: String?

    var body: some View {
        let notes = filtered
        let selected = store.notes.first { $0.id == selection && !model.hidden.contains($0.id) }
        ScreenScaffold(title: "Notes", subtitle: subtitle(notes.count), scrolls: false) {
            SearchField(text: $search, placeholder: "Search notes", focusToken: model.searchToken)
            Button("New note", systemImage: "square.and.pencil", action: create).buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
        } content: {
            VStack(spacing: 0) {
                if let error {
                    InlineNotice(text: error, icon: "exclamationmark.triangle", color: Palette.danger).padding(.horizontal, Space.xl).padding(.bottom, Space.m)
                }
                HStack(alignment: .top, spacing: 0) {
                    list(notes).frame(width: 300)
                    Rectangle().fill(Palette.stroke).frame(width: 1)
                    if let selected {
                        NoteDetail(note: selected, editing: isEditing(selected), autofocus: editing[selected.id] == true, onToggleEdit: { toggleEdit(selected) }, onPatch: { patch(selected, $0) },
                                   onDelete: { delete(selected, notes) })
                            .id(selected.id)
                    } else {
                        EmptyState(icon: "note.text", title: store.notes.isEmpty ? "No notes yet" : "Pick a note",
                                   message: store.notes.isEmpty ? "Briefs, meeting notes, captures and your own journal all land here."
                                       : "Or press N to start a new one.",
                                   actionTitle: "New note", action: create)
                    }
                }
                KeyLegend([(["J", "K"], "move"), (["N"], "new"), (["E"], "edit / read"), (["P"], "pin"), (["/"], "search"), (["⌫"], "delete")])
            }
        }
        .animation(Motion.settle, value: notes.map(\.id))
        .screenKeys(model) { keys($0, notes) }
        .onAppear {
            store.need(.notes)
            model.screenHasSearch = true
            if model.scenario["notes.edit"] == "1", let id = model.focusNoteId { editing[id] = true }
            focus(notes)
        }
        .onDisappear { model.screenHasSearch = false }
        .onChange(of: model.focusNoteId) { focus(notes) }
        .onChange(of: store.notes.isEmpty) { focus(notes) }
    }

    private var filtered: [Note] {
        let words = search.lowercased().split(separator: " ")
        return store.notes
            .filter { note in
                guard !model.hidden.contains(note.id), kind == nil || note.kind == kind else { return false }
                let hay = (note.title + "\n" + note.body).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            .sorted { ($0.pinned ? 1 : 0, $0.updatedAt) > ($1.pinned ? 1 : 0, $1.updatedAt) }
    }

    private func subtitle(_ shown: Int) -> String {
        shown == store.notes.count ? "\(shown) notes" : "\(shown) of \(store.notes.count) notes"
    }

    private func focus(_ notes: [Note]) {
        if let id = model.focusNoteId {
            selection = id
            kind = nil
            model.focusNoteId = nil
        } else if selection == nil {
            selection = notes.first?.id
        }
    }

    private func isEditing(_ note: Note) -> Bool {
        editing[note.id] ?? !NoteStyle.readsAsDocument(note.kind)
    }

    private func toggleEdit(_ note: Note) {
        withAnimation(Motion.snappy) { editing[note.id] = !isEditing(note) }
    }

    // MARK: List

    private func list(_ notes: [Note]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Flow(spacing: 5) {
                NoteKindChip(title: "All", icon: nil, color: Palette.textDim, on: kind == nil) { kind = nil }
                ForEach(NoteStyle.kinds, id: \.self) { option in
                    NoteKindChip(title: NoteStyle.title(option), icon: NoteStyle.icon(option), color: NoteStyle.color(option), on: kind == option) {
                        kind = kind == option ? nil : option
                    }
                }
            }
            .padding(.leading, Space.xl)
            .padding(.trailing, Space.m)
            .padding(.bottom, Space.m)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        if notes.isEmpty {
                            Text(store.notes.isEmpty ? "Nothing here yet." : "No note matches.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, Space.s + 2).padding(.top, Space.s)
                        }
                        ForEach(notes) { note in
                            NoteRow(note: note, selected: selection == note.id)
                                .id(note.id)
                                .onTapGesture { withAnimation(Motion.snappy) { selection = note.id } }
                                .contextMenu {
                                    Button(note.pinned ? "Unpin" : "Pin", systemImage: "pin") { patch(note, ["pinned": .bool(!note.pinned)]) }
                                    Button("Delete", systemImage: "trash", role: .destructive) { delete(note, notes) }
                                }
                        }
                    }
                    .padding(.leading, Space.xl - Space.s)
                    .padding(.trailing, Space.s)
                    .padding(.bottom, Space.l)
                }
                .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection) } } }
            }
        }
    }

    // MARK: Actions

    private func run(_ op: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await op()
                error = nil
            } catch {
                withAnimation(Motion.snappy) { self.error = error.brief }
            }
        }
    }

    private func patch(_ note: Note, _ fields: JSONValue) {
        let client = store.client
        run { _ = try await client.updateNote(note.id, fields) }
    }

    private func create() {
        let client = store.client
        run {
            let note = try await client.createNote(["kind": "journal", "title": .string(Date().formatted(.dateTime.weekday(.wide).day().month())), "body": ""])
            search = ""
            kind = nil
            editing[note.id] = true
            withAnimation(Motion.snappy) { selection = note.id }
        }
    }

    private func delete(_ note: Note, _ notes: [Note]) {
        let client = store.client
        if selection == note.id, let index = notes.firstIndex(of: note) {
            selection = notes.indices.contains(index + 1) ? notes[index + 1].id : notes.dropLast().last?.id
        }
        model.deferred("Deleted “\(note.title.nonEmpty ?? "Untitled")”", hiding: [note.id]) {
            Task { try? await client.deleteNote(note.id) }
        }
    }

    private func keys(_ stroke: KeyStroke, _ notes: [Note]) -> Bool {
        if let next = moveSelection(stroke, in: notes.map(\.id), from: selection) {
            selection = next
            return true
        }
        if stroke.plain("n") { create(); return true }
        if stroke.plain("/") { model.searchToken += 1; return true }
        guard stroke.mods.isEmpty, let note = notes.first(where: { $0.id == selection }) else { return false }
        switch stroke.key {
        case .char("p"):
            Haptics.tick()
            patch(note, ["pinned": .bool(!note.pinned)])
        case .char("e"), .enter: toggleEdit(note)
        case .delete: delete(note, notes)
        default: return false
        }
        return true
    }
}

private struct NoteKindChip: View {
    let title: String
    let icon: String?
    let color: Color
    let on: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { action() }
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 9, weight: .medium)) }
                Text(title).font(Typo.caption)
            }
            .foregroundStyle(on ? color : Palette.textDim)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(on ? color.opacity(0.14) : hovered ? Palette.pressed : Palette.hover, in: Capsule())
            .overlay(Capsule().strokeBorder(on ? color.opacity(0.4) : Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable(.bare))
        .onHover { hovered = $0 }
    }
}

private struct NoteRow: View {
    let note: Note
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.s) {
            Image(systemName: NoteStyle.icon(note.kind)).font(.system(size: 10.5, weight: .medium)).foregroundStyle(NoteStyle.color(note.kind))
                .frame(width: 16, height: 17)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(note.title.nonEmpty ?? "Untitled").font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Palette.accent) }
                    Spacer(minLength: Space.xs)
                    Text(Fmt.since(note.updatedAt)).font(Typo.numeric).foregroundStyle(Palette.textFaint)
                }
                Text(NoteStyle.excerpt(note.body).nonEmpty ?? "Empty").font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            }
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 7)
        .rowSurface(selected: selected)
    }
}

/// The selected note: header with its links, then the body as a readable document or a full-pane editor.
private struct NoteDetail: View {
    let note: Note
    let editing: Bool
    /// True when the user just switched this note to Edit: the caret should already be in the text.
    let autofocus: Bool
    let onToggleEdit: () -> Void
    let onPatch: (JSONValue) -> Void
    let onDelete: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.m)
            Rectangle().fill(Palette.stroke).frame(height: 1)
            if editing {
                NoteBodyEditor(text: note.body, autofocus: autofocus) { onPatch(["body": .string($0)]) }
            } else {
                ScrollView {
                    Group {
                        if note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("This note is empty. Press E to write.").font(Typo.body).foregroundStyle(Palette.textFaint)
                        } else {
                            MarkdownView(text: NoteStyle.document(note), document: true)
                        }
                    }
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.l)
                    .frame(maxWidth: 680 + Space.xl * 2, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                CommitField(placeholder: "Title", value: note.title, font: .system(size: 19, weight: .semibold)) { onPatch(["title": .string($0)]) }
                Spacer(minLength: Space.s)
                Segmented([(false, "Read", "doc.plaintext"), (true, "Edit", "pencil")], selection: Binding(get: { editing }, set: { if $0 != editing { onToggleEdit() } }))
                IconButton(icon: note.pinned ? "pin.fill" : "pin", help: note.pinned ? "Unpin (P)" : "Pin (P)", tint: note.pinned ? Palette.accent : Palette.textDim) {
                    onPatch(["pinned": .bool(!note.pinned)])
                }
                IconButton(icon: "trash", help: "Delete (⌫)", action: onDelete)
            }
            Flow(spacing: 6) {
                MenuChip(title: NoteStyle.title(note.kind), icon: NoteStyle.icon(note.kind)) {
                    ForEach(NoteStyle.kinds, id: \.self) { kind in
                        Button(NoteStyle.title(kind), systemImage: NoteStyle.icon(kind)) { onPatch(["kind": .string(kind.rawValue)]) }
                    }
                }
                taskLink
                meetingLink
                Text("Edited \(Fmt.day(note.updatedAt)) \(Fmt.time(note.updatedAt))").font(Typo.caption).foregroundStyle(Palette.textFaint)
                    .padding(.leading, 2).frame(height: 24)
            }
        }
    }

    @ViewBuilder private var taskLink: some View {
        let linked = model.library.task(note.taskId)
        if note.taskId != nil {
            NoteLinkChip(title: linked?.title ?? "Linked task", icon: "checklist", color: Palette.accent,
                         onOpen: { if let linked { model.inspect(linked) } }, onClear: { onPatch(["taskId": .null]) })
        } else {
            MenuChip(title: "Link task", icon: "checklist") {
                ForEach(store.tasks.prefix(25)) { task in
                    Button(task.title) { onPatch(["taskId": .string(task.id)]) }
                }
            }
        }
    }

    @ViewBuilder private var meetingLink: some View {
        if note.meetingId != nil {
            NoteLinkChip(title: store.meetings.first { $0.id == note.meetingId }?.title ?? "Linked meeting", icon: "calendar", color: Palette.info,
                         onOpen: { model.go(.meetings) }, onClear: { onPatch(["meetingId": .null]) })
        } else {
            MenuChip(title: "Link meeting", icon: "calendar") {
                ForEach(store.meetings.reversed()) { meeting in
                    Button("\(meeting.title) · \(Fmt.day(meeting.startAt))") { onPatch(["meetingId": .string(meeting.id)]) }
                }
            }
        }
    }
}

/// A linked task or meeting: click the name to open it, the cross to unlink.
private struct NoteLinkChip: View {
    let title: String
    let icon: String
    let color: Color
    let onOpen: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onOpen) {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 10, weight: .medium))
                    Text(title).font(Typo.caption).lineLimit(1).frame(maxWidth: 220, alignment: .leading).fixedSize()
                }
                .foregroundStyle(color)
            }
            .buttonStyle(.pressable(.bare))
            Button(action: onClear) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(color.opacity(0.7)).frame(width: 12, height: 20).contentShape(.rect)
            }
            .buttonStyle(.pressable(.bare))
            .help("Unlink")
        }
        .padding(.leading, 8)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

/// Plain-text body that fills the pane. Saves a moment after typing stops and when the editor goes away.
private struct NoteBodyEditor: View {
    let text: String
    let autofocus: Bool
    let onSave: (String) -> Void
    @State private var draft = ""
    @State private var saved = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        TextEditor(text: $draft)
            .font(.system(size: 14))
            .lineSpacing(4)
            .foregroundStyle(Palette.text)
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, Space.xl - 5)
            .padding(.vertical, Space.l)
            .frame(maxWidth: 680 + Space.xl * 2, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Write…  markdown is fine").font(.system(size: 14)).foregroundStyle(Palette.textFaint)
                        .padding(.horizontal, Space.xl).padding(.vertical, Space.l).allowsHitTesting(false)
                }
            }
            .onAppear {
                draft = text
                saved = text
                if autofocus { DispatchQueue.main.async { focused = true } }
            }
            // The store refetches after every save; only take its text when the user is not mid-sentence.
            .onChange(of: text) { if !focused, draft == saved { draft = text; saved = text } }
            .onChange(of: draft) {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .seconds(1))
                    if !Task.isCancelled { flush() }
                }
            }
            .onDisappear {
                pending?.cancel()
                flush()
            }
    }

    private func flush() {
        guard draft != saved else { return }
        saved = draft
        onSave(draft)
    }
}
