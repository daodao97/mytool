import XCTest
@testable import MyClip

final class JSONPathTests: XCTestCase {
    private let source = #"{"users":[{"name":"Alice","id":1},{"name":"Bob","id":2}],"nested":{"name":"Carol"},"a.b":{"x/y":{"~key":"value"}},"":{"0":true}}"#

    func testDotBracketWildcardAndRecursivePaths() throws {
        let document = try JSONDocument(source)
        for path in ["$.users[0].name", "users.0.name", "users[0].name", "/users/0/name"] {
            let ids = try JSONPathQuery(path).matchingIDs(in: document)
            XCTAssertEqual(ids.count, 1, path)
            XCTAssertEqual(document.nodes[try XCTUnwrap(ids.first)].value, "Alice")
        }
        XCTAssertEqual(try JSONPathQuery("$.users[*].name").matchingIDs(in: document).count, 2)
        XCTAssertEqual(try JSONPathQuery("$.users.*.name").matchingIDs(in: document).count, 2)
        XCTAssertEqual(try JSONPathQuery("$..name").matchingIDs(in: document).count, 3)
        XCTAssertEqual(try JSONPathQuery("$..*").matchingIDs(in: document).count, document.nodes.count - 1)
        XCTAssertEqual(try JSONPathQuery("$").matchingIDs(in: document), [0])
        XCTAssertEqual(try JSONPathQuery("$.Users").matchingIDs(in: document), [])
    }

    func testCanonicalPathAndPointerRoundTripForEveryNode() throws {
        let document = try JSONDocument(source)
        for node in document.nodes {
            XCTAssertTrue(try JSONPathQuery(node.nodePath).matches(node.path), node.nodePath)
            XCTAssertTrue(try JSONPathQuery(node.pointer).matches(node.path), node.pointer)
        }
        XCTAssertEqual(try JSONPathQuery("/a.b/x~1y/~0key").matchingIDs(in: document).count, 1)
        XCTAssertEqual(try JSONPathQuery(#"$['a.b']['x/y']['~key']"#).matchingIDs(in: document).count, 1)
        XCTAssertEqual(try JSONPathQuery(#"$[""]["0"]"#).matchingIDs(in: document).count, 1)
    }

    func testQuotedKeysHandleEscapedQuotesBackslashesAndUnicode() throws {
        let document = try JSONDocument(#"{"a'b":1,"a\"b":2,"\\":3,"中文":4,"😀":5}"#)
        for node in document.nodes.dropFirst() {
            XCTAssertTrue(try JSONPathQuery(node.nodePath).matches(node.path), node.nodePath)
        }
        XCTAssertEqual(try JSONPathQuery(#"$['a\'b']"#).matchingIDs(in: document).count, 1)
        XCTAssertEqual(try JSONPathQuery(#"$['a"b']"#).matchingIDs(in: document).count, 1)
    }

    func testInvalidAndUnsupportedPathsReturnErrors() {
        for path in ["$.", "$..", "users[", "users[]", "users[-1]", "users[01]", "users[0:2]", "users[?(@.id)]", "$.a b", "$foo", #"$["unfinished]"#, "/a~2b", "/a~"] {
            XCTAssertThrowsError(try JSONPathQuery(path), path)
        }
    }

    func testHistoryPathSearchOnlyReturnsJSONWithThatNode() {
        let first = ClipItem(text: source, date: Date())
        let second = ClipItem(text: #"{"other":1}"#, date: Date())
        let third = ClipItem(text: "path:$.users[0].name", date: Date())
        for mode in SearchMode.allCases {
            XCTAssertEqual(Search.filter([first, second, third], query: "path:$.users[*].name", mode: mode).map(\.id), [first.id])
        }
        XCTAssertEqual(Search.filter([first], query: "path:$.users[", mode: .mixed), [])
        XCTAssertEqual(Search.filter([first], query: "path:", mode: .exact), [])
        XCTAssertEqual(Search.filter([first], query: "path:/users/1/id", mode: .fuzzy).count, 1)
        XCTAssertEqual(Search.filter([first, second], query: "Alc", mode: .fuzzy).map(\.id), [first.id])
    }

    func testWideArrayRemainsSearchableBeyondTheFirstDisplayBatch() throws {
        let source = "{\"users\":[" + (0..<2000).map { "{\"id\":\($0)}" }.joined(separator: ",") + "]}"
        let document = try JSONDocument(source)
        let ids = try JSONPathQuery("$.users[*].id").matchingIDs(in: document)
        XCTAssertEqual(ids.count, 2000)
        let last = try XCTUnwrap(try JSONPathQuery("$.users[1999].id").matchingIDs(in: document).first)
        XCTAssertEqual(document.nodes[last].value, "1999")
        XCTAssertEqual(JSONTree.rows(in: document, expanded: [], matches: [last]).map(\.node.name), ["$", "users", "[1999]", "id"])
    }
}
