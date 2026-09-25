import AppKit
import Foundation
import RAMPCore

/// Where ⌥-click on a vhost (window / menu bar) opens the project.
enum ProjectOpenTarget: String, CaseIterable, Identifiable {
    case finder, phpStorm
    var id: String { rawValue }
}

struct ProjectOpenerError: Error, LocalizedError, Equatable {
    var title: String
    var message: String
    var errorDescription: String? { message }
}

/// Shared "open" actions for vhosts — browser, Finder, PhpStorm. Used by the Vhosty section (05-02) and the
/// menu bar (05-05). Never writes into project folders; only opens / reveals them.
@MainActor
final class ProjectOpener {
    static let optionClickTargetKey = "optionClickTarget"
    static let phpStormBundleIDs = ["com.jetbrains.PhpStorm", "com.jetbrains.PhpStorm-EAP"]

    /// PhpStorm location: a registered app bundle (preferred, reuses the running IDE) or a `phpstorm` launcher.
    enum PhpStorm: Equatable {
        case app(URL)
        case launcher(URL)
    }

    /// Resolved once — menu / context items are hidden when PhpStorm is not installed.
    let phpStorm: PhpStorm?
    var isPhpStormAvailable: Bool { phpStorm != nil }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        phpStorm = Self.locatePhpStorm(home: home)
    }

    /// ⌥-click target (`@AppStorage("optionClickTarget")`, surfaced in Settings by 05-06). Default: PhpStorm when
    /// available, else Finder.
    var optionClickTarget: ProjectOpenTarget {
        let stored = UserDefaults.standard.string(forKey: Self.optionClickTargetKey).flatMap(ProjectOpenTarget.init)
        let target = stored ?? (isPhpStormAvailable ? .phpStorm : .finder)
        return target == .phpStorm && !isPhpStormAvailable ? .finder : target
    }

    // MARK: Actions

    static func browserURL(for vhost: Vhost, port: Int) -> URL? {
        URL(string: port == 80 ? "http://\(vhost.domain)/" : "http://\(vhost.domain):\(port)/")
    }

    func openInBrowser(_ vhost: Vhost, config: RampConfig) {
        guard let url = Self.browserURL(for: vhost, port: config.apache.port) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealInFinder(_ path: String) throws(ProjectOpenerError) {
        let url = try existingFolder(path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInPhpStorm(_ path: String) throws(ProjectOpenerError) {
        let folder = try existingFolder(path)
        switch phpStorm {
        case .app(let app):
            // = `open -a PhpStorm <dir>`: reuses the running IDE instance.
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration)
        case .launcher(let launcher):
            let process = Process()
            process.executableURL = launcher
            process.arguments = [folder.path(percentEncoded: false)]   // argv, no shell
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw ProjectOpenerError(title: String(localized: "PhpStorm sa nepodarilo spustiť"),
                                         message: error.localizedDescription)
            }
        case nil:
            throw ProjectOpenerError(title: String(localized: "PhpStorm sa nenašiel"),
                                     message: String(localized: "Nainštalujte PhpStorm alebo jeho spúšťač „phpstorm“."))
        }
    }

    /// Opens the vhost's project folder (`ProjectRoot.resolve`: the folder with `.idea` / `.git`, not `www/`).
    func openProject(_ vhost: Vhost, target: ProjectOpenTarget) throws(ProjectOpenerError) {
        let root = ProjectRoot.resolve(docroot: vhost.docroot, home: FileManager.default.homeDirectoryForCurrentUser,
                                       fs: LiveFileChecking())
        switch target {
        case .finder: try revealInFinder(root)
        case .phpStorm: try openInPhpStorm(root)
        }
    }

    // MARK: private

    private func existingFolder(_ path: String) throws(ProjectOpenerError) -> URL {
        var isDir: ObjCBool = false
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ProjectOpenerError(title: String(localized: "Priečinok neexistuje"), message: path)
        }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    private static func locatePhpStorm(home: URL) -> PhpStorm? {
        for id in phpStormBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return .app(url) }
        }
        let launchers = [
            URL(filePath: "/usr/local/bin/phpstorm"),
            URL(filePath: "/opt/homebrew/bin/phpstorm"),
            home.appending(path: "Library/Application Support/JetBrains/Toolbox/scripts/phpstorm"),
        ]
        return launchers.first { FileManager.default.isExecutableFile(atPath: $0.path(percentEncoded: false)) }
            .map(PhpStorm.launcher)
    }
}
