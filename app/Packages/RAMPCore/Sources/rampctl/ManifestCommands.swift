import Foundation
import RAMPCore

// rampctl manifest validate — read-only: decode a manifest exactly like the app (plan 08-02).
//
//   rampctl manifest validate <url|path>             decode via ManifestLoader, print every entry
//   rampctl manifest validate - [--base <url>]       manifest JSON from stdin; relative / ${RAMP_DIST_BASE}
//                                                    URLs resolve against --base (default: cwd/manifest.json)
//   --verify-files                                   file:// entries: file exists, size + hash match
//
// Exit 0 = decodes (and files verify), 1 = invalid, 64 = usage.

let manifestUsageText = "       rampctl manifest validate <url|path|-> [--base <manifest-url>] [--verify-files]"

func manifestCommand(_ args: [String]) async -> Int32 {
    guard args.first == "validate", args.count >= 2 else { usage() }
    var source: String?
    var base: String?
    var verifyFiles = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--base":
            guard i + 1 < args.count else { usage() }
            base = args[i + 1]; i += 1
        case "--verify-files": verifyFiles = true
        default:
            guard source == nil else { usage() }
            source = args[i]
        }
        i += 1
    }
    guard let source else { usage() }

    let manifest: Manifest
    do {
        if source == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let url = base.map(manifestURL(from:)) ?? manifestURL(from: "manifest.json")
            manifest = try Manifest.decode(from: data, manifestURL: url)
        } else {
            manifest = try await ManifestLoader.load(manifestURL(from: source))
        }
    } catch {
        err("manifest invalid: \(error.localizedDescription)")
        return 1
    }

    out("manifest: \(manifest.manifestURL.absoluteString) (schema \(manifest.schema), generated \(manifest.generated ?? "?"))")
    var problems = 0
    for component in manifest.components.keys.sorted() {
        for branch in manifest.branches(of: component) {
            guard let e = manifest.entry(component: component, branch: branch) else { continue }
            let hash: String
            switch e.hash {
            case .sha256(let h): hash = "sha256:\(h.prefix(12))…"
            case .sha512(let h): hash = "sha512:\(h.prefix(12))…"
            }
            let support = e.support.map { "  support=\($0.rawValue)" + (e.eolDate.map { " eol=\($0)" } ?? "") } ?? ""
            out("  \(component) \(branch): \(e.version)  \(e.size.map { "\($0) B" } ?? "? B")  \(hash)\(support)  \(e.url.absoluteString)")
            guard verifyFiles, e.url.isFileURL else { continue }
            if let problem = verify(e) {
                err("    ✗ \(problem)")
                problems += 1
            }
        }
    }
    if problems > 0 {
        err("\(problems) entr\(problems == 1 ? "y" : "ies") failed file verification")
        return 1
    }
    out("ok: \(manifest.components.values.reduce(0) { $0 + $1.count }) entries")
    return 0
}

/// file:// entry → nil when the file exists and size + hash match, else a description.
private func verify(_ e: ManifestEntry) -> String? {
    let path = e.url.path(percentEncoded: false)
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let size = (attrs[.size] as? NSNumber)?.int64Value
    else { return "\(path): missing" }
    if let expected = e.size, expected != size { return "\(path): size \(size) ≠ \(expected)" }
    do {
        switch e.hash {
        case .sha256(let h): if try Checksum.sha256(of: e.url) != h { return "\(path): sha256 mismatch" }
        case .sha512(let h): if try Checksum.sha512(of: e.url) != h { return "\(path): sha512 mismatch" }
        }
    } catch {
        return "\(path): \(error.localizedDescription)"
    }
    return nil
}
