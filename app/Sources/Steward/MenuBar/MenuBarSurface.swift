import AppKit
import SwiftUI
import StewardKit

/// Status item with a template glyph and a count of things waiting on the user. A click opens the notch
/// island on that display: one panel to keep polished, and the same one everywhere.
@MainActor
final class MenuBarSurface: NSObject, Surface {
    private var item: NSStatusItem?
    private weak var app: AppContext?

    func start(app: AppContext) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.glyph()
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)
        self.item = item
        self.app = app

        watch { Self.count(app.store) } onChange: { [weak item] count in
            item?.button?.title = count > 0 ? " \(count)" : ""
            item?.button?.appearsDisabled = !app.store.connection.isOnline
        }
    }

    func stop() {
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
    }

    /// Approvals and suggestions to decide, plus sessions waiting on the user. -1 marks "offline" so the dimming updates.
    private static func count(_ store: AppStore) -> Int {
        guard store.connection.isOnline else { return -1 }
        return store.approvals.count + store.suggestions.count + store.sessions.filter(\.needsAttention).count
    }

    @objc private func toggle() {
        app?.hotkeys.press("notch")
    }

    /// The Steward mark: an open ring with a dot resting in the gap.
    private static func glyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: 5.6, startAngle: 80, endAngle: 10, clockwise: false)
            ring.lineWidth = 1.7
            ring.lineCapStyle = .round
            NSColor.black.setStroke()
            ring.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x + 3.1, y: center.y + 3.1, width: 3.4, height: 3.4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
