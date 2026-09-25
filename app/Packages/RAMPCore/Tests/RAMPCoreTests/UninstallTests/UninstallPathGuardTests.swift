import Foundation
import Testing
@testable import RAMPCore

/// Everything lives under `/tmp/ramp-un/<uuid>/` with a fake home — never the real one.
struct UninstallSandbox {
    let base: URL
    let home: URL
    var library: URL { home.appending(path: "Library", directoryHint: .isDirectory) }
    var appSupport: URL { library.appending(path: "Application Support/RAMP", directoryHint: .isDirectory) }
    var logs: URL { library.appending(path: "Logs/RAMP", directoryHint: .isDirectory) }
    var caches: URL { library.appending(path: "Caches/sk.tyron.ramp", directoryHint: .isDirectory) }
    var prefs: URL { library.appending(path: "Preferences/sk.tyron.ramp.plist", directoryHint: .notDirectory) }
    var sites: URL { home.appending(path: "Sites", directoryHint: .isDirectory) }
    var docroot: URL { sites.appending(path: "project/public", directoryHint: .isDirectory) }

    init() throws {
        base = URL(filePath: "/tmp/ramp-un", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        home = base.appending(path: "home/tester", directoryHint: .isDirectory)
        let fm = FileManager.default
        for dir in [appSupport, logs, caches, docroot, library.appending(path: "Preferences"),
                    home.appending(path: "Desktop"), home.appending(path: "Documents")] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try Data("<?php echo 1;".utf8).write(to: docroot.appending(path: "index.php"))
        try Data("plist".utf8).write(to: prefs)
    }

    var paths: Paths { Paths(root: appSupport, logs: logs) }

    func guardFor(paths: Paths? = nil) -> UninstallPathGuard {
        UninstallPathGuard(home: home, library: library, paths: paths ?? self.paths, bundleID: "sk.tyron.ramp",
                           deniedRoots: UninstallPathGuard.defaultDeniedRoots(home: home,
                                                                              docroots: [docroot.path(percentEncoded: false)]))
    }

    func cleanup() {
        // Only ever removes our own sandbox directory.
        precondition(base.path(percentEncoded: false).hasPrefix("/tmp/ramp-un/"))
        try? FileManager.default.removeItem(at: base)
        // Drop the shared parent once the last sandbox is gone (rmdir fails while parallel tests still use it).
        _ = rmdir("/tmp/ramp-un")
    }
}

@Suite struct UninstallPathGuardTests {
    private func allowed(_ g: UninstallPathGuard, _ path: String) -> Bool {
        if case .success = g.check(URL(filePath: path)) { return true }
        return false
    }

    private func p(_ url: URL, _ tail: String = "") -> String {
        url.path(percentEncoded: false) + tail
    }

    @Test func allowsRampOwnedDirectoriesAndTheirContents() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        try FileManager.default.createDirectory(at: s.appSupport.appending(path: "mysql-data/9.7"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s.library.appending(path: "HTTPStorages"),
                                                withIntermediateDirectories: true)
        let g = s.guardFor()
        #expect(allowed(g, p(s.appSupport)))
        #expect(allowed(g, p(s.appSupport, "mysql-data")))
        #expect(allowed(g, p(s.appSupport, "mysql-data/9.7/ibdata1")))
        #expect(allowed(g, p(s.logs, "apache-error.log")))
        #expect(allowed(g, p(s.caches, "x")))
        #expect(allowed(g, p(s.library, "HTTPStorages/sk.tyron.ramp")))
        #expect(allowed(g, p(s.prefs)))
    }

    @Test func rejectsEmptyRelativeAndRoot() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let g = s.guardFor()
        #expect(g.check(path: "") == .failure(.emptyPath))
        #expect(!allowed(g, "relative/RAMP"))
        #expect(!allowed(g, "/"))
        #expect(!allowed(g, "/tmp"))
        #expect(!allowed(g, p(s.home)))
        #expect(!allowed(g, p(s.library)))
        #expect(!allowed(g, p(s.library, "Application Support")))
        #expect(!allowed(g, p(s.home, "Desktop")))
        #expect(!allowed(g, p(s.home, "Documents")))
        #expect(!allowed(g, p(s.library, "Preferences")))
        #expect(!allowed(g, p(s.library, "Preferences/com.apple.finder.plist")))
        #expect(!allowed(g, p(s.library, "Preferences/sk.tyron.ramp.plist.bak")))
        #expect(!allowed(g, p(s.appSupport, "missing-parent/file")))   // unresolvable parent
        #expect(!allowed(g, p(s.library, "Caches/sk.tyron.rampx")))
    }

