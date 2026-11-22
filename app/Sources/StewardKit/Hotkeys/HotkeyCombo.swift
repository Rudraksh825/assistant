import Carbon.HIToolbox

/// A parsed hotkey string from config, e.g. "ctrl+opt+space", in Carbon terms.
public struct HotkeyCombo: Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    /// nil when the key is unknown or there is no key. Modifiers: ctrl, opt/alt, cmd, shift (and symbols).
    public static func parse(_ string: String) -> HotkeyCombo? {
        var modifiers: UInt32 = 0
        var key: UInt32?
        for part in string.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control", "⌃": modifiers |= UInt32(controlKey)
            case "opt", "option", "alt", "⌥": modifiers |= UInt32(optionKey)
            case "cmd", "command", "⌘": modifiers |= UInt32(cmdKey)
            case "shift", "⇧": modifiers |= UInt32(shiftKey)
            default:
                guard key == nil, let code = keyCodes[part] else { return nil }
                key = UInt32(code)
            }
        }
        return key.map { HotkeyCombo(keyCode: $0, modifiers: modifiers) }
    }

    /// "⌃⌥Space" for display.
    public static func display(_ string: String) -> String {
        string.split(separator: "+").map { part -> String in
            switch part.lowercased() {
            case "ctrl", "control": "⌃"
            case "opt", "option", "alt": "⌥"
            case "cmd", "command": "⌘"
            case "shift": "⇧"
            default: part.count == 1 ? part.uppercased() : part.capitalized
            }
        }.joined()
    }

    private static let keyCodes: [String: Int] = {
        var map: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab, "escape": kVK_Escape, "esc": kVK_Escape,
            "delete": kVK_Delete, "backspace": kVK_Delete, "up": kVK_UpArrow, "down": kVK_DownArrow, "left": kVK_LeftArrow, "right": kVK_RightArrow,
            "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket, ";": kVK_ANSI_Semicolon,
            "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash, "\\": kVK_ANSI_Backslash, "`": kVK_ANSI_Grave,
        ]
        let letters = [
            kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G, kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K,
            kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U, kVK_ANSI_V,
            kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
        ]
        for (i, code) in letters.enumerated() { map[String(UnicodeScalar(UInt8(97 + i)))] = code }
        let digits = [kVK_ANSI_0, kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        for (i, code) in digits.enumerated() { map[String(i)] = code }
        let fkeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
        for (i, code) in fkeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()
}
