import Foundation
import Testing
@testable import RAMPCore

@Suite struct LogTailReaderTests {
    private let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "ramp-logtail-\(UUID().uuidString)",
                                                               directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func file(_ name: String = "test.log") -> URL { dir.appending(path: name) }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func append(_ data: Data, to url: URL) throws {
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: data)
        try h.close()
    }

    private func append(_ text: String, to url: URL) throws { try append(Data(text.utf8), to: url) }

    @Test func tailOfLargeFileReturnsLastLines() throws {
        let url = file()
        try write((1...10_000).map { "line \($0)" }.joined(separator: "\n") + "\n", to: url)
        var reader = LogTailReader(url: url)
        let lines = try reader.initial(maxBytes: 512 * 1024, maxLines: 100)
        #expect(lines.count == 100)
        #expect(lines.first == "line 9901")
        #expect(lines.last == "line 10000")
    }

    @Test func byteLimitDropsCutFirstLine() throws {
        let url = file()
        try write((1...1000).map { "line \($0)" }.joined(separator: "\n") + "\n", to: url)
        var reader = LogTailReader(url: url)
        let lines = try reader.initial(maxBytes: 100, maxLines: 2000)
        #expect(!lines.isEmpty)
        #expect(lines.last == "line 1000")
        #expect(lines.allSatisfy { $0.hasPrefix("line ") })   // no cut fragment like "ne 988"
        #expect(lines.count < 12)
    }

    @Test func appendYieldsOnlyNewLines() throws {
        let url = file()
        try write("a\nb\n", to: url)
        var reader = LogTailReader(url: url)
        #expect(try reader.initial() == ["a", "b"])
        #expect(try reader.poll() == .init(lines: [], reset: false))
        try append("c\nd\n", to: url)
        #expect(try reader.poll() == .init(lines: ["c", "d"], reset: false))
    }

    @Test func partialLineCompletedOnNextPoll() throws {
        let url = file()
        try write("first\nsec", to: url)
        var reader = LogTailReader(url: url)
        #expect(try reader.initial() == ["first"])
        try append("ond\r\nthi", to: url)
        #expect(try reader.poll().lines == ["second"])
        try append("rd\n", to: url)
        #expect(try reader.poll().lines == ["third"])
    }

    @Test func truncateResets() throws {
        let url = file()
        try write("one\ntwo\nthree\n", to: url)
        var reader = LogTailReader(url: url)
        _ = try reader.initial()
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: 0)
        try h.close()
        try append("new\n", to: url)
        #expect(try reader.poll() == .init(lines: ["new"], reset: true))
        try append("more\n", to: url)
        #expect(try reader.poll() == .init(lines: ["more"], reset: false))
    }

    @Test func rotationResets() throws {
        let url = file()
        try write("old 1\nold 2\n", to: url)
        var reader = LogTailReader(url: url)
        _ = try reader.initial()
        // LogSink rotation: rename to .1, create a fresh file (possibly already larger than before).
        try FileManager.default.moveItem(at: url, to: file("test.log.1"))
        try write("fresh 1\nfresh 2\nfresh 3 is longer than the old content\n", to: url)
        #expect(try reader.poll() == .init(lines: ["fresh 1", "fresh 2", "fresh 3 is longer than the old content"],
                                           reset: true))
    }

    @Test func invalidUTF8DoesNotThrow() throws {
        let url = file()
        try write("ok\n", to: url)
        var reader = LogTailReader(url: url)
        _ = try reader.initial()
        try append(Data([0x62, 0x61, 0x64, 0xFF, 0xFE, 0x0A]), to: url)
        let lines = try reader.poll().lines
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("bad"))
        #expect(lines[0].contains("\u{FFFD}"))
    }

    @Test func emptyFile() throws {
        let url = file()
        try write("", to: url)
        var reader = LogTailReader(url: url)
        #expect(try reader.initial().isEmpty)
        #expect(try reader.poll() == .init(lines: [], reset: false))
    }

    @Test func missingFileResetsOnceItAppears() throws {
        let url = file("later.log")
        var reader = LogTailReader(url: url)
        #expect(try reader.initial().isEmpty)
        #expect(try reader.poll() == .init(lines: [], reset: false))
        try write("hello\n", to: url)
        #expect(try reader.poll() == .init(lines: ["hello"], reset: true))
        #expect(try reader.poll() == .init(lines: [], reset: false))
        try FileManager.default.removeItem(at: url)
        #expect(try reader.poll() == .init(lines: [], reset: false))
        try write("again\n", to: url)
        #expect(try reader.poll() == .init(lines: ["again"], reset: true))
    }

    @Test func largeCatchUpIsChunked() throws {
        let url = file()
        try write("", to: url)
        var reader = LogTailReader(url: url)
        _ = try reader.initial()
        let line = String(repeating: "x", count: 1023) + "\n"   // 1 KiB
        try append(String(repeating: line, count: 5 * 1024), to: url)   // 5 MiB
        let first = try reader.poll()
        #expect(first.lines.count == 4 * 1024)
        let second = try reader.poll()
        #expect(second.lines.count == 1024)
        #expect(try reader.poll().lines.isEmpty)
    }

    // MARK: LogCatalog

    @Test func catalogListsLogsGroupedAndSorted() throws {
        for name in ["redis.log", "apache-error.log", "php8.3-fpm.log", "php8.10-error.log", "php7.3-fpm.log",
                     "mysql9.7.err", "apache.log", "apache.log.1", "notes.txt", "custom.log", "elasticsearch.log"] {
            try write("x\n", to: file(name))
        }
        try FileManager.default.createDirectory(at: file("xdebug"), withIntermediateDirectories: true)
        try write("x\n", to: dir.appending(path: "xdebug/cachegrind.out.log"))
        let files = LogCatalog.files(in: dir)
        #expect(files.map(\.name) == ["apache-error.log", "apache.log", "php7.3-fpm.log", "php8.3-fpm.log",
                                      "php8.10-error.log", "mysql9.7.err", "redis.log", "elasticsearch.log",
                                      "custom.log"])
        #expect(files[2].group == .php("7.3"))
        #expect(files[0].size == 2)
        #expect(LogCatalog.files(in: dir.appending(path: "missing")).isEmpty)
    }

    @Test func catalogListsElasticsearchServerLog() throws {
        try write("x\n", to: file("elasticsearch.log"))
        try FileManager.default.createDirectory(at: file("elasticsearch"), withIntermediateDirectories: true)
        try write("y\n", to: dir.appending(path: "elasticsearch/elasticsearch.log"))
        try write("z\n", to: dir.appending(path: "elasticsearch/gc.log"))
        let files = LogCatalog.files(in: dir)
        #expect(files.map(\.name) == ["elasticsearch.log", "elasticsearch/elasticsearch.log"])
        #expect(files.allSatisfy { $0.group == .elasticsearch })
    }

    @Test func preferredFileNames() {
        #expect(LogCatalog.preferredFileName(for: .apache) == "apache-error.log")
        #expect(LogCatalog.preferredFileName(for: .phpFPM("8.4")) == "php8.4-error.log")
        #expect(LogCatalog.preferredFileName(for: .mysql("9.7")) == "mysql9.7.err")
        #expect(LogCatalog.preferredFileName(for: .redis) == "redis.log")
        #expect(LogCatalog.preferredFileName(for: .elasticsearch) == "elasticsearch/elasticsearch.log")
    }
}
