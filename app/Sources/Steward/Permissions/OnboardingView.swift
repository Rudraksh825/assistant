import SwiftUI
import StewardKit

/// The permission list: status, why it helps, and a button to grant. Used by onboarding and Settings.
struct PermissionsList: View {
    @State private var statuses: [Permission: Permission.Status] = [:]

    var body: some View {
        VStack(spacing: Space.xs) {
            ForEach(Permission.allCases) { permission in
                HStack(alignment: .top, spacing: Space.m) {
                    Image(systemName: permission.icon).font(.system(size: 14)).foregroundStyle(Palette.textDim).frame(width: 22, height: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title).font(Typo.bodyStrong).foregroundStyle(Palette.text)
                        Text(permission.why).font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.m)
                    switch statuses[permission] {
                    case .granted:
                        Pill("Granted", icon: "checkmark", color: Palette.ok)
                    case .denied:
                        Button("Open Settings") { permission.openSettings() }.buttonStyle(.pressable())
                    default:
                        Button("Allow") {
                            Task {
                                await permission.request()
                                await refresh()
                            }
                        }
                        .buttonStyle(.pressable())
                    }
                }
                .padding(.vertical, Space.s)
            }
        }
        .task {
            // Grants happen in System Settings, outside the app, so poll while visible.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func refresh() async {
        for permission in Permission.allCases { statuses[permission] = await permission.status() }
    }
}

/// First run: what Steward is, how to reach it, what the agent needs, the one-off scan, and the optional permissions.
struct OnboardingView: View {
    let onDone: () -> Void

    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @State private var scan: ScanState = .idle

    private enum ScanState: Equatable { case idle, started, failed(String) }

    private static let what: [(icon: String, text: String)] = [
        ("list.number", "Keeps one ranked list of what to do next, from what you capture and what it notices."),
        ("tray.and.arrow.down", "Watches your Claude Code sessions, calendar, chat and tickets, and proposes tasks in the Inbox. You accept or dismiss."),
        ("sparkles", "Runs an agent you can ask anything. It reads freely; anything other people would see waits for your approval."),
    ]
    private static let hotkeys: [(name: String, what: String)] = [
        ("capture", "Capture a thought from any app"),
        ("agent", "Ask the agent"),
        ("voice", "Hold to talk instead of typing"),
        ("notch", "Open the panel under the notch"),
        ("hud", "Show or hide the floating HUD"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Welcome to Steward").font(Typo.display).foregroundStyle(Palette.text)
                        ForEach(Self.what, id: \.text) { line in
                            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                                Image(systemName: line.icon).font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.accent).frame(width: 18)
                                Text(line.text).font(Typo.body).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    section("From anywhere") {
                        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: 6) {
                            ForEach(Self.hotkeys, id: \.name) { hotkey in
                                if let combo = store.setting("hotkeys.\(hotkey.name)").string?.nonEmpty ?? app.hotkeys.combos[hotkey.name]?.nonEmpty {
                                    GridRow {
                                        KeyHint(HotkeyCombo.display(combo)).gridColumnAlignment(.trailing)
                                        Text(hotkey.what).font(Typo.body).foregroundStyle(Palette.text)
                                    }
                                }
                            }
                        }
                        Text("Change them in Settings, Hotkeys.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                    }
                    section("The agent") {
                        Text("It runs on the Claude Code login already on this Mac, so there is nothing to set up. An Anthropic API key is optional: with one (Settings, Agent), small background calls are billed to the key instead of drawing on your plan. With neither, tasks, capture, the session radar and nudges still work; chat, briefs and connector syncs do not.")
                            .font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                        if let issue = store.agentIssue {
                            InlineNotice(text: issue, icon: "exclamationmark.triangle", color: Palette.warn)
                        }
                    }
                    section("Learn about my work") {
                        HStack(alignment: .top, spacing: Space.m) {
                            Text("One scan of your recent sessions, tickets, meetings and chat proposes your projects, people and first tasks. Nothing is created until you accept it in the Inbox. It takes a few minutes on the main model and costs about $1\u{2060}–\u{2060}2. You can also run it later from Settings, Jobs.")
                                .font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if scan == .started {
                                Pill("Started", icon: "checkmark", color: Palette.ok)
                            } else {
                                Button("Run the scan") { runScan() }.buttonStyle(.pressable()).fixedSize()
                                    .disabled(!store.connection.isOnline || store.agentIssue != nil)
                            }
                        }
                        if scan == .started {
                            Text("The proposals land in the Inbox, with a note summing up what it learned.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                        } else if case .failed(let why) = scan {
                            InlineNotice(text: why, icon: "exclamationmark.triangle", color: Palette.warn)
                        } else if !store.connection.isOnline {
                            Text("Waiting for the brain to start.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                        }
                    }
                    section("Permissions, all optional") {
                        Text("Steward works without any of them. Each one adds what its line says, and you can change them later in Settings.")
                            .font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                        PermissionsList()
                    }
                }
                .padding(Space.xl)
            }
            Rectangle().fill(Palette.stroke).frame(height: 1)
            HStack {
                Text("Show this again from Settings, Advanced.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                Spacer()
                Button("Done", action: onDone).buttonStyle(.pressable(.primary)).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Space.xl)
            .padding(.vertical, Space.m)
        }
        .frame(width: 580)
        .frame(maxHeight: 660)
        .background(Palette.bg)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel(title)
            content()
        }
    }

    private func runScan() {
        Task {
            do {
                try await store.client.runJob("onboarding-scan")
                withAnimation(Motion.snappy) { scan = .started }
            } catch BrainError.http(409, _, _) {
                withAnimation(Motion.snappy) { scan = .started }
            } catch {
                withAnimation(Motion.snappy) { scan = .failed(error.brief) }
            }
        }
    }
}
