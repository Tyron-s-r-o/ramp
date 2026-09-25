import AppKit
import SwiftUI

/// App language override (05-06): `AppleLanguages` in RAMP's own defaults domain; takes effect after a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, sk, en

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: "Systém"
        // Language names are shown in their own language.
        case .sk: "Slovenčina"
        case .en: "English"
        }
    }

    /// Only RAMP's persistent domain — `UserDefaults.standard.object(forKey:)` would also see the global
    /// `AppleLanguages` and always report an override.
    static var current: AppLanguage {
        guard let id = Bundle.main.bundleIdentifier,
              let languages = UserDefaults.standard.persistentDomain(forName: id)?["AppleLanguages"] as? [String],
              let first = languages.first else { return .system }
        return first.hasPrefix("en") ? .en : first.hasPrefix("sk") ? .sk : .system
    }

    static func set(_ language: AppLanguage) {
        switch language {
        case .system: UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .sk, .en: UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
        }
    }

    /// "Reštartovať teraz": a detached waiter reopens RAMP once this process has exited, then the normal
    /// terminate path stops every service. The new instance starts them again on launch. (Opening a second
    /// instance immediately would race the old one's stopAll for the ports.)
    @MainActor
    static func relaunch() {
        let waiter = Process()
        waiter.executableURL = URL(filePath: "/bin/sh")
        waiter.arguments = [
            "-c", #"while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.3; done; exec /usr/bin/open -n "$2""#,
            "ramp-relaunch", String(ProcessInfo.processInfo.processIdentifier),
            Bundle.main.bundleURL.path(percentEncoded: false),
        ]
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        do {
            try waiter.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }
}
