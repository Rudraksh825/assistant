import AppKit
import SwiftUI
import StewardKit

// MARK: - Jobs

struct SettingsJobsPane: View {
    @Environment(AppStore.self) private var store
    @State private var jobs: [Job] = []
    @State private var loaded = false
    /// Jobs started from here, shown as running until the brain's list catches up.
    @State private var started: Set<String> = []
    @State private var notice: String?

    var body: some View {
        let onboarding = jobs.first { $0.name.contains("onboarding") }
        let scheduled = jobs.filter { $0.name != onboarding?.name }
        SettingsPage {
            if let onboarding {
                Card("One-off") {
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(alignment: .top, spacing: Space.m) {
                            Image(systemName: "sparkle.magnifyingglass").font(.system(size: 20, weight: .light)).foregroundStyle(Palette.violet).frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Onboarding scan").font(Typo.bodyStrong).foregroundStyle(Palette.text)
                                Text("Reads your recent coding sessions, calendar and connected tools once, then proposes projects, people and first tasks. Nothing is created without you: the proposals land in the Inbox. Runs on the main model for a few minutes and costs about $1–2.")
                                    .font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                                Text(onboarding.lastRunAt == nil ? "Never run." : "Last run \(SettingsFormat.relative(onboarding.lastRunAt)), \(onboarding.lastStatus ?? "unknown").")
                                    .font(Typo.caption).foregroundStyle(Palette.textFaint)
                            }
                            Spacer(minLength: Space.s)
                            runButton(onboarding, title: onboarding.lastRunAt == nil ? "Run scan" : "Run again", primary: onboarding.lastRunAt == nil)
                        }
                    }
                }
            }
            if let notice { InlineNotice(text: notice, icon: "info.circle", color: Palette.warn) }
            SettingsGroup("Scheduled", footer: "Background jobs stop when a budget cap is reached and pick up again when it resets.") {
                if scheduled.isEmpty {
                    Text(loaded ? "The brain has no scheduled jobs yet." : "Loading…").font(Typo.caption).foregroundStyle(Palette.textFaint).padding(Space.m)
                }
                ForEach(scheduled) { job in
                    HStack(spacing: Space.m) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.name).font(.system(size: 12.5, weight: .medium, design: .monospaced)).foregroundStyle(job.enabled ? Palette.text : Palette.textDim)
                            scheduleControl(job)
                        }
                        Spacer(minLength: Space.s)
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(SettingsFormat.relative(job.lastRunAt)).font(Typo.caption).foregroundStyle(Palette.textDim)
                                if let status = job.lastStatus { Pill(status, color: SettingsFormat.statusColor(status)) }
                            }
                            if let next = job.nextRunAt { Text("next \(SettingsFormat.relative(next))").font(Typo.caption).foregroundStyle(Palette.textFaint) }
                        }
                        .frame(minWidth: 130, alignment: .trailing)
                        runButton(job, title: "Run now", primary: false).frame(width: 84, alignment: .trailing)
                        SettingsSwitch(isOn: job.enabled) { update(job, enabled: $0) }
                            .help(job.enabled ? "Stop running this on its schedule. Run now still works." : "Run this on its schedule again.")
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 9)
                }
            }
        }
        .task(id: "\(store.changes[.jobs] ?? 0)-\(store.connection.isOnline)") {
            // Jobs finish on their own time; poll while the pane is open.
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    @ViewBuilder private func runButton(_ job: Job, title: String, primary: Bool) -> some View {
        if job.running || started.contains(job.name) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                Text("Running").font(Typo.caption).foregroundStyle(Palette.info)
            }
        } else {
            Button(title) { run(job) }.buttonStyle(.pressable(primary ? .primary : .secondary)).fixedSize().disabled(!store.connection.isOnline)
        }
    }

    /// The schedule as a control: a period menu for interval jobs, a time field for daily ones.
    @ViewBuilder private func scheduleControl(_ job: Job) -> some View {
        HStack(spacing: 6) {
            if let every = job.scheduleSpec?.everyMin {
                MenuChip(title: job.schedule, icon: "clock", active: job.customSchedule) {
                    ForEach([1, 5, 10, 15, 30, 60, 120, 360, 720], id: \.self) { minutes in
                        Button("Every \(Fmt.span(Double(minutes) * 60))") { update(job, schedule: .some(.init(everyMin: minutes))) }.disabled(minutes == every)
                    }
                    if job.customSchedule {
                        Divider()
                        Button("Back to the default") { update(job, schedule: .some(nil)) }
                    }
                }
            } else if let at = job.scheduleSpec?.at {
                SettingsField(value: at, placeholder: "HH:MM", width: 62, mono: true) { text in
                    if text != at { update(job, schedule: .some(.init(at: text, days: job.scheduleSpec?.days))) }
                }
                .help("Local time, 24-hour. The days stay as they are.")
                Text(job.schedule.split(separator: " ").dropFirst().joined(separator: " ")).font(Typo.caption).foregroundStyle(Palette.textDim)
                if job.customSchedule {
                    Button("Default") { update(job, schedule: .some(nil)) }.buttonStyle(.pressable(.ghost)).font(Typo.caption).fixedSize()
                        .help("Go back to the time derived from your work hours")
                }
            } else {
                Text(job.schedule).font(Typo.caption).foregroundStyle(Palette.textDim)
            }
            if !job.enabled { Text("off").font(Typo.caption).foregroundStyle(Palette.textFaint) }
        }
        .opacity(job.enabled ? 1 : 0.6)
    }

    private func update(_ job: Job, enabled: Bool? = nil, schedule: Job.Schedule?? = nil) {
        notice = nil
        Task {
            do {
                let saved = try await store.client.updateJob(job.name, enabled: enabled, schedule: schedule)
                withAnimation(Motion.snappy) { if let i = jobs.firstIndex(where: { $0.name == saved.name }) { jobs[i] = saved } }
            } catch {
                notice = error.brief
            }
        }
    }

    private func load() async {
        guard store.connection.isOnline, let list = try? await store.client.jobs() else { return }
        withAnimation(Motion.snappy) {
            jobs = list
            started.formIntersection(list.filter(\.running).map(\.name))
        }
        loaded = true
    }

    private func run(_ job: Job) {
        started.insert(job.name)
        notice = nil
        Task {
            do {
                try await store.client.runJob(job.name)
            } catch BrainError.http(409, _, _) {
                notice = "\(job.name) is already running."
            } catch {
                started.remove(job.name)
                notice = error.brief
            }
            try? await Task.sleep(for: .seconds(1))
            await load()
        }
    }
}

