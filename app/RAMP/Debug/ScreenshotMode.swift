import AppKit
import SwiftUI
import RAMPCore

#if DEBUG
/// Marketing screenshots (DEBUG builds only): `RAMP -RAMPScreenshots <outputDir>`.
///
/// Runs against a throw-away sandbox (`/tmp/ramp-shots`: RAMP_HOME, logs, HOME for the terminal section) seeded
/// with `DemoData`. Nothing real is touched: no stack launch, no services / ports, no hosts sync or helper,
/// no Sparkle, no login item, no composer download. Models short-circuit their loaders to demo data (hooks guarded
/// by `ScreenshotMode.isActive`). Renders every view to PNG @2x (dark + light) and exits.
@MainActor
enum ScreenshotMode {
    nonisolated static let outputDir: URL? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "-RAMPScreenshots"), i + 1 < args.count else { return nil }
        return URL(filePath: (args[i + 1] as NSString).expandingTildeInPath, directoryHint: .isDirectory)
    }()
    nonisolated static var isActive: Bool { outputDir != nil }

    nonisolated static let sandbox = URL(filePath: "/tmp/ramp-shots", directoryHint: .isDirectory)
    nonisolated static var rampHome: URL { sandbox.appending(path: "ramp", directoryHint: .isDirectory) }
    nonisolated static var demoHome: URL { sandbox.appending(path: "home", directoryHint: .isDirectory) }

    /// UserDefaults keys the run may change (window frames, tabs…) — restored before exit.
    private static var savedDefaults: [String: Any] = [:]
    private static let touchedPrefixes = ["NSWindow Frame", "NSSplitView", "NSToolbar", "NSTableView",
                                          DatabaseTab.storageKey, VhostsModel.collapsedGroupsKey, "redisBrowserTree"]

    // MARK: Setup (before AppModel exists)

    /// Called first thing in `RAMPApp.init`: sandbox environment + demo ramp.json.
    static func prepare() {
        guard isActive else { return }
        let fm = FileManager.default
        try? fm.removeItem(at: sandbox)
        let logs = sandbox.appending(path: "logs", directoryHint: .isDirectory)
        for dir in [rampHome, logs, demoHome, demoHome.appending(path: ".ramp/bin"),
                    rampHome.appending(path: "composer")] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        setenv("RAMP_HOME", rampHome.path(percentEncoded: false), 1)
        setenv("RAMP_LOGS", logs.path(percentEncoded: false), 1)
        setenv("HOME", demoHome.path(percentEncoded: false), 1)   // ShellIntegration (Nastavenia › Terminál)
        setenv("RAMP_TMP_MYSQL_SOCK", "", 1)                      // never /tmp/mysql.sock
        unsetenv("RAMP_DEV_MANIFEST")

        let paths = Paths.standard()
        precondition(paths.root.path.hasPrefix(sandbox.path), "screenshot mode must never use the real RAMP_HOME")
        try? DemoData.config().encoded().write(to: paths.configFile)
        let block = ShellIntegration.block + "\n"
        for rc in [".zshrc", ".zprofile"] {
            try? Data(("export EDITOR=vim\n\n" + block).utf8).write(to: demoHome.appending(path: rc))
        }
        fm.createFile(atPath: paths.composerPhar.path(percentEncoded: false), contents: Data("demo".utf8))
        for shim in ["php", "composer", "mysql", "redis-cli"] {
            fm.createFile(atPath: demoHome.appending(path: ".ramp/bin/\(shim)").path(percentEncoded: false),
                          contents: Data())
        }

        let domain = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        savedDefaults = domain.filter { key, _ in touchedPrefixes.contains { key.hasPrefix($0) } }
    }

    // MARK: Driver

    /// Called from `applicationDidFinishLaunching` instead of the normal launch.
    static func start(_ app: AppModel) {
        Task { @MainActor in
            do {
                try await run(app)
            } catch {
                FileHandle.standardError.write(Data("screenshot mode failed: \(error)\n".utf8))
            }
            restoreDefaults()
            exit(0)
        }
    }

    private struct Shot {
        var name: String
        var setup: @MainActor (AppModel) async -> Void
        var target: Target = .window
        enum Target { case window, sheet, menuBar }
    }

    private static let shots: [Shot] = [
        Shot(name: "services") { $0.selection = .services },
        Shot(name: "vhosts") { $0.selection = .vhosts },
        Shot(name: "php") { app in
            app.selection = .php
            app.php.selection = .branch("8.4")
            app.php.detailTab = .settings
        },
        Shot(name: "database-mysql") { app in
            UserDefaults.standard.set(DatabaseTab.mysql.rawValue, forKey: DatabaseTab.storageKey)
            app.selection = .database
        },
        Shot(name: "database-redis") { app in
            UserDefaults.standard.set(DatabaseTab.redis.rawValue, forKey: DatabaseTab.storageKey)
            UserDefaults.standard.set(false, forKey: "redisBrowserTree")   // flat list: every demo key visible
            app.selection = .database
        },
        Shot(name: "terminal-settings") { app in
            app.selection = .settings
            try? await Task.sleep(for: .milliseconds(900))
            if let window = mainWindow() { scrollDetail(in: window, by: settingsTerminalOffset) }
        },
        Shot(name: "vhost-editor", setup: { app in
            app.selection = .vhosts
            try? await Task.sleep(for: .milliseconds(300))
            app.vhosts.editor = VhostDraft(DemoData.editorVhost)
        }, target: .sheet),
        Shot(name: "menubar", setup: { _ in }, target: .menuBar),
    ]

    private static func run(_ app: AppModel) async throws {
        guard let outputDir else { return }
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: VhostsModel.collapsedGroupsKey)
        await app.reloadConfig()
        await app.hostsHelper.refreshStatus()
        await app.services.refresh()
        await app.php.refresh()
        let only = ProcessInfo.processInfo.environment["RAMP_SHOTS_ONLY"]?.split(separator: ",").map(String.init)

        for (suffix, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            guard let window = await waitForMainWindow() else { throw ShotError.noWindow }
            let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
            window.setFrame(centered(NSSize(width: 1280, height: 660), on: retina), display: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            try await Task.sleep(for: .milliseconds(500))
            log("active=\(NSApp.isActive) key=\(window.isKeyWindow) scale=\(window.backingScaleFactor)")
            for shot in shots where only?.contains(shot.name) ?? true {
                await shot.setup(app)
                try await Task.sleep(for: .milliseconds(1200))
                try await ensureActive(window)
                let url = outputDir.appending(path: "\(shot.name)-\(suffix).png")
                switch shot.target {
                case .window:
                    try captureWindows([window], to: url)
                case .sheet:
                    guard let sheet = window.attachedSheet ?? window.sheets.first else { throw ShotError.noSheet }
                    try captureWindows([window, sheet], to: url)
                    app.vhosts.editor = nil
                    try await Task.sleep(for: .milliseconds(600))
                case .menuBar:
                    try await captureMenuBar(app, appearance: appearance, to: url)
                }
                print("wrote \(url.path(percentEncoded: false))")
            }
        }
    }

    /// The key-window look (colored traffic lights, accent selection) needs RAMP frontmost.
    private static func ensureActive(_ window: NSWindow) async throws {
        for _ in 0..<20 where !(NSApp.isActive && window.isKeyWindow) {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(250))
        }
        if !window.isKeyWindow { log("warning: window not key (another app took focus)") }
    }

    static func log(_ text: String) { FileHandle.standardError.write(Data((text + "\n").utf8)) }

    enum ShotError: Error { case noWindow, noSheet, noBitmap, encode }

    // MARK: Windows

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { w in
            w.identifier?.rawValue.hasPrefix("main") == true && w.contentView != nil && !(w is NSPanel)
        } ?? NSApp.windows.first { $0.title == "RAMP" && $0.isVisible && !($0 is NSPanel) }
    }

    private static func waitForMainWindow() async -> NSWindow? {
        for _ in 0..<50 {
            if let w = mainWindow() { return w }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return nil
    }

    private static func centered(_ size: NSSize, on screen: NSScreen?) -> NSRect {
        let visible = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Nastavenia › Terminál offset from the top of the Settings form (points; SwiftUI Form has no NSScrollView).
    static var settingsTerminalOffset: Int {
        Int(ProcessInfo.processInfo.environment["RAMP_SHOTS_TERMINAL_OFFSET"] ?? "") ?? 770
    }

    /// Synthetic pixel scroll-wheel events over the detail column.
    private static func scrollDetail(in window: NSWindow, by points: Int) {
        let location = NSPoint(x: window.frame.width * 0.6, y: window.frame.height * 0.5)
        var remaining = points
        while remaining > 0 {
            let step = min(remaining, 200)
            remaining -= step
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                                   wheel1: Int32(-step), wheel2: 0, wheel3: 0) else { return }
            cg.location = CGPoint(x: window.frame.minX + location.x,
                                  y: (NSScreen.screens.first?.frame.height ?? 0) - (window.frame.minY + location.y))
            if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
        }
    }

    /// Scrolls the detail Form so the section whose header matches one of `titles` sits at the top.
    private static func scrollToSection(in window: NSWindow, titles: [String]) {
        guard let content = window.contentView else { return }
        let header = findElement(in: content, matching: titles)
        let scrollViews = allSubviews(of: content).compactMap { $0 as? NSScrollView }
            .filter { $0.convert($0.bounds, to: nil).minX > 120 }
        log("scroll: header=\(String(describing: header)) scrollViews=\(scrollViews.map { "\(type(of: $0)) \($0.frame) doc=\($0.documentView?.frame ?? .zero)" })")
        guard let header else { return }
        guard let scroll = scrollViews.max(by: {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        }) else { return }
        // Accessibility frames are in screen coordinates (origin bottom-left).
        let screenTop = scroll.window?.convertToScreen(scroll.convert(scroll.bounds, to: nil)).maxY ?? 0
        let delta = screenTop - header.maxY - 8
        var origin = scroll.contentView.bounds.origin
        origin.y += scroll.contentView.isFlipped ? delta : -delta
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private static func findElement(in root: NSView, matching titles: [String]) -> NSRect? {
        var queue: [Any] = [root]
        var visited = 0
        while !queue.isEmpty, visited < 20_000 {
            let element = queue.removeFirst()
            visited += 1
            guard let a = element as? NSAccessibilityProtocol else { continue }
            let label = (a.accessibilityLabel() ?? "") + "|" + ((a.accessibilityValue() as? String) ?? "")
            let role = a.accessibilityRole()
            if role == .staticText || role == NSAccessibility.Role(rawValue: "AXHeading"),
               titles.contains(where: { label == $0 + "|" || label == "|" + $0 || label == $0 + "|" + $0 }) {
                return a.accessibilityFrame()
            }
            if let children = a.accessibilityChildren() { queue.append(contentsOf: children) }
        }
        return nil
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }

    // MARK: Menu bar popover

    /// Opens the real `MenuBarExtra` window (click on RAMP's status item) and captures it; falls back to a
    /// standalone render of `MenuBarContent`.
    private static func captureMenuBar(_ app: AppModel, appearance: NSAppearance.Name, to url: URL) async throws {
        let before = Set(NSApp.windows.map(\.windowNumber))
        let button = NSApp.windows.filter { $0.className.contains("StatusBar") }
            .flatMap { allSubviews(of: $0.contentView ?? NSView()) + [$0.contentView].compactMap { $0 } }
            .first { $0 is NSButton } as? NSButton
        log("status views: " + NSApp.windows.filter { $0.className.contains("StatusBar") }
            .flatMap { allSubviews(of: $0.contentView ?? NSView()) }.map { String(describing: type(of: $0)) }.joined(separator: ","))
        log("windows: " + NSApp.windows.map { "\($0.className)[\($0.contentView.map { String(describing: type(of: $0)) } ?? "-")]" }.joined(separator: ", "))
        if let button {
            log("button action=\(String(describing: button.action)) target=\(String(describing: button.target))")
            if let w = button.window {
                let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(e, atStart: false)
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(1500))
            log("after click: " + NSApp.windows.map { "\($0.className) vis=\($0.isVisible) new=\(!before.contains($0.windowNumber))" }.joined(separator: ", "))
            if let popover = NSApp.windows.first(where: { !before.contains($0.windowNumber) && $0.isVisible })
                ?? NSApp.windows.first(where: { $0.isVisible && $0.className.contains("MenuBarExtra") }) {
                try captureWindows([popover], to: url)
                popover.orderOut(nil)
                button.performClick(nil)
                try await Task.sleep(for: .milliseconds(400))
                return
            }
        }
        FileHandle.standardError.write(Data("menubar: status item popover not found, standalone render\n".utf8))
        try await captureStandaloneMenuBar(app, appearance: appearance, to: url)
    }

    private static func captureStandaloneMenuBar(_ app: AppModel, appearance: NSAppearance.Name, to url: URL) async throws {
        // 616 pt: the popover's 620 pt cap would cut the next vhost row in half.
        let root = MenuBarContent()
            .environment(app)
            .frame(height: 616, alignment: .top)
            .clipped()
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let panel = KeyPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.appearance = NSAppearance(named: appearance)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentView = host
        let screen = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let visible = screen?.visibleFrame ?? .zero
        panel.setFrameTopLeftPoint(NSPoint(x: visible.maxX - size.width - 20, y: visible.maxY - 8))
        panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(1200))
        try captureWindows([panel], to: url)
        panel.orderOut(nil)
    }

    // MARK: Rendering

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Window-server image of one of OUR windows (no Screen Recording permission needed for own windows).
    /// `CGWindowListCreateImage` is unavailable to Swift in the current SDK, hence dlsym.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(sym, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow, kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution
        return create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue()
    }

    /// First window = base; the others (sheets) are composited at their on-screen offset. Falls back to
    /// `cacheDisplay` of the first window's frame view.
    static func captureWindows(_ windows: [NSWindow], to url: URL) throws {
        guard let base = windows.first else { return }
        guard let baseImage = windowImage(base) else {
            return try capture(base.contentView?.superview ?? base.contentView!, to: url)
        }
        let scale = CGFloat(baseImage.width) / base.frame.width
        guard let ctx = CGContext(data: nil, width: baseImage.width, height: baseImage.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ShotError.noBitmap }
        ctx.draw(baseImage, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        for w in windows.dropFirst() {
            guard let img = windowImage(w) else { continue }
            let x = (w.frame.minX - base.frame.minX) * scale
            let y = (w.frame.minY - base.frame.minY) * scale
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 40 * scale,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.draw(img, in: CGRect(x: x, y: y, width: CGFloat(img.width), height: CGFloat(img.height)))
            ctx.restoreGState()
        }
        guard let out = ctx.makeImage(),
              let data = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
        else { throw ShotError.encode }
        try data.write(to: url)
    }

    /// PNG @2x of `view` (independent of the current display scale).
    static func capture(_ view: NSView, to url: URL, scale: CGFloat = 2) throws {
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * scale),
                                         pixelsHigh: Int(bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw ShotError.noBitmap }
        rep.size = bounds.size
        view.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ShotError.encode }
        try data.write(to: url)
    }

    // MARK: Cleanup

    private static func restoreDefaults() {
        let defaults = UserDefaults.standard
        let current = defaults.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        for key in current.keys where touchedPrefixes.contains(where: { key.hasPrefix($0) }) && savedDefaults[key] == nil {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in savedDefaults { defaults.set(value, forKey: key) }
        defaults.synchronize()
    }
}
/// Borderless panel that can be key (active controls look like the real popover).
private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
#else
/// Release builds: screenshot mode does not exist.
enum ScreenshotMode {
    static let isActive = false
    static func prepare() {}
}
#endif
