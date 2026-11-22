import AppKit
import SwiftUI

/// One key press in the main window, normalised: letters are lowercase, modifiers are separate.
struct KeyStroke {
    enum Key: Equatable { case char(Character), up, down, left, right, enter, space, escape, delete, tab }

    let key: Key
    let mods: NSEvent.ModifierFlags

    init?(_ event: NSEvent) {
        mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 126: key = .up
        case 125: key = .down
        case 123: key = .left
        case 124: key = .right
        case 36, 76: key = .enter
        case 49: key = .space
        case 53: key = .escape
        case 51, 117: key = .delete
        case 48: key = .tab
        default:
            guard let ch = event.charactersIgnoringModifiers?.lowercased().first else { return nil }
            key = .char(ch)
        }
    }

    init(_ key: Key, _ mods: NSEvent.ModifierFlags = []) {
        self.key = key
        self.mods = mods
    }

    /// A bare key: no ⌘, ⌥ or ⌃ (shift is checked separately, `?` needs it).
    func plain(_ ch: Character) -> Bool { key == .char(ch) && mods.isEmpty }
    func shift(_ ch: Character) -> Bool { key == .char(ch) && mods == .shift }
    func command(_ ch: Character) -> Bool { key == .char(ch) && mods == .command }
    func plain(_ k: Key) -> Bool { key == k && mods.isEmpty }
    func command(_ k: Key) -> Bool { key == k && mods == .command }

    /// "ctrl+opt+space", the config format `HotkeyCombo.parse` reads. nil without a modifier.
    var hotkeyString: String? {
        guard !mods.isEmpty else { return nil }
        let name: String
        switch key {
        case .char(let c): name = String(c)
        case .space: name = "space"
        case .enter: name = "return"
        case .tab: name = "tab"
        case .up: name = "up"
        case .down: name = "down"
        case .left: name = "left"
        case .right: name = "right"
        case .delete: name = "delete"
        case .escape: return nil
        }
        var parts: [String] = []
        if mods.contains(.control) { parts.append("ctrl") }
        if mods.contains(.option) { parts.append("opt") }
        if mods.contains(.shift) { parts.append("shift") }
        if mods.contains(.command) { parts.append("cmd") }
        return (parts + [name]).joined(separator: "+")
    }
}

/// Installs the screen's key handler while it is on screen. The handler runs for keys pressed when no
/// text field has focus; return true to swallow the key.
private struct ScreenKeys: NSViewRepresentable {
    let model: MainWindowModel
    let handler: (KeyStroke) -> Bool

    final class Owner: NSView {}

    func makeNSView(context: Context) -> Owner { Owner() }

    // Re-installed on every update so the closure always sees the screen's current state.
    func updateNSView(_ view: Owner, context: Context) {
        model.screenKeys = (ObjectIdentifier(view), handler)
    }

    static func dismantleNSView(_ view: Owner, coordinator: ()) {
        MainActor.assumeIsolated {
            guard let model = MainWindowModel.current, model.screenKeys?.owner == ObjectIdentifier(view) else { return }
            model.screenKeys = nil
        }
    }
}

extension View {
    func screenKeys(_ model: MainWindowModel, _ handler: @escaping (KeyStroke) -> Bool) -> some View {
        background(ScreenKeys(model: model, handler: handler).frame(width: 0, height: 0))
    }
}

/// j/k and arrow movement over a list of ids; returns the new selection (clamped), or nil when the key is not a move.
func moveSelection<ID: Equatable>(_ stroke: KeyStroke, in ids: [ID], from current: ID?) -> ID? {
    let delta: Int
    if stroke.plain("j") || stroke.plain(.down) { delta = 1 } else if stroke.plain("k") || stroke.plain(.up) { delta = -1 } else { return nil }
    guard !ids.isEmpty else { return nil }
    guard let current, let index = ids.firstIndex(of: current) else { return delta > 0 ? ids.first : ids.last }
    return ids[min(max(index + delta, 0), ids.count - 1)]
}
