import SwiftUI
import StewardKit

// Small building blocks used across the main window's screens.

extension Error {
    /// The brain's agent runtime is not running (or not built yet): recap, prep and chat can't answer.
    var isAgentUnavailable: Bool {
        guard let error = self as? BrainError, case .http(let status, let code, _) = error else { return false }
        return status == 503 || code == "agent_unavailable"
    }

    var brief: String {
        if isAgentUnavailable { return "The agent isn't available right now. Everything else keeps working." }
        return (self as? BrainError)?.errorDescription ?? localizedDescription
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

extension TaskStatus {
    var title: String { TaskQuery.title(self) }

    var icon: String {
        switch self {
        case .inbox: "tray"
        case .todo: "circle"
        case .doing: "play.circle.fill"
        case .waiting: "hourglass"
        case .done: "checkmark.circle.fill"
        case .dropped: "xmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .doing: Palette.accent
        case .waiting: Palette.info
        case .done: Palette.ok
        case .inbox: Palette.violet
        default: Palette.textDim
        }
    }
}

extension SourceKind {
    var title: String {
        switch self {
        case .claude: "Coding sessions"
        case .chat: "Chat"
        case .meeting: "Meetings"
        case .ticket: "Tickets"
        case .doc: "Docs"
        case .calendar: "Calendar"
        case .message: "Messages"
        case .browser: "Browser"
        case .git: "Git"
        case .agent: "Agent"
        case .capture: "Captures"
        case .manual: "Manual"
        case .unknown: "Other"
        }
    }

    var icon: String {
        switch self {
        case .claude: "terminal"
        case .chat: "bubble.left.and.bubble.right"
        case .meeting: "person.2.wave.2"
        case .ticket: "ticket"
        case .doc: "doc.text"
        case .calendar: "calendar"
        case .message: "message"
        case .browser: "safari"
        case .git: "arrow.triangle.branch"
        case .agent: "sparkles"
        case .capture: "bolt"
        case .manual: "hand.point.up.left"
        case .unknown: "circle.dashed"
        }
    }
}

enum Priority {
    static let all: [(value: Int, title: String)] = [(0, "None"), (1, "Low"), (2, "High"), (3, "Urgent")]
    static func title(_ p: Int) -> String { all.first { $0.value == p }?.title ?? "None" }
}

enum Snooze {
    static func options(now: Date = Date()) -> [(title: String, date: Date)] {
        let cal = Calendar.current
        let tomorrow = cal.startOfDay(for: now.addingTimeInterval(86_400)).addingTimeInterval(9 * 3600)
        // Next Monday 9:00, or a week out when today is Monday.
        let weekday = cal.component(.weekday, from: now)
        let toMonday = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
        let monday = cal.startOfDay(for: now.addingTimeInterval(Double(toMonday) * 86_400)).addingTimeInterval(9 * 3600)
        return [("In 3 hours", now.addingTimeInterval(3 * 3600)), ("Tomorrow morning", tomorrow), ("Next Monday", monday),
                ("In a week", tomorrow.addingTimeInterval(6 * 86_400))]
    }
}

/// Stable colour for a name (avatars, app bars, project dots without a colour of their own).
func nameTint(_ name: String) -> Color {
    let hues: [Color] = [Palette.accent, Palette.ok, Palette.info, Palette.violet, Palette.warn, Palette.danger,
                         Color(hex: 0x8BD3A0), Color(hex: 0xE59FCB), Color(hex: 0x6CC4E8), Color(hex: 0xD9B38C)]
    let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
    return hues[sum % hues.count]
}

extension View {
    /// Row background that answers to hover and selection. Selection gets the accent wash and a leading bar.
    func rowSurface(selected: Bool = false, radius: CGFloat = Radius.s + 2) -> some View {
        modifier(RowSurface(selected: selected, radius: radius))
    }
}

private struct RowSurface: ViewModifier {
    let selected: Bool
    let radius: CGFloat
    @State private var hovered = false

    func body(content: Content) -> some View {
        content
            .background(selected ? Palette.accent.opacity(0.10) : hovered ? Palette.hover : .clear, in: .continuous(radius))
            .overlay(alignment: .leading) {
                Capsule().fill(Palette.accent).frame(width: 2.5).padding(.vertical, 6).opacity(selected ? 1 : 0)
            }
            .contentShape(.rect)
            .onHover { hovered = $0 }
            .animation(Motion.snappy, value: hovered)
            .animation(Motion.snappy, value: selected)
    }
}

/// Re-renders `content` on a timer so countdowns and "12m" labels stay live without touching the store.
struct Live<C: View>: View {
    var every: TimeInterval = 30
    @ViewBuilder var content: (Date) -> C

    var body: some View {
        TimelineView(.periodic(from: .now, by: every)) { content($0.date) }
    }
}

struct IconButton: View {
    let icon: String
    var help: String = ""
    var tint: Color = Palette.textDim
    var size: CGFloat = 24
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.5, weight: .medium))
                .foregroundStyle(hovered ? Palette.text : tint)
                .frame(width: size, height: size)
                .background(hovered ? Palette.pressed : .clear, in: .continuous(Radius.s))
                .contentShape(.rect)
        }
        .buttonStyle(.pressable(.bare))
        .onHover { hovered = $0 }
        .animation(Motion.snappy, value: hovered)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct SearchField: View {
    @Binding var text: String
    var placeholder = "Search"
    /// Focuses the field whenever this changes (⌘F).
    var focusToken = 0
    var width: CGFloat? = 220
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium)).foregroundStyle(focused ? Palette.accent : Palette.textFaint)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.text)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Palette.textFaint)
                }
                .buttonStyle(.plain)
            } else if !focused {
                KeyHint("⌘", "F")
            }
        }
        .padding(.horizontal, Space.s)
        .frame(width: width, height: 28)
        .background(Palette.bgSunken.opacity(0.8), in: .continuous(Radius.s + 1))
        .overlay(RoundedRectangle.continuous(Radius.s + 1).strokeBorder(focused ? Palette.accent.opacity(0.5) : Palette.stroke, lineWidth: 1))
        .animation(Motion.snappy, value: focused)
        .onChange(of: focusToken) { focused = true }
    }
}

