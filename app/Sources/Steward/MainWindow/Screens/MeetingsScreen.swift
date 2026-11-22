import SwiftUI
import StewardKit

/// What is coming up (with prep) and what just happened (with action items that become tasks in one click).
struct MeetingsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model
    @State private var selection: String?
    @State private var fetched: [Meeting]?
    /// Action items turned into tasks this session, as "meetingId#title", so the tick shows before the refetch lands.
    @State private var added: Set<String> = []

    var body: some View {
        Live(every: 30) { now in content(now) }
            .task(id: store.changes[.meetings]) {
                if let list = try? await store.client.meetings(from: Date().addingTimeInterval(-21 * 86_400), to: Date()) { fetched = list }
            }
            .task(id: store.changes[.tasks]) { await model.library.refresh() }
            .onAppear {
                if let preset = model.scenario["meetings.selected"] { selection = preset }
                takeFocus()
            }
            .onChange(of: model.focusMeetingId) { takeFocus() }
    }

    private func takeFocus() {
        guard let id = model.focusMeetingId else { return }
        selection = id
        model.focusMeetingId = nil
    }

    @ViewBuilder private func content(_ now: Date) -> some View {
        let upcoming = store.meetings.filter { $0.endAt > now }.sorted { $0.startAt < $1.startAt }
        let past = (fetched ?? store.meetings).filter { $0.endAt <= now }.sorted { $0.startAt > $1.startAt }
        let hero = upcoming.first
        let later = Array(upcoming.dropFirst())
        VStack(spacing: 0) {
            ScreenScaffold(title: "Meetings", subtitle: subtitle(upcoming, now)) {
                ScrollViewReader { proxy in
                    VStack(alignment: .leading, spacing: Space.l) {
                        SectionLabel("Upcoming", count: upcoming.count)
                        if let hero {
                            MeetingHero(meeting: hero, now: now, selected: selection == hero.id).id(hero.id)
                                .onTapGesture { selection = hero.id }
                        } else {
                            EmptyState(icon: "calendar", title: "Nothing on the calendar", message: "Meetings for the next seven days show up here once the calendar connector has synced.")
                                .frame(height: 170).cardSurface(radius: Radius.l)
                        }
                        ForEach(MeetingDay.group(later, now: now)) { day in
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text(day.title).font(Typo.heading).foregroundStyle(Palette.textDim).padding(.leading, Space.s)
                                ForEach(day.meetings) { meeting in
                                    MeetingUpcomingRow(meeting: meeting, now: now, expanded: selection == meeting.id).id(meeting.id)
                                        .onTapGesture { withAnimation(Motion.snappy) { selection = selection == meeting.id ? nil : meeting.id } }
                                }
                            }
                        }
                        SectionLabel("Past", count: past.count).padding(.top, Space.s)
                        if past.isEmpty {
                            EmptyState(icon: "clock.arrow.circlepath", title: "No past meetings yet", message: "Summaries, action items and recordings from the last three weeks land here.")
                                .frame(height: 150).cardSurface(radius: Radius.l)
                        }
                        VStack(spacing: Space.s) {
                            ForEach(past) { meeting in
                                MeetingPastCard(meeting: meeting, expanded: selection == meeting.id || (selection == nil && meeting.id == past.first?.id),
                                                selected: selection == meeting.id, isAdded: { isAdded($0, meeting) }, onAdd: { add($0, from: meeting) },
                                                onAddAll: { addAll(meeting) })
                                    .id(meeting.id)
                                    .onTapGesture { withAnimation(Motion.snappy) { selection = selection == meeting.id ? nil : meeting.id } }
                            }
                        }
                    }
                    .onChange(of: selection) { if let selection { withAnimation(Motion.snappy) { proxy.scrollTo(selection, anchor: .center) } } }
                }
            }
            KeyLegend([(["J", "K"], "move"), (["↩"], "join"), (["P"], "prepare"), (["T"], "action items to tasks")])
        }
        .animation(Motion.snappy, value: selection)
        .screenKeys(model) { keys($0, upcoming: upcoming, past: past, now: now) }
    }

    private func subtitle(_ upcoming: [Meeting], _ now: Date) -> String {
        guard let next = upcoming.first else { return "Nothing coming up" }
        let today = upcoming.filter { Calendar.current.isDate($0.startAt, inSameDayAs: now) }.count
        let when = next.startAt <= now ? "one is on now" : "next in \(Fmt.span(next.startAt.timeIntervalSince(now)))"
        return "\(today) left today · \(when)"
    }

    // MARK: Action items

    private func isAdded(_ item: String, _ meeting: Meeting) -> Bool {
        added.contains("\(meeting.id)#\(item)")
            || model.library.tasks.contains { $0.source == .meeting && $0.sourceRef == meeting.id && $0.title == item }
    }

    private func add(_ item: String, from meeting: Meeting) {
        guard !isAdded(item, meeting) else { return }
        var fields: [String: JSONValue] = ["title": .string(item), "status": "todo", "source": "meeting", "sourceRef": .string(meeting.id)]
        if let url = meeting.recordingUrl ?? meeting.joinUrl {
            fields["links"] = [["kind": "meeting", "title": .string(meeting.title), "url": .string(url)]]
        }
        withAnimation(Motion.bounce) { _ = added.insert("\(meeting.id)#\(item)") }
        Haptics.success()
        Task {
            // The tick is optimistic; take it back if the brain refuses the task.
            if (try? await store.client.createTask(.object(fields))) == nil { withAnimation(Motion.snappy) { _ = added.remove("\(meeting.id)#\(item)") } }
        }
    }

    private func addAll(_ meeting: Meeting) {
        meeting.actionItems.forEach { add($0, from: meeting) }
    }

    // MARK: Keys

    private func keys(_ stroke: KeyStroke, upcoming: [Meeting], past: [Meeting], now: Date) -> Bool {
        if let next = moveSelection(stroke, in: (upcoming + past).map(\.id), from: selection) {
            selection = next
            return true
        }
        if stroke.plain(.escape), selection != nil {
            selection = nil
            return true
        }
        let chosen = selection ?? upcoming.first?.id
        if let meeting = upcoming.first(where: { $0.id == chosen }) {
            if stroke.plain(.enter), meeting.joinUrl != nil {
                app.open(meeting.joinUrl)
                return true
            }
            if stroke.plain("p"), meeting.prepNote == nil, meeting.prepStatus != .running {
                model.prepare(meeting)
                return true
            }
        }
        if stroke.plain("t"), let meeting = past.first(where: { $0.id == (selection ?? past.first?.id) }), !meeting.actionItems.isEmpty {
            addAll(meeting)
            return true
        }
        return false
    }
}

