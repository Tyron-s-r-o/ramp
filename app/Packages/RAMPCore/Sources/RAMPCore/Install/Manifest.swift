import Foundation

/// Errors raised while loading / decoding `manifest.json`.
public enum ManifestError: Error, LocalizedError {
    /// Manifest written for a newer RAMP.
    case unsupportedSchema(found: Int, supported: Int)
    /// A package or manifest URL uses a scheme other than `file` / `https`.
    case insecureURL(String)
    /// A known component entry is missing a required field or has an invalid value.
    case invalidEntry(component: String, branch: String, reason: String)
    /// Not valid JSON / not a manifest object.
    case malformed(String)
    /// The manifest could not be fetched.
    case loadFailed(url: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let found, let supported):
            return "manifest.json has schema \(found), this RAMP supports up to \(supported). Update RAMP."
        case .insecureURL(let url):
            return "Refusing insecure URL \(url) — only file:// and https:// are allowed."
        case .invalidEntry(let component, let branch, let reason):
            return "manifest.json entry \(component) \(branch) is invalid: \(reason)"
        case .malformed(let reason):
            return "manifest.json is malformed: \(reason)"
        case .loadFailed(let url, let reason):
            return "Could not load manifest \(url): \(reason)"
        }
    }
}

/// Package hash as published in the manifest (lowercase hex).
public enum ManifestHash: Sendable, Equatable {
    case sha256(String)
    /// Elasticsearch (official elastic.co artifact, installable on demand since 06-03).
    case sha512(String)
}

/// One installable package: `components[component][branch]`.
public struct ManifestEntry: Sendable, Equatable {
    public let component: String
    public let branch: String
    public let version: String
    /// Fully resolved download URL (file:// or https://).
    public let url: URL
    public let hash: ManifestHash
    /// Archive size in bytes, if published.
    public let size: Int64?
    /// PHP only: extension dir relative to the package root.
    public let extensionDirRel: String?
    /// PHP only: bundled extensions.
    public let extensions: [String]
    /// PHP only: upstream support status (`support`), nil when the manifest does not say (older manifests).
    public var support: PHPSupportStatus? = nil
    /// PHP only: end of (security) support, `YYYY-MM-DD` (`eolDate`), nil when unknown.
    public var eolDate: String? = nil

    /// `support == .eol` (unknown support is never EOL).
    public var isEOL: Bool { support == .eol }
}

/// php.net support phase of a PHP branch (manifest `support`).
public enum PHPSupportStatus: String, Sendable, Equatable, CaseIterable {
    /// Active support (bug + security fixes).
    case active
    /// Security fixes only.
    case security
    /// End of life — no fixes at all.
    case eol
}

/// Parsed Phase 1 `manifest.json`:
/// `{schema:1, generated, components:{php:{"8.3":{version,url,sha256,size,extension_dir_rel,extensions}}, …}}`.
///
/// Unknown components are ignored. Relative URLs and the `${RAMP_DIST_BASE}` placeholder resolve against
/// the manifest's own directory.
public struct Manifest: Sendable, Equatable {
    public static let supportedSchema = 1
    public static let placeholder = "${RAMP_DIST_BASE}"
    /// Components this RAMP understands (decoded).
    public static let knownComponents: Set<String> = [
        "php", "apache", "mysql", "redis", "phpmyadmin", "elasticsearch", "elasticvue",
    ]
    /// Components `PackageInstaller` can install (elasticsearch + elasticvue on demand only, 06-03 — never in the default set).
    public static let installableComponents: Set<String> = [
        "php", "apache", "mysql", "redis", "phpmyadmin", "elasticsearch", "elasticvue",
    ]

    public let schema: Int
    public let generated: String?
    /// Where the manifest was loaded from (relative URLs resolve against its directory).
    public let manifestURL: URL
    /// component → branch → entry (known components only).
    public let components: [String: [String: ManifestEntry]]

    public func entry(component: String, branch: String) -> ManifestEntry? {
        components[component]?[branch]
    }

    /// Branch keys of `component`, sorted ascending by numeric version order.
    public func branches(of component: String) -> [String] {
        (components[component]?.keys.map { $0 } ?? []).sorted {
            $0.compare($1, options: .numeric) == .orderedAscending
        }
    }

    // MARK: Decoding

    public static func decode(from data: Data, manifestURL: URL) throws -> Manifest {
        let root: [String: Any]
        do {
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ManifestError.malformed("top level is not an object")
            }
            root = dict
        } catch let error as ManifestError {
            throw error
        } catch {
            throw ManifestError.malformed(error.localizedDescription)
        }
        guard let schema = root["schema"] as? Int else { throw ManifestError.malformed("schema missing") }
        guard schema <= supportedSchema else {
            throw ManifestError.unsupportedSchema(found: schema, supported: supportedSchema)
        }
        guard let rawComponents = root["components"] as? [String: Any] else {
            throw ManifestError.malformed("components missing")
        }
        try validateScheme(manifestURL)
        let baseDir = manifestURL.deletingLastPathComponent()

