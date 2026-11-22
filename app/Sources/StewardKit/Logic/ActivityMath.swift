import Foundation

/// Span arithmetic for the Activity screen. Pure; `spans` may be unsorted and may overlap the range edges.
public enum ActivityMath {
    public struct HourBucket: Identifiable, Equatable, Sendable {
        /// Start of the hour.
        public var hour: Date
        /// Non-idle seconds inside the hour.
        public var focus: TimeInterval
        /// App changes that happened in the hour.
        public var switches: Int
        public var id: Date { hour }
    }

    public static func idle(_ spans: [ActivitySpan]) -> TimeInterval {
        spans.filter(\.idle).reduce(0) { $0 + $1.endAt.timeIntervalSince($1.startAt) }
    }

    /// The longest run without going idle. Gaps (or idle spans) up to `tolerance` seconds do not break a run.
    public static func longestStretch(_ spans: [ActivitySpan], tolerance: TimeInterval = 120) -> TimeInterval {
        var best: TimeInterval = 0
        var run: (start: Date, end: Date)?
        for span in spans.sorted(by: { $0.startAt < $1.startAt }) where !span.idle {
            if let current = run, span.startAt.timeIntervalSince(current.end) <= tolerance {
                run = (current.start, max(current.end, span.endAt))
            } else {
                run = (span.startAt, span.endAt)
            }
            best = max(best, run!.end.timeIntervalSince(run!.start))
        }
        return best
    }

    /// One bucket per hour from `from` (expected on the hour) up to `to`: focused time clipped to the hour, and
    /// the number of times the front app changed in it.
    public static func hours(_ spans: [ActivitySpan], from: Date, to: Date) -> [HourBucket] {
        guard to > from else { return [] }
        var buckets = stride(from: from, to: to, by: 3600).map { HourBucket(hour: $0, focus: 0, switches: 0) }
        var lastApp: String?
        for span in spans.sorted(by: { $0.startAt < $1.startAt }) where !span.idle {
            let start = max(span.startAt, from), end = min(span.endAt, to)
            guard end > start else { continue }
            let first = Int(start.timeIntervalSince(from) / 3600)
            if let lastApp, lastApp != span.app { buckets[first].switches += 1 }
            lastApp = span.app
            var index = first
            while index < buckets.count, buckets[index].hour < end {
                let lo = max(start, buckets[index].hour), hi = min(end, buckets[index].hour.addingTimeInterval(3600))
                buckets[index].focus += max(0, hi.timeIntervalSince(lo))
                index += 1
            }
        }
        return buckets
    }
}
