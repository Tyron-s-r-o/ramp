import Foundation
import Testing
@testable import RAMPHostsKit

/// Exact content of a pristine macOS /etc/hosts.
let macOSDefaultHosts = """
##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1\tlocalhost
255.255.255.255\tbroadcasthost
::1             localhost

"""

@Suite("HostsBlock render/merge/parse")
struct HostsBlockTests {
    static let header = "# RAMP BEGIN — managed by RAMP, do not edit (changes are overwritten)"

    static let twoNamesBlock = """
    # RAMP BEGIN — managed by RAMP, do not edit (changes are overwritten)
    127.0.0.1\tasteel.local
    ::1\tasteel.local
    127.0.0.1\tfront.asteel.local
    ::1\tfront.asteel.local
    # RAMP END
    """

    // MARK: render

    @Test("render: exact format, sorted, deduped case-insensitively")
    func renderExact() throws {
        let out = try HostsBlock.render(names: ["front.asteel.local", "ASTEEL.local", "asteel.local."])
        #expect(out == Self.twoNamesBlock)
        #expect(HostsBlock.beginMarker == "# RAMP BEGIN")
        #expect(HostsBlock.endMarker == "# RAMP END")
        #expect(HostsBlock.beginLine == Self.header)
    }

    @Test("render: invalid name throws")
    func renderInvalid() {
        #expect(throws: HostsError.invalidHostname("bad name.local")) {
            try HostsBlock.render(names: ["asteel.local", "bad name.local"])
        }
    }

    @Test("render: too many names")
    func renderTooMany() throws {
        let names = (0...Hostname.maxNames).map { "h\($0).local" }
        #expect(throws: HostsError.tooManyNames(Hostname.maxNames + 1)) {
            try HostsBlock.render(names: names)
        }
        // exactly maxNames is fine
        _ = try HostsBlock.render(names: Array(names.prefix(Hostname.maxNames)))
    }

    // MARK: merge — append

    @Test("merge: append to macOS default keeps it byte-for-byte")
    func appendDefault() throws {
        let out = try HostsBlock.merge(existing: macOSDefaultHosts, names: ["front.asteel.local", "asteel.local"])
        #expect(out == macOSDefaultHosts + "\n" + Self.twoNamesBlock + "\n")
    }

    @Test("merge: file without trailing newline gets one")
    func appendNoTrailingNewline() throws {
        let out = try HostsBlock.merge(existing: "127.0.0.1\tlocalhost", names: ["asteel.local"])
        #expect(out == "127.0.0.1\tlocalhost\n\n" + (try HostsBlock.render(names: ["asteel.local"])) + "\n")
    }

    @Test("merge: empty file")
    func appendEmpty() throws {
        let out = try HostsBlock.merge(existing: "", names: ["asteel.local"])
        #expect(out == (try HostsBlock.render(names: ["asteel.local"])) + "\n")
    }

    @Test("merge: no block + no names → unchanged")
    func noBlockNoNames() throws {
        #expect(try HostsBlock.merge(existing: macOSDefaultHosts, names: []) == macOSDefaultHosts)
        #expect(try HostsBlock.merge(existing: "x", names: []) == "x")
    }

    // MARK: merge — replace / remove

    @Test("merge: replaces existing block in place, preserving surroundings")
    func replaceInPlace() throws {
        let before = "# top comment\n127.0.0.1\tmine.test\n\n"
        let after = "\n# user after\n10.0.0.5\tnas.lan   # comment\n"
        let existing = before + (try HostsBlock.render(names: ["old.local"])) + after
        let out = try HostsBlock.merge(existing: existing, names: ["asteel.local", "front.asteel.local"])
        #expect(out == before + Self.twoNamesBlock + after)
    }

    @Test("merge: markers with trailing whitespace and edited header recognized")
    func markerVariants() throws {
        let existing = "a\n# RAMP BEGIN (edited)   \n127.0.0.1\tx.local\n# RAMP END  \t\nb\n"
        let out = try HostsBlock.merge(existing: existing, names: ["asteel.local"])
        #expect(out == "a\n" + (try HostsBlock.render(names: ["asteel.local"])) + "\nb\n")
    }

    @Test("merge: empty names removes block and the blank line RAMP added")
    func removeBlock() throws {
        let added = try HostsBlock.merge(existing: macOSDefaultHosts, names: ["asteel.local"])
        #expect(try HostsBlock.merge(existing: added, names: []) == macOSDefaultHosts)
    }

    @Test("merge: removal in the middle removes one preceding blank line only")
    func removeMiddle() throws {
        let existing = "a\n\n\n" + (try HostsBlock.render(names: ["asteel.local"])) + "\nb\n"
        #expect(try HostsBlock.merge(existing: existing, names: []) == "a\n\nb\n")
    }

    @Test("merge: removal of a block at start of file")
    func removeAtStart() throws {
        let existing = (try HostsBlock.render(names: ["asteel.local"])) + "\nb\n"
        #expect(try HostsBlock.merge(existing: existing, names: []) == "b\n")
    }

    @Test("merge: removal of block at EOF without trailing newline")
    func removeAtEOFNoNewline() throws {
        let existing = "a\n\n" + (try HostsBlock.render(names: ["asteel.local"]))
        #expect(try HostsBlock.merge(existing: existing, names: []) == "a\n")
    }

    // MARK: idempotency

    @Test("merge: idempotent and order/case independent")
    func idempotent() throws {
        let inputs = [macOSDefaultHosts, "", "x", "a\n\n# RAMP BEGIN\n# RAMP END\nz"]
        for x in inputs {
            let n = ["front.asteel.local", "asteel.local", "admin.asteel.local"]
            let once = try HostsBlock.merge(existing: x, names: n)
            #expect(try HostsBlock.merge(existing: once, names: n) == once)
            #expect(try HostsBlock.merge(existing: x, names: ["ADMIN.asteel.local", "asteel.local", "Front.Asteel.Local", "asteel.local"]) == once)
            let removed = try HostsBlock.merge(existing: once, names: [])
            #expect(try HostsBlock.merge(existing: removed, names: []) == removed)
        }
    }

    // MARK: malformed

    @Test("merge: malformed blocks refused", arguments: [
        "a\n# RAMP BEGIN\n127.0.0.1\tx.local\n",
        "a\n# RAMP END\nb\n",
        "# RAMP BEGIN\n# RAMP END\n# RAMP BEGIN\n# RAMP END\n",
        "# RAMP END\n# RAMP BEGIN\n",
        "# RAMP BEGIN\n# RAMP BEGIN\n# RAMP END\n",
        "# RAMP BEGIN\n# RAMP END\n# RAMP END\n",
    ])
    func malformed(existing: String) {
        #expect {
            try HostsBlock.merge(existing: existing, names: ["asteel.local"])
        } throws: { error in
            if case HostsError.malformedBlock = error { return true }
            return false
        }
        #expect {
            try HostsBlock.merge(existing: existing, names: [])
        } throws: { error in
            if case HostsError.malformedBlock = error { return true }
            return false
        }
    }

    @Test("merge: > 1 MiB refused")
    func tooLarge() {
        let big = String(repeating: "#", count: HostsBlock.maxFileSize + 1)
        #expect(throws: HostsError.fileTooLarge) {
            try HostsBlock.merge(existing: big, names: ["asteel.local"])
        }
    }

    @Test("merge: invalid names refused before touching content")
    func mergeInvalid() {
        #expect(throws: HostsError.invalidHostname("evil\n127.0.0.1 bank.com")) {
            try HostsBlock.merge(existing: macOSDefaultHosts, names: ["evil\n127.0.0.1 bank.com"])
        }
    }

    // MARK: real hosts copy

    @Test("merge against a temp copy of the real /etc/hosts only appends the block")
    func realHostsCopy() throws {
        let data = try Data(contentsOf: URL(filePath: "/private/etc/hosts"))
        let tmp = FileManager.default.temporaryDirectory.appending(path: "ramp-hosts-copy-\(UUID().uuidString)")
        try data.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let original = try String(contentsOf: tmp, encoding: .utf8)
        // Skip the check if a RAMP block already exists on this machine.
        guard HostsBlock.names(in: original) == nil else { return }
        let out = try HostsBlock.merge(existing: original, names: ["asteel.local"])
        #expect(out.hasPrefix(original))
        let suffix = String(out.dropFirst(original.count))
        let expectedSuffix = (original.isEmpty || original.hasSuffix("\n") ? "" : "\n") + "\n"
            + (try HostsBlock.render(names: ["asteel.local"])) + "\n"
        #expect(suffix == expectedSuffix)
        let normalizedOriginal = original.isEmpty || original.hasSuffix("\n") ? original : original + "\n"
        #expect(try HostsBlock.merge(existing: out, names: []) == normalizedOriginal)
    }

    // MARK: names(in:) / foreignEntries

    @Test("names(in:) parses the block; nil without block")
    func parseNames() throws {
        #expect(HostsBlock.names(in: macOSDefaultHosts) == nil)
        let merged = try HostsBlock.merge(existing: macOSDefaultHosts, names: ["front.asteel.local", "asteel.local"])
        #expect(HostsBlock.names(in: merged) == ["asteel.local", "front.asteel.local"])
        #expect(HostsBlock.names(in: "# RAMP BEGIN\n# RAMP END\n") == [])
        #expect(HostsBlock.names(in: "# RAMP BEGIN\n127.0.0.1 a.local\n") == nil)
    }

    @Test("foreignEntries finds names mapped on non-RAMP lines")
    func foreign() throws {
        let existing = macOSDefaultHosts
            + "127.0.0.1\tasteel.local\tAlias.Local # MAMP PRO\n"
            + "# 127.0.0.1 commented.local\n"
            + "10.0.0.1 other.local#inline\n"
        let merged = try HostsBlock.merge(existing: existing, names: ["asteel.local", "front.asteel.local"])
        let found = HostsBlock.foreignEntries(
            in: merged,
            names: ["asteel.local", "front.asteel.local", "alias.local", "commented.local", "other.local"]
        )
        #expect(found == ["asteel.local", "alias.local", "other.local"])
    }
}
