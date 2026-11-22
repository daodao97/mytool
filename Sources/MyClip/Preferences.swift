import AppKit
import Carbon
import MyToolKit

enum SearchMode: String, CaseIterable, Identifiable {
    case exact, fuzzy, regex, mixed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .exact: "精确"
        case .fuzzy: "模糊"
        case .regex: "正则"
        case .mixed: "混合"
        }
    }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case open, pin, delete, preview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: "打开"
        case .pin: "置顶"
        case .delete: "删除"
        case .preview: "预览"
        }
    }

    var defaultShortcut: Shortcut {
        switch self {
        case .open: Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey), label: "V")
        case .pin: Shortcut(keyCode: UInt32(kVK_ANSI_P), modifiers: UInt32(optionKey), label: "P")
        case .delete: Shortcut(keyCode: UInt32(kVK_Delete), modifiers: UInt32(optionKey), label: "⌫")
        case .preview: Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey), label: "空格")
        }
    }

    /// 「打开」沿用旧版本的 key，已保存的快捷键不会丢
    fileprivate var defaultsKey: String { self == .open ? "shortcut" : "shortcut.\(rawValue)" }
}

@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()
    private let defaults = ToolStorage.defaults("MyClip")

    /// 没有条目表示该快捷键已清除
    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    @Published var searchMode: SearchMode {
        didSet { defaults.set(searchMode.rawValue, forKey: "searchMode") }
    }
    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: "autoPaste") }
    }
    @Published var plainTextPaste: Bool {
        didSet { defaults.set(plainTextPaste, forKey: "plainTextPaste") }
    }
    /// 非收藏、非置顶条目的最大保留数量
    @Published var maxHistory: Int {
        didSet { defaults.set(maxHistory, forKey: "maxHistory") }
    }
    /// 保留天数，0 表示永久
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: "retentionDays") }
    }
    @Published var recordImages: Bool {
        didSet { defaults.set(recordImages, forKey: "recordImages") }
    }
    @Published var recordFiles: Bool {
        didSet { defaults.set(recordFiles, forKey: "recordFiles") }
    }
    /// 用 Vision 识别图片里的文字，供搜索和复制
    @Published var recognizeText: Bool {
        didSet { defaults.set(recognizeText, forKey: "recognizeText") }
    }
    /// ⌃⌥1–9 不打开面板直接粘贴第 1–9 条
    @Published var quickPaste: Bool {
        didSet { defaults.set(quickPaste, forKey: "quickPaste") }
    }
    /// 不记录这些 App（bundle id）里复制的内容
    @Published private(set) var ignoredApps: [String] {
        didSet { defaults.set(ignoredApps, forKey: "ignoredApps") }
    }

    /// 由 PanelController 提供：注册全局呼出快捷键（nil 为注销），失败返回 false
    var registerOpen: ((Shortcut?) -> Bool)?
    @Published var shortcutWarning: String?

    private init() {
        searchMode = SearchMode(rawValue: defaults.string(forKey: "searchMode") ?? "") ?? .exact
        autoPaste = defaults.object(forKey: "autoPaste") as? Bool ?? true
        plainTextPaste = defaults.object(forKey: "plainTextPaste") as? Bool ?? true
        maxHistory = defaults.object(forKey: "maxHistory") as? Int ?? 200
        retentionDays = defaults.object(forKey: "retentionDays") as? Int ?? 0
        recordImages = defaults.object(forKey: "recordImages") as? Bool ?? true
        recordFiles = defaults.object(forKey: "recordFiles") as? Bool ?? true
        recognizeText = defaults.object(forKey: "recognizeText") as? Bool ?? true
        quickPaste = defaults.object(forKey: "quickPaste") as? Bool ?? true
        ignoredApps = defaults.stringArray(forKey: "ignoredApps")
            ?? ["com.apple.keychainaccess", "com.apple.Passwords"]
        for action in ShortcutAction.allCases {
            // key 不存在用默认值；存的是空数据表示用户清除了
            if let data = defaults.data(forKey: action.defaultsKey) {
                shortcuts[action] = try? JSONDecoder().decode(Shortcut.self, from: data)
            } else {
                shortcuts[action] = action.defaultShortcut
            }
        }
    }

    var openHostSettings: () -> Void = {}

    /// 设置快捷键，返回错误信息，nil 表示成功
    func setShortcut(_ shortcut: Shortcut?, for action: ShortcutAction) -> String? {
        if let shortcut,
           let other = ShortcutAction.allCases.first(where: { $0 != action && shortcuts[$0] == shortcut }) {
            return "\(shortcut.display) 已被「\(other.title)」使用"
        }
        if action == .open, let registerOpen, !registerOpen(shortcut) {
            return "\(shortcut?.display ?? "") 已被其他 App 占用"
        }
        shortcuts[action] = shortcut
        let data = shortcut.flatMap { try? JSONEncoder().encode($0) } ?? Data()
        defaults.set(data, forKey: action.defaultsKey)
        return nil
    }

    func ignoreApp(_ bundleID: String) {
        if !ignoredApps.contains(bundleID) { ignoredApps.append(bundleID) }
    }

    func unignoreApp(_ bundleID: String) {
        ignoredApps.removeAll { $0 == bundleID }
    }

    /// 录制「打开」快捷键期间先注销，否则按下它会被全局热键拦截
    func pauseOpenShortcut(_ paused: Bool) {
        _ = registerOpen?(paused ? nil : shortcuts[.open])
    }
}
