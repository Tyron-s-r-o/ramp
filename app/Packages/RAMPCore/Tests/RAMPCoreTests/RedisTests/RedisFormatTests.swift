import Foundation
import Testing
@testable import RAMPCore

@Suite struct RedisFormatTests {
    @Test func kindDetection() {
        #expect(RedisValueFormat.kind(Data(#"{"a":1,"b":[true,null]}"#.utf8)) == .json)
        #expect(RedisValueFormat.kind(Data("  [1,2]".utf8)) == .json)
        #expect(RedisValueFormat.kind(Data("{broken".utf8)) == .text)
        #expect(RedisValueFormat.kind(Data("42".utf8)) == .text)
        #expect(RedisValueFormat.kind(Data(#"a:2:{i:0;s:1:"x";i:1;b:1;}"#.utf8)) == .phpSerialized)
        #expect(RedisValueFormat.kind(Data(#"O:8:"stdClass":1:{s:1:"a";i:1;}"#.utf8)) == .phpSerialized)
        #expect(RedisValueFormat.kind(Data(#"s:5:"hello";"#.utf8)) == .phpSerialized)
        #expect(RedisValueFormat.kind(Data("i:42;".utf8)) == .phpSerialized)
        #expect(RedisValueFormat.kind(Data("b:0;".utf8)) == .phpSerialized)
        #expect(RedisValueFormat.kind(Data("N;".utf8)) == .phpSerialized)
        #expect(RedisValueFormat.kind(Data("a: normal text".utf8)) == .text)
        #expect(RedisValueFormat.kind(Data([0x00, 0x01, 0xFF])) == .binary)
        #expect(RedisValueFormat.kind(Data("ok\u{0}".utf8)) == .binary)
        #expect(RedisValueFormat.kind(Data("čšž\ttab\nline".utf8)) == .text)
    }

    @Test func displayFallsBackToHex() {
        #expect(RedisValueFormat.display(Data("user:1".utf8)) == "user:1")
        #expect(RedisValueFormat.display(Data([0xDE, 0xAD, 0x00])) == "0xdead00")
    }

    @Test func hexDumpLayout() {
        let dump = RedisValueFormat.hexDump(Data("Hello, binary world!".utf8))
        let lines = dump.split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "00000000  48 65 6c 6c 6f 2c 20 62 69 6e 61 72 79 20 77 6f  |Hello, binary wo|")
        #expect(lines[1].hasPrefix("00000010  72 6c 64 21"))
        #expect(lines[1].hasSuffix("|rld!|"))
        #expect(RedisValueFormat.hexDump(Data(repeating: 0, count: 100), limit: 32).split(separator: "\n").count == 2)
    }

    @Test func prettyJSONKeepsOrder() {
        let pretty = RedisValueFormat.prettyJSON(#"{"z":1,"a":{"s":"x,{y}:\"q\""},"e":[],"o":{},"l":[1,2]}"#)
        #expect(pretty == """
        {
          "z": 1,
          "a": {
            "s": "x,{y}:\\"q\\""
          },
          "e": [],
          "o": {},
          "l": [
            1,
            2
          ]
        }
        """)
        #expect(RedisValueFormat.prettyJSON("not json") == "not json")
    }

    @Test func jsonTokens() {
        let text = #"{"k": "v", "n": -1.5e3, "b": true, "x": null}"#
        let toks = RedisValueFormat.jsonTokens(text)
        let u = Array(text.utf16)
        func str(_ r: Range<Int>) -> String { String(decoding: u[r], as: UTF16.self) }
        let keys = toks.filter { $0.kind == .key }.map { str($0.range) }
        #expect(keys == [#""k""#, #""n""#, #""b""#, #""x""#])
        #expect(toks.filter { $0.kind == .string }.map { str($0.range) } == [#""v""#])
        #expect(toks.filter { $0.kind == .number }.map { str($0.range) } == ["-1.5e3"])
        #expect(toks.filter { $0.kind == .literal }.map { str($0.range) } == ["true", "null"])
    }

    @Test func keyspaceParsing() {
        let info = "# Keyspace\r\ndb0:keys=12,expires=3,avg_ttl=100,subexpiry=0\r\ndb5:keys=1,expires=0,avg_ttl=0\r\n"
        let ks = RedisBrowserService.parseKeyspace(info)
        #expect(ks == [0: RedisDBStats(keys: 12, expires: 3), 5: RedisDBStats(keys: 1, expires: 0)])
        #expect(RedisBrowserService.parseKeyspace("# Keyspace\r\n").isEmpty)
    }

    @Test func namespaceTree() {
        let keys = ["user:1:name", "user:1:mail", "user:2:name", "user", "session:abc", "plain", "a::b"].map(RedisKey.init)
        let tree = RedisKeyTree.build(keys)
        #expect(tree.map(\.name) == ["a", "session", "user", "plain", "user"])
        #expect(tree.map(\.isFolder) == [true, true, true, false, false])
        let user = tree[2]
        #expect(user.count == 3)
        #expect(user.children?.map(\.name) == ["1", "2"])
        #expect(user.children?[0].children?.map(\.name) == ["mail", "name"])
        #expect(user.children?[0].children?[0].key?.name == "user:1:mail")
        // Empty segment gets a visible name.
        #expect(tree[0].children?.first?.name == "∅")
        #expect(tree[0].children?.first?.children?.first?.key?.name == "a::b")
        // Folder and key ids never collide.
        #expect(Set(tree.map(\.id)).count == tree.count)
    }
}
