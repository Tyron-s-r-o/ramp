import AppKit
import SwiftUI
import RAMPCore

/// Menu-bar icon: RAMP elephant glyph + status dots. Plain template symbol when there is nothing to show (all running,
/// no Xdebug, no updates); otherwise a non-template 18×18 pt image whose glyph is drawn in `labelColor`.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    /// Menu bar appearance → rebuild the image so the glyph color follows light / dark.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let health = app.services.health
        let badges = MenuBarIcon.Badges(level: health.level, xdebugOn: health.xdebugOn,
                                        updates: !app.updates.updates.isEmpty)
        Image(nsImage: MenuBarIcon.image(badges, dark: colorScheme == .dark))
            .accessibilityLabel(Text(verbatim: MenuBarIcon.accessibilityText(health: health, updates: badges.updates)))
    }
}

enum MenuBarIcon {
    struct Badges: Equatable, Sendable {
        var level: StackHealth.Level
        var xdebugOn: Bool
        var updates: Bool

        var isPlain: Bool { level == .allRunning && !xdebugOn && !updates }
    }

    static let size = NSSize(width: 18, height: 18)

    static func image(_ badges: Badges, dark: Bool) -> NSImage {
        if badges.isPlain, let glyph = glyph() {
            glyph.isTemplate = true
            return glyph
        }
        let image = NSImage(size: size, flipped: false) { rect in
            let glyph = glyph()
            // Glyph, tinted: resolved at draw time (the status item draws with the menu bar's appearance);
            // `dark` only forces a redraw when the appearance flips.
            if let glyph {
                let g = glyph.size
                let glyphRect = NSRect(x: (rect.width - g.width) / 2 - 1, y: (rect.height - g.height) / 2,
                                       width: g.width, height: g.height)
                glyph.draw(in: glyphRect)
                let tint = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua || dark
                    ? NSColor.white : NSColor.black
                tint.set()
                glyphRect.fill(using: .sourceAtop)
            }
            // Status (bottom-right, 6 pt).
            let status = NSRect(x: rect.maxX - 6.5, y: 0.5, width: 6, height: 6)
            switch badges.level {
            case .allRunning: break
            case .partial: dot(status, fill: .systemOrange)
            case .error: dot(status, fill: .systemRed)
            case .stopped: dot(status, stroke: .systemGray)
            }
            // Xdebug (top-right, 5 pt).
            if badges.xdebugOn { dot(NSRect(x: rect.maxX - 5.5, y: rect.maxY - 5.5, width: 5, height: 5), fill: .systemPurple) }
            // Updates (top-left, 5 pt).
            if badges.updates { dot(NSRect(x: 0.5, y: rect.maxY - 5.5, width: 5, height: 5), fill: .systemBlue) }
            return true
        }
        image.isTemplate = false
        return image
    }

    /// RAMP elephant (template asset, 18×18 pt); falls back to `server.rack` if the asset is missing.
    private static func glyph() -> NSImage? {
        if let elephant = NSImage(named: "MenuBarGlyph")?.copy() as? NSImage {
            elephant.size = NSSize(width: 16, height: 16)
            return elephant
        }
        return NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
    }

    /// Knocks a 1 pt gap out of the glyph around the dot, then draws it.
    private static func dot(_ rect: NSRect, fill: NSColor? = nil, stroke: NSColor? = nil) {
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        context.compositingOperation = .clear
        NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1)).fill()
        context.compositingOperation = .sourceOver
        if let fill {
            fill.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
        if let stroke {
            stroke.setStroke()
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
            path.lineWidth = 1.2
            path.stroke()
        }
        context.restoreGraphicsState()
    }

    static func accessibilityText(health: StackHealth, updates: Bool) -> String {
        var parts: [String]
        switch health.level {
        case .allRunning: parts = [String(localized: "RAMP: všetko beží")]
        case .partial: parts = [String(localized: "RAMP: čiastočne beží")]
        case .stopped: parts = [String(localized: "RAMP: zastavené")]
        case .error:
            let names = health.failed.map(\.displayName).joined(separator: ", ")
            parts = [String(localized: "RAMP: chyba – \(names)")]
        }
        if health.xdebugOn { parts.append(String(localized: "Xdebug zapnutý")) }
        if updates { parts.append(String(localized: "dostupné aktualizácie")) }
        return parts.joined(separator: ", ")
    }
}
