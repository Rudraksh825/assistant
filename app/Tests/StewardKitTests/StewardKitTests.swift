import Foundation
import Testing
@testable import StewardKit
import Carbon.HIToolbox

@Test func listSurvivesUnknownEnumsMissingFieldsAndBadElements() throws {
    let json = #"""
    {"items":[
      {"id":"t1","title":"Ship it","status":"brand_new_status","priority":2,"score":71.5,"scoreReasons":["due today"],
       "source":"manual","createdAt":1700000000000,"updatedAt":1700000000000,"dueAt":1700003600000,
       "links":[{"kind":"pr","title":"#1","url":"https://example.com/1"},{"kind":7}]},
      {"id":"t2","title":"No timestamps, so this one cannot decode"},
      {"id":"t3","title":"Minimal","status":"todo","createdAt":1,"updatedAt":2,"tags":null}
    ]}
    """#
    let tasks = try BrainJSON.decoder.decode(ItemsResponse<TaskItem>.self, from: Data(json.utf8)).items
    #expect(tasks.map(\.id) == ["t1", "t3"])
    #expect(tasks[0].status == .unknown)
    #expect(tasks[0].dueAt == Date(timeIntervalSince1970: 1_700_003_600))
    #expect(tasks[0].links.count == 1)
    #expect(tasks[1].tags.isEmpty && tasks[1].notes.isEmpty && tasks[1].priority == 0 && !tasks[1].pinned)
}

@Test func snapshotDecodesWithSectionsMissing() throws {
    let snapshot = try BrainJSON.decoder.decode(StateSnapshot.self, from: Data(#"{"top":[],"counts":{"inbox":3},"serverTime":1700000000000}"#.utf8))
    #expect(snapshot.counts.inbox == 3 && snapshot.counts.overdue == 0)
    #expect(snapshot.now == nil && snapshot.sessions.isEmpty && snapshot.budget.billing == .unknown)
}

@Test func datesEncodeAsIntegerMilliseconds() throws {
    let span = ActivitySpanInput(app: "Editor", bundleId: nil, title: nil, startAt: Date(timeIntervalSince1970: 1.5), endAt: Date(timeIntervalSince1970: 2), idle: false)
    let text = String(decoding: try BrainJSON.encoder.encode(span), as: UTF8.self)
    #expect(text.contains(#""startAt":1500"#) && text.contains(#""endAt":2000"#))
    #expect(JSONValue.ms(Date(timeIntervalSince1970: 1_700_000_000)).text() == "1700000000000")
}

@Test func sseParserSplitsEventsOnBlankLines() throws {
    var parser = SSEParser()
    var events: [(String, String)] = []
    let stream = "event: hello\ndata: {\"version\":\"1\"}\n\n: comment\nevent: ping\r\ndata: {}\r\n\r\ndata: a\ndata: b\n\n"
    for byte in stream.utf8 {
        if let (type, data) = parser.feed(byte) { events.append((type, String(decoding: data, as: UTF8.self))) }
    }
    #expect(events.map(\.0) == ["hello", "ping", "message"])
    #expect(events[2].1 == "a\nb")
    guard case .hello(let version)? = try BrainEvent.parse(type: "hello", data: Data(events[0].1.utf8)) else {
        Issue.record("hello did not parse")
        return
    }
    #expect(version == "1")
    #expect(try BrainEvent.parse(type: "from.the.future", data: Data("{}".utf8)) == nil)
}

@MainActor @Test func storeAppliesStreamingChatAndSessionEvents() throws {
    let store = AppStore(client: BrainClient(dataDir: DataDir(url: URL(fileURLWithPath: "/nonexistent"))))
    func feed(_ type: String, _ json: String) throws { store.apply(try #require(try BrainEvent.parse(type: type, data: Data(json.utf8)))) }

    try feed("chat.started", #"{"threadId":"th","runId":"r1"}"#)
    try feed("chat.delta", #"{"threadId":"th","runId":"r1","text":"Hel"}"#)
    try feed("chat.delta", #"{"threadId":"th","runId":"r1","text":"lo"}"#)
    try feed("chat.tool", #"{"threadId":"th","runId":"r1","callId":"c1","name":"tasks_search","input":{"q":"x"},"status":"running"}"#)
    try feed("chat.tool", #"{"threadId":"th","runId":"r1","callId":"c1","name":"tasks_search","status":"ok","result":"2 tasks"}"#)
    try feed("chat.delta", #"{"threadId":"th","runId":"r1","text":"Done."}"#)
    let thread = try #require(store.messages["th"])
    #expect(thread.map(\.text) == ["Hello", "", "Done."])
    #expect(thread[1].tool?.status == .ok && thread[1].tool?.result == "2 tasks")
    #expect(store.streamingThreads == ["th"])

    let session = #"{"id":"s1","cwd":"/tmp/acme","state":"waiting","stateSince":1,"startedAt":1,"updatedAt":1}"#
    try feed("session.updated", session)
    #expect(store.sessions.first?.needsAttention == true)
    try feed("session.updated", session.replacingOccurrences(of: "waiting", with: "ended"))
    #expect(store.sessions.isEmpty)

    var seen: [String] = []
    store.onEvent { if case .uiCommand(let c) = $0 { seen.append(c.command.rawValue) } }
    try feed("ui.command", #"{"command":"open_view","args":{"view":"inbox"}}"#)
    #expect(seen == ["open_view"])
}

@Test func hotkeyStringsParse() {
    let combo = HotkeyCombo.parse("ctrl+opt+space")
    #expect(combo?.keyCode == UInt32(kVK_Space))
    #expect(combo?.modifiers == UInt32(controlKey | optionKey))
    #expect(HotkeyCombo.parse("cmd+shift+F5")?.keyCode == UInt32(kVK_F5))
    #expect(HotkeyCombo.parse("ctrl+opt") == nil && HotkeyCombo.parse("ctrl+nope") == nil)
    #expect(HotkeyCombo.display("ctrl+opt+a") == "⌃⌥A")
}

@Test func resistSpringStartsSlowerThenSettlesAtOne() {
    let plain = SpringSpec(response: SpringSpec.resist.response, damping: SpringSpec.resist.damping)
    #expect(SpringSpec.resist.progress(at: 0.05) < plain.progress(at: 0.05) * 0.5)
    let peak = stride(from: 0.0, through: 1.0, by: 0.01).map(SpringSpec.resist.progress(at:)).max() ?? 0
    #expect((1.01...1.2).contains(peak), "overshoots a little on release")
    #expect(abs(SpringSpec.resist.progress(at: SpringSpec.resist.settlingDuration) - 1) < 0.01)
    #expect(JSONValue.object([:]).setting("ui.haptics", to: false)["ui"]["haptics"].bool == false)
}

@Test func mainWindowFieldsDecodeAndStayOptionalForAnOlderBrain() throws {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try BrainJSON.decoder.decode(type, from: Data(json.utf8)) }
    let job = try decode(Job.self, #"{"name":"brief:morning","schedule":"09:00 mon,fri","enabled":true,"running":false,"scheduleSpec":{"at":"09:00","days":[1,5]},"customSchedule":true}"#)
    #expect(job.scheduleSpec?.at == "09:00" && job.scheduleSpec?.days == [1, 5] && job.scheduleSpec?.everyMin == nil && job.customSchedule)
    #expect(try decode(Job.self, #"{"name":"triage","schedule":"every 10m","enabled":true}"#).scheduleSpec == nil)

    let meeting = try decode(Meeting.self, #"{"id":"m1","source":"calendar","externalId":"e","title":"Sync","startAt":1,"endAt":2,"updatedAt":3,"prepStatus":"failed","prepError":"no connector"}"#)
    #expect(meeting.prepStatus == .failed && meeting.prepError == "no connector")
    #expect(try decode(Meeting.self, #"{"id":"m1","title":"Sync","startAt":1,"endAt":2,"updatedAt":3,"prepStatus":null}"#).prepStatus == nil)

    let tree = try decode(Tree.self, #"{"initiatives":[],"looseProjects":[{"id":"p1","title":"Billing","createdAt":1,"updatedAt":1,"openTasks":3,"doneTasks":2}]}"#)
    #expect(tree.looseProjects[0].openTasks == 3 && tree.looseProjects[0].doneTasks == 2)

    let message = try decode(ChatMessage.self, #"{"id":"c1","threadId":"t","role":"assistant","text":"Done","tool":null,"costUsd":0.12,"createdAt":1}"#)
    #expect(message.costUsd == 0.12)
    let state = try decode(StateSnapshot.self, #"{"top":[],"agent":{"busy":false,"activity":null,"available":false},"serverTime":1}"#)
    #expect(state.agent.available == false)
    #expect(try decode(TaskItem.self, #"{"id":"t","title":"x","createdAt":1,"updatedAt":2,"startedAt":1500}"#).startedAt == Date(timeIntervalSince1970: 1.5))
}
