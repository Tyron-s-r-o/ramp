import Foundation
import Testing
@testable import RAMPHostsKit

@Suite("HostsFileWriter (temp files only)")
struct HostsFileWriterTests {
    /// Fresh temp directory per test; never touches /etc/hosts.
    final class TempDir {
        let url: URL
        init() throws {
            url = FileManager.default.temporaryDirectory.appending(path: "ramp-hostskit-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: url) }

        func file(_ name: String = "hosts", content: String, mode: Int = 0o644) throws -> URL {
            let f = url.appending(path: name)
            try Data(content.utf8).write(to: f)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: f.path)
            return f
        }

        func contents() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }
    }

    static func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    static func attrs(_ url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    @Test("system path constant is /private/etc/hosts")
    func systemPath() {
        #expect(HostsFileWriter.systemHostsPath == "/private/etc/hosts")
    }

    @Test("apply writes merged content, preserves mode, leaves no temp files")
    func applyWrites() throws {
        let dir = try TempDir()
        let f = try dir.file(content: macOSDefaultHosts, mode: 0o640)
        let changed = try HostsFileWriter(path: f).apply(names: ["front.asteel.local", "asteel.local"])
        #expect(changed)
        #expect(try Self.read(f) == (try HostsBlock.merge(existing: macOSDefaultHosts, names: ["asteel.local", "front.asteel.local"])))
        #expect((try Self.attrs(f)[.posixPermissions] as? Int) == 0o640)
        #expect(try dir.contents() == ["hosts"])
    }

    @Test("apply with identical result does not write (same inode, returns false)")
    func applyNoop() throws {
        let dir = try TempDir()
        let f = try dir.file(content: macOSDefaultHosts)
        let w = HostsFileWriter(path: f)
        #expect(try w.apply(names: ["asteel.local"]))
        let inode = try Self.attrs(f)[.systemFileNumber] as? Int
        #expect(try w.apply(names: ["ASTEEL.local"]) == false)
        #expect((try Self.attrs(f)[.systemFileNumber] as? Int) == inode)
        #expect(try w.apply(names: []))
        #expect(try Self.read(f) == macOSDefaultHosts)
        #expect(try w.apply(names: []) == false)
        #expect(try dir.contents() == ["hosts"])
    }

    @Test("symlink is refused")
    func symlinkRefused() throws {
        let dir = try TempDir()
        let target = try dir.file("real", content: macOSDefaultHosts)
        let link = dir.url.appending(path: "hosts")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: HostsError.notRegularFile) {
            try HostsFileWriter(path: link).apply(names: ["asteel.local"])
        }
        #expect(try Self.read(target) == macOSDefaultHosts)
        #expect(try dir.contents() == ["hosts", "real"])
    }

    @Test("directory is refused")
    func directoryRefused() throws {
        let dir = try TempDir()
        let sub = dir.url.appending(path: "hosts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: false)
        #expect(throws: HostsError.notRegularFile) {
            try HostsFileWriter(path: sub).apply(names: ["asteel.local"])
        }
    }

    @Test("missing file → io error")
    func missing() throws {
        let dir = try TempDir()
        #expect {
            try HostsFileWriter(path: dir.url.appending(path: "nope")).apply(names: ["asteel.local"])
        } throws: { error in
            if case HostsError.io = error { return true }
            return false
        }
    }

    @Test("oversized file refused, untouched")
    func oversized() throws {
        let dir = try TempDir()
        let big = String(repeating: "#", count: HostsBlock.maxFileSize + 10)
        let f = try dir.file(content: big)
        #expect(throws: HostsError.fileTooLarge) {
            try HostsFileWriter(path: f).apply(names: ["asteel.local"])
        }
        #expect(try Self.read(f) == big)
        #expect(try dir.contents() == ["hosts"])
    }

    @Test("malformed block refused, file untouched, no temp file")
    func malformed() throws {
        let dir = try TempDir()
        let content = macOSDefaultHosts + "# RAMP BEGIN\n127.0.0.1\tx.local\n"
        let f = try dir.file(content: content)
        #expect {
            try HostsFileWriter(path: f).apply(names: ["asteel.local"])
        } throws: { error in
            if case HostsError.malformedBlock = error { return true }
            return false
        }
        #expect(try Self.read(f) == content)
        #expect(try dir.contents() == ["hosts"])
    }

    @Test("rename failure cleans up temp file")
    func renameFailureCleansUp() throws {
        // Read-only directory: temp creation fails → io error, nothing left behind.
        let dir = try TempDir()
        let f = try dir.file(content: macOSDefaultHosts)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path) }
        #expect {
            try HostsFileWriter(path: f).apply(names: ["asteel.local"])
        } throws: { error in
            if case HostsError.io = error { return true }
            return false
        }
        #expect(try Self.read(f) == macOSDefaultHosts)
        #expect(try dir.contents() == ["hosts"])
    }
}

@Suite("Hosts helper constants")
struct HostsHelperConstantsTests {
    @Test("labels")
    func labels() {
        #expect(RAMPHostsHelper.label == "sk.tyron.ramp.hostshelper")
        #expect(RAMPHostsHelper.plistName == "sk.tyron.ramp.hostshelper.plist")
        #expect(RAMPHostsHelper.appIdentifier == "sk.tyron.ramp")
        #expect(RAMPHostsHelper.version == "1")
    }

    @Test("code signing requirement")
    func requirement() throws {
        #expect(try RAMPHostsHelper.codeSigningRequirement(identifier: "sk.tyron.ramp", teamID: "S25RFUK37U")
            == #"anchor apple generic and identifier "sk.tyron.ramp" and certificate leaf[subject.OU] = "S25RFUK37U""#)
    }

    @Test("invalid team IDs rejected", arguments: ["", "S25RFUK37", "S25RFUK37UX", "s25rfuk37u", "S25RFUK37\"", "S25RF K37U"])
    func invalidTeam(team: String) {
        #expect(throws: HostsError.invalidTeamID(team)) {
            try RAMPHostsHelper.codeSigningRequirement(identifier: "sk.tyron.ramp", teamID: team)
        }
    }

    @Test("invalid identifier rejected")
    func invalidIdentifier() {
        #expect(throws: HostsError.invalidIdentifier("sk.tyron\" or true")) {
            try RAMPHostsHelper.codeSigningRequirement(identifier: "sk.tyron\" or true", teamID: "S25RFUK37U")
        }
    }
}
