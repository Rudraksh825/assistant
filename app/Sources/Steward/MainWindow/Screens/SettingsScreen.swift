import SwiftUI
import StewardKit

enum SettingsPane: String, CaseIterable, Identifiable {
    case agent, budget, connectors, jobs, hotkeys, interface, permissions, memory, runs, advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .agent: "sparkles"
        case .budget: "dollarsign.circle"
        case .connectors: "point.3.connected.trianglepath.dotted"
        case .jobs: "clock.arrow.2.circlepath"
        case .hotkeys: "keyboard"
        case .interface: "paintbrush"
        case .permissions: "lock.shield"
        case .memory: "brain"
        case .runs: "list.bullet.rectangle"
        case .advanced: "wrench.and.screwdriver"
        }
    }
}

struct SettingsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @AppStorage("settings.pane") private var paneRaw = SettingsPane.agent.rawValue

    private var pane: SettingsPane { SettingsPane(rawValue: paneRaw) ?? .agent }

    var body: some View {
        ScreenScaffold(title: "Settings", subtitle: nil, scrolls: false) {
            HStack(spacing: 0) {
                VStack(spacing: 1) {
                    ForEach(SettingsPane.allCases) { item in
                        Button { select(item) } label: {
                            HStack(spacing: Space.s) {
                                Image(systemName: item.icon).font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(item == pane ? Palette.accent : Palette.textDim).frame(width: 18)
                                Text(item.title).font(item == pane ? Typo.bodyStrong : Typo.body).foregroundStyle(item == pane ? Palette.text : Palette.textDim)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, Space.s)
                            .frame(height: 28)
                            .rowSurface(selected: item == pane)
                        }
                        .buttonStyle(.pressable(.bare, haptic: false))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, Space.xl - Space.s)
                .padding(.trailing, Space.m)
                .frame(width: 196)
                Rectangle().fill(Palette.stroke).frame(width: 1).padding(.bottom, Space.l)
                Group {
                    switch pane {
                    case .agent: SettingsAgentPane()
                    case .budget: SettingsBudgetPane()
                    case .connectors: SettingsConnectorsPane()
                    case .jobs: SettingsJobsPane()
                    case .hotkeys: SettingsHotkeysPane()
                    case .interface: SettingsInterfacePane()
                    case .permissions: SettingsPermissionsPane()
                    case .memory: SettingsMemoryPane()
                    case .runs: SettingsRunsPane()
                    case .advanced: SettingsAdvancedPane()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(pane)
                .transition(.opacity)
            }
        }
        .screenKeys(model) { stroke in
            guard let next = moveSelection(stroke, in: SettingsPane.allCases, from: pane) else { return false }
            select(next)
            return true
        }
        .onAppear { if let preset = model.scenario["settings.pane"] { paneRaw = preset } }
    }

    private func select(_ item: SettingsPane) {
        withAnimation(Motion.snappy) { paneRaw = item.rawValue }
    }
}

// MARK: - Building blocks shared by the panes

/// Scrolling pane at reading width.
struct SettingsPage<Content: View>: View {
    var width: CGFloat = 720
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) { content }
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: width, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A titled card of rows with hairlines between them.
struct SettingsGroup<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title { SectionLabel(title).padding(.leading, 2) }
            VStack(spacing: 0) {
                Group(subviews: content) { subviews in
                    ForEach(Array(subviews.enumerated()), id: \.element.id) { index, subview in
                        if index > 0 { Rectangle().fill(Palette.stroke).frame(height: 1).padding(.leading, Space.m) }
                        subview
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(radius: Radius.l)
            if let footer {
                Text(footer).font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true).padding(.leading, 2)
            }
        }
    }
}

/// Label and one line of help on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var control: Control

    init(_ title: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typo.body).foregroundStyle(Palette.text)
                if let help { Text(help).font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: Space.m)
            control
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
        .frame(minHeight: 46)
    }
}

/// Boxed text field that commits on Return or blur.
struct SettingsField: View {
    let value: String
    var placeholder = ""
    var width: CGFloat = 200
    var mono = false
    var prefix: String?
    let onCommit: (String) -> Void

    var body: some View {
        HStack(spacing: 3) {
            if let prefix { Text(prefix).font(Typo.body).foregroundStyle(Palette.textFaint) }
            CommitField(placeholder: placeholder, value: value, font: mono ? Typo.mono : Typo.body, onCommit: onCommit)
        }
        .padding(.horizontal, Space.s)
        .frame(width: width, height: 26)
        .background(Palette.bgSunken.opacity(0.8), in: .continuous(Radius.s + 1))
        .overlay(RoundedRectangle.continuous(Radius.s + 1).strokeBorder(Palette.stroke, lineWidth: 1))
    }
}

struct SettingsSwitch: View {
    let isOn: Bool
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: onChange)).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
    }
}

extension AppStore {
    /// Reads a config value by dotted path ("ui.haptics").
    func setting(_ path: String) -> JSONValue {
        path.split(separator: ".").reduce(settings) { $0[String($1)] }
    }
}

enum SettingsFormat {
    /// "4m ago", "in 12m", or "never".
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        return date > now ? "in \(Fmt.since(date, now: now))" : "\(Fmt.since(date, now: now)) ago"
    }

    static func statusColor(_ status: String?) -> Color {
        switch status {
        case "ok": Palette.ok
        case "error", "failed": Palette.danger
        case "running": Palette.info
        case "interrupted", "cancelled": Palette.warn
        default: Palette.textFaint
        }
    }
}
