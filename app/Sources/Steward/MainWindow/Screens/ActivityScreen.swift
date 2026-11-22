import Charts
import SwiftUI
import StewardKit

/// Where a day went: a strip of the day by app, time per app and task, and how focused each hour was.
struct ActivityScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(MainWindowModel.self) private var model
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var spans: [ActivitySpan] = []
    @State private var summary: ActivitySummary?
    @State private var loaded = false
    @State private var failure: String?

    private var isToday: Bool { Calendar.current.isDateInToday(day) }
    private var dayEnd: Date { min(day.addingTimeInterval(86_400), Date()) }

    var body: some View {
        ScreenScaffold(title: "Activity", subtitle: subtitle, width: 1100) {
            ActivityDayPicker(day: $day)
        } content: {
            if let failure { InlineNotice(text: failure, icon: "exclamationmark.triangle", color: Palette.danger) }
            let active = spans.filter { !$0.idle }
            if active.isEmpty {
                if loaded {
                    EmptyState(icon: "chart.bar.xaxis", title: isToday ? "Nothing recorded yet today" : "Nothing recorded this day",
                               message: "Steward notes which app is in front while it runs. Window titles need the Accessibility permission.")
                        .frame(height: 320)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).frame(height: 320)
                }
            } else {
                stats
                let range = ActivityStrip.range(spans, day, dayEnd)
                ActivityStrip(spans: spans, range: range, byApp: summary?.byApp ?? [])
                ActivityHours(buckets: ActivityMath.hours(spans, from: range.lowerBound, to: range.upperBound))
                HStack(alignment: .top, spacing: Space.l) {
                    Card("Time per app") {
                        let rows = (summary?.byApp ?? []).prefix(8)
                        ForEach(Array(rows), id: \.app) { row in
                            ActivityBar(label: row.app, value: row.ms / 1000, peak: (rows.first?.ms ?? 1) / 1000, color: nameTint(row.app))
                        }
                    }
                    Card("Time per task") {
                        let rows = (summary?.byTask ?? []).prefix(8)
                        if rows.isEmpty {
                            Text("Time lands on a task while it is the one in progress. Start one from Today to see it here.")
                                .font(Typo.caption).foregroundStyle(Palette.textFaint).fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(Array(rows), id: \.taskId) { row in
                            Button { model.inspect(model.library.task(row.taskId)) } label: {
                                ActivityBar(label: row.title.nonEmpty ?? "Deleted task", value: row.ms / 1000, peak: (rows.first?.ms ?? 1) / 1000, color: Palette.accent)
                            }
                            .buttonStyle(.pressable(.bare, haptic: false))
                            .help("Open the task")
                        }
                    }
                }
            }
        }
        .task(id: "\(day.timeIntervalSince1970)-\(store.connection.isOnline)") {
            loaded = false
            repeat {
                await load()
                try? await Task.sleep(for: .seconds(60))
            } while isToday && !Task.isCancelled
        }
        .task(id: store.changes[.tasks]) { await model.library.refresh() }
        .screenKeys(model) { stroke in
            if stroke.plain(.left) { step(-1) } else if stroke.plain(.right) { step(1) } else if stroke.plain("t") { go(Calendar.current.startOfDay(for: Date())) } else { return false }
            return true
        }
    }

    private var subtitle: String {
        isToday ? "Where today went" : day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    private func step(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day), next <= Date() else { return }
        go(next)
    }

    private func go(_ date: Date) {
        Haptics.tick()
        withAnimation(Motion.snappy) { day = date }
    }

    private func load() async {
        guard store.connection.isOnline else { return }
        do {
            async let fetchedSpans = store.client.activity(from: day, to: dayEnd)
            async let fetchedSummary = store.client.activitySummary(from: day, to: dayEnd)
            let (newSpans, newSummary) = try await (fetchedSpans, fetchedSummary)
            withAnimation(Motion.settle) {
                spans = newSpans
                summary = newSummary
            }
            failure = nil
        } catch {
            failure = error.brief
        }
        loaded = true
    }

    private var stats: some View {
        let idle = ActivityMath.idle(spans.map { clip($0) })
        return HStack(spacing: Space.m) {
            ActivityStat(label: "Focus", value: Fmt.span((summary?.focusMs ?? 0) / 1000), note: "time at the keyboard", color: Palette.ok)
            ActivityStat(label: "Switches", value: "\(summary?.switches ?? 0)", note: switchRate, color: Palette.warn)
            ActivityStat(label: "Longest stretch", value: Fmt.span(ActivityMath.longestStretch(spans)), note: "without going idle", color: Palette.accent)
            ActivityStat(label: "Idle", value: Fmt.span(idle), note: "away or locked", color: Palette.textFaint)
        }
    }

    private var switchRate: String {
        guard let summary, summary.focusMs > 60_000 else { return "between apps" }
        let perHour = Double(summary.switches) / (summary.focusMs / 3_600_000)
        return "about \(Int(perHour.rounded())) an hour"
    }

    private func clip(_ span: ActivitySpan) -> ActivitySpan {
        var s = span
        s.startAt = max(s.startAt, day)
        s.endAt = max(s.startAt, min(s.endAt, dayEnd))
        return s
    }
}

