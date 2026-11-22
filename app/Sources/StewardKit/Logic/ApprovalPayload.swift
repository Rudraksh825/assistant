import Foundation

/// What an approval will run, laid out for reading: the literal input, field by field, with nothing the agent wrote
/// standing in for it and nothing in it left invisible. Every approval surface renders this and only this as "what runs".
public struct ApprovalPayload: Equatable, Sendable {
    public struct Field: Equatable, Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        /// The value with control and invisible characters made visible. This is display text, not what is sent.
        public let text: String
    }

    public let fields: [Field]
    /// Things about the payload a reader could miss: hidden characters, look-alike letters.
    public let warnings: [String]

    /// What the main card shows before "Show all"; beyond it the card must be expanded before it can be approved.
    public static let fullLimit = 1500
    /// What the notch and a toast have room for. A payload that does not fit cannot be approved there.
    public static let compactLimit = 160
    public static let compactLines = 3

    public init(_ approval: Approval) {
        self.init(tool: approval.tool, input: approval.input)
    }

    public init(tool: String, input: [String: JSONValue]) {
        // The command first for a shell call; everything else by name, so the same input always reads the same way.
        let order = input.keys.sorted { a, b in (a == "command" && tool == "Bash") ? true : (b == "command" && tool == "Bash") ? false : a < b }
        var raw = ""
        fields = order.map { key in
            let value = input[key] ?? .null
            // A string is shown as it is, line breaks and all; anything else as indented JSON.
            let text = value.string ?? value.text(pretty: true)
            raw += text
            return Field(name: key, text: Self.visible(text))
        }
        var notes: [String] = []
        if raw.unicodeScalars.contains(where: { Self.hidden($0) }) { notes.append("Contains invisible or control characters, shown as ⟨U+…⟩.") }
        if raw.unicodeScalars.contains(where: { $0.value > 0x7E && !Self.hidden($0) && $0.properties.isAlphabetic }) { notes.append("Contains non-ASCII letters, which can look like other letters.") }
        warnings = notes
    }

    /// Characters across all fields, as displayed.
    public var length: Int { fields.reduce(0) { $0 + $1.text.count } }
    public var isLong: Bool { length > Self.fullLimit }

    /// The fields cut to `limit` characters in total. Used only behind an explicit "Show all N characters".
    public func clipped(to limit: Int = fullLimit) -> [Field] {
        var left = limit
        var out: [Field] = []
        for field in fields where left > 0 {
            out.append(Field(name: field.name, text: String(field.text.prefix(left))))
            left -= field.text.count
        }
        return out
    }

    /// One block for the small surfaces, and whether it holds the whole payload. When it does not, those surfaces
    /// offer "Review" instead of "Approve".
    public var compact: (text: String, complete: Bool) {
        let whole = fields.count == 1 ? fields[0].text : fields.map { "\($0.name): \($0.text)" }.joined(separator: "\n")
        let lines = whole.split(separator: "\n", omittingEmptySubsequences: false)
        let fits = whole.count <= Self.compactLimit && lines.count <= Self.compactLines
        if fits { return (whole, true) }
        let head = lines.prefix(Self.compactLines).joined(separator: "\n")
        return (String(head.prefix(Self.compactLimit)) + "…", false)
    }

    // MARK: Making text honest

    /// Agent-written text (summary, target) for a label: one line, hidden characters shown, cut at `max`.
    public static func label(_ text: String, max: Int = 200) -> String {
        let flat = visible(text).replacingOccurrences(of: "↵\n", with: " ↵ ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    /// Line breaks keep breaking but are marked; every other control, format, or odd-space character is spelled out;
    /// long runs of spaces are counted instead of drawn, so nothing can be pushed out of sight.
    public static func visible(_ text: String) -> String {
        var out = ""
        var spaces = 0
        func flush() {
            if spaces >= 16 { out += "⟨\(spaces) spaces⟩" } else { out += String(repeating: " ", count: spaces) }
            spaces = 0
        }
        for scalar in text.unicodeScalars {
            if scalar == " " { spaces += 1; continue }
            flush()
            switch scalar {
            case "\n": out += "↵\n"
            case "\t": out += "⇥"
            default:
                if hidden(scalar) { out += "⟨U+\(String(scalar.value, radix: 16, uppercase: true).leftPadded(to: 4))⟩" } else { out.unicodeScalars.append(scalar) }
            }
        }
        flush()
        return out
    }

    /// Characters that draw nothing, move the cursor, reorder text or pass for a plain space.
    static func hidden(_ s: Unicode.Scalar) -> Bool {
        if s == "\n" || s == "\t" { return false }
        switch s.value {
        case 0x00...0x1F, 0x7F...0x9F: return true
        case 0x00A0, 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x1680, 0x17B4, 0x17B5, 0x180B...0x180F: return true
        case 0x2000...0x200F, 0x2028...0x202F, 0x205F...0x206F, 0x3000, 0x3164, 0xFEFF, 0xFFA0, 0xFFF9...0xFFFB: return true
        case 0xE0000...0xE007F: return true
        default: return false
        }
    }
}

private extension String {
    func leftPadded(to width: Int) -> String { count >= width ? self : String(repeating: "0", count: width - count) + self }
}