/// Pill-shaped menu used for filters and pickers. `active` tints it when it is doing something.
struct MenuChip<Content: View>: View {
    let title: String
    var icon: String?
    var active = false
    @ViewBuilder var content: Content
    @State private var hovered = false

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .medium)) }
                Text(title).font(Typo.caption).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
            }
            .foregroundStyle(active ? Palette.accent : Palette.textDim)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(active ? Palette.accent.opacity(0.12) : hovered ? Palette.pressed : Palette.hover, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Palette.accent.opacity(0.35) : Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovered = $0 }
        .animation(Motion.snappy, value: hovered)
    }
}

/// On/off chip for boolean filters.
struct ToggleChip: View {
    let title: String
    var icon: String?
    @Binding var isOn: Bool
    @State private var hovered = false

    var body: some View {
        Button {
            withAnimation(Motion.snappy) { isOn.toggle() }
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10, weight: .medium)) }
                Text(title).font(Typo.caption).lineLimit(1)
            }
            .foregroundStyle(isOn ? Palette.accent : Palette.textDim)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(isOn ? Palette.accent.opacity(0.12) : hovered ? Palette.pressed : Palette.hover, in: Capsule())
            .overlay(Capsule().strokeBorder(isOn ? Palette.accent.opacity(0.35) : Palette.stroke, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable(.bare))
        .onHover { hovered = $0 }
    }
}

/// Segmented control whose selection slides between segments.
struct Segmented<T: Hashable>: View {
    let options: [(value: T, title: String, icon: String?)]
    @Binding var selection: T
    @Namespace private var space

