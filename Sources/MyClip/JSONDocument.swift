import Foundation

enum JSONReadError: LocalizedError, Equatable {
    case invalid, tooLarge, tooComplex
    var errorDescription: String? {
        switch self {
        case .invalid: return "不是有效的 JSON，已保留原文。"
        case .tooLarge: return "JSON 超过 4 MiB，使用原文预览。"
        case .tooComplex: return "JSON 超过 50,000 个节点或 128 层，使用原文预览。"
        }
    }
}

enum JSONPathComponent: Hashable, Sendable {
    case key(String), index(Int)
}

struct JSONNode: Identifiable, Sendable {
    enum Kind: String, Sendable { case object, array, string, number, boolean, null }
    let id: Int
    let kind: Kind
    /// Decoded string, or the original number/bool/null token. Numbers never pass through Double.
    let value: String
    let path: [JSONPathComponent]
    let children: [JSONNode]

    var isContainer: Bool { kind == .object || kind == .array }
    var name: String {
        switch path.last {
        case .key(let key): return key
        case .index(let index): return "[\(index)]"
        case nil: return "$"
        }
    }
    var nodePath: String {
        path.reduce("$") { result, component in
            switch component {
            case .index(let index): return result + "[\(index)]"
            case .key(let key):
                let simple = !key.isEmpty && key.unicodeScalars.enumerated().allSatisfy { index, scalar in
                    CharacterSet.letters.contains(scalar) || scalar == "_" || scalar == "$"
                        || (index > 0 && CharacterSet.decimalDigits.contains(scalar))
                }
                return result + (simple ? "." + key : "[" + Self.quote(key) + "]")
            }
        }
    }
    var pointer: String {
        path.map { component in
            let part: String
            switch component { case .key(let key): part = key; case .index(let index): part = String(index) }
            return "/" + part.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }.joined()
    }
    var summary: String {
        switch kind {
        case .object: return "{ \(children.count) 个字段 }"
        case .array: return "[ \(children.count) 项 ]"
        case .string: return Self.quote(String(value.prefix(300))) + (value.count > 300 ? " …" : "")
        default: return String(value.prefix(300))
        }
    }
    func json(pretty: Bool, level: Int = 0) -> String {
        if kind == .string { return Self.quote(value) }
        guard isContainer else { return value }
        let (open, close) = kind == .object ? ("{", "}") : ("[", "]")
        guard !children.isEmpty else { return open + close }
        let indent = pretty ? String(repeating: "  ", count: level + 1) : ""
        let entries = children.map { child in
            let key = kind == .object ? Self.quote(child.name) + (pretty ? ": " : ":") : ""
            return indent + key + child.json(pretty: pretty, level: level + 1)
        }
        return open + (pretty ? "\n" : "") + entries.joined(separator: pretty ? ",\n" : ",")
            + (pretty ? "\n" + String(repeating: "  ", count: level) : "") + close
    }
    static func quote(_ string: String) -> String {
        // JSONEncoder handles control characters, backslashes, and Unicode escaping correctly.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(string), as: UTF8.self)
    }
}

struct JSONDocument: Sendable {
    let source: String
    let root: JSONNode
    let nodes: [JSONNode]
    let parents: [Int: Int]

    init(_ text: String) throws {
        guard text.utf8.count <= 4 * 1024 * 1024 else { throw JSONReadError.tooLarge }
        var parser = JSONParser(bytes: Array(text.utf8))
        root = try parser.parse(path: [], depth: 0)
        parser.whitespace()
        guard parser.position == parser.bytes.count else { throw JSONReadError.invalid }
        source = text
        var nodes: [JSONNode] = [], parents: [Int: Int] = [:]
        var stack: [(JSONNode, Int?)] = [(root, nil)]
        while let (node, parent) = stack.popLast() {
            nodes.append(node)
            if let parent { parents[node.id] = parent }
            stack.append(contentsOf: node.children.reversed().map { ($0, node.id) })
        }
        self.nodes = nodes; self.parents = parents
    }

    func matching(_ query: String, fuzzy: Bool) -> Set<Int> {
        Set(nodes.filter { node in
            let text = node.name + "\n" + (node.isContainer ? "" : node.value)
            return fuzzy ? Search.fuzzy(text, query) : text.localizedCaseInsensitiveContains(query)
        }.map(\.id))
    }
    func context(for matches: Set<Int>) -> Set<Int> {
        var result = matches
        for id in matches {
            var parent = parents[id]
            while let id = parent {
                if !result.insert(id).inserted { break }
                parent = parents[id]
            }
        }
        return result
    }
}

