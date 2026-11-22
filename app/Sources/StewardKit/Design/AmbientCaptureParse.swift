import Foundation

/// What the capture field's shortcuts mean, for the preview chips only: a leading `>` forces the agent,
/// and the rest are the app-wide `QuickAdd` tokens. The brain parses the raw text itself; nothing here
/// changes what is sent.
public struct CaptureDraft: Equatable, Sendable {
    public var forceAgent: Bool
    public var quick: QuickAdd

    public var isEmpty: Bool { quick.title.isEmpty && quick.hashes.isEmpty && quick.people.isEmpty }

    public static func parse(_ text: String) -> CaptureDraft {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let forceAgent = trimmed.hasPrefix(">")
        return CaptureDraft(forceAgent: forceAgent, quick: QuickAdd.parse(forceAgent ? String(trimmed.dropFirst()) : trimmed))
    }
}

/// Where a finished utterance goes.
public enum VoiceRoute: Equatable, Sendable {
    case capture(String)
    case agent(String)

    /// Longest first, so "hey steward" wins over "steward".
    static let wakePhrases = ["hey steward", "ok steward", "okay steward", "ask steward", "steward", "ask"]

    public static func route(_ utterance: String) -> VoiceRoute {
        let text = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        for phrase in wakePhrases where lower.hasPrefix(phrase) {
            let after = text.dropFirst(phrase.count)
            // "asking" and "stewardship" are not wake phrases.
            guard after.first.map({ !$0.isLetter && !$0.isNumber }) ?? true else { continue }
            let question = after.drop { $0.isWhitespace || $0.isPunctuation }
            return question.isEmpty ? .capture(text) : .agent(String(question))
        }
        return .capture(text)
    }

    public var isAgent: Bool {
        if case .agent = self { true } else { false }
    }
}