// MARK: - Hotkeys

struct SettingsHotkeysPane: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var recording: String?

    private static let about: [(name: String, title: String, help: String)] = [
        ("capture", "Quick capture", "Opens the capture field from anywhere."),
        ("agent", "Quick chat", "Opens the floating chat with the agent, with your last conversation in it."),
        ("voice", "Voice", "Hold to talk, release to send."),
        ("hud", "HUD", "Shows or hides the floating HUD."),
        ("notch", "Notch panel", "Expands or collapses the notch."),
    ]

    var body: some View {
        // Config wins over what is registered, so a just-recorded combo shows at once.
        let configured = store.setting("hotkeys").object?.compactMapValues(\.string) ?? [:]
        let combos = app.hotkeys.combos.merging(configured) { _, new in new }
        let known = Self.about.map(\.name)
        let rows = Self.about + combos.keys.filter { !known.contains($0) }.sorted().map { (name: $0, title: $0.capitalized, help: "") }
        SettingsPage {
            SettingsGroup("Global hotkeys", footer: "These work in every app. Click Record, then press the combination: at least one of ⌃ ⌥ ⌘ plus a key. Esc cancels, ⌫ turns the hotkey off.") {
                ForEach(rows, id: \.name) { row in
                    SettingsRow(row.title, help: app.hotkeys.failures[row.name].map { "Not active: \($0)." } ?? row.help.nonEmpty) {
                        if recording == row.name {
                            Pill("Press a combination…", icon: "record.circle", color: Palette.accent)
                            Button("Cancel") { stop() }.buttonStyle(.pressable(.ghost)).fixedSize()
                        } else {
                            let combo = combos[row.name] ?? ""
                            if combo.isEmpty {
                                Text("Off").font(Typo.caption).foregroundStyle(Palette.textFaint)
                            } else {
                                KeyHint(HotkeyCombo.display(combo))
                                if app.hotkeys.failures[row.name] != nil {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(Palette.danger)
                                }
                            }
                            Button("Record") { record(row.name) }.buttonStyle(.pressable()).fixedSize()
                        }
                    }
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private func record(_ name: String) {
        withAnimation(Motion.snappy) { recording = name }
        model.recorder = { stroke in
            if stroke.plain(.escape) { return stop() }
            if stroke.plain(.delete) { return set(name, "") }
            // Shift alone would swallow ordinary typing system-wide.
            guard !stroke.mods.intersection([.control, .option, .command]).isEmpty,
                  let combo = stroke.hotkeyString, HotkeyCombo.parse(combo) != nil else { return }
            set(name, combo)
        }
    }

    private func set(_ name: String, _ combo: String) {
        Haptics.thunk()
        store.setSetting("hotkeys.\(name)", .string(combo))
        stop()
    }

    private func stop() {
        model.recorder = nil
        withAnimation(Motion.snappy) { recording = nil }
    }
}

// MARK: - Interface

struct SettingsInterfacePane: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var design = DesignSettings.shared
        let hud = store.setting("ui.hudDisplay").string ?? "auto"
        SettingsPage {
            SettingsGroup("Feel") {
                toggle("Haptics", help: "A trackpad tick when you complete, accept or snap something into place.", path: "ui.haptics", fallback: true)
                toggle("Sounds", help: "A quiet sound with toasts that need you.", path: "ui.sounds", fallback: false)
                toggle("Speak replies", help: "Reads the answer aloud when you ask by voice. Off shows it as a toast instead.", path: "ui.speakReplies", fallback: true)
                SettingsRow("Reduce motion", help: "Stops looping animations such as the pulse on a waiting session.") {
                    SettingsSwitch(isOn: design.reduceMotion) {
                        design.reduceMotion = $0
                        UserDefaults.standard.set($0, forKey: "ui.reduceMotion")
                    }
                }
            }
            SettingsGroup("Surfaces") {
                SettingsRow("Panels", help: "Glass uses the system's translucent material; Solid is opaque and easier to read over busy windows.") {
                    Segmented([(MaterialStyle.glass, "Glass", nil), (MaterialStyle.solid, "Solid", nil)],
                              selection: Binding(get: { design.materialStyle }, set: {
                                  design.materialStyle = $0
                                  UserDefaults.standard.set($0.rawValue, forKey: "ui.materialStyle")
                              }))
                }
                toggle("Notch on every display", help: "Shows a notch-shaped pill at the top of displays that have no notch.", path: "ui.notchOnAllDisplays", fallback: true)
                SettingsRow("HUD display", help: "Which display the floating HUD lives on. Automatic keeps it where you last dragged it.") {
                    MenuChip(title: hud == "auto" ? "Automatic" : hud, icon: "display", active: hud != "auto") {
                        Button("Automatic") { store.setSetting("ui.hudDisplay", "auto") }
                        Divider()
                        ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { name in
                            Button(name) { store.setSetting("ui.hudDisplay", .string(name)) }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ title: String, help: String, path: String, fallback: Bool) -> some View {
        SettingsRow(title, help: help) {
            SettingsSwitch(isOn: store.setting(path).bool ?? fallback) { store.setSetting(path, .bool($0)) }
        }
    }
}

// MARK: - Permissions

struct SettingsPermissionsPane: View {
    var body: some View {
        SettingsPage {
            Text("Everything here is optional. Steward runs without any of it; each permission only unlocks what its line says.")
                .font(Typo.body).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
            Card { PermissionsList() }
        }
    }
}

// MARK: - Runs

struct SettingsRunsPane: View {
    @Environment(AppStore.self) private var store
    @State private var runs: [AgentRun] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.m) {
                Text("Every model call the agent made, newest first.").font(Typo.body).foregroundStyle(Palette.textDim)
                Spacer()
                if !runs.isEmpty {
                    Text("\(runs.count) runs · \(Fmt.usd(runs.reduce(0) { $0 + $1.costUsd }))").font(Typo.numeric).foregroundStyle(Palette.textFaint)
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.m)
            header
            if runs.isEmpty {
                if loaded {
                    EmptyState(icon: "list.bullet.rectangle", title: "No runs yet", message: "Chat, briefs, triage and syncs show up here with their tokens and cost.")
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(runs) { run in row(run) }
                    }
                    .padding(.horizontal, Space.xl - Space.s)
                    .padding(.bottom, Space.xl)
                }
            }
        }
        .task(id: "\(store.changes[.budget] ?? 0)-\(store.connection.isOnline)") {
            guard store.connection.isOnline, let list = try? await store.client.runs(limit: 100) else { return }
            runs = list
            loaded = true
        }
    }

    private enum Col {
        static let time: CGFloat = 104, trigger: CGFloat = 72, model: CGFloat = 78, status: CGFloat = 58, tokens: CGFloat = 86, cost: CGFloat = 54, billing: CGFloat = 40
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            head("When", Col.time)
            Text("RUN").font(Typo.label).kerning(0.5).foregroundStyle(Palette.textFaint).frame(maxWidth: .infinity, alignment: .leading)
            head("Trigger", Col.trigger)
            head("Model", Col.model)
            head("Status", Col.status)
            head("Tokens", Col.tokens, .trailing).help("Input / output")
            head("Cost", Col.cost, .trailing)
            head("Via", Col.billing)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: 26)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }

    private func head(_ title: String, _ width: CGFloat, _ alignment: Alignment = .leading) -> some View {
        Text(title.uppercased()).font(Typo.label).kerning(0.5).foregroundStyle(Palette.textFaint).lineLimit(1).frame(width: width, alignment: alignment)
    }

    private func row(_ run: AgentRun) -> some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(Fmt.time(run.startedAt)).font(Typo.numeric).foregroundStyle(Palette.textDim)
                if !Calendar.current.isDateInToday(run.startedAt) { Text(Fmt.day(run.startedAt)).font(Typo.caption).foregroundStyle(Palette.textFaint) }
            }
            .lineLimit(1)
            .frame(width: Col.time, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.kind).font(Typo.mono).foregroundStyle(Palette.text)
                if let summary = run.summary?.nonEmpty {
                    Text(summary).font(Typo.caption).foregroundStyle(run.status == .error ? Palette.danger : Palette.textDim).help(summary)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(run.trigger.rawValue).font(Typo.caption).foregroundStyle(Palette.textDim).frame(width: Col.trigger, alignment: .leading)
            Text(run.model.replacingOccurrences(of: "claude-", with: "")).font(Typo.mono).foregroundStyle(Palette.textDim).lineLimit(1).frame(width: Col.model, alignment: .leading).help(run.model)
            HStack(spacing: 5) {
                Circle().fill(SettingsFormat.statusColor(run.status.rawValue)).frame(width: 6, height: 6)
                Text(run.status.rawValue).font(Typo.caption).foregroundStyle(run.status == .error ? Palette.danger : Palette.textDim)
            }
            .frame(width: Col.status, alignment: .leading)
            Text("\(run.inputTokens.formatted(.number.notation(.compactName))) / \(run.outputTokens.formatted(.number.notation(.compactName)))")
                .font(Typo.numeric).foregroundStyle(Palette.textDim).frame(width: Col.tokens, alignment: .trailing)
            Text(run.costUsd < 0.01 && run.costUsd > 0 ? "<$0.01" : Fmt.usd(run.costUsd)).font(Typo.numeric).foregroundStyle(Palette.text).frame(width: Col.cost, alignment: .trailing)
            Text(run.billing.rawValue).font(Typo.caption).foregroundStyle(Palette.textFaint).frame(width: Col.billing, alignment: .leading)
        }
        .padding(.horizontal, Space.s)
        .frame(height: 40)
        .rowSurface(radius: Radius.s)
    }
}

