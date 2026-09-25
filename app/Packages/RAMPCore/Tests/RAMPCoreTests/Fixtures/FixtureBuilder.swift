import CryptoKit
import Foundation
@testable import RAMPCore

/// Builds real package archives (`.tar.xz` by default) + a manifest.json in a private temp dir for
/// installer tests. Uses stock `/usr/bin/tar` (bsdtar) with `PATH=/usr/bin:/bin` — no external compressors.
final class FixtureBuilder {
    enum Compression {
        case xz, gzip, none

        var flag: String? {
            switch self {
            case .xz: return "-J"
            case .gzip: return "-z"
            case .none: return nil
            }
        }

        var suffix: String {
            switch self {
            case .xz: return ".tar.xz"
            case .gzip: return ".tar.gz"
            case .none: return ".tar"
            }
        }
    }

    struct Archive {
        let url: URL
        let sha256: String
        let size: Int64
        var fileName: String { url.lastPathComponent }
    }

    /// One manifest entry to render into manifest.json.
    struct Entry {
        var component: String
        var branch: String
        var version: String
        var archive: Archive
        var sha256Override: String? = nil
        var sizeOverride: Int64? = nil
        var extensionDirRel: String? = nil
    }

    let base: URL
    let dist: URL
    let paths: Paths

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appending(path: "ramp-install-\(UUID().uuidString)", directoryHint: .isDirectory)
        dist = base.appending(path: "dist", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        paths = Paths(root: base.appending(path: "root"), logs: base.appending(path: "logs"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }

    /// Sanity file each component must ship (mirrors the installer contract).
    static func sanityFile(_ component: String) -> String {
        switch component {
        case "php": return "sbin/php-fpm"
        case "apache": return "bin/httpd"
        case "mysql": return "bin/mysqld"
        case "redis": return "bin/redis-server"
        case "phpmyadmin": return "index.php"
        case "elasticvue": return "index.html"
        default: return "README"
        }
    }

    /// Package archive for `component` with its sanity file (executable) + a few extra files.
    /// - Parameters:
    ///   - topLevelDir: wrap the tree in a single directory (e.g. "8.3.35") instead of storing it directly.
    ///   - omitSanity: leave the sanity file out (invalid package).
    ///   - symlinks: relative link path → target.
    ///   - substitution: bsdtar `-s` pattern applied with `-P` (crafts `../x` or `/abs/x` entries).
    func package(
        _ component: String,
        version: String,
        topLevelDir: String? = nil,
        omitSanity: Bool = false,
        symlinks: [String: String] = [:],
        substitution: String? = nil,
        compression: Compression = .xz,
        name: String? = nil,
        extraFiles: [String: String] = [:]
    ) throws -> Archive {
        let fm = FileManager.default
        let work = base.appending(path: "src-\(UUID().uuidString)", directoryHint: .isDirectory)
        let tree = topLevelDir.map { work.appending(path: $0, directoryHint: .isDirectory) } ?? work
        try fm.createDirectory(at: tree, withIntermediateDirectories: true)

        var files: [String: (String, Int)] = ["share/VERSION": (version, 0o644)]
        if !omitSanity {
            files[Self.sanityFile(component)] = ("#!/bin/sh\necho \(component) \(version)\n", 0o755)
        }
        for (rel, content) in extraFiles { files[rel] = (content, 0o644) }
        for (rel, (content, mode)) in files {
            let url = tree.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
        }
        for (rel, target) in symlinks {
            let url = tree.appending(path: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: url.path(percentEncoded: false), withDestinationPath: target)
        }

        let out = dist.appending(path: name ?? "\(component)-\(version)\(compression.suffix)")
        var args = compression.flag.map { [$0] } ?? []
        args += ["-cf", out.path(percentEncoded: false)]
        if let substitution { args += ["-P", "-s", substitution] }
        args += ["-C", work.path(percentEncoded: false)]
        if let topLevelDir {
            args.append(topLevelDir)
        } else {
            // Store the tree directly (no wrapping directory).
            args += try fm.contentsOfDirectory(atPath: work.path(percentEncoded: false)).sorted()
        }
        try Self.run("/usr/bin/tar", args)
        try? fm.removeItem(at: work)
        return try describe(out)
    }

    /// sha256 + size of an existing file (computed independently of `Checksum`).
    func describe(_ url: URL) throws -> Archive {
        let data = try Data(contentsOf: url)
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Archive(url: url, sha256: hex, size: Int64(data.count))
    }

    /// Writes `dist/manifest.json` (URLs relative via `${RAMP_DIST_BASE}`) and decodes it.
    @discardableResult
    func manifest(_ entries: [Entry], extra: [String: Any] = [:]) throws -> Manifest {
        var components: [String: [String: Any]] = [:]
        for e in entries {
            var obj: [String: Any] = [
                "version": e.version,
                "url": "${RAMP_DIST_BASE}/\(e.archive.fileName)",
                "sha256": e.sha256Override ?? e.archive.sha256,
                "size": e.sizeOverride ?? e.archive.size,
            ]
            if let rel = e.extensionDirRel {
                obj["extension_dir_rel"] = rel
                obj["extensions"] = ["opcache", "intl"]
            }
            components[e.component, default: [:]][e.branch] = obj
        }
        for (k, v) in extra { components[k] = v as? [String: Any] }
        let json: [String: Any] = ["schema": 1, "generated": "2026-09-24T00:00:00Z", "components": components]
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let url = manifestURL
        try data.write(to: url)
        return try Manifest.decode(from: data, manifestURL: url)
    }

    var manifestURL: URL { dist.appending(path: "manifest.json") }

    static func run(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(filePath: exe)
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin"]  // prove stock macOS tools suffice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw NSError(domain: "FixtureBuilder", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "\(exe) \(args) failed: \(msg)"])
        }
    }
}
