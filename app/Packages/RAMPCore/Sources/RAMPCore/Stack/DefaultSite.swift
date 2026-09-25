import Foundation

/// The default site served on http://localhost/ (`Paths.defaultDocroot`).
public enum DefaultSite {
    public static let indexContents = "<?php phpinfo();\n"

    /// Writes `www/default/index.php` only when the docroot has no index yet (user edits are never touched).
    /// - Returns: `true` when the file was created.
    @discardableResult
    public static func ensure(paths: Paths) throws -> Bool {
        let fm = FileManager.default
        let dir = paths.defaultDocroot
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for name in ["index.php", "index.html"] {
            var st = stat()
            if lstat(dir.appending(path: name, directoryHint: .notDirectory).path(percentEncoded: false), &st) == 0 {
                return false
            }
        }
        let index = dir.appending(path: "index.php", directoryHint: .notDirectory)
        guard fm.createFile(atPath: index.path(percentEncoded: false), contents: Data(indexContents.utf8),
                            attributes: [.posixPermissions: 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: index.path(percentEncoded: false)])
        }
        return true
    }
}
