import Foundation

/// How much of a long prompt or reply a conversation shows before "Show all".
public enum TurnFold {
    public static let lines = 9
    public static let characters = 700

    /// The head of `text` that fits the limits, cut at a line or word boundary, and whether anything was left out.
    public static func preview(_ text: String, lines: Int = TurnFold.lines, characters: Int = TurnFold.characters) -> (text: String, folded: Bool) {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept = all.prefix(lines).joined(separator: "\n")
        var folded = all.count > lines
        if kept.count > characters {
            let head = kept.prefix(characters)
            // Back up to the last space so a word is not cut in half, unless that would throw most of it away.
            let cut = head.lastIndex(where: { $0 == " " || $0 == "\n" }).flatMap { head.distance(from: head.startIndex, to: $0) > characters / 2 ? $0 : nil } ?? head.endIndex
            kept = String(head[..<cut])
            folded = true
        }
        return (folded ? kept.trimmingCharacters(in: .whitespacesAndNewlines) + "…" : text, folded)
    }
}