private struct MeetingDay: Identifiable {
    let id: Date
    let title: String
    let meetings: [Meeting]

    static func group(_ meetings: [Meeting], now: Date) -> [MeetingDay] {
        let cal = Calendar.current
        return Dictionary(grouping: meetings) { cal.startOfDay(for: $0.startAt) }
            .map { MeetingDay(id: $0.key, title: Fmt.day($0.key, now: now), meetings: $0.value.sorted { $0.startAt < $1.startAt }) }
            .sorted { $0.id < $1.id }
    }
}

private func meetingTimeRange(_ meeting: Meeting) -> String {
    meeting.hasStartTime ? "\(Fmt.time(meeting.startAt)) – \(Fmt.time(meeting.endAt))" : "time not recorded"
}

/// "in 38m", or "Now" with the time left once it has started.
private struct MeetingCountdown: View {
    let meeting: Meeting
    let now: Date
    var large = false

    var body: some View {
        let live = meeting.startAt <= now
        let soon = !live && meeting.startAt.timeIntervalSince(now) < 15 * 60
        VStack(alignment: .trailing, spacing: 0) {
            Text(live ? "Now" : "in \(Fmt.span(meeting.startAt.timeIntervalSince(now)))")
                .font(large ? .system(size: 28, weight: .medium, design: .rounded).monospacedDigit() : Typo.numeric)
                .foregroundStyle(live ? Palette.accent : soon ? Palette.warn : large ? Palette.text : Palette.textDim)
                .contentTransition(.numericText())
            if live, large {
                Text("\(Fmt.span(meeting.endAt.timeIntervalSince(now))) left").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
        }
        .fixedSize()
    }
}

/// Prep note, or the way to get one: the Prepare button, its progress, or why it failed.
private struct MeetingPrepBlock: View {
    let meeting: Meeting
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let note = meeting.prepNote, !note.isEmpty {
                HStack(spacing: 6) {
                    SectionLabel("Prep")
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Palette.ok)
                }
                MarkdownView(text: note)
            } else {
                HStack(spacing: Space.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No prep note yet").font(Typo.bodyStrong).foregroundStyle(Palette.textDim)
                        Text("The agent reads the invite, recent threads with these people and your open tasks, then writes what you need to walk in with.")
                            .font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Space.s)
                    if meeting.prepStatus == .running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Preparing…").font(Typo.bodyStrong).foregroundStyle(Palette.violet)
                        }
                        .fixedSize()
                    } else {
                        Button(model.prepFailure(meeting) == nil ? "Prepare" : "Try again", systemImage: "sparkles") { model.prepare(meeting) }
                            .buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                    }
                }
                if meeting.prepStatus != .running, let why = model.prepFailure(meeting) {
                    InlineNotice(text: why, icon: "exclamationmark.circle", color: Palette.warn)
                }
            }
        }
    }
}

