import Foundation
import Testing
@testable import RAMPCore

@Suite struct SiteStoreTests {
    private func tempStore() -> (SiteStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ramp-sites-\(UUID().uuidString)", directoryHint: .isDirectory)
        return (SiteStore(url: dir.appending(path: "remote/sites.json")), dir)
    }

    @Test func missingFileIsEmpty() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try store.load() == [])
        #expect(store.groups() == [])
    }

    @Test func upsertDeleteAndSorting() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let b = RemoteSite(name: "shop 10", proto: .sftp, host: "b.example", username: "u", group: "Klienti")
        let a = RemoteSite(name: "shop 2", proto: .ftpes, host: "a.example", username: "u", group: "Klienti")
        let c = RemoteSite(name: "zeta", proto: .ftp, host: "c.example", username: "u")
        let d = RemoteSite(name: "alfa", proto: .ftps, host: "d.example", username: "u", group: "Archív")

        try store.upsert(b)
        try store.upsert(a)
        try store.upsert(c)
        let all = try store.upsert(d)
        #expect(all.map(\.name) == ["zeta", "alfa", "shop 2", "shop 10"])
        #expect(try store.load() == all)
        #expect(store.groups() == ["Archív", "Klienti"])

        var edited = a
        edited.name = "shop 1"
        edited.port = 2121
        let afterEdit = try store.upsert(edited)
        #expect(afterEdit.count == 4)
        #expect(afterEdit.first { $0.id == a.id }?.port == 2121)

        let afterDelete = try store.delete(id: c.id)
        #expect(afterDelete.map(\.id).contains(c.id) == false)
        #expect(try store.load().count == 3)
    }

    @Test func fileFormatBackupAndPermissions() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let site = RemoteSite(name: "one", proto: .sftp, host: "h", username: "u")
        try store.save([site])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        #expect(json?["version"] as? Int == 1)
        #expect((json?["sites"] as? [Any])?.count == 1)

        try store.save([site, RemoteSite(name: "two", proto: .ftp, host: "h2", username: "u")])
        let backup = store.url.appendingPathExtension("bak")
        let backupJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any]
        #expect((backupJSON?["sites"] as? [Any])?.count == 1)

        let attrs = try FileManager.default.attributesOfItem(atPath: store.url.path(percentEncoded: false))
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let dirAttrs = try FileManager.default.attributesOfItem(
            atPath: store.url.deletingLastPathComponent().path(percentEncoded: false))
        #expect((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func corruptFileThrowsAndIsKept() throws {
        let (store, dir) = tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: store.url)
        #expect(throws: RemoteError.self) { try store.load() }
        #expect(throws: RemoteError.self) {
            try store.upsert(RemoteSite(name: "x", proto: .ftp, host: "h", username: "u"))
        }
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "{not json")
    }
}
