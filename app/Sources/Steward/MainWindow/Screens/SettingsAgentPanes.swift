import Charts
import SwiftUI
import StewardKit

// MARK: - Agent

struct SettingsAgentPane: View {
    @Environment(AppStore.self) private var store
    @State private var apiKey = ""
    @State private var notice: String?

    private static let models = ["claude-opus-5-5", "claude-fable-5-2", "claude-haiku-5-5"]

    var body: some View {
        let billing = store.setting("agent.billing").string ?? "login"
        let keySet = store.setting("secretsSet").array?.contains(.string("ANTHROPIC_API_KEY")) ?? false
        let days = Set(store.setting("user.workHours.days").array?.compactMap(\.int) ?? [1, 2, 3, 4, 5])
        SettingsPage {
            SettingsGroup("You", footer: "Connector syncs, briefs and reminders about your list keep to these hours. Sessions and meetings nudge whenever they happen.") {
                SettingsRow("Name", help: "How the agent refers to you, and how it finds you in chat, tickets and meetings.") {
                    SettingsField(value: store.setting("user.name").string ?? "", placeholder: "Your name", width: 220) { store.setSetting("user.name", .string($0)) }
                }
                SettingsRow("Work hours", help: "Local time, 24-hour. The morning brief runs at the start, the end-of-day brief half an hour before the end.") {
                    HStack(spacing: 2) {
                        ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { day, letter in
                            Button(letter) {
                                store.setSetting("user.workHours.days", .array(days.symmetricDifference([day]).sorted().map { .number(Double($0)) }))
                            }
                            .buttonStyle(.pressable(days.contains(day) ? .secondary : .ghost)).font(Typo.caption)
                            .foregroundStyle(days.contains(day) ? Palette.text : Palette.textFaint)
                        }
                    }
                    hours("user.workHours.start", fallback: "09:00")
                    Text("to").font(Typo.caption).foregroundStyle(Palette.textFaint)
                    hours("user.workHours.end", fallback: "19:00")
                }
            }
            SettingsGroup("Billing", footer: "Either way, the agent can read but never post: anything visible to other people waits for your approval.") {
                SettingsRow("How the agent runs", help: "Applies to chat, briefs and background work.") {
                    Segmented([("login", "Claude login", "person.crop.circle"), ("api", "API key", "key")],
                              selection: Binding(get: { billing }, set: { store.setSetting("agent.billing", .string($0)) }))
                }
                HStack(alignment: .top, spacing: Space.m) {
                    mode("Claude login", active: billing == "login", points: [
                        (true, "Uses the Claude Code login already on this Mac. No key needed."),
                        (true, "Can read the connectors that login has: chat, calendar, tickets, docs."),
                        (false, "Costs shown in Budget are estimates; the plan's own limits apply."),
                    ])
                    mode("API key", active: billing == "api", points: [
                        (true, "Uses your Anthropic API key, billed per token."),
                        (true, "Costs shown in Budget are what you pay."),
                        (false, "Connectors that belong to the login may be out of reach."),
                    ])
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(Space.m)
                SettingsRow("Anthropic API key", help: keySet ? "Stored in secrets.env on this Mac. It is never shown again." : "Optional with the login. Quick calls (triage, titles, recaps) use it when present.") {
                    Pill(keySet ? "Set" : "Not set", icon: keySet ? "checkmark" : nil, color: keySet ? Palette.ok : Palette.textDim)
                    SecureField(keySet ? "Replace key" : "sk-ant-…", text: $apiKey)
                        .textFieldStyle(.plain).font(Typo.mono).foregroundStyle(Palette.text)
                        .padding(.horizontal, Space.s)
                        .frame(width: 170, height: 26)
                        .background(Palette.bgSunken.opacity(0.8), in: .continuous(Radius.s + 1))
                        .overlay(RoundedRectangle.continuous(Radius.s + 1).strokeBorder(Palette.stroke, lineWidth: 1))
                        .onSubmit { saveKey(apiKey) }
                    Button("Save") { saveKey(apiKey) }.buttonStyle(.pressable(.primary)).fixedSize().disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if keySet { Button("Remove") { saveKey("") }.buttonStyle(.pressable(.danger)).fixedSize() }
                }
            }
            if let notice { InlineNotice(text: notice, icon: "exclamationmark.triangle", color: Palette.danger) }
            SettingsGroup("Models") {
                model("Main model", help: "Chat, briefs and anything you ask for.", path: "models.main")
                model("Fast model", help: "Triage, capture parsing, titles and recaps.", path: "models.fast")
                SettingsRow("Effort", help: "How hard the main model thinks before it answers. Higher costs more.") {
                    Segmented([("low", "Low", nil), ("medium", "Medium", nil), ("high", "High", nil)],
                              selection: Binding(get: { store.setting("agent.effort").string ?? "medium" }, set: { store.setSetting("agent.effort", .string($0)) }))
                }
            }
            SettingsGroup("Changing itself") {
                SettingsRow("When the agent rebuilds the app", help: "\"Always ask\" shows you every change before it is built. Otherwise only changes that start processes, open connections or touch the safety checks wait for you.") {
                    Segmented([("auto", "Ask when risky", nil), ("ask", "Always ask", nil)],
                              selection: Binding(get: { store.setting("agent.selfModify").string == "auto" ? "auto" : "ask" }, set: { store.setSetting("agent.selfModify", .string($0)) }))
                }
            }
        }
    }

    /// A time field that only saves a valid HH:MM: the brain schedules jobs from it.
    private func hours(_ path: String, fallback: String) -> some View {
        SettingsField(value: store.setting(path).string ?? fallback, placeholder: fallback, width: 62, mono: true) { text in
            if text.range(of: #"^([01]?\d|2[0-3]):[0-5]\d$"#, options: .regularExpression) != nil { store.setSetting(path, .string(text)) }
        }
    }

    private func mode(_ title: String, active: Bool, points: [(Bool, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Space.s) {
                Text(title).font(Typo.bodyStrong).foregroundStyle(active ? Palette.text : Palette.textDim)
                if active { Pill("In use", color: Palette.accent) }
            }
            ForEach(points, id: \.1) { good, text in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: good ? "checkmark" : "minus").font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(good ? Palette.ok : Palette.warn).frame(width: 10)
                    Text(text).font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(active ? Palette.accent.opacity(0.06) : Palette.bgSunken.opacity(0.5), in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(active ? Palette.accent.opacity(0.3) : Palette.stroke, lineWidth: 1))
        .animation(Motion.snappy, value: active)
    }

    private func model(_ title: String, help: String, path: String) -> some View {
        SettingsRow(title, help: help) {
            SettingsField(value: store.setting(path).string ?? "", placeholder: "model id", width: 190, mono: true) {
                if !$0.isEmpty { store.setSetting(path, .string($0)) }
            }
            MenuChip(title: "Pick") {
                ForEach(Self.models, id: \.self) { id in Button(id) { store.setSetting(path, .string(id)) } }
            }
        }
    }

    private func saveKey(_ value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = ""
        Task {
            do {
                try await store.client.setSecret(name: "ANTHROPIC_API_KEY", value: value)
                notice = nil
                store.refresh()
            } catch {
                notice = error.brief
            }
        }
    }
}

// MARK: - Budget

struct SettingsBudgetPane: View {
    @Environment(AppStore.self) private var store
    @State private var cost: CostReport?
    @State private var failure: String?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let kindColors: [Color] = [Palette.accent, Palette.info, Palette.ok, Palette.violet, Palette.warn, Palette.danger, Color(hex: 0x8BD3A0), Color(hex: 0xE59FCB)]

    var body: some View {
        let budget = store.snapshot?.budget
        let dailyCap = store.setting("budget.dailyCapUsd").double ?? budget?.dailyCapUsd ?? 0
        let monthlyCap = store.setting("budget.monthlyCapUsd").double ?? 0
        SettingsPage {
            SettingsGroup("Caps", footer: "At 80% of a cap you get a nudge. At 100% scheduled and background work stops until it resets; chat you start yourself still runs, with a warning. Runs on the Claude login are counted at list price.") {
                cap("Daily cap", help: "Resets at midnight.", spent: cost?.today ?? budget?.todayUsd ?? 0, cap: dailyCap, path: "budget.dailyCapUsd")
                cap("Monthly cap", help: "Resets on the 1st.", spent: cost?.month ?? budget?.monthUsd ?? 0, cap: monthlyCap, path: "budget.monthlyCapUsd")
            }
            if let failure { InlineNotice(text: failure, icon: "exclamationmark.triangle", color: Palette.danger) }
            if let cost {
                let days = cost.byDay.compactMap { day in Self.dayFormat.date(from: day.day).map { (date: $0, usd: day.usd) } }
                let total = cost.byDay.reduce(0) { $0 + $1.usd }
                Card(title: "Last 30 days") {
                    Text("\(Fmt.usd(total)) total · \(Fmt.usd(total / Double(max(1, cost.byDay.count)))) a day")
                        .font(Typo.caption).foregroundStyle(Palette.textDim)
                } content: {
                    if days.isEmpty {
                        Text("No agent runs in the last 30 days.").font(Typo.caption).foregroundStyle(Palette.textFaint).frame(height: 60)
                    } else {
                        chart(days, series: cost.byDayKind, kinds: cost.byKind.map(\.kind), cap: dailyCap)
                    }
                }
                Card(title: "By kind") {
                    Text("same 30 days").font(Typo.caption).foregroundStyle(Palette.textFaint)
                } content: {
                    kinds(cost.byKind)
                }
            } else if failure == nil {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 120)
            }
        }
        .task(id: "\(store.changes[.budget] ?? 0)-\(store.connection.isOnline)") {
            guard store.connection.isOnline else { return }
            do {
                cost = try await store.client.cost(days: 30)
                failure = nil
            } catch {
                failure = error.brief
            }
        }
    }

    private func cap(_ title: String, help: String, spent: Double, cap: Double, path: String) -> some View {
        let used = cap > 0 ? spent / cap : 0
        return SettingsRow(title, help: help) {
            VStack(alignment: .trailing, spacing: 5) {
                Text("\(Fmt.usd(spent)) of \(Fmt.usd(cap))").font(Typo.numeric).foregroundStyle(used >= 1 ? Palette.danger : Palette.textDim)
                Meter(fraction: used, color: used >= 1 ? Palette.danger : used >= 0.8 ? Palette.warn : Palette.ok, height: 4).frame(width: 150)
            }
            SettingsField(value: cap == cap.rounded() ? String(Int(cap)) : String(cap), placeholder: "0", width: 72, prefix: "$") { text in
                if let value = Double(text.replacingOccurrences(of: "$", with: "")), value >= 0 { store.setSetting(path, .number(value)) }
            }
        }
    }

    /// One bar per day, stacked by kind in the colours of the "By kind" legend below it.
    private func chart(_ days: [(date: Date, usd: Double)], series: [CostReport.DayKind], kinds: [String], cap: Double) -> some View {
        let peak = max(days.map(\.usd).max() ?? 0, cap)
        let color = Dictionary(kinds.enumerated().map { ($1, Self.kindColors[$0 % Self.kindColors.count]) }, uniquingKeysWith: { a, _ in a })
        let slices = series.compactMap { row in Self.dayFormat.date(from: row.day).map { (date: $0, kind: row.kind, usd: row.usd) } }
        return Chart {
            ForEach(Array(slices.enumerated()), id: \.offset) { _, slice in
                BarMark(x: .value("Day", slice.date, unit: .day), y: .value("Spend", slice.usd), width: .ratio(0.7))
                    .foregroundStyle((color[slice.kind] ?? Palette.accent).opacity(Calendar.current.isDateInToday(slice.date) ? 1 : 0.75))
            }
            if cap > 0 {
                RuleMark(y: .value("Daily cap", cap))
                    .foregroundStyle(Palette.textFaint)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .trailing, spacing: 2) {
                        Text("daily cap \(Fmt.usd(cap))").font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint)
                    }
            }
        }
        .chartYScale(domain: 0...(peak * 1.18))
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Palette.stroke)
                AxisValueLabel { Text("$\(Int(value.as(Double.self) ?? 0))").font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint) }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                AxisValueLabel(format: .dateTime.day().month(.abbreviated)).font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint)
            }
        }
        .frame(height: 150)
        .padding(.top, Space.s)
    }

    @ViewBuilder private func kinds(_ kinds: [CostReport.Kind]) -> some View {
        let total = kinds.reduce(0) { $0 + $1.usd }
        if kinds.isEmpty || total <= 0 {
            Text("Nothing spent yet.").font(Typo.caption).foregroundStyle(Palette.textFaint)
        } else {
            let colored = kinds.enumerated().map { (kind: $1, color: Self.kindColors[$0 % Self.kindColors.count]) }
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(colored, id: \.kind.kind) { item in
                        Rectangle().fill(item.color).frame(width: max(2, (geo.size.width - CGFloat(kinds.count) * 1.5) * item.kind.usd / total))
                            .help("\(item.kind.kind): \(Fmt.usd(item.kind.usd))")
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: 6) {
                ForEach(colored, id: \.kind.kind) { item in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle.continuous(2).fill(item.color).frame(width: 9, height: 9)
                            Text(item.kind.kind).font(Typo.body).foregroundStyle(Palette.text)
                        }
                        Text(Self.explain(item.kind.kind)).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        Text(Fmt.usd(item.kind.usd)).font(Typo.numeric).foregroundStyle(Palette.textDim).gridColumnAlignment(.trailing)
                        Text("\(Int((item.kind.usd / total * 100).rounded()))%").font(Typo.numeric).foregroundStyle(Palette.textFaint).gridColumnAlignment(.trailing)
                    }
                }
            }
            .padding(.top, Space.xs)
        }
    }

    static func explain(_ kind: String) -> String {
        if kind.hasPrefix("sync:") { return "reading \(kind.dropFirst(5))" }
        if kind.hasPrefix("brief:"), kind != "brief:prep" { return "the \(kind.dropFirst(6)) brief" }
        if kind.hasPrefix("job:") { return "a job the agent scheduled" }
        switch kind {
        case "chat": return "conversations you start"
        case "brief:prep": return "meeting prep notes"
        case "title": return "naming sessions and chats"
        case "onboarding-scan": return "the one-off scan that learns about you"
        case "memory-digest": return "folding the day into memory"
        case "approval": return "carrying out what you approved"
        case "bridge", "bridge:schema": return "connector reads relayed for chat"
        case "brief": return "morning, evening and pre-meeting briefs"
        case "triage": return "turning signals into suggestions"
        case "recap": return "session recaps"
        case "capture": return "parsing captures into tasks"
        case "self": return "editing the app"
        default: return ""
        }
    }
}