private struct ActivityDayPicker: View {
    @Binding var day: Date

    var body: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        HStack(spacing: Space.s) {
            HStack(spacing: 2) {
                ForEach((0..<7).reversed(), id: \.self) { back in
                    let date = cal.date(byAdding: .day, value: -back, to: today) ?? today
                    let on = cal.isDate(date, inSameDayAs: day)
                    Button { withAnimation(Motion.snappy) { day = date } } label: {
                        VStack(spacing: 1) {
                            Text(back == 0 ? "Today" : date.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 9.5, weight: .medium))
                            Text(date.formatted(.dateTime.day())).font(Typo.numeric)
                        }
                        .foregroundStyle(on ? Palette.text : Palette.textDim)
                        .frame(width: 38, height: 34)
                        .background(on ? Palette.pressed : .clear, in: .continuous(Radius.s))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.pressable(.bare))
                }
            }
            .padding(2)
            .background(Palette.bgSunken.opacity(0.8), in: .continuous(Radius.s + 2))
            .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(Palette.stroke, lineWidth: 1))
            IconButton(icon: "chevron.left", help: "Previous day (←)") { shift(-1) }
            IconButton(icon: "chevron.right", help: "Next day (→)") { shift(1) }
                .disabled(cal.isDateInToday(day))
                .opacity(cal.isDateInToday(day) ? 0.35 : 1)
        }
    }

    private func shift(_ days: Int) {
        guard let next = Calendar.current.date(byAdding: .day, value: days, to: day), next <= Date() else { return }
        withAnimation(Motion.snappy) { day = next }
    }
}

private struct ActivityStat: View {
    let label: String
    let value: String
    let note: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Circle().fill(color).frame(width: 6, height: 6)
                SectionLabel(label)
            }
            Text(value).font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit()).foregroundStyle(Palette.text).contentTransition(.numericText())
            Text(note).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.l)
    }
}

private struct ActivityBar: View {
    let label: String
    /// Seconds.
    let value: Double
    let peak: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Space.s) {
                Text(label).font(Typo.body).foregroundStyle(Palette.text).lineLimit(1)
                Spacer(minLength: Space.s)
                Text(Fmt.span(value)).font(Typo.numeric).foregroundStyle(Palette.textDim)
            }
            Meter(fraction: peak > 0 ? value / peak : 0, color: color, height: 5)
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
    }
}

/// The day as one band: a coloured segment per span, gaps where the Mac was idle.
private struct ActivityStrip: View {
    let spans: [ActivitySpan]
    let range: Range<Date>
    let byApp: [ActivitySummary.AppTime]
    @State private var hovered: ActivitySpan?

    /// Whole hours around the recorded spans, at least four wide so a short morning does not stretch across the card.
    static func range(_ spans: [ActivitySpan], _ from: Date, _ to: Date) -> Range<Date> {
        let active = spans.filter { !$0.idle }
        let first = max(from, active.map(\.startAt).min() ?? from), last = min(to, active.map(\.endAt).max() ?? to)
        let lower = from.addingTimeInterval((first.timeIntervalSince(from) / 3600).rounded(.down) * 3600)
        var upper = from.addingTimeInterval(max(1, (last.timeIntervalSince(from) / 3600).rounded(.up)) * 3600)
        if upper.timeIntervalSince(lower) < 4 * 3600 { upper = lower.addingTimeInterval(4 * 3600) }
        return lower..<max(upper, lower.addingTimeInterval(3600))
    }

