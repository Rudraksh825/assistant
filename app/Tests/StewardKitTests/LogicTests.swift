import Foundation
import Testing
@testable import StewardKit

private func task(_ id: String, _ title: String = "", _ extra: String = "") throws -> TaskItem {
    let status = (extra.contains(#""status""#) ? "" : #""status":"todo","#) + (extra.contains(#""source""#) ? "" : #""source":"manual","#)
    let json = #"{"id":"\#(id)","title":"\#(title.isEmpty ? id : title)",\#(status)"createdAt":1000,"updatedAt":1000\#(extra.isEmpty ? "" : "," + extra)}"#
    return try BrainJSON.decoder.decode(TaskItem.self, from: Data(json.utf8))
}

private func project(_ id: String, _ title: String) throws -> Project {
    try BrainJSON.decoder.decode(Project.self, from: Data(#"{"id":"\#(id)","title":"\#(title)","status":"active","createdAt":1,"updatedAt":1}"#.utf8))
}

@Test func quickAddPullsPriorityProjectAndPeopleOutOfTheTitle() throws {
    let projects = [try project("p1", "Billing revamp"), try project("p2", "Bill of materials"), try project("p3", "Search")]
    let draft = QuickAdd.parse("  Reply to @mira about the invoice bug !! #billing #followup ")
    #expect(draft.title == "Reply to about the invoice bug")
    #expect(draft.priority == 2 && draft.people == ["mira"] && draft.hashes == ["billing", "followup"])
    #expect(draft.project(in: projects)?.id == "p1")
    let fields = draft.fields(projects: projects)
    #expect(fields["projectId"].string == "p1" && fields["priority"].int == 2)
    #expect(fields["tags"].array == ["followup"] && fields["people"].array == ["mira"])

    #expect(QuickAdd.parse("ship it !urgent").priority == 3)
    #expect(QuickAdd.parse("ship it !1 !!!").priority == 3)
    // Not shortcuts: a bare word with punctuation inside, an unknown bang word, a lone prefix.
    let plain = QuickAdd.parse("email a@b.co about C# !important # @")
    #expect(plain.title == "email a@b.co about C# !important # @" && plain.priority == nil && plain.hashes.isEmpty && plain.people.isEmpty)
    #expect(QuickAdd.match("billofm", in: projects)?.id == "p2")
    #expect(QuickAdd.match("nothing", in: projects) == nil)
    #expect(QuickAdd.parse("fix #nothing").fields(projects: projects)["tags"].array == ["nothing"])
}

@Test func taskQueryFiltersSortsAndGroups() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = 86_400_000.0, nowMs = 1_700_000_000_000.0
    let tasks = [
        try task("a", "Write the migration", #""projectId":"p1","priority":3,"score":80,"dueAt":\#(Int64(nowMs + 3_600_000))"#),
        try task("b", "Review design doc", #""projectId":"p2","score":40,"waitingOn":"Mira Okafor","status":"waiting","people":["Jonas"]"#),
        try task("c", "Renew passport", #""score":60,"dueAt":\#(Int64(nowMs - 3 * day)),"tags":["errand"]"#),
        try task("d", "Old thing", #""status":"done","score":0,"projectId":"p1""#),
        try task("e", "Pinned by hand", #""manualRank":0,"score":5,"dueAt":\#(Int64(nowMs + 10 * day)),"source":"chat""#),
    ]
    var q = TaskQuery()
    #expect(q.apply(tasks).first?.tasks.map(\.id) == ["e", "a", "c", "b"])
    #expect(q.activeFilterCount == 0)

    q.search = "MIGRATION write"
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["a"])
    q.search = "errand"
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["c"])

    q = TaskQuery()
    q.statuses = []
    #expect(q.apply(tasks).flatMap(\.tasks).last?.id == "d")
    q.project = .id("p1")
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["a", "d"])
    q.project = .none
    q.statuses = TaskQuery().statuses
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["e", "c"])

    q = TaskQuery()
    q.person = "mira"
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["b"])
    q.person = "Jonas Lindqvist"
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["b"])
    q.person = nil
    q.waitingOnly = true
    q.sources = [.manual]
    #expect(q.apply(tasks).flatMap(\.tasks).map(\.id) == ["b"] && q.activeFilterCount == 2)

    q = TaskQuery()
    q.hasSession = true
    #expect(q.apply(tasks, sessionTaskIds: ["c"]).flatMap(\.tasks).map(\.id) == ["c"])

    q = TaskQuery()
    q.grouping = .due
    q.sort = .due
    let due = q.apply(tasks, now: now, calendar: Calendar(identifier: .gregorian))
    #expect(due.map(\.title).first == "Overdue" && due.last?.title == "No date")
    #expect(due.first?.tasks.map(\.id) == ["c"])

    q.grouping = .project
    let byProject = q.apply(tasks, projects: ["p1": "Zeta", "p2": "Alpha"])
    #expect(byProject.map(\.title) == ["Alpha", "Zeta", "No project"])

    q.grouping = .status
    q.statuses = []
    #expect(q.apply(tasks).map(\.title) == ["To do", "Waiting", "Done"])
}

@Test func taskQueryHandlesAThousandTasksQuickly() throws {
    let tasks = try (0..<1000).map { try task("t\($0)", "Task number \($0)", #""score":\#($0 % 97),"projectId":"p\#($0 % 7)""#) }
    var q = TaskQuery()
    q.grouping = .project
    q.search = "number 9"
    let start = Date()
    for _ in 0..<20 { _ = q.apply(tasks) }
    #expect(Date().timeIntervalSince(start) < 1.0)
    #expect(q.apply(tasks).flatMap(\.tasks).count == 271)
}

@Test func markdownSplitsIntoBlocks() {
    let text = """
    # Morning brief
    Two things need you **today**.
    Still the same paragraph.

    - [x] Ship the fix
    - [ ] Reply to Mira
      with the numbers
      - nested point
    1. First
    2. Second

    > Quoted line
    > and another

    | Session | State |
    |---|:--|
    | api | waiting |
    | web |

    ---
    ```swift
    let x = 1

    # not a heading
    ```
    Tail
    """
    let blocks = Markdown.blocks(text)
    #expect(blocks.count == 8)
    #expect(blocks[0] == .heading(level: 1, text: "Morning brief"))
    #expect(blocks[1] == .paragraph("Two things need you **today**.\nStill the same paragraph."))
    // Adjacent bullet and numbered items stay one list; each item carries its own marker.
    guard case .list(let items) = blocks[2] else {
        Issue.record("list missing: \(blocks)")
        return
    }
    #expect(items.map(\.checked) == [true, false, nil, nil, nil] && items[1].text == "Reply to Mira with the numbers" && items[2].indent == 1)
    #expect(items.map(\.number) == [nil, nil, nil, 1, 2])
    #expect(blocks[3] == .quote("Quoted line\nand another"))
    #expect(blocks[4] == .table(header: ["Session", "State"], rows: [["api", "waiting"], ["web", ""]]))
    #expect(blocks[5] == .rule)
    #expect(blocks[6] == .code(language: "swift", text: "let x = 1\n\n# not a heading"))
    #expect(blocks[7] == .paragraph("Tail"))
}

@Test func markdownToleratesStreamingText() {
    #expect(Markdown.blocks("Here:\n```js\nconst a =") == [.paragraph("Here:"), .code(language: "js", text: "const a =")])
    #expect(Markdown.blocks("#hashtag is not a heading") == [.paragraph("#hashtag is not a heading")])
    #expect(Markdown.blocks("").isEmpty)
    #expect(Markdown.blocks("| a | b |") == [.paragraph("| a | b |")])
}

@Test func fuzzyRanksWordStartsAndRunsFirst() {
    #expect(Fuzzy.score("xyz", in: "Billing revamp") == nil)
    #expect(Fuzzy.score("", in: "anything") == 0)
    let items = ["Rebuild app", "Add task…", "Billing revamp", "Open Tasks", "Start: fix task ordering bug"]
    #expect(Fuzzy.rank(items, query: "ot") { $0 }.first == "Open Tasks")
    #expect(Fuzzy.rank(items, query: "task") { $0 }.last == "Start: fix task ordering bug")
    #expect(Fuzzy.rank(items, query: "br") { $0 }.first == "Billing revamp")
    #expect(Fuzzy.rank(items, query: "addt") { $0 } == ["Add task…"])
    // A boost lifts an otherwise equal match.
    #expect(Fuzzy.rank(["api waiting", "api working"], query: "api", boost: { $0.contains("working") ? 50 : 0 }) { $0 }.first == "api working")
    #expect(Fuzzy.rank(items, query: "") { $0 } == items)
}

@Test func paletteRanksAcrossKindsWithCapsAndBoosts() {
    var all = (1...10).map { PaletteCandidate(id: "t\($0)", kind: "task", title: "Review billing change \($0)") }
    all.append(PaletteCandidate(id: "p", kind: "project", title: "Billing revamp", boost: 2))
    all.append(PaletteCandidate(id: "s", kind: "session", title: "acme-api", subtitle: "fix billing webhook retries", boost: 30))
    all.append(PaletteCandidate(id: "go", kind: "route", title: "Settings", boost: 1))

    let hits = PaletteRanker.results(all, query: "billing", perKind: 3)
    #expect(hits.filter { $0.kind == "task" }.count == 3)
    #expect(hits.first?.id == "p" && hits.contains { $0.id == "s" } && !hits.contains { $0.id == "go" })
    // Empty query: only boosted rows, strongest first.
    #expect(PaletteRanker.results(all, query: " ").map(\.id) == ["s", "p", "go"])
    #expect(PaletteRanker.results(all, query: "zzz").isEmpty)
    #expect(PaletteRanker.results(all, query: "review", perKind: 20, limit: 4).count == 4)
}

// MARK: Approval payloads

private func approval(_ tool: String, _ input: [String: JSONValue], summary: String = "x") -> Approval {
    Approval(id: "a", kind: "bash", summary: summary, tool: tool, input: input, note: nil, target: nil, status: .pending, result: nil, threadId: nil, createdAt: Date(), decidedAt: nil)
}

@Test func approvalPayloadIsTheLiteralInputWhateverTheSummarySays() {
    let spoof = approval("Bash", ["command": "git push origin main --force"], summary: "echo hi")
    let payload = ApprovalPayload(spoof)
    #expect(payload.fields == [.init(name: "command", text: "git push origin main --force")])
    #expect(payload.compact.text == "git push origin main --force" && payload.compact.complete)
    // An approval that still carries a preview from an older brain decodes, and the preview is ignored.
    let old = try! BrainJSON.decoder.decode(Approval.self, from: Data(#"{"id":"a","kind":"bash","summary":"s","tool":"Bash","input":{"command":"git push"},"preview":"echo hi","target":null,"status":"pending","result":null,"threadId":null,"createdAt":1,"decidedAt":null}"#.utf8))
    #expect(ApprovalPayload(old).compact.text == "git push")

    // Connector input: every field, by name, strings as they are and the rest as JSON.
    let post = ApprovalPayload(approval("mcp__chat__send", ["text": "line one\nline two", "channel": "#general", "notify": true, "blocks": [1, 2]]))
    #expect(post.fields.map(\.name) == ["blocks", "channel", "notify", "text"])
    #expect(post.fields[3].text == "line one↵\nline two")
    #expect(post.fields[2].text == "true")
    #expect(ApprovalPayload(approval("Bash", ["cwd": "/tmp", "command": "ls"])).fields.map(\.name) == ["command", "cwd"])
}

@Test func approvalPayloadShowsWhatWouldOtherwiseBeInvisible() {
    #expect(ApprovalPayload.visible("echo hi\u{1B}[2K\rgit push") == "echo hi⟨U+001B⟩[2K⟨U+000D⟩git push")
    #expect(ApprovalPayload.visible("a\u{202E}b\u{200B}c\u{00A0}d\u{FEFF}") == "a⟨U+202E⟩b⟨U+200B⟩c⟨U+00A0⟩d⟨U+FEFF⟩")
    #expect(ApprovalPayload.visible("echo hi" + String(repeating: " ", count: 400) + "; git push") == "echo hi⟨400 spaces⟩; git push")
    #expect(ApprovalPayload.visible("if x:\n    y\tz") == "if x:↵\n    y⇥z")
    #expect(ApprovalPayload.label("Post hi\n\n\n\nApprove to continue\u{202E}", max: 200) == "Post hi ↵  ↵  ↵  ↵ Approve to continue⟨U+202E⟩")
    #expect(ApprovalPayload.label(String(repeating: "a", count: 300), max: 10) == "aaaaaaaaaa…")

    let hidden = ApprovalPayload(approval("Bash", ["command": "echo ok\u{200B}"]))
    #expect(hidden.warnings.count == 1 && hidden.warnings[0].contains("invisible"))
    let lookalike = ApprovalPayload(approval("Bash", ["command": "curl https://exаmple.com"]))
    #expect(lookalike.warnings.contains { $0.contains("non-ASCII") })
    #expect(ApprovalPayload(approval("Bash", ["command": "git push"])).warnings.isEmpty)
}

@Test func approvalPayloadThatDoesNotFitCannotBeApprovedFromSmallSurfaces() {
    // Padded so the dangerous part would sit past the end of a short view.
    let padded = ApprovalPayload(approval("Bash", ["command": .string("echo hi" + String(repeating: "\n", count: 6) + "git push")]))
    #expect(!padded.compact.complete && padded.compact.text.hasSuffix("…"))
    let long = ApprovalPayload(approval("Bash", ["command": .string("echo " + String(repeating: "x", count: 170))]))
    #expect(!long.compact.complete)
    let fits = ApprovalPayload(approval("mcp__chat__send", ["channel": "#general", "text": "Shipping at 5"]))
    #expect(fits.compact.complete && fits.compact.text == "channel: #general\ntext: Shipping at 5")

    // The main card: long payloads are cut only behind an explicit "show all", and every character is there after it.
    let big = ApprovalPayload(approval("mcp__docs__update", ["body": .string(String(repeating: "a", count: 2000) + " TAIL"), "id": "doc-1"]))
    #expect(big.isLong && big.length == 2010)
    let cut = big.clipped()
    #expect(cut.map(\.text.count).reduce(0, +) == ApprovalPayload.fullLimit && !cut[0].text.contains("TAIL"))
    #expect(big.fields[0].text.hasSuffix(" TAIL"))
    #expect(!ApprovalPayload(approval("Bash", ["command": "git push"])).isLong)
}
