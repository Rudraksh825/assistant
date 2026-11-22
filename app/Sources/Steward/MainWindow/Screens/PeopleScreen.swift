import AppKit
import SwiftUI
import StewardKit

/// Who the work runs through: when you last talked, what you know about them, and the tasks between you.
struct PeopleScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var selection: String?
    @State private var search = ""

    var body: some View {
        let tasks = model.visible(store.tasks)
        let people = filtered
        let selected = people.first { $0.id == selection } ?? people.first
        ScreenScaffold(title: "People", subtitle: "\(store.people.count) people", scrolls: false) {
            SearchField(text: $search, placeholder: "Search people", focusToken: model.searchToken)
        } content: {
            if store.people.isEmpty {
                VStack(spacing: 0) {
                    EmptyState(icon: "person.2", title: "No people yet",
                               message: "People appear here as chat, meetings and tickets mention them. Add someone yourself below, or type @name in a task.")
                    CaptureField("Add a person by name…", icon: "person.badge.plus") { add($0) }
                        .frame(maxWidth: 320)
                        .padding(.bottom, Space.xxl)
                }
            } else {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 0) {
                        ScrollViewReader { proxy in
                            ScrollView {
                                LazyVStack(spacing: 1) {
                                    CaptureField("Add a person…", icon: "person.badge.plus") { add($0) }
                                        .padding(.bottom, Space.xs)
                                    if people.isEmpty {
                                        Text("Nobody matches “\(search)”.").font(Typo.caption).foregroundStyle(Palette.textFaint).padding(Space.l)
                                    }
                                    ForEach(people) { person in
                                        PeopleRow(person: person, selected: person.id == selected?.id,
                                                  waiting: tasks.filter { TaskQuery.waitsOn($0, person.name) }.count,
                                                  involved: tasks.filter { TaskQuery.involves($0, person.name) }.count)
                                            .id(person.id)
                                            .onTapGesture { selection = person.id }
                                            .contextMenu { Button("Remove \(person.name)", systemImage: "trash", role: .destructive) { remove(person) } }
                                    }
                                }
                                .padding(.leading, Space.xl - Space.s)
                                .padding(.trailing, Space.s)
                                .padding(.bottom, Space.xl)
                            }
                            .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection) } } }
                        }
                        .frame(width: 300)
                        Rectangle().fill(Palette.stroke).frame(width: 1)
                        if let selected {
                            PeopleDetail(person: selected, tasks: tasks).id(selected.id).transition(.opacity)
                        }
                    }
                    KeyLegend([(["J", "K"], "move"), (["/"], "search"), (["A"], "ask agent"), (["⌫"], "remove")])
                }
            }
        }
        .animation(Motion.snappy, value: selected?.id)
        .screenKeys(model) { keys($0, people, selected) }
        .onAppear {
            store.need(.people)
            model.screenHasSearch = true
            if let preset = model.scenario["people.selected"] { selection = preset }
            takeFocus()
        }
        .onDisappear { model.screenHasSearch = false }
        .onChange(of: model.focusPersonId) { takeFocus() }
    }

    private var filtered: [Person] {
        let sorted = store.people.filter { !model.hidden.contains($0.id) }.sorted { ($0.lastContactAt ?? .distantPast, $1.name) > ($1.lastContactAt ?? .distantPast, $0.name) }
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return sorted }
        return sorted.filter { person in
            Fuzzy.score(query, in: person.name) != nil || person.handles.values.contains { $0.localizedCaseInsensitiveContains(query) }
                || person.notes.localizedCaseInsensitiveContains(query)
        }
    }

    private func takeFocus() {
        guard let id = model.focusPersonId else { return }
        search = ""
        selection = id
        model.focusPersonId = nil
    }

    private func keys(_ stroke: KeyStroke, _ people: [Person], _ selected: Person?) -> Bool {
        if let next = moveSelection(stroke, in: people.map(\.id), from: selected?.id) {
            selection = next
            return true
        }
        if stroke.plain("/") {
            model.searchToken += 1
            return true
        }
        if stroke.plain("a"), let selected {
            model.ask(PeopleDetail.question(selected))
            return true
        }
        if stroke.plain(.delete), let selected {
            remove(selected)
            return true
        }
        return false
    }

    private func add(_ name: String) {
        Task {
            // The brain announces `people`, which refetches the list; selecting the id now makes the new row the open one.
            if let person = try? await store.client.createPerson(["name": .string(name)]) { selection = person.id }
        }
    }

    private func remove(_ person: Person) {
        if selection == person.id { selection = nil }
        model.deferred("Removed \(person.name)", hiding: [person.id]) { [store] in
            Task { try? await store.client.deletePerson(person.id) }
        }
    }
}

