import XCTest
@testable import MyClip

final class JSONDocumentTests: XCTestCase {
    func testTypesOrderUnicodeAndExactNumbersSurviveFormatting() throws {
        let source = #"{"z":123456789012345678901234567890,"a":0.1234567890123456789012345,"exp":1.20e+300,"yes":true,"no":false,"nil":null,"unicode":"你好\n\uD83D\uDE00","empty":[],"obj":{}}"#
        let document = try JSONDocument(source)
        XCTAssertEqual(document.root.children.map(\.name), ["z", "a", "exp", "yes", "no", "nil", "unicode", "empty", "obj"])
        XCTAssertEqual(document.root.children[0].kind, .number)
        XCTAssertEqual(document.root.children[3].kind, .boolean)
        XCTAssertEqual(document.root.children[5].kind, .null)
        XCTAssertEqual(document.root.children[6].value, "你好\n😀")
        let pretty = document.root.json(pretty: true)
        XCTAssertTrue(pretty.contains("123456789012345678901234567890"))
        XCTAssertTrue(pretty.contains("0.1234567890123456789012345"))
        XCTAssertTrue(pretty.contains("1.20e+300"))
        let roundTrip = try JSONDocument(pretty)
        XCTAssertEqual(roundTrip.root.json(pretty: false), document.root.json(pretty: false))
    }

    func testEscapedAndDuplicateKeysKeepDistinctNodeIdentities() throws {
        let document = try JSONDocument(#"{"a.b":{"":1},"a.b":2,"a\"b":"\\"}"#)
        XCTAssertEqual(Set(document.nodes.map(\.id)).count, document.nodes.count)
        XCTAssertEqual(document.root.children[0].nodePath, #"$["a.b"]"#)
        XCTAssertEqual(document.root.children[0].children[0].nodePath, #"$["a.b"][""]"#)
        XCTAssertEqual(try JSONDocument(document.root.json(pretty: false)).root.children.count, 3)
        XCTAssertEqual(try JSONPathQuery(#"$["a.b"]"#).matchingIDs(in: document).count, 2)
    }

    func testStrictJSONValidationRejectsMalformedInput() {
        for text in ["", " ", "{", "[1,]", #"{"x":1,}"#, "[01]", "[+1]", "[.1]", "[1.]", "[1e]", "[NaN]", "[Infinity]", "[TRUE]", "[true false]", #"{"x" 1}"#, "{} trailing", #"["\x"]"#, #"["\uD800"]"#, "[\"a\nb\"]"] {
            XCTAssertThrowsError(try JSONDocument(text), text)
        }
    }

    func testValidNumericGrammarAndFragments() throws {
        for value in ["0", "-0", "1", "-123", "0.5", "-0.01", "1E-4", "1e+7", "true", "false", "null", #""text""#] {
            XCTAssertEqual(try JSONDocument(value).root.json(pretty: false), value)
        }
        XCTAssertNoThrow(try JSONDocument("\t\n [1, 2] \r"))
    }

    func testPasteTransformsPreserveExactNumbersAndDoNotModifyInput() throws {
        let source = #"{"id":123456789012345678901234567890,"value":0.1234567890123456789012345}"#
        let formatted = try XCTUnwrap(TextTransform.jsonPretty.apply(source))
        XCTAssertEqual(TextTransform.jsonMinify.apply(formatted), source)
        XCTAssertNil(TextTransform.jsonPretty.apply("{bad json}"))
    }

    func testComplexityLimitsFailWithoutTruncatingTheSource() {
        let deep = String(repeating: "[", count: 130) + "0" + String(repeating: "]", count: 130)
        XCTAssertThrowsError(try JSONDocument(deep)) { XCTAssertEqual($0 as? JSONReadError, .tooComplex) }
        let large = "[\"" + String(repeating: "a", count: 4 * 1024 * 1024) + "\"]"
        XCTAssertThrowsError(try JSONDocument(large)) { XCTAssertEqual($0 as? JSONReadError, .tooLarge) }
        let many = "[" + Array(repeating: "0", count: 50_000).joined(separator: ",") + "]"
        XCTAssertThrowsError(try JSONDocument(many)) { XCTAssertEqual($0 as? JSONReadError, .tooComplex) }
    }

    func testSearchFindsKeysAndValuesButNotUnrelatedAncestors() throws {
        let document = try JSONDocument(#"{"users":[{"name":"Alice"},{"name":"Bob"}],"active":true}"#)
        XCTAssertEqual(document.matching("name", fuzzy: false).count, 2)
        XCTAssertEqual(document.matching("ALICE", fuzzy: false).count, 1)
        XCTAssertEqual(document.matching("Alc", fuzzy: true).count, 1)
        XCTAssertEqual(document.matching("acv", fuzzy: true).count, 1)
        XCTAssertEqual(document.matching("true", fuzzy: false).count, 1)
        let ids = document.matching("Alice", fuzzy: false)
        XCTAssertEqual(document.context(for: ids).count, 4)
    }

    func testCollapseExpandAndSearchContextAreIndependent() throws {
        let document = try JSONDocument(#"{"users":[{"name":"Alice"}],"other":0}"#)
        XCTAssertEqual(JSONTree.rows(in: document, expanded: []).count, 1)
        XCTAssertEqual(JSONTree.rows(in: document, expanded: [0]).count, 3)
        let matches = document.matching("Alice", fuzzy: false)
        XCTAssertEqual(JSONTree.rows(in: document, expanded: [], matches: matches).map(\.node.name), ["$", "users", "[0]", "name"])
        XCTAssertEqual(JSONTree.rows(in: document, expanded: [], matches: matches, collapsedMatches: [0]).count, 1)
        XCTAssertEqual(JSONTree.rows(in: document, expanded: [0], matches: []).count, 0)
        XCTAssertEqual(JSONTree.rows(in: document, expanded: [], matches: document.matching("users", fuzzy: false)).map(\.node.name), ["$", "users", "[0]", "name"])
    }
}
