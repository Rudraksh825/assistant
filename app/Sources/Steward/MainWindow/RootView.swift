import SwiftUI
import StewardKit

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @AppStorage("main.sidebarWidth") private var sidebarWidth = 196.0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar().frame(width: sidebarWidth)
                SidebarHandle(width: $sidebarWidth)
                GeometryReader { geo in
                    // The inspector sits beside the screen when there is room for both, and over its right edge when not.
                    let beside = geo.size.width - Self.inspectorWidth >= app.route.minWidth
                    HStack(spacing: 0) {
                        app.route.screen
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .id(app.route)
                            .transition(.opacity)
                        if beside, let id = model.inspectedTaskId { inspector(id) }
                    }
                    .overlay(alignment: .trailing) {
                        if !beside, let id = model.inspectedTaskId { inspector(id).elevation(4) }
                    }
                }
                .clipped()
            }
            StatusBar()
        }
        .background(Palette.bg)
        .tint(Palette.accent)
        .overlay(alignment: .bottom) {
            if let entry = model.undoEntry {
                UndoToast(entry: entry).padding(.bottom, 66).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let tasks = model.snoozing {
                SnoozePanel(tasks: tasks).padding(.bottom, 70).transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if let mode = model.palette {
                CommandPalette(mode: mode).transition(.opacity)
            }
        }
        // An overlay, not a sheet: a sheet makes AppKit refuse to quit until it is dismissed.
        .overlay {
            if app.showOnboarding {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    OnboardingView {
                        UserDefaults.standard.set(true, forKey: "onboarded")
                        withAnimation(Motion.snappy) { app.showOnboarding = false }
                    }
                    .clipShape(.continuous(Radius.xl))
                    .overlay(RoundedRectangle.continuous(Radius.xl).strokeBorder(Palette.strokeStrong, lineWidth: 1))
                    .elevation(4)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
    }
}

extension RootView {
    static let inspectorWidth: CGFloat = 372

    func inspector(_ id: String) -> some View {
        TaskInspector(taskId: id)
            .frame(width: Self.inspectorWidth)
            .id(id)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

private struct SidebarHandle: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hovered = false

    var body: some View {
        Rectangle()
            .fill(hovered || start != nil ? Palette.accent.opacity(0.5) : Palette.stroke)
            .frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(.rect)
            .padding(.horizontal, -3)
            .onHover { inside in
                hovered = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    if start == nil { start = width }
                    width = min(280, max(160, (start ?? width) + drag.translation.width))
                }
                .onEnded { _ in start = nil })
            .animation(Motion.snappy, value: hovered)
            .zIndex(1)
    }
}

struct Sidebar: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @Namespace private var space

    private static let groups: [[Route]] = [[.today, .inbox, .tasks, .projects], [.sessions, .meetings, .notes, .people], [.agent, .activity]]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights: the window's title bar is transparent.
            Color.clear.frame(height: 46)
            Button { model.openPalette() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                    Text("Search or run").font(Typo.caption)
                    Spacer(minLength: 0)
                    KeyHint("⌘", "K")
                }
                .foregroundStyle(Palette.textFaint)
                .padding(.horizontal, Space.s)
                .frame(height: 28)
                .background(Palette.hover, in: .continuous(Radius.s + 1))
                .overlay(RoundedRectangle.continuous(Radius.s + 1).strokeBorder(Palette.stroke, lineWidth: 1))
            }
            .buttonStyle(.pressable(.bare))
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.m)

            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Color.clear.frame(height: Space.m) }
                ForEach(group) { row($0) }
            }
            Spacer(minLength: Space.m)
            row(.guide)
            row(.settings).padding(.bottom, Space.s)
        }
        .background(Palette.bgSunken)
    }

    private func row(_ route: Route) -> some View {
        SidebarRow(route: route, selected: app.route == route, badge: badge(route), space: space) { model.go(route) }
            .padding(.horizontal, Space.s)
    }

    private func badge(_ route: Route) -> (count: Int, color: Color)? {
        switch route {
        case .inbox:
            let n = store.suggestions.filter { !model.hidden.contains($0.id) }.count + store.approvals.count
            return n > 0 ? (n, store.approvals.isEmpty ? Palette.accent : Palette.danger) : nil
        case .sessions:
            let waiting = store.sessions.filter(\.needsAttention)
            return waiting.isEmpty ? nil : (waiting.count, waiting.contains { $0.state == .blocked } ? Palette.danger : Palette.accent)
        case .today:
            let overdue = store.snapshot?.counts.overdue ?? 0
            return overdue > 0 ? (overdue, Palette.danger) : nil
        default:
            return nil
        }
    }
}