    init(_ options: [(T, String, String?)], selection: Binding<T>) {
        self.options = options.map { (value: $0.0, title: $0.1, icon: $0.2) }
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(Motion.snappy) { selection = option.value }
                } label: {
                    HStack(spacing: 4) {
                        if let icon = option.icon { Image(systemName: icon).font(.system(size: 10, weight: .medium)) }
                        if !option.title.isEmpty { Text(option.title).font(Typo.caption) }
                    }
                    .foregroundStyle(on ? Palette.text : Palette.textDim)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background {
                        if on { RoundedRectangle.continuous(Radius.s).fill(Palette.pressed).matchedGeometryEffect(id: "pick", in: space) }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.pressable(.bare))
            }
        }
        .padding(2)
        .background(Palette.bgSunken.opacity(0.8), in: .continuous(Radius.s + 2))
        .overlay(RoundedRectangle.continuous(Radius.s + 2).strokeBorder(Palette.stroke, lineWidth: 1))
        .fixedSize()
    }
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 22

    var body: some View {
        let color = nameTint(name)
        Text(initials)
            .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: Circle())
            .overlay(Circle().strokeBorder(color.opacity(0.3), lineWidth: 1))
            .help(name)
    }

    private var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

/// Overlapping avatars with a "+3" tail.
struct AvatarStack: View {
    let names: [String]
    var limit = 5
    var size: CGFloat = 22

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(names.prefix(limit), id: \.self) { name in
                Avatar(name: name, size: size).background(Palette.bgRaised, in: Circle())
            }
            if names.count > limit {
                Text("+\(names.count - limit)").font(Typo.caption).foregroundStyle(Palette.textFaint).padding(.leading, size * 0.28 + 4)
            }
        }
    }
}

/// Weight 0–3 as three bars, like signal strength. Click a bar to set it; click the current one to step down.
struct WeightControl: View {
    let weight: Int
    var color: Color = Palette.accent
    var onChange: ((Int) -> Void)?
    @State private var hover: Int?

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(1...3, id: \.self) { level in
                let lit = level <= (hover ?? weight)
                RoundedRectangle.continuous(1.5)
                    .fill(lit ? color.opacity(hover == nil ? 1 : 0.7) : Palette.strokeStrong)
                    .frame(width: 5, height: CGFloat(5 + level * 3))
                    .frame(height: 16, alignment: .bottom)
                    .padding(.horizontal, 1)
                    .contentShape(.rect)
                    .onHover { inside in if onChange != nil { hover = inside ? level : (hover == level ? nil : hover) } }
                    .onTapGesture {
                        guard let onChange else { return }
                        Haptics.tick()
                        onChange(level == weight ? level - 1 : level)
                    }
            }
        }
        .animation(Motion.snappy, value: weight)
        .animation(Motion.snappy, value: hover)
        .help(onChange == nil ? "Weight \(weight) of 3" : "Weight \(weight) of 3. Click to change, or press 0–3.")
        .accessibilityLabel("Weight \(weight) of 3")
    }
}

struct Meter: View {
    let fraction: Double
    var color: Color = Palette.accent
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.stroke)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: height)
        .animation(Motion.settle, value: fraction)
    }
}

/// Quiet inline message: an agent that is not running, a failed request, a hint.
struct InlineNotice: View {
    let text: String
    var icon = "info.circle"
    var color: Color = Palette.textDim

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(color)
            Text(text).font(Typo.caption).foregroundStyle(Palette.textDim).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.s + 2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.07), in: .continuous(Radius.s + 1))
    }
}

/// Titled card: the standard container for a block of content on a screen.
struct Card<Trailing: View, Content: View>: View {
    var title: String?
    var count: Int?
    var padding: CGFloat = Space.m
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if let title {
                HStack(spacing: Space.s) {
                    SectionLabel(title, count: count)
                    Spacer(minLength: 0)
                    trailing
                }
                .frame(minHeight: 16)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Radius.l)
    }
}

extension Card where Trailing == EmptyView {
    init(_ title: String? = nil, count: Int? = nil, padding: CGFloat = Space.m, @ViewBuilder content: () -> Content) {
        self.init(title: title, count: count, padding: padding, trailing: { EmptyView() }, content: content)
    }
}

