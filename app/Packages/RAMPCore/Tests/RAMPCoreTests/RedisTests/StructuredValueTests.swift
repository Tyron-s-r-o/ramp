import Foundation
import Testing
@testable import RAMPCore

@Suite struct PHPSerializedParserTests {
    private func parse(_ s: String) throws -> StructuredValue { try PHPSerializedParser.parse(s) }

    @Test func scalars() throws {
        #expect(try parse("N;") == .null)
        #expect(try parse("b:1;") == .bool(true))
        #expect(try parse("b:0;") == .bool(false))
        #expect(try parse("i:42;") == .int(42))
        #expect(try parse("i:-17;") == .int(-17))
        #expect(try parse("i:9223372036854775807;") == .int(.max))
        #expect(try parse("d:0.5;") == .double(0.5))
        #expect(try parse("d:-1.25;") == .double(-1.25))
        #expect(try parse("d:1.0E+25;") == .double(1e25))
        #expect(try parse("d:INF;") == .double(.infinity))
        #expect(try parse("d:-INF;") == .double(-.infinity))
        guard case .double(let nan) = try parse("d:NAN;") else { Issue.record("not double"); return }
        #expect(nan.isNaN)
        #expect(try parse(#"s:5:"hello";"#) == .string("hello"))
        #expect(try parse(#"s:0:"";"#) == .string(""))
    }

    @Test func stringLengthIsInUTF8Bytes() throws {
        // "Árvíztűrő" = 9 characters, 13 bytes; "žltý kôň" = 8 characters, 12 bytes.
        #expect(try parse(#"s:13:"Árvíztűrő";"#) == .string("Árvíztűrő"))
        #expect(try parse(#"s:12:"žltý kôň";"#) == .string("žltý kôň"))
        #expect(try parse(#"s:4:"😀";"#) == .string("😀"))
        // Quotes and semicolons inside the declared length are data.
        #expect(try parse(#"s:5:"a";b"";"#) == .string(#"a";b""#))
        // Character count instead of byte count is malformed.
        #expect(throws: StructuredParseError.self) { try parse(#"s:9:"Árvíztűrő";"#) }
    }