/// Bounded recursive descent preserves object order, duplicate keys, and exact numeric tokens.
private struct JSONParser {
    let bytes: [UInt8]
    var position = 0
    var nextID = 0
    mutating func whitespace() { while position < bytes.count && [9, 10, 13, 32].contains(bytes[position]) { position += 1 } }
    mutating func consume(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else { return false }
        position += 1; return true
    }
    mutating func parse(path: [JSONPathComponent], depth: Int) throws -> JSONNode {
        guard depth <= 128, nextID < 50_000 else { throw JSONReadError.tooComplex }
        whitespace()
        guard position < bytes.count else { throw JSONReadError.invalid }
        let id = nextID; nextID += 1
        let kind: JSONNode.Kind
        var value = "", children: [JSONNode] = []
        switch bytes[position] {
        case 123, 91:
            let object = bytes[position] == 123
            kind = object ? .object : .array
            position += 1; whitespace()
            let close: UInt8 = object ? 125 : 93
            if !consume(close) {
                repeat {
                    whitespace()
                    let component: JSONPathComponent
                    if object {
                        component = .key(try string()); whitespace()
                        guard consume(58) else { throw JSONReadError.invalid }
                    } else { component = .index(children.count) }
                    children.append(try parse(path: path + [component], depth: depth + 1))
                    whitespace()
                    if consume(close) { break }
                    guard consume(44) else { throw JSONReadError.invalid }
                } while true
            }
        case 34: kind = .string; value = try string()
        case 116: kind = .boolean; value = try literal("true")
        case 102: kind = .boolean; value = try literal("false")
        case 110: kind = .null; value = try literal("null")
        default: kind = .number; value = try number()
        }
        return JSONNode(id: id, kind: kind, value: value, path: path, children: children)
    }
    mutating func string() throws -> String {
        let start = position
        guard consume(34) else { throw JSONReadError.invalid }
        while position < bytes.count {
            let byte = bytes[position]; position += 1
            if byte == 34 {
                guard let string = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<position])) else { throw JSONReadError.invalid }
                return string
            }
            if byte == 92 {
                guard position < bytes.count else { throw JSONReadError.invalid }
                position += 1
            } else if byte < 32 { throw JSONReadError.invalid }
        }
        throw JSONReadError.invalid
    }
    mutating func literal(_ text: String) throws -> String {
        let token = Array(text.utf8)
        guard position + token.count <= bytes.count, Array(bytes[position..<position + token.count]) == token else { throw JSONReadError.invalid }
        position += token.count; return text
    }
    mutating func number() throws -> String {
        let start = position
        _ = consume(45)
        if !consume(48) {
            guard position < bytes.count, (49...57).contains(bytes[position]) else { throw JSONReadError.invalid }
            digits()
        }
        if consume(46) { guard hasDigit else { throw JSONReadError.invalid }; digits() }
        if consume(101) || consume(69) {
            if !consume(43) { _ = consume(45) }
            guard hasDigit else { throw JSONReadError.invalid }; digits()
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }
    private var hasDigit: Bool { position < bytes.count && (48...57).contains(bytes[position]) }
    mutating func digits() { while hasDigit { position += 1 } }
}

/// Shared by cards, history path search and previews. Invalid JSON is cached too.
final class JSONDocumentCache: @unchecked Sendable {
    static let shared = JSONDocumentCache()
    private final class Entry: NSObject {
        let result: Result<JSONDocument, JSONReadError>
        init(_ result: Result<JSONDocument, JSONReadError>) { self.result = result }
    }
    private let cache = NSCache<NSString, Entry>()
    init() { cache.countLimit = 24; cache.totalCostLimit = 32 * 1024 * 1024 }
    static func isCandidate(_ text: String) -> Bool {
        let first = text.first(where: { !$0.isWhitespace })
        return first == "{" || first == "["
    }
    func result(_ text: String) -> Result<JSONDocument, JSONReadError>? {
        guard Self.isCandidate(text) else { return nil }
        if let entry = cache.object(forKey: text as NSString) { return entry.result }
        let result: Result<JSONDocument, JSONReadError>
        do { result = .success(try JSONDocument(text)) }
        catch { result = .failure(error as? JSONReadError ?? .invalid) }
        let count = (try? result.get().nodes.count) ?? 0
        cache.setObject(Entry(result), forKey: text as NSString, cost: text.utf8.count * 2 + count * 256)
        return result
    }
    func document(_ text: String) -> JSONDocument? { try? result(text)?.get() }
}