    var body: some View {
        let length = range.upperBound.timeIntervalSince(range.lowerBound)
        let hours = Int(length / 3600)
        let every = hours > 16 ? 3 : hours > 8 ? 2 : 1
        Card(title: "Timeline") {
            if let hovered {
                Text("\(hovered.app)\(hovered.title.map { " · \($0)" } ?? "") · \(Fmt.time(hovered.startAt))–\(Fmt.time(hovered.endAt)) · \(Fmt.span(hovered.endAt.timeIntervalSince(hovered.startAt)))")
                    .font(Typo.caption).foregroundStyle(Palette.textDim).lineLimit(1)
            } else {
                Text("Hover a segment for the window title").font(Typo.caption).foregroundStyle(Palette.textFaint)
            }
        } content: {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    let x = { (date: Date) in max(0, min(1, date.timeIntervalSince(range.lowerBound) / length)) * geo.size.width }
                    ZStack(alignment: .leading) {
                        RoundedRectangle.continuous(Radius.s).fill(Palette.bgSunken)
                        ForEach(spans.filter { !$0.idle }) { span in
                            let lo = x(span.startAt), hi = x(span.endAt)
                            RoundedRectangle.continuous(2)
                                .fill(nameTint(span.app).opacity(hovered == nil || hovered?.id == span.id ? 0.9 : 0.4))
                                .frame(width: max(1, hi - lo - 0.5))
                                .offset(x: lo)
                        }
                    }
                    .clipShape(.continuous(Radius.s))
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let date = range.lowerBound.addingTimeInterval(point.x / geo.size.width * length)
                            hovered = spans.first { !$0.idle && $0.startAt <= date && date < $0.endAt }
                        case .ended:
                            hovered = nil
                        }
                    }
                }
                .frame(height: 34)
                // Hour ticks, labelled at the left edge of each hour.
                GeometryReader { geo in
                    ForEach(Array(stride(from: 0, through: hours, by: every)), id: \.self) { hour in
                        Text(range.lowerBound.addingTimeInterval(Double(hour) * 3600).formatted(.dateTime.hour()))
                            .font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint).fixedSize()
                            // Zero-width anchor: the label hangs left, centred or right of its tick so the ends stay inside the card.
                            .frame(width: 0, alignment: hour == hours ? .trailing : hour == 0 ? .leading : .center)
                            .offset(x: CGFloat(hour) / CGFloat(max(1, hours)) * geo.size.width)
                    }
                }
                .frame(height: 12)
                Flow(spacing: Space.m) {
                    ForEach(Array(byApp.prefix(7)), id: \.app) { row in
                        HStack(spacing: 5) {
                            RoundedRectangle.continuous(2).fill(nameTint(row.app)).frame(width: 9, height: 9)
                            Text(row.app).font(Typo.caption).foregroundStyle(Palette.textDim)
                            Text(Fmt.span(row.ms / 1000)).font(Typo.numeric).foregroundStyle(Palette.textFaint)
                        }
                    }
                }
                .padding(.top, Space.xs)
            }
            .animation(Motion.snappy, value: hovered?.id)
        }
    }
}

/// Focus against switching, hour by hour: tall calm bars are deep work, short bars under a high line are thrash.
private struct ActivityHours: View {
    let buckets: [ActivityMath.HourBucket]

    var body: some View {
        let peak = max(4, buckets.map(\.switches).max() ?? 0)
        // The line stops at the last hour with data; hours still to come are not zero-switch hours.
        let last = buckets.lastIndex { $0.focus > 0 } ?? -1
        let recorded = Set(buckets.prefix(last + 1).map(\.hour))
        Card(title: "Focus vs. switching") {
            HStack(spacing: Space.m) {
                legend(Palette.ok, "focused minutes")
                legend(Palette.warn, "app switches")
            }
        } content: {
            Chart(buckets) { bucket in
                BarMark(x: .value("Hour", bucket.hour, unit: .hour), y: .value("Focused minutes", bucket.focus / 60), width: .ratio(0.62))
                    .foregroundStyle(Palette.ok.opacity(0.75))
                    .cornerRadius(3)
                // Switches share the plot, scaled so the busiest hour reaches the top.
                if recorded.contains(bucket.hour) {
                    let y = Double(bucket.switches) / Double(peak) * 60
                    LineMark(x: .value("Hour", bucket.hour.addingTimeInterval(1800)), y: .value("Switches", y))
                        .foregroundStyle(Palette.warn)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                    PointMark(x: .value("Hour", bucket.hour.addingTimeInterval(1800)), y: .value("Switches", y))
                        .foregroundStyle(Palette.warn)
                        .symbolSize(22)
                        .annotation(position: .top, spacing: 2) {
                            if bucket.switches > 0 { Text("\(bucket.switches)").font(.system(size: 9, weight: .medium, design: .rounded)).foregroundStyle(Palette.warn) }
                        }
                }
            }
            .chartYScale(domain: 0...70)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 30, 60]) { value in
                    AxisGridLine().foregroundStyle(Palette.stroke)
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)m").font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: buckets.count > 16 ? 3 : buckets.count > 8 ? 2 : 1)) { _ in
                    AxisValueLabel(format: .dateTime.hour(), anchor: .topLeading).font(.system(size: 9.5, design: .rounded)).foregroundStyle(Palette.textFaint)
                }
            }
            .frame(height: 150)
            .padding(.top, Space.xs)
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(Typo.caption).foregroundStyle(Palette.textFaint)
        }
    }
}