    @Test func arraysKeepOrderAndKeyTypes() throws {
        let v = try parse(#"a:3:{i:0;s:1:"x";s:3:"key";i:-5;i:7;a:0:{}}"#)
        #expect(v == .array([
            .init(key: .int(0), value: .string("x")),
            .init(key: .string("key"), value: .int(-5)),
            .init(key: .int(7), value: .array([])),
        ]))
        #expect(v.childCount == 3)
        #expect(try parse("a:0:{}") == .array([]))
    }

    @Test func objectPropertyManglingDecoded() throws {
        let v = try parse("O:3:\"Foo\":3:{s:3:\"pub\";i:1;s:6:\"\0*\0pro\";b:1;s:8:\"\0Foo\0pri\";N;}")
        #expect(v == .object(className: "Foo", properties: [
            .init(name: "pub", visibility: .public, value: .int(1)),
            .init(name: "pro", visibility: .protected, value: .bool(true)),
            .init(name: "pri", visibility: .private("Foo"), value: .null),
        ]))
    }

    @Test func realWorldApiResponse() throws {
        let s = #"O:33:"TyrionWeb\Lib\Classes\ApiResponse":3:{s:6:"status";s:7:"success";s:4:"data";a:2:{s:4:"page";O:8:"stdClass":2:{s:5:"title";s:15:"Pneumatiky ľš";s:5:"price";d:49.9;}s:5:"items";a:2:{i:0;a:2:{s:2:"id";i:12;s:4:"name";s:11:"Gumiabroncs";}i:1;a:0:{}}}s:7:"message";N;}"#
        let v = try parse(s)
        guard case .object(let cls, let props) = v else { Issue.record("not object"); return }
        #expect(cls == #"TyrionWeb\Lib\Classes\ApiResponse"#)
        #expect(props.map(\.name) == ["status", "data", "message"])
        #expect(v.node(at: [0]) == .string("success"))
        #expect(v.node(at: [1, 0, 0]) == .string("Pneumatiky ľš"))
        #expect(v.node(at: [1, 0, 1]) == .double(49.9))
        #expect(v.node(at: [1, 1, 0, 1]) == .string("Gumiabroncs"))
        #expect(v.node(at: [1, 1, 1]) == .array([]))
        #expect(v.node(at: [2]) == .null)
        #expect(v.node(at: [9]) == nil)
        #expect(v.path(of: [1, 0, 0]) == "data.page.title")
        #expect(v.path(of: [1, 1, 0, 1]) == "data.items[0].name")
        #expect(v.search("pneumatiky") == [[1, 0, 0]])
        #expect(v.search("ApiResponse") == [[]])
        #expect(v.search("NAME").count == 1)
    }

    @Test func customEnumReferences() throws {
        #expect(try parse(#"C:11:"ArrayObject":21:{x:i:0;a:0:{};m:a:0:{}}"#)
            == .custom(className: "ArrayObject", payload: "x:i:0;a:0:{};m:a:0:{}"))
        #expect(try parse(#"E:11:"Suit:Hearts";"#) == .enumCase(className: "Suit", caseName: "Hearts"))
        // $o = new stdClass; $o->self = $o; → r:1 points back at the object (no infinite loop).
        let cyclic = try parse(#"O:8:"stdClass":1:{s:4:"self";r:1;}"#)
        #expect(cyclic.node(at: [0]) == .reference(index: 1, byReference: false))
        #expect(cyclic.phpSlotPath(1) == [])
        // $a = [1]; $a[] = &$a[0]; → R:2 = slot of the first element.
        let refs = try parse("a:3:{i:0;i:1;i:1;R:2;i:2;a:1:{i:0;s:1:\"x\";}}")
        #expect(refs.node(at: [1]) == .reference(index: 2, byReference: true))
        #expect(refs.phpSlotPath(2) == [0])
        // R: doesn't take a slot: slot 3 is the nested array, 4 its element.
        #expect(refs.phpSlotPath(3) == [2])
        #expect(refs.phpSlotPath(4) == [2, 0])
        #expect(refs.phpSlotPath(99) == nil)
        #expect(cyclic.prettyText().contains("→ ref #1"))
    }

    @Test func toleratesSurroundingWhitespace() throws {
        #expect(try parse("  i:1;\n") == .int(1))
        #expect(try parse("a:0:{}\r\n") == .array([]))
    }

    @Test func malformedReportsByteOffset() {
        func offset(_ s: String) -> Int? {
            do { _ = try parse(s); return nil } catch { return (error as? StructuredParseError)?.offset }
        }
        #expect(offset(#"s:10:"short";"#) == 2)
        #expect(offset("a:2:{i:0;i:1;}") == 13)
        #expect(offset("i:12") == 4)
        #expect(offset("b:2;") == 2)
        #expect(offset("x:1;") == 0)
        #expect(offset("i:1;garbage") == 4)
        #expect(offset("d:abc;") == 2)
        #expect(offset("a:1:{d:1.0;i:1;}") == 5)
        #expect(offset("") == 0)
        #expect(offset(String(repeating: "a:1:{i:0;", count: 300) + "N;" + String(repeating: "}", count: 300)) != nil)
        #expect(offset(String(repeating: "a:1:{i:0;", count: 250) + "N;" + String(repeating: "}", count: 250)) == nil)
    }

    @Test func deepNestingWalksDoNotOverflow() throws {
        let v = try parse(String(repeating: "a:1:{i:0;", count: 250) + #"s:4:"deep";"# + String(repeating: "}", count: 250))
        let path = Array(repeating: 0, count: 250)
        #expect(v.search("deep") == [path])
        #expect(v.phpSlotPath(251) == path)
        #expect(v.prettyText().contains(#""deep""#))
        #expect(v.node(at: path) == .string("deep"))
    }

    @Test func prettyTextOfPHP() throws {
        let v = try parse("O:3:\"Foo\":3:{s:1:\"a\";a:2:{i:0;i:1;i:1;s:2:\"ž\";}s:4:\"\0*\0b\";a:1:{s:1:\"k\";d:INF;}s:6:\"\0Foo\0c\";a:0:{}}")
        #expect(v.prettyText() == """
        {
          "@class": "Foo",
          "a": [
            1,
            "ž"
          ],
          "b (protected)": {
            "k": INF
          },
          "c (private Foo)": []
        }
        """)
    }

    @Test func kindAndStructuredEntryPoint() throws {
        let d = Data(#"a:1:{s:1:"a";b:1;}"#.utf8)
        #expect(try RedisValueFormat.structured(d, kind: RedisValueFormat.kind(d)) == .array([.init(key: .string("a"), value: .bool(true))]))
        #expect(try RedisValueFormat.structured(Data("plain".utf8), kind: .text) == nil)
    }
}

@Suite struct OrderedJSONParserTests {
    @Test func keepsKeyOrderAndTypes() throws {
        let v = try OrderedJSONParser.parse(#"{"z":1,"a":{"s":"x"},"e":[],"o":{},"l":[1.5,-2,true,false,null],"big":12345678901234567890}"#)
        guard case .object(nil, let props) = v else { Issue.record("not object"); return }
        #expect(props.map(\.name) == ["z", "a", "e", "o", "l", "big"])
        #expect(v.node(at: [4]) == .array([
            .init(key: .int(0), value: .double(1.5)),
            .init(key: .int(1), value: .int(-2)),
            .init(key: .int(2), value: .bool(true)),
            .init(key: .int(3), value: .bool(false)),
            .init(key: .int(4), value: .null),
        ]))
        #expect(v.node(at: [5]) == .double(Double("12345678901234567890")!))
        #expect(v.path(of: [4, 2]) == "l[2]")
    }

    @Test func stringsAndEscapes() throws {
        #expect(try OrderedJSONParser.parse(#""a\"b\\c\/\n\tá😀""#) == .string("a\"b\\c/\n\tá😀"))
        #expect(try OrderedJSONParser.parse(#""Mikulášová, Győr""#) == .string("Mikulášová, Győr"))
        #expect(try OrderedJSONParser.parse(" 42 ") == .int(42))
    }

    @Test func rejectsInvalid() {
        for bad in ["{", "[1,]", #"{"a" 1}"#, "01", "tru", #""\x""#, "[1] x", "{'a':1}", "1.", "-"] {
            #expect(throws: StructuredParseError.self, "\(bad)") { try OrderedJSONParser.parse(bad) }
        }
    }

    @Test func agreesWithJSONSerialization() throws {
        let doc = #"{"a":[1,2,{"b":"č"}],"c":{"d":null,"e":0.25},"f":"x"}"#
        let v = try OrderedJSONParser.parse(doc)
        let reparsed = try JSONSerialization.jsonObject(with: Data(v.prettyText().utf8)) as? NSDictionary
        let original = try JSONSerialization.jsonObject(with: Data(doc.utf8)) as? NSDictionary
        #expect(reparsed == original)
    }

    @Test func pathsQuoteNonIdentifierKeys() {
        #expect(StructuredValue.appendPath("", .string("data")) == "data")
        #expect(StructuredValue.appendPath("data", .string("a.b")) == #"data["a.b"]"#)
        #expect(StructuredValue.appendPath("data", .int(3)) == "data[3]")
        #expect(StructuredValue.appendPath("", .string("1x")) == #"["1x"]"#)
    }

    @Test func searchIsDiacriticInsensitive() throws {
        let v = try OrderedJSONParser.parse(#"{"názov":"Žltá","list":["abc","ZLTA"]}"#)
        #expect(v.search("zlta") == [[0], [1, 1]])
        #expect(v.search("nazov") == [[0]])
        #expect(v.search("zlta", limit: 1) == [[0]])
        #expect(v.search("  ") == [])
    }
}
