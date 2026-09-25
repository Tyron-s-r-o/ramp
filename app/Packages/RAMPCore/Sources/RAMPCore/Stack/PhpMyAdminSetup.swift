import Foundation

// MARK: - phpMyAdmin setup (04-04)

extension StackController {
    /// When phpMyAdmin is installed: persists a random blowfish secret once (never regenerated) and creates
    /// `<root>/tmp/phpmyadmin` (0700). Runs before every render (`prepare`, `applyConfigChanges`), so the
    /// pure generators always see the secret. The config files themselves need no reload (read per request).
    public func ensurePhpMyAdminSetup() async throws {
        var config = try await configStore.load()
        guard PhpMyAdminConfigGenerator.isInstalled(config) else { return }
        if config.phpmyadmin.blowfishSecret == nil {
            let secret = try PhpMyAdminConfigGenerator.generateSecret()
            config = try await configStore.update {
                if $0.phpmyadmin.blowfishSecret == nil { $0.phpmyadmin.blowfishSecret = secret }
            }
        }
        let tmp = PhpMyAdminConfigGenerator.tempDir(paths)
        let fm = FileManager.default
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmp.path(percentEncoded: false))
    }
}
