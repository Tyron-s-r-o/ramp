import Foundation
import Testing
@testable import RAMPCore

@Suite struct RESPParserTests {
    private func parse(_ s: String) throws -> RESPValue {
        try RESPParser.parse(Data(s.utf8))
    }

    @Test func simpleErrorInteger() throws {
        #expect(try parse("+OK\r\n") == .simple("OK"))
        #expect(try parse("-ERR unknown command\r\n") == .error("ERR unknown command"))
        #expect(try parse(":1000\r\n") == .integer(1000))
        #expect(try parse(":-2\r\n") == .integer(-2))
    }

    @Test func bulkAndNulls() throws {
        #expect(try parse("$5\r\nhello\r\n") == .bulk(Data("hello".utf8)))
        #expect(try parse("$0\r\n\r\n") == .bulk(Data()))
        #expect(try parse("$-1\r\n") == .null)
        #expect(try parse("*-1\r\n") == .null)
        #expect(try parse("_\r\n") == .null)
    }

    @Test func bulkIsBinarySafe() throws {
        var raw = Data("$6\r\n".utf8)
        let payload = Data([0x00, 0xFF, 0x0D, 0x0A, 0x80, 0x41])
        raw.append(payload)
        raw.append(Data("\r\n".utf8))
        #expect(try RESPParser.parse(raw) == .bulk(payload))
    }

    @Test func arraysNested() throws {
        let v = try parse("*3\r\n:1\r\n*2\r\n+a\r\n$1\r\nb\r\n$-1\r\n")
        #expect(v == .array([.integer(1), .array([.simple("a"), .bulk(Data("b".utf8))]), .null]))
        #expect(try parse("*0\r\n") == .array([]))
    }

    @Test func resp3Types() throws {
        #expect(try parse("%2\r\n+a\r\n:1\r\n+b\r\n:2\r\n")
                == .map([RESPPair(.simple("a"), .integer(1)), RESPPair(.simple("b"), .integer(2))]))
        #expect(try parse("~2\r\n+x\r\n+y\r\n") == .set([.simple("x"), .simple("y")]))
        #expect(try parse(">2\r\n+message\r\n+hi\r\n") == .push([.simple("message"), .simple("hi")]))
        #expect(try parse(",3.14\r\n") == .double(3.14))
        #expect(try parse(",inf\r\n") == .double(.infinity))
        #expect(try parse("#t\r\n") == .boolean(true))
        #expect(try parse("#f\r\n") == .boolean(false))
        #expect(try parse("(3492890328409238509324850943850943825024385\r\n")
                == .bigNumber("3492890328409238509324850943850943825024385"))
        #expect(try parse("!21\r\nSYNTAX invalid syntax\r\n") == .error("SYNTAX invalid syntax"))
        #expect(try parse("=15\r\ntxt:Some string\r\n") == .verbatim(format: "txt", Data("Some string".utf8)))
        // Attribute is skipped, the following reply returned.
        #expect(try parse("|1\r\n+ttl\r\n:3600\r\n:42\r\n") == .integer(42))
    }

    @Test func mapFlattensToRESP2Shape() throws {
        let v = try parse("%1\r\n$1\r\nk\r\n$1\r\nv\r\n")
        #expect(v.elements == [.bulk(Data("k".utf8)), .bulk(Data("v".utf8))])
    }

    @Test func partialReadsByteByByte() throws {
        let raw = Array("*2\r\n$5\r\nhello\r\n%1\r\n+k\r\n*1\r\n:7\r\n+NEXT\r\n".utf8)
        var p = RESPParser()
        var values: [RESPValue] = []
        for b in raw {
            p.append([b])
            while let v = try p.next() { values.append(v) }
        }
        #expect(values == [
            .array([.bulk(Data("hello".utf8)), .map([RESPPair(.simple("k"), .array([.integer(7)]))])]),
            .simple("NEXT"),
        ])
        #expect(p.pending == 0)
    }

    @Test func incompleteReturnsNil() throws {
        var p = RESPParser()
        p.append(Data("$11\r\nhel".utf8))
        #expect(try p.next() == nil)
        p.append(Data("lo worl".utf8))
        #expect(try p.next() == nil)
        p.append(Data("d\r".utf8))
        #expect(try p.next() == nil)
        p.append(Data("\n".utf8))
        #expect(try p.next() == .bulk(Data("hello world".utf8)))
    }

    @Test func multipleRepliesInOneChunk() throws {
        var p = RESPParser()
        p.append(Data("+string\r\n:5\r\n$3\r\nabc\r\n".utf8))
        #expect(try p.next() == .simple("string"))
        #expect(try p.next() == .integer(5))
        #expect(try p.next() == .bulk(Data("abc".utf8)))
        #expect(try p.next() == nil)
    }

    @Test func protocolErrors() {
        #expect(throws: RESPError.self) { try parse("?what\r\n") }
        #expect(throws: RESPError.self) { try parse(":abc\r\n") }
        #expect(throws: RESPError.self) { try parse("$3\r\nabcd\r\n") }
        #expect(throws: RESPError.self) { try parse("$-5\r\n") }
        #expect(throws: RESPError.self) { try parse("+OK\r\n+extra\r\n") }
    }

    @Test func encoderBuildsBulkArray() {
        let d = RESPEncoder.command(["SET", "k", "vä"])
        #expect(String(decoding: d, as: UTF8.self) == "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$3\r\nvä\r\n")
    }

    @Test func accessors() {
        #expect(RESPValue.bulk(Data("12".utf8)).int == 12)
        #expect(RESPValue.simple("x").string == "x")
        #expect(RESPValue.integer(3).elements == nil)
        #expect(RESPValue.null.isNull)
    }
}
