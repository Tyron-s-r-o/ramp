import AppKit

/// "Skryť ikonu v Docku" (05-06): runtime activation policy; `INFOPLIST_KEY_LSUIElement` stays NO.
@MainActor
enum DockPolicy {
    /// `@AppStorage` key (bool, default false).
    static let hideDockIconKey = "hideDockIcon"

    static var isHidden: Bool { UserDefaults.standard.bool(forKey: hideDockIconKey) }

    /// `applicationWillFinishLaunching` → stored preference.
    static func applyStored() {
        NSApp.setActivationPolicy(isHidden ? .accessory : .regular)
    }

    /// Live toggle. Open windows stay open; RAMP is re-activated so they stay in front.
    static func apply(hidden: Bool) {
        NSApp.setActivationPolicy(hidden ? .accessory : .regular)
        if NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSApp.activate()
        }
    }

    /// A window was opened (Settings scene, ⌘,): without a Dock icon it would stay behind the frontmost app.
    static func windowOpened() {
        if isHidden { NSApp.activate() }
    }
}
