import Foundation
import Testing
@testable import StewardKit

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try BrainJSON.decoder.decode(type, from: Data(json.utf8))
}

@Test func aLongTurnFoldsAtALineOrWordBoundaryAndAShortOneIsLeftAlone() {
    let short = "All 12 tests pass.\nWant me to open a pull request?"
    #expect(TurnFold.preview(short).text == short && !TurnFold.preview(short).folded)

    let lines = (1...20).map { "line \($0)" }.joined(separator: "\n")
    let byLines = TurnFold.preview(lines, lines: 3, characters: 1000)
    #expect(byLines.folded && byLines.text == "line 1\nline 2\nline 3…")

    let paragraph = Array(repeating: "wordy", count: 300).joined(separator: " ")
    let byLength = TurnFold.preview(paragraph, lines: 9, characters: 100)
    #expect(byLength.folded && byLength.text.count <= 101 && byLength.text.hasSuffix("wordy…"), "cut between words, not inside one")

    let unbroken = String(repeating: "x", count: 500)
    #expect(TurnFold.preview(unbroken, lines: 9, characters: 100).text == String(repeating: "x", count: 100) + "…", "nothing to break on: cut at the limit")
}

@Test func theFewLooseEndsShownFirstTakeOneFromEachGroupBeforeASecondFromAny() throws {
    let list = try decode(LooseEnds.self, #"""
    {"count":6,"at":1,"groups":[
      {"kind":"commitment","title":"You said you would","items":[{"id":"c1","kind":"commitment","title":"Send the copy","reason":"2 days ago","since":1000,"place":{"view":"inbox","path":"/suggestions/g1"},"url":null}]},
      {"kind":"page","title":"Pages you keep opening","items":[
        {"id":"p1","kind":"page","title":"A","reason":"r","since":1,"place":null,"url":"https://docs.example.com/a"},
        {"id":"p2","kind":"page","title":"B","reason":"r","since":2,"place":null,"url":null},
        {"id":"p3","kind":"page","title":"C","reason":"r","since":3}]},
      {"kind":"something-new","title":"Later kinds","items":[{"id":"n1","kind":"something-new","title":"N","reason":"r","since":4}]}
    ]}
    """#)
    #expect(list.all.map(\.id) == ["c1", "p1", "p2", "p3", "n1"])
    #expect(list.top(4).map(\.id) == ["c1", "p1", "n1", "p2"])
    #expect(list.top(1).map(\.id) == ["c1"] && list.top(99).count == 5)
    #expect(list.groups[0].items[0].place == .init(view: "inbox", path: "/suggestions/g1") && list.groups[1].items[0].place == nil)
    #expect(list.groups[2].kind == .unknown, "a kind this build does not know still shows")
    #expect(try decode(LooseEnds.self, #"{"items":[]}"#).all.isEmpty, "an older brain's empty answer decodes to an empty list")
}

@Test func aCommitmentIsReadFromTheSuggestionPayloadAndOnlyFromThere() throws {
    let promised = try decode(Suggestion.self, #"""
    {"id":"g1","kind":"followup","title":"Send the numbers","rationale":"","payload":{"title":"Send the numbers","commitment":{"quote":"I'll send the numbers","to":"Hana Sato","madeAt":1700000000000}},
     "source":"chat","sourceRef":"C1:1","sourceUrl":null,"confidence":0.8,"status":"pending","createdAt":1,"decidedAt":null}
    """#)
    #expect(promised.commitment == Commitment(quote: "I'll send the numbers", to: "Hana Sato", madeAt: Date(timeIntervalSince1970: 1_700_000_000)))
    let owed = try decode(Suggestion.self, #"{"id":"g2","kind":"followup","title":"Chase Teo","payload":{"waitingOn":"Teo"},"source":"chat","status":"pending","createdAt":1}"#)
    #expect(owed.commitment == nil)
}

@Test func placesDecodeFromTheBrainAndFromAnOlderBrainThatSendsLess() throws {
    let old = try decode(CodeSession.self, #"{"id":"s1","cwd":"/work/acme-api","state":"waiting","stateSince":1,"startedAt":1,"updatedAt":1}"#)
    #expect(old.notes == "", "a session from a brain without notes still decodes")

    let place = try decode(TaskPlace.self, #"""
    {"task":{"id":"t1","title":"Reply to Mira","status":"todo","source":"chat","sourceRef":"C1:1","createdAt":1,"updatedAt":1},
     "origins":[{"source":"chat","kind":"mention","title":"#billing","body":"Are we good for the 3rd?","actor":"Mira Okafor","at":1700000000000,"url":"https://chat.example.com/p1","signalId":"sig1","sessionId":null,"meetingId":null,"noteId":null}],
     "context":{"id":"c1","subject":"src:chat:C1:1","status":"ok","body":"**Asked**: a date","error":null,"fetchedAt":1700000000000,"costUsd":0.03,
                "draftStatus":"weird","draft":"On track.","draftApprovalId":"a1","draftNote":"Waiting in Approvals.","draftAt":1,"createdAt":1,"updatedAt":1},
     "related":{"tasks":[{"task":{"id":"t2","title":"Other","status":"waiting","createdAt":1,"updatedAt":1},"why":"same thread"}],"suggestions":[],"sessions":[],"meetings":[]},
     "sessions":[{"id":"s1","cwd":"/work/acme-api","state":"ended","stateSince":1,"notes":"mine","startedAt":1,"updatedAt":1}],
     "seeMoreVia":"chat","replyVia":null}
    """#)
    #expect(place.origins.first?.actor == "Mira Okafor" && place.origins.first?.source == .chat)
    #expect(place.context?.status == .ok && place.context?.draftStatus == .unknown && place.context?.draftApprovalId == "a1")
    #expect(place.related.count == 1 && !place.related.isEmpty && place.related.tasks[0].why == "same thread")
    #expect(place.sessions.first?.state == .ended && place.sessions.first?.notes == "mine")
    #expect(place.seeMoreVia == "chat" && place.replyVia == nil)

    let turns = try decode(SessionTurns.self, #"{"items":[{"role":"user","at":1700000000000,"text":"hi"},{"role":"tools","at":null,"text":"Read ×2"},{"role":"narrator","text":"?"}],"from":"transcript","truncated":true}"#)
    #expect(turns.items.map(\.role) == [.user, .tools, .unknown] && turns.items[1].at == nil && turns.truncated)

    let event = try BrainEvent.parse(type: "state.changed", data: Data(#"{"entities":["places","tasks"]}"#.utf8))
    guard case .stateChanged(let entities)? = event else { Issue.record("not a state.changed"); return }
    #expect(entities == [.places, .tasks])
}