private struct PeopleRow: View {
    let person: Person
    let selected: Bool
    let waiting: Int
    let involved: Int

    var body: some View {
        HStack(spacing: Space.s + 2) {
            Avatar(name: person.name, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                Text(person.lastContactAt.map { "\(Fmt.since($0)) ago" } ?? "No contact yet").font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
            }
            Spacer(minLength: Space.xs)
            if waiting > 0 {
                Label("\(waiting)", systemImage: "hourglass").font(Typo.numeric).labelStyle(.titleAndIcon).foregroundStyle(Palette.info)
                    .help("\(waiting) task\(waiting == 1 ? "" : "s") waiting on \(person.name)")
            }
            if involved > waiting {
                Label("\(involved - waiting)", systemImage: "checklist").font(Typo.numeric).labelStyle(.titleAndIcon).foregroundStyle(Palette.textDim)
                    .help("\(involved - waiting) more open task\(involved - waiting == 1 ? "" : "s") involving \(person.name)")
            }
        }
        .padding(.horizontal, Space.s + 2)
        .frame(height: 46)
        .rowSurface(selected: selected)
    }
}

private struct PeopleDetail: View {
    let person: Person
    let tasks: [TaskItem]
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var copied: String?

    static func question(_ person: Person) -> String {
        "What do I owe \(person.name) and what are they waiting on from me?"
    }

    var body: some View {
        let waiting = tasks.filter { TaskQuery.waitsOn($0, person.name) }
        let involving = tasks.filter { TaskQuery.involves($0, person.name) && !TaskQuery.waitsOn($0, person.name) }
        let projects = Dictionary(store.tree.allProjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                HStack(alignment: .center, spacing: Space.m) {
                    Avatar(name: person.name, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name).font(Typo.title).foregroundStyle(Palette.text)
                        Text(person.lastContactAt.map { "Last contact \(Fmt.day($0)), \(Fmt.time($0)) · \(Fmt.since($0)) ago" } ?? "No contact recorded yet")
                            .font(Typo.caption).foregroundStyle(Palette.textDim)
                    }
                    Spacer(minLength: Space.s)
                    Button("Ask agent", systemImage: "sparkles") { model.ask(Self.question(person)) }
                        .buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                        .help(Self.question(person))
                }
                if !person.handles.isEmpty {
                    Flow(spacing: 6) {
                        ForEach(person.handles.keys.sorted(), id: \.self) { kind in
                            let value = person.handles[kind] ?? ""
                            Button { copy(value) } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: copied == value ? "checkmark" : Self.icon(kind)).font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(copied == value ? Palette.ok : Palette.textFaint)
                                    Text(kind).font(Typo.caption).foregroundStyle(Palette.textFaint)
                                    Text(value).font(Typo.caption).foregroundStyle(Palette.text)
                                }
                                .padding(.horizontal, 8)
                                .frame(height: 24)
                                .background(Palette.hover, in: Capsule())
                                .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
                            }
                            .buttonStyle(.pressable(.bare))
                            .help("Copy \(value)")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: Space.s) {
                    SectionLabel("Notes")
                    NotesEditor(text: person.notes, minHeight: 64) { notes in
                        Task { try? await store.client.updatePerson(person.id, ["notes": .string(notes)]) }
                    }
                }
                list("Waiting on \(person.name.split(separator: " ").first.map(String.init) ?? person.name)", waiting, projects,
                     empty: "Nothing is waiting on them.")
                list("Involving them", involving, projects, empty: "No other open tasks mention them.")
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xl)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func list(_ title: String, _ tasks: [TaskItem], _ projects: [String: Project], empty: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            SectionLabel(title, count: tasks.count)
            if tasks.isEmpty {
                Text(empty).font(Typo.caption).foregroundStyle(Palette.textFaint).padding(.vertical, Space.xs)
            }
            VStack(spacing: 1) {
                ForEach(tasks) { task in
                    TaskLine(task: task, project: projects[task.projectId ?? ""], selected: model.inspectedTaskId == task.id,
                             onComplete: { model.complete(task) }, onOpen: { model.inspect(task) }, onStart: { store.start(task) })
                        .equatable()
                        .taskMenu(task)
                }
            }
            .padding(.horizontal, -(Space.s + 2))
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        Haptics.tick()
        withAnimation(Motion.snappy) { copied = value }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.snappy) { if copied == value { copied = nil } }
        }
    }

    static func icon(_ kind: String) -> String {
        switch kind.lowercased() {
        case "email", "mail": "envelope"
        case "chat", "slack": "bubble.left"
        case "git", "github": "arrow.triangle.branch"
        case "phone": "phone"
        default: "at"
        }
    }
}
