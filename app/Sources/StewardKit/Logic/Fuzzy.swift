import Foundation

/// Subsequence matching for the command palette: every query character must appear in order.
public enum Fuzzy {
    /// nil when `query` does not match. Higher is better: word starts, runs and early matches score up.
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var score = 0, qi = 0, last = -2
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            let wordStart = ti == 0 || !(t[ti - 1].isLetter || t[ti - 1].isNumber)
            score += 1 + (wordStart ? 8 : 0) + (ti == last + 1 ? 5 : 0) + (ti == 0 ? 6 : 0)
            last = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        if text.lowercased().contains(String(q)) { score += 12 }
        return score - min(t.count, 60) / 6
    }

    /// Matching items, best first. `boost` breaks ties in favour of what matters now (a waiting session, the current task).
    public static func rank<T>(_ items: [T], query: String, boost: (T) -> Int = { _ in 0 }, key: (T) -> String) -> [T] {
        items.enumerated()
            .compactMap { index, item in score(query, in: key(item)).map { (item, $0 + boost(item), index) } }
            .sorted { ($0.1, -$0.2) > ($1.1, -$1.2) }
            .map(\.0)
    }
}

/// One row the command palette can show. `kind` groups rows ("action", "task", "project"…).
public struct PaletteCandidate: Identifiable, Equatable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var subtitle: String
    /// Added to the match score; with an empty query only boosted rows are shown, highest first.
    public var boost: Int

    public init(id: String, kind: String, title: String, subtitle: String = "", boost: Int = 0) {
        self.id = id; self.kind = kind; self.title = title; self.subtitle = subtitle; self.boost = boost
    }
}

public enum PaletteRanker {
    /// Best matches across kinds. A title match counts in full, a subtitle match half; no kind takes
    /// more than `perKind` rows, so forty tasks cannot push the one matching action off the list.
    public static func results(_ all: [PaletteCandidate], query: String, perKind: Int = 6, limit: Int = 30) -> [PaletteCandidate] {
        let query = query.trimmingCharacters(in: .whitespaces)
        let scored: [(PaletteCandidate, Int, Int)]
        if query.isEmpty {
            scored = all.enumerated().filter { $0.element.boost > 0 }.map { ($0.element, $0.element.boost, $0.offset) }
        } else {
            scored = all.enumerated().compactMap { index, c in
                let best = [Fuzzy.score(query, in: c.title), Fuzzy.score(query, in: c.subtitle).map { $0 / 2 }].compactMap { $0 }.max()
                return best.map { (c, $0 + c.boost, index) }
            }
        }
        var taken: [String: Int] = [:]
        var out: [PaletteCandidate] = []
        for (candidate, _, _) in scored.sorted(by: { ($0.1, -$0.2) > ($1.1, -$1.2) }) where out.count < limit {
            guard taken[candidate.kind, default: 0] < perKind else { continue }
            taken[candidate.kind, default: 0] += 1
            out.append(candidate)
        }
        return out
    }
}
