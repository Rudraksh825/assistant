import Foundation
import Testing
@testable import StewardKit

private let base = Date(timeIntervalSince1970: 1_700_000_000 - 1_700_000_000.truncatingRemainder(dividingBy: 3600))

private func span(_ app: String, _ startMin: Double, _ endMin: Double, idle: Bool = false) -> ActivitySpan {
    ActivitySpan(id: "\(app)\(startMin)", app: app, bundleId: nil, title: nil, startAt: base.addingTimeInterval(startMin * 60),
                 endAt: base.addingTimeInterval(endMin * 60), idle: idle, sessionId: nil, taskId: nil)
}

@Test func longestStretchBridgesShortGapsAndBreaksOnIdle() {
    let spans = [
        span("Editor", 30, 50), span("Terminal", 0, 20), span("Browser", 21, 30),   // unsorted; 1-minute gap is bridged: 0–50
        span("Idle", 50, 70, idle: true),
        span("Editor", 70, 100),                                                     // 30 minutes
    ]
    #expect(ActivityMath.longestStretch(spans) == 3000)
    #expect(ActivityMath.longestStretch(spans, tolerance: 0) == 1800)
    #expect(ActivityMath.idle(spans) == 1200)
    #expect(ActivityMath.longestStretch([]) == 0)
    // A short idle blip does not end the run.
    #expect(ActivityMath.longestStretch([span("A", 0, 10), span("Idle", 10, 11, idle: true), span("A", 11, 20)]) == 1200)
}

@Test func hourBucketsClipSpansAndCountSwitches() {
    let spans = [
        span("Terminal", -10, 20),            // starts before the range: only 20 minutes count
        span("Editor", 20, 50),               // switch #1 in hour 0
        span("Idle", 50, 55, idle: true),
        span("Editor", 55, 70),               // same app: no switch; 5 min in hour 0, 10 in hour 1
        span("Browser", 70, 200),             // switch in hour 1; runs past the range end (3h)
    ]
    let buckets = ActivityMath.hours(spans, from: base, to: base.addingTimeInterval(3 * 3600))
    #expect(buckets.count == 3)
    let focus: [TimeInterval] = [3300, 3600, 3600]
    #expect(buckets.map(\.focus) == focus)
    #expect(buckets.map(\.switches) == [1, 1, 0])
    #expect(ActivityMath.hours(spans, from: base, to: base).isEmpty)
    #expect(ActivityMath.hours([], from: base, to: base.addingTimeInterval(3600)) == [ActivityMath.HourBucket(hour: base, focus: 0, switches: 0)])
}