private struct SidebarRow: View {
    let route: Route
    let selected: Bool
    let badge: (count: Int, color: Color)?
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: route.icon)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(selected ? Palette.accent : Palette.textDim)
                    .frame(width: 18)
                Text(route.title).font(selected ? Typo.bodyStrong : Typo.body).foregroundStyle(selected ? Palette.text : Palette.textDim)
                Spacer(minLength: 0)
                if let badge {
                    Text("\(badge.count)")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(badge.color)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(badge.color.opacity(0.15), in: Capsule())
                        .contentTransition(.numericText())
                } else if hovered {
                    Text(route.shortcut).font(.system(size: 10, weight: .medium, design: .rounded)).foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            .background {
                if selected {
                    RoundedRectangle.continuous(Radius.s + 1).fill(Palette.pressed).matchedGeometryEffect(id: "selection", in: space)
                } else if hovered {
                    RoundedRectangle.continuous(Radius.s + 1).fill(Palette.hover)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.pressable(.bare, haptic: false))
        .onHover { hovered = $0 }
        .animation(Motion.snappy, value: hovered)
        .animation(Motion.snappy, value: badge?.count)
        .accessibilityLabel(route.title)
    }
}

/// Always-visible strip along the bottom: connection, what the agent is doing, counts, spend.
struct StatusBar: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        HStack(spacing: Space.m) {
            HStack(spacing: 6) {
                Circle().fill(connectionColor).frame(width: 6, height: 6)
                Text(connectionText).foregroundStyle(Palette.textDim).lineLimit(1)
            }
            if store.connection.isOnline {
                divider
                HStack(spacing: 6) {
                    if store.agent.busy { ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 10, height: 10) }
                    else { Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Palette.textFaint) }
                    Text(store.agent.activity ?? (store.agent.busy ? "Agent working…" : store.agentIssue == nil ? "Agent idle" : "Agent unavailable"))
                        .foregroundStyle(store.agent.busy ? Palette.text : store.agentIssue == nil ? Palette.textFaint : Palette.warn).lineLimit(1)
                }
                .help(store.agentIssue ?? "")
                .animation(Motion.snappy, value: store.agent.busy)
            }
            Spacer(minLength: Space.s)
            if let counts = store.snapshot?.counts {
                let waiting = store.sessions.filter(\.needsAttention).count
                count("tray", counts.suggestions + counts.approvals, "to review", .inbox, counts.approvals > 0 ? Palette.danger : Palette.accent)
                count("exclamationmark.circle", counts.overdue, "overdue", .tasks, Palette.danger)
                count("calendar", counts.dueToday, "due today", .today, Palette.text)
                count("hourglass", counts.waiting, "waiting", .tasks, Palette.info)
                count("terminal", waiting, waiting == 1 ? "session needs you" : "sessions need you", .sessions, Palette.accent)
            }
            if let budget = store.snapshot?.budget, budget.dailyCapUsd > 0 {
                divider
                Button { model.go(.settings) } label: {
                    HStack(spacing: 6) {
                        Text("\(Fmt.usd(budget.todayUsd)) / \(Fmt.usd(budget.dailyCapUsd))").font(Typo.numeric).foregroundStyle(Palette.textDim)
                        let used = budget.todayUsd / budget.dailyCapUsd
                        Meter(fraction: used, color: used >= 1 ? Palette.danger : used >= 0.8 ? Palette.warn : Palette.ok, height: 3).frame(width: 36)
                    }
                }
                .buttonStyle(.pressable(.bare, haptic: false))
                .help("Agent spend today against the daily cap")
            }
        }
        .font(Typo.caption)
        .padding(.horizontal, Space.m)
        .frame(height: 26)
        .background(Palette.bgSunken)
        .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }

    private var divider: some View { Rectangle().fill(Palette.stroke).frame(width: 1, height: 12) }

    @ViewBuilder private func count(_ icon: String, _ value: Int, _ label: String, _ route: Route, _ color: Color) -> some View {
        if value > 0 {
            Button { model.go(route) } label: {
                HStack(spacing: 4) {
                    Image(systemName: icon).font(.system(size: 9.5, weight: .medium)).foregroundStyle(color.opacity(0.9))
                    Text("\(value)").font(Typo.numeric).foregroundStyle(Palette.text).contentTransition(.numericText())
                    Text(label).foregroundStyle(Palette.textFaint)
                }
            }
            .buttonStyle(.pressable(.bare, haptic: false))
        }
    }

    private var connectionColor: Color {
        switch store.connection {
        case .online: Palette.ok
        case .connecting: Palette.warn
        case .offline: Palette.danger
        }
    }

    private var connectionText: String {
        switch store.connection {
        case .online: "Connected" + (store.brainVersion.map { " · \($0)" } ?? "")
        case .connecting: "Connecting…"
        case .offline: store.brainNote ?? "Brain offline"
        }
    }
}

