import Foundation

/// Loads and atomically saves `ramp.json` (`Paths.configFile`). All access is serialized by the actor.
///
/// - `load()`: missing file → defaults; corrupt file → `ConfigError.corrupt`, file left untouched.
/// - `save(_:)`: previous file copied to `ramp.json.bak`, new content written to a temp file in the
///   same directory and swapped in with `replaceItemAt`; mode 0600 (holds the MySQL root password).
/// - `update(_:)`: load → mutate → save as one serialized step.
public actor ConfigStore {
    public let paths: Paths

    public init(paths: Paths) { self.paths = paths }

    public func load() throws -> RampConfig {
        let url = paths.configFile
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return RampConfig()
        }
        return try RampConfig.decode(from: data)
    }

    public func save(_ config: RampConfig) throws {
        let fm = FileManager.default
        let dir = paths.root
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let data = try config.encoded()

        let target = paths.configFile
        let targetPath = target.path(percentEncoded: false)
        let temp = dir.appending(path: ".ramp.json.\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        let tempPath = temp.path(percentEncoded: false)
        guard fm.createFile(atPath: tempPath, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tempPath])
        }
        do {
            if fm.fileExists(atPath: targetPath) {
                let backup = paths.configBackup
                try? fm.removeItem(at: backup)
                try fm.copyItem(at: target, to: backup)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path(percentEncoded: false))
                _ = try fm.replaceItemAt(target, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: target)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: targetPath)
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// Serialized load-mutate-save. Returns the saved config.
    @discardableResult
    public func update(_ mutate: @Sendable (inout RampConfig) -> Void) throws -> RampConfig {
        var config = try load()
        mutate(&config)
        try save(config)
        return config
    }
}
