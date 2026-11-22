import Foundation

enum Search {
    static func isPathQuery(_ query: String) -> Bool {
        query.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("path:")
    }

    static func filter(_ items: [ClipItem], query: String, mode: SearchMode) -> [ClipItem] {
        if isPathQuery(query) {
            let path = String(query.trimmingCharacters(in: .whitespaces).dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, let matcher = try? JSONPathQuery(path) else { return [] }
            return items.filter { item in
                guard !Task.isCancelled else { return false }
                guard item.kind == .text, let document = JSONDocumentCache.shared.document(item.text) else { return false }
                return document.nodes.contains { matcher.matches($0.path) }
            }
        }
        switch mode {
        case .exact:
            return items.filter { $0.searchText.localizedCaseInsensitiveContains(query) }
        case .regex:
            return items.filter { $0.searchText.range(of: query, options: [.regularExpression, .caseInsensitive]) != nil }
        case .fuzzy:
            return items.filter { fuzzy($0.searchText, query) }
        case .mixed:
            // 精确匹配排最前，其次正则，最后模糊
            var seen = Set<UUID>()
            var result: [ClipItem] = []
            for pass in [SearchMode.exact, .regex, .fuzzy] {
                for item in filter(items, query: query, mode: pass) where seen.insert(item.id).inserted {
                    result.append(item)
                }
            }
            return result
        }
    }

    /// 关键词里的字符按顺序出现在文本中即算匹配
    static func fuzzy(_ text: String, _ query: String) -> Bool {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return true }
        var i = 0
        for ch in text.lowercased() where ch == q[i] {
            i += 1
            if i == q.count { return true }
        }
        return false
    }
}
