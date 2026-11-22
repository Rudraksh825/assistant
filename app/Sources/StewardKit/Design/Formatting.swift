import Foundation

/// Short human strings for times; UI text only.
public enum Fmt {
    /// "12m", "3h", "2d": compact elapsed/remaining time.
    public static func span(_ seconds: TimeInterval) -> String {
        let s = Int(abs(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86_400 { return s % 3600 >= 300 && s < 4 * 3600 ? "\(s / 3600)h \(s % 3600 / 60)m" : "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    public static func since(_ date: Date, now: Date = Date()) -> String { span(now.timeIntervalSince(date)) }

    public static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    public static func day(_ date: Date, now: Date = Date()) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return "Today" }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(date, inSameDayAs: t) { return "Tomorrow" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// Due label and whether it is overdue: ("Today 5:00 PM", false), ("2d overdue", true).
    public static func due(_ date: Date, now: Date = Date()) -> (text: String, overdue: Bool) {
        if date < now {
            return (Calendar.current.isDate(date, inSameDayAs: now) ? "Due \(time(date))" : "\(since(date, now: now)) overdue", true)
        }
        let cal = Calendar.current
        let midnight = cal.component(.hour, from: date) == 0 && cal.component(.minute, from: date) == 0
        return (midnight ? day(date, now: now) : "\(day(date, now: now)) \(time(date))", false)
    }

    public static func usd(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(2))) }
}
