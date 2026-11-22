import Foundation

struct JSONPathQuery {
    enum Token { case member(String), key(String), index(Int), any, recursive(String?), pointer(String) }
    let tokens: [Token]

    enum PathError: LocalizedError {
        case invalid
        var errorDescription: String? { "路径无效。支持 $.users[0].name、$.users[*].name、$..name 和 /users/0/name。" }
    }

    init(_ text: String) throws {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.utf8.count <= 8192 else { throw PathError.invalid }
        if query.hasPrefix("/") {
            tokens = try query.dropFirst().components(separatedBy: "/").map { part in
                var decoded = "", index = part.startIndex
                while index < part.endIndex {
                    let character = part[index]; index = part.index(after: index)
                    if character == "~" {
                        guard index < part.endIndex else { throw PathError.invalid }
                        switch part[index] {
                        case "0": decoded.append("~")
                        case "1": decoded.append("/")
                        default: throw PathError.invalid
                        }
                        index = part.index(after: index)
                    } else { decoded.append(character) }
                }
                return .pointer(decoded)
            }
        } else {
            var parser = PathParser(characters: Array(query))
            tokens = try parser.parse()
        }
        guard tokens.count <= 256 else { throw PathError.invalid }
    }

    func matches(_ path: [JSONPathComponent]) -> Bool {
        var memo: [Int: Bool] = [:]
        func match(_ tokenIndex: Int, _ pathIndex: Int) -> Bool {
            let key = tokenIndex * (path.count + 1) + pathIndex
            if let cached = memo[key] { return cached }
            let result: Bool
            if tokenIndex == tokens.count { result = pathIndex == path.count }
            else if case .recursive(let name) = tokens[tokenIndex] {
                result = (pathIndex..<path.count).contains { index in
                    let accepts: Bool
                    if let name { accepts = path[index] == .key(name) } else { accepts = true }
                    return accepts && match(tokenIndex + 1, index + 1)
                }
            } else if pathIndex < path.count {
                let component = path[pathIndex]
                let accepts: Bool
                switch tokens[tokenIndex] {
                case .any: accepts = true
                case .key(let key): accepts = component == .key(key)
                case .index(let index): accepts = component == .index(index)
                case .member(let key), .pointer(let key):
                    switch component {
                    case .key(let value): accepts = key == value
                    case .index(let value): accepts = key == String(value)
                    }
                case .recursive: accepts = false
                }
                result = accepts && match(tokenIndex + 1, pathIndex + 1)
            } else { result = false }
            memo[key] = result; return result
        }
        return match(0, 0)
    }

    func matchingIDs(in document: JSONDocument) -> Set<Int> {
        Set(document.nodes.filter { matches($0.path) }.map(\.id))
    }
}

private struct PathParser {
    let characters: [Character]
    var position = 0
    var current: Character? { position < characters.count ? characters[position] : nil }
    mutating func take(_ character: Character) -> Bool {
        guard current == character else { return false }; position += 1; return true
    }
    mutating func parse() throws -> [JSONPathQuery.Token] {
        var tokens: [JSONPathQuery.Token] = []
        let rooted = take("$")
        if !rooted, current != nil, current != "[" { tokens.append(try member()) }
        while current != nil {
            if take(".") {
                if take(".") {
                    if take("*") { tokens.append(.recursive(nil)) }
                    else {
                        guard case .member(let name) = try member() else { throw JSONPathQuery.PathError.invalid }
                        tokens.append(.recursive(name))
                    }
                } else { tokens.append(try member()) }
            } else if take("[") {
                if take("*") { tokens.append(.any) }
                else if current == "\"" || current == "'" { tokens.append(.key(try quoted())) }
                else {
                    let start = position
                    while let c = current, c.isASCII, c.isNumber { position += 1 }
                    let digits = String(characters[start..<position])
                    guard let index = Int(digits), digits == String(index) else { throw JSONPathQuery.PathError.invalid }
                    tokens.append(.index(index))
                }
                guard take("]") else { throw JSONPathQuery.PathError.invalid }
            } else { throw JSONPathQuery.PathError.invalid }
        }
        return tokens
    }
    mutating func member() throws -> JSONPathQuery.Token {
        if take("*") { return .any }
        let start = position
        while let character = current, character.isLetter || character.isNumber || character == "_" || character == "$" { position += 1 }
        guard position > start else { throw JSONPathQuery.PathError.invalid }
        return .member(String(characters[start..<position]))
    }
    mutating func quoted() throws -> String {
        guard let quote = current else { throw JSONPathQuery.PathError.invalid }
        position += 1
        var encoded = "\""
        while let c = current {
            position += 1
            if c == quote {
                encoded.append("\"")
                guard let value = try? JSONDecoder().decode(String.self, from: Data(encoded.utf8)) else { throw JSONPathQuery.PathError.invalid }
                return value
            }
            if c == "\\" {
                guard let next = current else { throw JSONPathQuery.PathError.invalid }
                position += 1
                if next == "'", quote == "'" { encoded.append("'") }
                else { encoded.append("\\"); encoded.append(next) }
            } else if c == "\"" { encoded.append("\\\"") }
            else { encoded.append(c) }
        }
        throw JSONPathQuery.PathError.invalid
    }
}

struct JSONTreeRow: Identifiable {
    let node: JSONNode
    let expanded: Bool
    var id: Int { node.id }
}

enum JSONTree {
    /// Filtering exposes matching nodes and their ancestors without altering normal expansion state.
    static func rows(in document: JSONDocument, expanded: Set<Int>, matches: Set<Int>? = nil,
                     collapsedMatches: Set<Int> = []) -> [JSONTreeRow] {
        let context = matches.map { matches -> Set<Int> in
            var context = document.context(for: matches)
            var descendants = document.nodes.filter { matches.contains($0.id) && $0.isContainer }.flatMap(\.children)
            var visited: Set<Int> = []
            while let node = descendants.popLast() {
                guard visited.insert(node.id).inserted else { continue }
                context.insert(node.id)
                descendants.append(contentsOf: node.children)
            }
            return context
        }
        var rows: [JSONTreeRow] = [], stack = [document.root]
        while let node = stack.popLast() {
            if let context, !context.contains(node.id) { continue }
            let open = matches != nil ? !collapsedMatches.contains(node.id) : expanded.contains(node.id)
            rows.append(JSONTreeRow(node: node, expanded: open))
            if open { stack.append(contentsOf: node.children.reversed()) }
        }
        return rows
    }
}
