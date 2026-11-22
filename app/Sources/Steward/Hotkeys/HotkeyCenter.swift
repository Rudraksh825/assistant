import AppKit
import Carbon.HIToolbox
import StewardKit

/// Global hotkeys via Carbon `RegisterEventHotKey` (works without Accessibility permission).
/// Surfaces register a handler by name; key combos come from the `hotkeys` config section.
@MainActor
final class HotkeyCenter {
    enum Phase { case down, up }

    static let defaults = ["capture": "ctrl+opt+space", "agent": "ctrl+opt+a", "voice": "ctrl+opt+v", "hud": "ctrl+opt+h", "notch": "ctrl+opt+n"]

    /// Names whose combo could not be parsed or is taken by another app, with the reason.
    private(set) var failures: [String: String] = [:]
    /// The combos in effect, by name (for display).
    private(set) var combos: [String: String] = HotkeyCenter.defaults

    private var handlers: [String: (Phase) -> Void] = [:]
    private var registered: [UInt32: (name: String, ref: EventHotKeyRef)] = [:]
    private var eventHandler: EventHandlerRef?

    /// One handler per name; registering again replaces it. `.up` fires on release (hold-to-talk).
    func on(_ name: String, _ handler: @escaping (Phase) -> Void) {
        handlers[name] = handler
    }

    /// (Re)registers every hotkey: `config` values override the defaults; an empty string disables one.
    func apply(_ config: [String: String]) {
        installHandlerIfNeeded()
        for (_, entry) in registered { UnregisterEventHotKey(entry.ref) }
        registered = [:]
        failures = [:]
        combos = Self.defaults.merging(config) { _, new in new }

        for (index, name) in combos.keys.sorted().enumerated() {
            guard let string = combos[name], !string.isEmpty else { continue }
            guard let combo = HotkeyCombo.parse(string) else {
                failures[name] = "can't parse \"\(string)\""
                continue
            }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: 0x5354_5744 /* 'STWD' */, id: UInt32(index + 1))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[id.id] = (name, ref)
            } else {
                failures[name] = "\"\(string)\" is in use by another app"
            }
        }
        Log.info("hotkeys: \(registered.values.map { "\($0.name)=\(combos[$0.name] ?? "")" }.sorted().joined(separator: " "))"
            + (failures.isEmpty ? "" : " failed: \(failures)"))
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let phase: Phase = GetEventKind(event) == UInt32(kEventHotKeyPressed) ? .down : .up
            let center = Unmanaged<HotkeyCenter>.fromOpaque(userData).takeUnretainedValue()
            // Carbon delivers hotkeys on the main thread.
            MainActor.assumeIsolated { center.fire(id.id, phase) }
            return noErr
        }
        InstallEventHandler(GetEventDispatcherTarget(), callback, types.count, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    /// Runs a hotkey's handler as if it had been pressed (the menu bar item shares the notch hotkey's action).
    func press(_ name: String) {
        handlers[name]?(.down)
        handlers[name]?(.up)
    }

    private func fire(_ id: UInt32, _ phase: Phase) {
        guard let name = registered[id]?.name else { return }
        handlers[name]?(phase)
    }
}
