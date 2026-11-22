import SwiftUI
import StewardKit

/// Common screen chrome: a fixed header (title, subtitle, trailing controls), the offline banner, and content.
/// `scrolls: false` hands the whole area to the content, for split views that scroll their own columns.
struct ScreenScaffold<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var scrolls = true
    /// Reading width for scrolling screens; nil fills the window.
    var width: CGFloat? = 860
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Space.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Typo.title).foregroundStyle(Palette.text)
                    if let subtitle { Text(subtitle).font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1) }
                }
                Spacer(minLength: Space.m)
                trailing
            }
            .padding(.horizontal, Space.xl)
            .padding(.top, 22)
            .padding(.bottom, Space.m)
            .frame(minHeight: 72, alignment: .bottom)

            if !store.connection.isOnline || store.lastError != nil {
                VStack(alignment: .leading, spacing: Space.xs) {
                    OfflineBanner(connection: store.connection, note: store.brainNote) { store.refresh() }
                    if let error = store.lastError, store.connection.isOnline {
                        InlineNotice(text: error, icon: "exclamationmark.triangle", color: Palette.danger)
                    }
                }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.m)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if scrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.l) { content }
                        .padding(.horizontal, Space.xl)
                        .padding(.bottom, Space.xl)
                        .frame(maxWidth: width ?? .infinity, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .animation(Motion.snappy, value: store.connection.isOnline)
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, scrolls: Bool = true, width: CGFloat? = 860, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, scrolls: scrolls, width: width, trailing: { EmptyView() }, content: content)
    }
}

/// Right-click actions shared by every task list.
struct TaskMenu: ViewModifier {
    let task: TaskItem
    @Environment(AppStore.self) private var store
    // Optional: the menu also works on surfaces outside the main window, minus undo and the inspector.
    @Environment(MainWindowModel.self) private var model: MainWindowModel?

    func body(content: Content) -> some View {
        content.contextMenu {
            if let model { Button("Open", systemImage: "sidebar.right") { model.inspect(task) } }
            if task.status != .doing { Button("Start", systemImage: "play") { store.start(task) } }
            Button("Complete", systemImage: "checkmark") { if let model { model.complete(task) } else { store.complete(task) } }
            Menu("Priority") {
                ForEach(Priority.all.reversed(), id: \.value) { option in
                    Button(option.title) { store.update(task, ["priority": .number(Double(option.value))]) }
                }
            }
            Menu("Snooze") {
                ForEach(Snooze.options(), id: \.title) { option in
                    Button(option.title) { if let model { model.snooze(task, until: option.date) } else { store.snooze(task, until: option.date) } }
                }
            }
            Menu("Project") {
                Button("None") { store.update(task, ["projectId": .null]) }
                ForEach(store.tree.allProjects) { project in
                    Button(project.title) { store.update(task, ["projectId": .string(project.id)]) }
                }
            }
            Button(task.pinned ? "Unpin" : "Pin", systemImage: "pin") { store.update(task, ["pinned": .bool(!task.pinned)]) }
            if task.status == .inbox { Button("Move to To do", systemImage: "arrow.right") { store.update(task, ["status": "todo"]) } }
            if let model {
                Divider()
                Button("Ask agent about this", systemImage: "sparkles") {
                    model.agentContext = [.init(kind: .task, id: task.id, title: task.title)]
                    model.go(.agent)
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { if let model { model.delete([task]) } else { store.delete(task) } }
        }
    }
}

extension View {
    func taskMenu(_ task: TaskItem) -> some View { modifier(TaskMenu(task: task)) }
}
