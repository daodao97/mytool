import Foundation

/// 右键「处理后粘贴」里的文本转换
enum TextTransform: String, CaseIterable, Identifiable {
    case uppercase, lowercase, capitalized
    case trimmed, singleLine
    case urlEncode, urlDecode, base64Encode, base64Decode
    case jsonPretty, jsonMinify

    var id: String { rawValue }

    var title: String {
        switch self {
        case .uppercase: "转大写"
        case .lowercase: "转小写"
        case .capitalized: "单词首字母大写"
        case .trimmed: "去掉首尾空白"
        case .singleLine: "合并为一行"
        case .urlEncode: "URL 编码"
        case .urlDecode: "URL 解码"
        case .base64Encode: "Base64 编码"
        case .base64Decode: "Base64 解码"
        case .jsonPretty: "JSON 格式化"
        case .jsonMinify: "JSON 压缩"
        }
    }

    /// 菜单里每组的第一项，前面加分隔线
    var startsGroup: Bool {
        [.trimmed, .urlEncode, .jsonPretty].contains(self)
    }

    /// URL 编码时保留的字符（RFC 3986 unreserved）
    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 转换结果；不适用（如不是合法 JSON、Base64）时返回 nil
    func apply(_ text: String) -> String? {
        let result: String?
        switch self {
        case .uppercase: result = text.uppercased()
        case .lowercase: result = text.lowercased()
        case .capitalized: result = text.capitalized
        case .trimmed: result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .singleLine:
            result = text.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        case .urlEncode: result = text.addingPercentEncoding(withAllowedCharacters: Self.unreserved)
        case .urlDecode: result = text.removingPercentEncoding
        case .base64Encode: result = Data(text.utf8).base64EncodedString()
        case .base64Decode:
            result = Data(base64Encoded: text.filter { !$0.isWhitespace })
                .flatMap { String(data: $0, encoding: .utf8) }
        case .jsonPretty: result = Self.json(text, pretty: true)
        case .jsonMinify: result = Self.json(text, pretty: false)
        }
        guard let result, !result.isEmpty else { return nil }
        return result
    }

    private static func json(_ text: String, pretty: Bool) -> String? {
        guard let document = try? JSONDocument(text) else { return nil }
        return document.root.json(pretty: pretty)
    }
}
