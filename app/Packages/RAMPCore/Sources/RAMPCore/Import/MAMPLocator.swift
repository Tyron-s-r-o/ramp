import Foundation

/// Where MAMP PRO keeps its generated Apache configs (plan 07-03). Read-only; RAMP never writes there.
public struct MAMPLocation: Sendable, Equatable {
    public var httpConf: URL
    public var sslConf: URL
    public var httpReadable: Bool
    public var sslReadable: Bool
}

public enum MAMPLocator {
    /// `~/Library/Application Support/appsolute/MAMP PRO/{httpd.conf, httpd-ssl.conf}` + readability.
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> MAMPLocation {
        let dir = home.appending(path: "Library/Application Support/appsolute/MAMP PRO", directoryHint: .isDirectory)
        let http = dir.appending(path: "httpd.conf", directoryHint: .notDirectory)
        let ssl = dir.appending(path: "httpd-ssl.conf", directoryHint: .notDirectory)
        let fm = FileManager.default
        return MAMPLocation(httpConf: http, sslConf: ssl,
                            httpReadable: fm.isReadableFile(atPath: http.path(percentEncoded: false)),
                            sslReadable: fm.isReadableFile(atPath: ssl.path(percentEncoded: false)))
    }

    /// The default location when MAMP PRO's httpd.conf exists and is readable, else `nil`.
    public static func `default`() -> MAMPLocation? {
        let location = locate()
        return location.httpReadable ? location : nil
    }

    /// Reads a config file read-only (size-checked before loading) and parses the vhosts for `port`.
    public static func read(_ url: URL, port: Int) throws -> [MAMPVhost] {
        let path = url.path(percentEncoded: false)
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? nil
        if let size, size > MAMPConfigParser.maxBytes { throw MAMPImportError.tooLarge }
        guard let handle = FileHandle(forReadingAtPath: path) else { throw MAMPImportError.unreadable(path: path) }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: MAMPConfigParser.maxBytes + 1) ?? Data() else {
            throw MAMPImportError.unreadable(path: path)
        }
        return try MAMPConfigParser.parse(String(decoding: data, as: UTF8.self), port: port)
    }

    /// Dry-run over the MAMP PRO configs at `location` (SSL file optional).
    public static func dryRun(_ location: MAMPLocation, existing: RampConfig, availableBranches: Set<String>,
                              files: any FileChecking = LiveFileChecking(), paths: Paths = .standard()) throws -> ImportPlan {
        let http = try read(location.httpConf, port: 80)
        let ssl = location.sslReadable ? try read(location.sslConf, port: 443) : []
        return MAMPImportPlanner.plan(http: http, ssl: ssl, existing: existing,
                                      availableBranches: availableBranches, files: files, paths: paths)
    }
}