private struct MeetingPeople: View {
    let names: [String]

    var body: some View {
        if !names.isEmpty {
            HStack(spacing: Space.s) {
                AvatarStack(names: names, limit: 6)
                Text(names.count <= 3 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) and \(names.count - 2) more")
                    .font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            }
        }
    }
}

private struct MeetingHero: View {
    let meeting: Meeting
    let now: Date
    let selected: Bool
    @Environment(AppContext.self) private var app

    var body: some View {
        let live = meeting.startAt <= now
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.l) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(live ? "ON NOW" : "NEXT").font(Typo.label).kerning(0.8).foregroundStyle(live ? Palette.accent : Palette.info)
                    Text(meeting.title).font(.system(size: 18, weight: .semibold)).foregroundStyle(Palette.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Space.s) {
                        Label(meetingTimeRange(meeting), systemImage: "clock").font(Typo.numeric).foregroundStyle(Palette.textDim).labelStyle(.titleAndIcon)
                        Text(Fmt.span(meeting.endAt.timeIntervalSince(meeting.startAt))).font(Typo.caption).foregroundStyle(Palette.textFaint)
                        if let location = meeting.location, !location.isEmpty {
                            Label(location, systemImage: "mappin").font(Typo.caption).foregroundStyle(Palette.textFaint).labelStyle(.titleAndIcon).lineLimit(1)
                        }
                    }
                    MeetingPeople(names: meeting.attendees).padding(.top, 2)
                }
                Spacer(minLength: Space.s)
                VStack(alignment: .trailing, spacing: Space.s) {
                    MeetingCountdown(meeting: meeting, now: now, large: true)
                    if meeting.joinUrl != nil {
                        Button("Join", systemImage: "video.fill") { app.open(meeting.joinUrl) }
                            .buttonStyle(.pressable(.primary)).labelStyle(.titleAndIcon).fixedSize()
                            .help("Join (↩)")
                    }
                }
            }
            Rectangle().fill(Palette.stroke).frame(height: 1)
            MeetingPrepBlock(meeting: meeting)
        }
        .padding(Space.l)
        .background(
            LinearGradient(colors: [(live ? Palette.accent : Palette.info).opacity(0.10), .clear], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .continuous(Radius.l))
        .background(Palette.bgRaised, in: .continuous(Radius.l))
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(selected ? Palette.accent.opacity(0.7) : (live ? Palette.accent : Palette.info).opacity(0.28), lineWidth: selected ? 1.5 : 1))
        .contentShape(.rect)
    }
}

private struct MeetingUpcomingRow: View {
    let meeting: Meeting
    let now: Date
    let expanded: Bool
    @Environment(AppContext.self) private var app
    @Environment(MainWindowModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s + 2) {
                Text(meeting.hasStartTime ? Fmt.time(meeting.startAt) : "–").font(Typo.numeric).foregroundStyle(Palette.textDim).frame(width: 66, alignment: .leading)
                RoundedRectangle.continuous(1.5).fill(Palette.info.opacity(0.8)).frame(width: 3, height: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                    Text("\(meeting.hasStartTime ? Fmt.span(meeting.endAt.timeIntervalSince(meeting.startAt)) : "time not recorded") · \(meeting.attendees.count == 1 ? meeting.attendees[0] : "\(meeting.attendees.count) people")")
                        .font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if !expanded { AvatarStack(names: meeting.attendees, limit: 4, size: 20) }
                if meeting.prepNote != nil {
                    Pill("Prep ready", icon: "checkmark", color: Palette.ok)
                } else if meeting.prepStatus == .running {
                    Pill("Preparing…", icon: "sparkles", color: Palette.violet)
                } else if model.prepFailure(meeting) != nil {
                    Pill("Prep failed", icon: "exclamationmark.circle", color: Palette.warn)
                }
                MeetingCountdown(meeting: meeting, now: now).frame(minWidth: 52, alignment: .trailing)
            }
            if expanded {
                VStack(alignment: .leading, spacing: Space.m) {
                    HStack(spacing: Space.m) {
                        MeetingPeople(names: meeting.attendees)
                        Spacer(minLength: Space.s)
                        if meeting.joinUrl != nil {
                            Button("Join", systemImage: "video.fill") { app.open(meeting.joinUrl) }.buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                        }
                    }
                    MeetingPrepBlock(meeting: meeting)
                }
                .padding(.leading, 66 + Space.s + 2 + 3 + Space.s + 2)
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s + 2)
        .background(expanded ? Palette.bgRaised : .clear, in: .continuous(Radius.m))
        .overlay(RoundedRectangle.continuous(Radius.m).strokeBorder(expanded ? Palette.accent.opacity(0.6) : .clear, lineWidth: 1.5))
        .rowSurface(radius: Radius.m)
    }
}