/// The row of shortcut hints along the bottom of a keyboard-first screen.
struct KeyLegend: View {
    let items: [(keys: [String], label: String)]

    init(_ items: [([String], String)]) { self.items = items.map { (keys: $0.0, label: $0.1) } }

    var body: some View {
        HStack(spacing: Space.m) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(item.keys, id: \.self) { KeyHint($0) }
                    }
                    Text(item.label).font(Typo.caption).foregroundStyle(Palette.textFaint).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.xl)
        .frame(height: 30)
        .background(Palette.bg)
        .overlay(alignment: .top) { Rectangle().fill(Palette.stroke).frame(height: 1) }
    }
}

/// A date value shown as a chip; click for presets and a calendar.
struct DateChip: View {
    let title: String
    let icon: String
    let date: Date?
    var withTime = false
    var presets: [(title: String, date: Date)] = DateChip.dayPresets()
    let onChange: (Date?) -> Void
    @State private var open = false
    @State private var draft = Date()

    static func dayPresets(now: Date = Date()) -> [(title: String, date: Date)] {
        let start = Calendar.current.startOfDay(for: now)
        let day: TimeInterval = 86_400
        let weekday = Calendar.current.component(.weekday, from: now)
        let toFriday = (6 - weekday + 7) % 7
        return [("Today", start.addingTimeInterval(17 * 3600)), ("Tomorrow", start.addingTimeInterval(day + 17 * 3600)),
                ("Friday", start.addingTimeInterval(Double(toFriday == 0 ? 7 : toFriday) * day + 17 * 3600)), ("In a week", start.addingTimeInterval(7 * day + 17 * 3600))]
    }

    var body: some View {
        Button {
            draft = date ?? presets.first?.date ?? Date()
            open = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .medium))
                Text(date.map { Fmt.due($0).text } ?? title).font(Typo.caption).lineLimit(1)
            }
            .foregroundStyle(date == nil ? Palette.textFaint : (date! < Date() && title == "Due" ? Palette.danger : Palette.text))
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Palette.hover, in: Capsule())
            .overlay(Capsule().strokeBorder(Palette.stroke, lineWidth: 1))
        }
        .buttonStyle(.pressable(.bare))
        .help(title)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.s) {
                SectionLabel(title)
                HStack(spacing: Space.xs) {
                    ForEach(presets, id: \.title) { preset in
                        Button(preset.title) { pick(preset.date) }.buttonStyle(.pressable())
                    }
                }
                DatePicker("", selection: $draft, displayedComponents: withTime ? [.date, .hourAndMinute] : [.date])
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    if date != nil { Button("Clear") { pick(nil) }.buttonStyle(.pressable(.ghost)) }
                    Spacer()
                    Button("Set") { pick(draft) }.buttonStyle(.pressable(.primary))
                }
            }
            .padding(Space.m)
            .frame(width: 300)
        }
    }

    private func pick(_ date: Date?) {
        open = false
        onChange(date)
    }
}

/// Text that commits on Return or when focus leaves, and reverts on Escape. For titles and one-line fields.
struct CommitField: View {
    let placeholder: String
    let value: String
    var font: Font = Typo.body
    var axis: Axis = .horizontal
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $draft, axis: axis)
            .textFieldStyle(.plain)
            .font(font)
            .foregroundStyle(Palette.text)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { if !focused { draft = value } }
            .onChange(of: focused) { if !focused { commit() } }
            .onSubmit(commit)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value { onCommit(trimmed) }
    }
}

/// Wrapping row of chips.
struct Flow: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                // A chip wider than the whole row is held to the row's width (its text truncates) instead of running out of its container.
                let ideal = subviews[index].sizeThatFits(.unspecified)
                let size = ideal.width > bounds.width ? subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) : ideal
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let ideal = subviews[index].sizeThatFits(.unspecified)
            let size = ideal.width > width ? subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil)) : ideal
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