// MARK: - Advanced

struct SettingsAdvancedPane: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app

    private enum Rebuild: Equatable { case idle, confirming, running, done(ok: Bool, log: String) }
    @State private var rebuild = Rebuild.idle

    var body: some View {
        let dir = store.client.dataDir.url
        SettingsPage {
            SettingsGroup("Brain") {
                SettingsRow("Status", help: statusHelp) {
                    Circle().fill(store.connection.isOnline ? Palette.ok : Palette.warn).frame(width: 7, height: 7)
                    Text(statusText).font(Typo.body).foregroundStyle(store.connection.isOnline ? Palette.text : Palette.warn)
                    if !store.connection.isOnline { Button("Retry") { store.refresh() }.buttonStyle(.pressable()).fixedSize() }
                }
                SettingsRow("Data folder", help: (dir.path as NSString).abbreviatingWithTildeInPath) {
                    Button("Reveal in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
                        .buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                }
            }
            SettingsGroup("App", footer: "Config, the database, memory and logs all live in the data folder; nothing personal is kept in the app or its repo.") {
                SettingsRow("Rebuild app", help: "Builds the brain and the app from this checkout, then relaunches into the new build. The previous build is kept as a fallback.") {
                    switch rebuild {
                    case .idle, .done:
                        Button("Rebuild…") { withAnimation(Motion.snappy) { rebuild = .confirming } }.buttonStyle(.pressable()).fixedSize().disabled(!store.connection.isOnline)
                    case .confirming:
                        Text("Rebuild and relaunch?").font(Typo.caption).foregroundStyle(Palette.textDim)
                        Button("Cancel") { withAnimation(Motion.snappy) { rebuild = .idle } }.buttonStyle(.pressable(.ghost)).fixedSize()
                        Button("Rebuild", action: runRebuild).buttonStyle(.pressable(.primary)).fixedSize()
                    case .running:
                        ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 14, height: 14)
                        Text("Building… this takes a minute").font(Typo.caption).foregroundStyle(Palette.info)
                    }
                }
                if case .done(let ok, let log) = rebuild {
                    VStack(alignment: .leading, spacing: Space.s) {
                        InlineNotice(text: ok ? "Build finished. The app relaunches on its own." : "The rebuild did not run. The agent runtime may be unavailable.",
                                     icon: ok ? "checkmark.circle" : "exclamationmark.triangle", color: ok ? Palette.ok : Palette.warn)
                        if !log.isEmpty {
                            ScrollView {
                                Text(log).font(Typo.mono).foregroundStyle(Palette.textDim).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(Space.s)
                            }
                            .frame(maxHeight: 150)
                            .background(Palette.bgSunken, in: .continuous(Radius.s))
                        }
                    }
                    .padding(Space.m)
                }
                SettingsRow("Welcome screen", help: "Shows the first-run introduction again: hotkeys, the scan, permissions.") {
                    Button("Show") { withAnimation(Motion.snappy) { app.showOnboarding = true } }.buttonStyle(.pressable()).fixedSize()
                }
            }
        }
    }

    private var statusText: String {
        switch store.connection {
        case .online: "Connected"
        case .connecting: "Connecting…"
        case .offline: "Offline"
        }
    }

    private var statusHelp: String {
        switch store.connection {
        case .online: "Version \(store.brainVersion ?? "unknown"), on port \(store.client.dataDir.port.map(String.init) ?? "?"), local to this Mac."
        case .connecting: "Waiting for the brain to answer."
        case .offline(let why): store.brainNote ?? why
        }
    }

    private func runRebuild() {
        rebuild = .running
        Task {
            do {
                let result = try await store.client.rebuildApp()
                withAnimation(Motion.snappy) { rebuild = .done(ok: result.ok, log: result.log) }
            } catch {
                withAnimation(Motion.snappy) { rebuild = .done(ok: false, log: error.brief) }
            }
        }
    }
}