private struct MeetingPastCard: View {
    let meeting: Meeting
    let expanded: Bool
    let selected: Bool
    let isAdded: (String) -> Bool
    let onAdd: (String) -> Void
    let onAddAll: () -> Void
    @Environment(AppContext.self) private var app

    var body: some View {
        let open = meeting.actionItems.filter { !isAdded($0) }.count
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s + 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(Typo.bodyStrong).foregroundStyle(Palette.text).lineLimit(1)
                    Text("\(Fmt.day(meeting.startAt)) · \(meetingTimeRange(meeting)) · \(meeting.attendees.count) people")
                        .font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                if !expanded { AvatarStack(names: meeting.attendees, limit: 4, size: 20) }
                if !meeting.actionItems.isEmpty {
                    Pill(open == 0 ? "All added" : "\(open) action item\(open == 1 ? "" : "s")", icon: open == 0 ? "checkmark" : "checklist", color: open == 0 ? Palette.ok : Palette.accent)
                }
                if let recording = meeting.recordingUrl {
                    Button("Recording", systemImage: "play.rectangle") { app.open(recording) }.buttonStyle(.pressable(.ghost)).labelStyle(.titleAndIcon).fixedSize()
                }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(Palette.textFaint).rotationEffect(.degrees(expanded ? 90 : 0))
            }
            if expanded {
                if meeting.summary == nil && meeting.actionItems.isEmpty {
                    Text("No summary or action items were captured for this meeting.").font(Typo.caption).foregroundStyle(Palette.textFaint)
                }
                if let summary = meeting.summary, !summary.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        SectionLabel("Summary")
                        MarkdownView(text: summary)
                    }
                }
                if !meeting.actionItems.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack {
                            SectionLabel("Action items", count: meeting.actionItems.count)
                            Spacer()
                            if open > 1 {
                                Button { onAddAll() } label: {
                                    HStack(spacing: 5) {
                                        Text("Add all as tasks")
                                        KeyHint("T")
                                    }
                                }
                                .buttonStyle(.pressable(.ghost)).fixedSize()
                            }
                        }
                        ForEach(meeting.actionItems, id: \.self) { item in
                            let done = isAdded(item)
                            HStack(spacing: Space.s) {
                                Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 13))
                                    .foregroundStyle(done ? Palette.ok : Palette.textFaint).frame(width: 16)
                                    .contentTransition(.symbolEffect(.replace))
                                Text(item).font(Typo.body).foregroundStyle(done ? Palette.textDim : Palette.text).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: Space.s)
                                if done {
                                    Text("Added").font(Typo.caption).foregroundStyle(Palette.ok)
                                } else {
                                    Button("Add task", systemImage: "plus") { onAdd(item) }.buttonStyle(.pressable()).labelStyle(.titleAndIcon).fixedSize()
                                }
                            }
                            .padding(.horizontal, Space.s)
                            .frame(minHeight: 32)
                            .rowSurface(radius: Radius.s)
                        }
                    }
                }
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.bgRaised, in: .continuous(Radius.l))
        .overlay(RoundedRectangle.continuous(Radius.l).strokeBorder(selected ? Palette.accent.opacity(0.7) : Palette.stroke, lineWidth: selected ? 1.5 : 1))
        .contentShape(.rect)
    }
}