        var components: [String: [String: ManifestEntry]] = [:]
        for (component, value) in rawComponents where knownComponents.contains(component) {
            guard let branches = value as? [String: Any] else {
                throw ManifestError.invalidEntry(component: component, branch: "*", reason: "not an object")
            }
            for (branch, raw) in branches {
                guard let obj = raw as? [String: Any] else {
                    throw ManifestError.invalidEntry(component: component, branch: branch, reason: "not an object")
                }
                components[component, default: [:]][branch] =
                    try parseEntry(obj, component: component, branch: branch, baseDir: baseDir)
            }
        }
        return Manifest(schema: schema, generated: root["generated"] as? String,
                        manifestURL: manifestURL, components: components)
    }

    private static func parseEntry(
        _ obj: [String: Any], component: String, branch: String, baseDir: URL
    ) throws -> ManifestEntry {
        func invalid(_ reason: String) -> ManifestError {
            .invalidEntry(component: component, branch: branch, reason: reason)
        }
        guard let version = obj["version"] as? String, !version.isEmpty else { throw invalid("version missing") }
        guard let rawURL = obj["url"] as? String, !rawURL.isEmpty else { throw invalid("url missing") }

        let hash: ManifestHash
        if let sha = obj["sha256"] as? String, !sha.isEmpty {
            hash = .sha256(sha.lowercased())
        } else if let sha = obj["sha512"] as? String, !sha.isEmpty {
            hash = .sha512(sha.lowercased())
        } else {
            throw invalid("sha256/sha512 missing")
        }

        let size: Int64?
        switch obj["size"] {
        case nil, is NSNull: size = nil
        case let n as NSNumber: size = n.int64Value
        default: throw invalid("size is not a number")
        }

        var extensions: [String] = []
        if let list = obj["extensions"] as? [Any] {
            extensions = list.compactMap { ($0 as? String) ?? (($0 as? [String: Any])?["name"] as? String) }
        }

        // Optional, lenient (forward compatible): an unknown `support` value or a malformed date → nil.
        let support = (obj["support"] as? String).flatMap { PHPSupportStatus(rawValue: $0.lowercased()) }
        let eolDate = ((obj["eolDate"] ?? obj["eol_date"]) as? String).flatMap(Self.validDate)

        return ManifestEntry(
            component: component, branch: branch, version: version,
            url: try resolve(rawURL, baseDir: baseDir, component: component, branch: branch),
            hash: hash, size: size,
            extensionDirRel: obj["extension_dir_rel"] as? String,
            extensions: extensions, support: support, eolDate: eolDate)
    }

    /// `YYYY-MM-DD` (a real calendar date) or nil.
    static func validDate(_ raw: String) -> String? {
        guard raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}\z"#, options: .regularExpression) != nil else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: raw) != nil ? raw : nil
    }

    /// Resolves a package URL: `${RAMP_DIST_BASE}/x` and relative paths against `baseDir`;
    /// absolute URLs must be file:// or https://.
    static func resolve(_ raw: String, baseDir: URL, component: String, branch: String) throws -> URL {
        var string = raw
        if string.hasPrefix(placeholder) {
            string = String(string.dropFirst(placeholder.count))
            while string.hasPrefix("/") { string.removeFirst() }
        }
        let resolved: URL?
        if let absolute = URL(string: string), absolute.scheme != nil {
            resolved = absolute
        } else {
            let escaped = string.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? string
            resolved = URL(string: escaped, relativeTo: baseDir)?.absoluteURL
        }
        guard let url = resolved else {
            throw ManifestError.invalidEntry(component: component, branch: branch, reason: "bad url \(raw)")
        }
        try validateScheme(url)
        return url.isFileURL ? url.standardizedFileURL : url
    }

    static func validateScheme(_ url: URL) throws {
        switch url.scheme?.lowercased() {
        case "file", "https": return
        default: throw ManifestError.insecureURL(url.absoluteString)
        }
    }
}

/// Loads `manifest.json` from file:// or https:// (never plain http).
public enum ManifestLoader {
    public static func load(_ url: URL, session: URLSession = .shared) async throws -> Manifest {
        try Manifest.validateScheme(url)
        let data: Data
        if url.isFileURL {
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ManifestError.loadFailed(url: url.absoluteString, reason: error.localizedDescription)
            }
        } else {
            let response: URLResponse
            do {
                (data, response) = try await session.data(from: url)
            } catch {
                throw ManifestError.loadFailed(url: url.absoluteString, reason: error.localizedDescription)
            }
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw ManifestError.loadFailed(url: url.absoluteString, reason: "HTTP \(http.statusCode)")
            }
        }
        return try Manifest.decode(from: data, manifestURL: url)
    }
}