    @Test func rejectsDotDotTraversal() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let g = s.guardFor()
        #expect(!allowed(g, p(s.appSupport, "../../..")))
        #expect(!allowed(g, p(s.appSupport, "..")))
        #expect(!allowed(g, p(s.appSupport, "../RAMP")))   // even when it lexically lands inside again
        #expect(!allowed(g, p(s.appSupport, "conf/../../../../Sites/project")))
        #expect(!allowed(g, p(s.appSupport, "./.")))
    }

    @Test func siblingWithCommonStringPrefixIsNotInside() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let sibling = s.library.appending(path: "Application Support/RAMP2", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let g = s.guardFor()
        #expect(!allowed(g, p(sibling)))
        #expect(!allowed(g, p(sibling, "data")))
        #expect(!allowed(g, p(s.library, "Logs/RAMP-old")))
    }

    @Test func symlinkInsideRootIsAllowedAsLinkButNotThroughIt() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let link = s.appSupport.appending(path: "project-link", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.docroot)
        let g = s.guardFor()
        // The link itself may be removed (unlink, target untouched) ...
        guard case .success(let resolved) = g.check(link) else {
            Issue.record("link inside root must be allowed")
            return
        }
        #expect(resolved.lastPathComponent == "project-link")
        // ... but nothing reached through it.
        #expect(!allowed(g, p(link, "/index.php")))
        #expect(!allowed(g, p(link, "/")))
    }

    @Test func symlinkedParentPointingOutsideIsRejected() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let dirLink = s.appSupport.appending(path: "sites", directoryHint: .notDirectory)
        try FileManager.default.createSymbolicLink(at: dirLink, withDestinationURL: s.sites)
        let g = s.guardFor()
        #expect(!allowed(g, p(dirLink, "/project")))
        #expect(!allowed(g, p(dirLink, "/project/public/index.php")))
    }

    @Test func docrootInsideRampRootMakesItsAncestorsUndeletable() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let inside = s.appSupport.appending(path: "projects/shop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let g = UninstallPathGuard(home: s.home, library: s.library, paths: s.paths, bundleID: "sk.tyron.ramp",
                                   deniedRoots: UninstallPathGuard.defaultDeniedRoots(
                                       home: s.home, docroots: [inside.path(percentEncoded: false)]))
        #expect(!allowed(g, p(s.appSupport)))
        #expect(!allowed(g, p(s.appSupport, "projects")))
        #expect(!allowed(g, p(inside)))
        #expect(!allowed(g, p(inside, "index.php")))
        #expect(allowed(g, p(s.appSupport, "mysql-data")))
    }

    @Test func customRampHomeInsideHomeIsAllowed() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let custom = s.home.appending(path: "dev/ramp-home", directoryHint: .isDirectory)
        let customLogs = s.home.appending(path: "dev/ramp-logs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customLogs, withIntermediateDirectories: true)
        let g = s.guardFor(paths: Paths(root: custom, logs: customLogs))
        #expect(allowed(g, p(custom, "ramp.json")))
        #expect(allowed(g, p(custom)))
        #expect(allowed(g, p(customLogs, "x.log")))
        #expect(g.refusedRoots.isEmpty)
    }

    @Test(arguments: ["", "Library", "Sites", "Sites/project", "Desktop", "Documents", "dev"])
    func abusiveRampHomeIsRefused(_ relative: String) throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let root = relative.isEmpty ? s.home : s.home.appending(path: relative, directoryHint: .isDirectory)
        let g = s.guardFor(paths: Paths(root: root, logs: s.logs))
        #expect(!g.refusedRoots.isEmpty)
        #expect(!allowed(g, p(root, "ramp.json")))
        #expect(!allowed(g, p(root)))
    }

    @Test func rampHomeInsideADocrootOrOutsideHomeIsRefused() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        for root in [s.docroot.appending(path: "ramp"), URL(filePath: "/tmp/ramp-un-outside/x/y"),
                     s.sites.appending(path: "a/b"), URL(filePath: "/")] {
            let g = s.guardFor(paths: Paths(root: root, logs: s.logs))
            #expect(!g.refusedRoots.isEmpty, "\(root.path(percentEncoded: false))")
            #expect(!allowed(g, p(root, "ramp.json")))
        }
    }

    @Test func rampHomeThatIsAnAncestorOfADocrootIsRefused() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let root = s.home.appending(path: "work/all", directoryHint: .isDirectory)
        let doc = root.appending(path: "client/public", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: doc, withIntermediateDirectories: true)
        let g = UninstallPathGuard(home: s.home, library: s.library, paths: Paths(root: root, logs: s.logs),
                                   bundleID: "sk.tyron.ramp",
                                   deniedRoots: UninstallPathGuard.defaultDeniedRoots(
                                       home: s.home, docroots: [doc.path(percentEncoded: false)]))
        #expect(!g.refusedRoots.isEmpty)
        #expect(!allowed(g, p(root, "client")))
    }

    @Test func symlinkedRampHomePointingIntoProjectsIsRefused() throws {
        let s = try UninstallSandbox()
        defer { s.cleanup() }
        let link = s.home.appending(path: "dev/ramp-link", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: s.sites)
        let g = s.guardFor(paths: Paths(root: link, logs: s.logs))
        #expect(!g.refusedRoots.isEmpty)
        #expect(!allowed(g, p(link, "/project")))
    }

    @Test func shallowHomeIsRejectedEntirely() {
        let g = UninstallPathGuard(home: URL(filePath: "/"), library: URL(filePath: "/Library"),
                                   paths: Paths(root: URL(filePath: "/Library/Application Support/RAMP"),
                                                logs: URL(filePath: "/Library/Logs/RAMP")),
                                   bundleID: "sk.tyron.ramp", deniedRoots: [])
        #expect(!allowed(g, "/Library/Application Support/RAMP/x"))
    }
}