struct UndoToast: View {
    let entry: MainWindowModel.UndoEntry
    @Environment(MainWindowModel.self) private var model
    @State private var remaining = 1.0

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Palette.ok)
            Text(entry.label).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1).frame(maxWidth: 320, alignment: .leading).fixedSize()
            Button { model.performUndo() } label: {
                HStack(spacing: 5) {
                    Text("Undo")
                    KeyHint("⌘", "Z")
                }
            }
            .buttonStyle(.pressable())
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.s)
        .frame(height: 40)
        .background(Palette.bgRaised, in: Capsule())
        .overlay(alignment: .bottom) {
            // Drains over the undo window.
            Capsule().fill(Palette.accent.opacity(0.7)).frame(height: 2).scaleEffect(x: remaining, anchor: .leading).padding(.horizontal, 18)
        }
        .overlay(Capsule().strokeBorder(Palette.strokeStrong, lineWidth: 1))
        .elevation(3)
        .id(entry.id)
        .onAppear { withAnimation(.linear(duration: 6)) { remaining = 0 } }
    }
}

/// "Snooze until…" with number keys. In-window so the keyboard path stays in one place.
struct SnoozePanel: View {
    let tasks: [TaskItem]
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "moon.zzz").font(.system(size: 12)).foregroundStyle(Palette.violet)
                Text(tasks.count == 1 ? "Snooze “\(tasks[0].title)”" : "Snooze \(tasks.count) tasks").font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                Spacer()
                KeyHint("esc")
            }
            HStack(spacing: Space.s) {
                ForEach(Array(Snooze.options().enumerated()), id: \.offset) { index, option in
                    Button {
                        model.snooze(tasks, until: option.date)
                        withAnimation(Motion.snappy) { model.snoozing = nil }
                    } label: {
                        HStack(spacing: 6) {
                            KeyHint("\(index + 1)")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(option.title).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                                Text(Fmt.due(option.date).text).font(Typo.caption).foregroundStyle(Palette.textFaint)
                            }
                        }
                        .padding(.horizontal, Space.s)
                        .frame(height: 40)
                        .rowSurface()
                    }
                    .buttonStyle(.pressable(.bare))
                }
            }
        }
        .padding(Space.m)
        .frame(width: 620)
        .background(Palette.bgRaised, in: .continuous(Radius.l))
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(Palette.strokeStrong, lineWidth: 1))
        .elevation(3)
    }
}