// MARK: - Connectors

struct SettingsConnectorsPane: View {
    @Environment(AppStore.self) private var store

    private static let about: [String: (icon: String, what: String)] = [
        "chat": ("bubble.left.and.bubble.right", "Mentions, direct messages and threads you are in"),
        "calendar": ("calendar", "Events, attendees and join links"),
        "tickets": ("ticket", "Tickets assigned to you or that you watch"),
        "meetings": ("person.2.wave.2", "Summaries, action items and recordings"),
        "docs": ("doc.text", "Docs you wrote or were mentioned in"),
        "messages": ("message", "Local messages on this Mac (needs Full Disk Access)"),
        "browser": ("safari", "The tabs you spend time in"),
        "github": ("arrow.triangle.branch", "Your open pull requests, through the gh CLI on this Mac"),
        "badges": ("app.badge", "Dock badge counts, so a sync is skipped when nothing new arrived"),
    ]

    var body: some View {
        let config = store.setting("connectors").object ?? [:]
        let health = store.snapshot?.health
        // Health also reports the agent and each server of the login; only the configurable sources get a row with a switch.
        let names = config.keys.sorted()
        let servers = (health?.connectors ?? [:]).filter { $0.key.hasPrefix("connector:") }.sorted { $0.key < $1.key }
        let relay = store.setting("agent.connectors").string == "bridge"
        SettingsPage {
            SettingsGroup("Connectors", footer: "Connectors only read. They run on the cheap model, on a timer, and turn what they find into suggestions in the Inbox.") {
                if names.isEmpty {
                    Text(store.connection.isOnline ? "No connectors configured." : "Connect to the brain to see connectors.")
                        .font(Typo.caption).foregroundStyle(Palette.textFaint).padding(Space.m)
                }
                ForEach(names, id: \.self) { name in
                    let enabled = config[name]?["enabled"].bool ?? false
                    let state = enabled ? (health?.connectors[name] ?? .unknown) : .off
                    HStack(spacing: Space.m) {
                        Image(systemName: Self.about[name]?.icon ?? "point.3.connected.trianglepath.dotted").font(.system(size: 13))
                            .foregroundStyle(enabled ? Palette.text : Palette.textFaint).frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.s) {
                                Text(name.capitalized).font(Typo.body).foregroundStyle(enabled ? Palette.text : Palette.textDim)
                                Pill(Self.label(state), color: Self.color(state))
                            }
                            Text(Self.about[name]?.what ?? "").font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
                        }
                        Spacer(minLength: Space.s)
                        if enabled {
                            Text(health?.lastSyncAt[name].map { "synced \(Fmt.since($0)) ago" } ?? "not synced yet")
                                .font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                        }
                        if let every = config[name]?["everyMin"].int {
                            MenuChip(title: "every \(Fmt.span(Double(every) * 60))", icon: "clock") {
                                ForEach([5, 15, 30, 60, 240, 720], id: \.self) { minutes in
                                    Button("Every \(Fmt.span(Double(minutes) * 60))") { store.setSetting("connectors.\(name).everyMin", .number(Double(minutes))) }
                                }
                            }
                            .disabled(!enabled)
                            .opacity(enabled ? 1 : 0.5)
                        }
                        SettingsSwitch(isOn: enabled) { store.setSetting("connectors.\(name).enabled", .bool($0)) }
                    }
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 10)
                }
            }
            if names.contains(where: { health?.connectors[$0] == .error }) {
                InlineNotice(text: "A connector in error usually means the Claude login can't reach it right now. The agent keeps working with the others.",
                             icon: "exclamationmark.triangle", color: Palette.warn)
            }
            SettingsGroup("In chat") {
                SettingsRow("How chat reads connectors", help: relay
                    ? "Relay: each read goes through a small fast-model run. About a third fewer tokens per chat turn, a little slower per lookup."
                    : "Direct: the chat agent holds the connector tools itself. Fastest lookups, more tokens on every turn.") {
                    Segmented([("native", "Direct", nil), ("bridge", "Relay", nil)],
                              selection: Binding(get: { relay ? "bridge" : "native" }, set: { store.setSetting("agent.connectors", .string($0)) }))
                }
            }
            SettingsGroup("Your Claude login", footer: "These are the servers the Claude Code login on this Mac exposes. Add or remove them in Claude; Steward only reads through them.") {
                SettingsRow("Login", help: "Chat, briefs and syncs run on it unless billing is set to an API key.") {
                    let state = health?.connectors["agent:login"] ?? .unknown
                    Pill(state == .ok ? "Signed in" : state == .error ? "Not working" : "Not checked yet", color: Self.color(state))
                }
                if servers.isEmpty {
                    Text(store.connection.isOnline ? "No connector servers found yet. They are listed a few seconds after the brain starts." : "Connect to the brain to see them.")
                        .font(Typo.caption).foregroundStyle(Palette.textFaint).padding(Space.m)
                } else {
                    Flow(spacing: 6) {
                        ForEach(servers, id: \.key) { server in
                            Pill(String(server.key.dropFirst("connector:".count)), icon: server.value == .ok ? "checkmark" : "exclamationmark.triangle", color: Self.color(server.value))
                        }
                    }
                    .padding(Space.m)
                }
            }
        }
    }

    static func label(_ health: ConnectorHealth) -> String {
        switch health {
        case .ok: "Healthy"
        case .error: "Error"
        case .off: "Off"
        case .unknown: "No data yet"
        }
    }

    static func color(_ health: ConnectorHealth) -> Color {
        switch health {
        case .ok: Palette.ok
        case .error: Palette.danger
        case .off: Palette.textFaint
        case .unknown: Palette.textDim
        }
    }
}
