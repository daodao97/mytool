import AppKit
import Combine
import UniformTypeIdentifiers

struct ClipItem: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case text, image, file
    }

    var id = UUID()
    /// 文本内容；图片为「图片 宽×高」，文件为换行分隔的路径，都可以被搜索
    var text: String
    var date: Date
    var isFavorite = false
    /// 置顶的条目始终排在列表最前面
    var isPinned = false
    /// 复制来源 App 的 bundle id
    var sourceApp: String?
    /// 复制时附带的富文本（RTF），用于带格式粘贴
    var rtf: Data?
    var kind: Kind = .text
    /// 图片条目在 ImageStore 里的文件名
    var imageFile: String?
    /// 图片像素尺寸，如「1920×1080」
    var imageSize: String?
    /// 文件条目的路径
    var paths: [String]?
    /// 图片里识别出的文字；空字符串表示已识别但没有文字，nil 表示还没识别
    var ocrText: String?

    private enum CodingKeys: String, CodingKey {
        case id, text, date, isFavorite, isPinned, sourceApp, rtf, kind, imageFile, imageSize, paths, ocrText
    }

    /// 搜索用的文本，图片包含识别出的文字
    var searchText: String {
        guard let ocrText, !ocrText.isEmpty else { return text }
        return text + "\n" + ocrText
    }

    var preview: String {
        String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
    }

    var isLink: Bool {
        guard kind == .text else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !t.contains(where: \.isWhitespace) && (t.hasPrefix("http://") || t.hasPrefix("https://"))
    }

    var isJSONCandidate: Bool { kind == .text && JSONDocumentCache.isCandidate(text) }

    var fileURLs: [URL] {
        (paths ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// 直接复制的图片和访达中复制的单张图片共用预览入口。
    @MainActor var previewImageURL: URL? {
        if kind == .image, let imageFile { return ImageStore.url(imageFile) }
        guard kind == .file, let paths, paths.count == 1 else { return nil }
        let url = URL(fileURLWithPath: paths[0])
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
        return url
    }

    var typeTitle: String {
        switch kind {
        case .text: isLink ? "链接" : "文本"
        case .image: "图片"
        case .file: fileURLs.count > 1 ? "\(fileURLs.count) 个文件" : "文件"
        }
    }

    /// 卡片底部的说明：字数、图片尺寸或文件所在目录
    var detail: String {
        switch kind {
        case .text:
            return "\(text.count) 个字符"
        case .image:
            let size = imageSize ?? ""
            return ocrText?.isEmpty == false ? "\(size) · 含文字" : size
        case .file:
            guard let first = fileURLs.first else { return "" }
            return (first.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        }
    }

    /// 同一内容再次复制时合并为一条
    func isSameContent(as other: ClipItem) -> Bool {
        guard kind == other.kind else { return false }
        return kind == .image ? imageFile == other.imageFile : text == other.text
    }
}

extension ClipItem {
    // 兼容旧版本保存的数据（缺少后来新增的字段）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        date = try c.decode(Date.self, forKey: .date)
        isFavorite = try c.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        sourceApp = try c.decodeIfPresent(String.self, forKey: .sourceApp)
        rtf = try c.decodeIfPresent(Data.self, forKey: .rtf)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
        imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile)
        imageSize = try c.decodeIfPresent(String.self, forKey: .imageSize)
        paths = try c.decodeIfPresent([String].self, forKey: .paths)
        ocrText = try c.decodeIfPresent(String.self, forKey: .ocrText)
    }
}

@MainActor
final class ClipStore: ObservableObject {
    @Published private(set) var items: [ClipItem] = [] { didSet { historyRevision += 1 } }
    @Published private(set) var historyRevision = 0
    @Published private(set) var isSearchingPath = false
    private var pathQuery = ""
    private var pathRevision = -1
    private var pathMatches: Set<UUID> = []
    /// 暂停记录直到这个时间；distantFuture 表示直到手动恢复
    @Published private(set) var pausedUntil: Date?

    private let prefs = Preferences.shared
    /// 超过这个大小的富文本不保存，避免历史文件膨胀
    private let maxRTFSize = 512 * 1024
    /// 超过这个大小的图片不记录
    private let maxImageSize = 50 * 1024 * 1024
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var timers: [Timer] = []
    private var cancellables = Set<AnyCancellable>()
    private let fileURL: URL

    private static let ignoredTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
        .init("com.agilebits.onepassword"),
    ]

    init(monitorChanges: Bool = true) throws {
        try FileManager.default.createDirectory(at: ImageStore.dir, withIntermediateDirectories: true)
        fileURL = ImageStore.dir.deletingLastPathComponent().appendingPathComponent("history.json")
        try load()
        if trim() { save() }
        ImageStore.removeOrphans(keeping: Set(items.compactMap(\.imageFile)))
        // 之前记录的图片补做文字识别
        if prefs.recognizeText {
            for name in Set(items.filter { $0.ocrText == nil }.compactMap(\.imageFile)) {
                recognizeText(in: name)
            }
        }

        if monitorChanges {
            timers = [
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                },
                // 定期按保留时长清理过期条目
                Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyLimits() }
                },
            ]
        }

        // @Published 在赋值前发出通知，延到下一轮主循环再读取新值
        prefs.$maxHistory.combineLatest(prefs.$retentionDays)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.applyLimits() } }
            .store(in: &cancellables)
    }

    func filtered(query: String, favorites: Bool, mode: SearchMode) -> [ClipItem] {
        let base = items.filter { !favorites || $0.isFavorite }
        let matched: [ClipItem]
        if Search.isPathQuery(query) {
            guard !isSearchingPath, query == pathQuery, pathRevision == historyRevision else { return [] }
            matched = base.filter { pathMatches.contains($0.id) }
        } else { matched = query.isEmpty ? base : Search.filter(base, query: query, mode: mode) }
        return matched.filter(\.isPinned) + matched.filter { !$0.isPinned }
    }

    /// Parsing an entire history stays off the UI thread; cancelled keystrokes never publish stale results.
    func searchPath(_ query: String) async {
        guard Search.isPathQuery(query) else { isSearchingPath = false; return }
        if pathQuery == query, pathRevision == historyRevision { isSearchingPath = false; return }
        isSearchingPath = true
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let snapshot = items, revision = historyRevision
        let worker = Task.detached(priority: .userInitiated) {
            Set(Search.filter(snapshot, query: query, mode: .exact).map(\.id))
        }
        let matches = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        guard !Task.isCancelled, revision == historyRevision else { return }
        pathMatches = matches; pathQuery = query; pathRevision = revision
        isSearchingPath = false
    }

    // MARK: - 监听

    private func poll() {
        if let until = pausedUntil, until <= Date() { pausedUntil = nil }

        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        // 暂停期间的复制直接丢弃，恢复后也不会补记
        guard pausedUntil == nil else { return }
        let types = pb.types ?? []
        if types.contains(where: Self.ignoredTypes.contains) { return }
        let source = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if let source, prefs.ignoredApps.contains(source) { return }

        // 文件优先：访达复制文件时还会附带文件名文本
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            guard prefs.recordFiles else { return }
            let paths = urls.map(\.path)
            add(ClipItem(text: paths.joined(separator: "\n"), date: Date(), sourceApp: source, kind: .file, paths: paths))
            return
        }

        let rtfData = pb.data(forType: .rtf)
        // 只有富文本没有纯文本时，从 RTF 里取文字
        if let text = pb.string(forType: .string)
            ?? rtfData.flatMap({ NSAttributedString(rtf: $0, documentAttributes: nil)?.string }),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rtf = rtfData.flatMap { $0.count <= maxRTFSize ? $0 : nil }
            add(ClipItem(text: text, date: Date(), sourceApp: source, rtf: rtf))
            return
        }

        // 图片：截图、浏览器「拷贝图像」等
        guard prefs.recordImages,
              let type = pb.availableType(from: [.png, .tiff]),
              let data = pb.data(forType: type), data.count <= maxImageSize,
              let image = ImageStore.save(data, isPNG: type == .png) else { return }
        let size = "\(image.width)×\(image.height)"
        add(ClipItem(text: "图片 \(size)", date: Date(), sourceApp: source,
                     kind: .image, imageFile: image.name, imageSize: size))
        if prefs.recognizeText, items.first?.ocrText == nil { recognizeText(in: image.name) }
    }

    /// 内容已存在时移到最前，保留收藏、置顶状态；新条目的来源和富文本为空时沿用旧值
    private func add(_ new: ClipItem) {
        var item = new
        if let i = items.firstIndex(where: { $0.isSameContent(as: new) }) {
            let old = items.remove(at: i)
            item.id = old.id
            item.isFavorite = old.isFavorite
            item.isPinned = old.isPinned
            item.sourceApp = new.sourceApp ?? old.sourceApp
            item.rtf = new.rtf ?? old.rtf
            item.ocrText = new.ocrText ?? old.ocrText
        }
        items.insert(item, at: 0)
        trim()
        save()
    }

    /// 按保留条数和时长删除旧条目，收藏和置顶的不删；返回是否有删除
    @discardableResult
    private func trim() -> Bool {
        let cutoff = prefs.retentionDays > 0
            ? Date().addingTimeInterval(-Double(prefs.retentionDays) * 86400) : nil
        var count = 0
        return remove { item in
            guard !item.isFavorite, !item.isPinned else { return false }
            if let cutoff, item.date < cutoff { return true }
            count += 1
            return count > prefs.maxHistory
        }
    }

    private func applyLimits() {
        if trim() { save() }
    }

    /// 删除条目并清理对应的图片文件；predicate 对每个条目只调用一次
    @discardableResult
    private func remove(where shouldRemove: (ClipItem) -> Bool) -> Bool {
        var kept: [ClipItem] = []
        var removed: [ClipItem] = []
        for item in items {
            if shouldRemove(item) { removed.append(item) } else { kept.append(item) }
        }
        guard !removed.isEmpty else { return false }
        items = kept
        let stillUsed = Set(kept.compactMap(\.imageFile))
        for name in removed.compactMap(\.imageFile) where !stillUsed.contains(name) {
            ImageStore.delete(name)
        }
        return true
    }

    // MARK: - 文字识别

    private func recognizeText(in name: String) {
        let url = ImageStore.url(name)
        Task { [weak self] in
            let text = await OCR.recognize(url)
            self?.setOCRText(text, for: name)
        }
    }

    private func setOCRText(_ text: String, for name: String) {
        var changed = false
        for i in items.indices where items[i].imageFile == name && items[i].ocrText == nil {
            items[i].ocrText = text
            changed = true
        }
        if changed { save() }
    }

    // MARK: - 操作

    #if DEBUG
    func setPreviewItems(_ items: [ClipItem]) { self.items = items }
    #endif

    /// Inspection copies leave the history order and current preview selection unchanged.
    func copyPreviewText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents(); pb.setString(text, forType: .string)
        lastChangeCount = pb.changeCount
    }

    /// plain 为 true 时文本只写入纯文本；图片和文件不受影响
    func copy(_ item: ClipItem, plain: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            if !plain, let rtf = item.rtf { pb.setData(rtf, forType: .rtf) }
            pb.setString(item.text, forType: .string)
        case .image:
            if let name = item.imageFile, let data = try? Data(contentsOf: ImageStore.url(name)) {
                pb.setData(data, forType: .png)
                // 不少 App 只认 TIFF
                if let tiff = NSImage(data: data)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        case .file:
            pb.writeObjects(item.fileURLs as [NSURL])
        }
        lastChangeCount = pb.changeCount

        var again = item
        again.date = Date()
        add(again)
    }

    func toggleFavorite(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isFavorite.toggle()
        trim()
        save()
    }

    func togglePin(_ item: ClipItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].isPinned.toggle()
        trim()
        save()
    }

    func delete(_ item: ClipItem) {
        remove { $0.id == item.id }
        save()
    }

    /// 清空历史，保留收藏和置顶
    func clearHistory() {
        remove { !$0.isFavorite && !$0.isPinned }
        save()
    }

    /// minutes 为 nil 时一直暂停，直到手动恢复
    func pause(minutes: Int?) {
        pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) } ?? .distantFuture
    }

    func resume() {
        pausedUntil = nil
    }

    // MARK: - 持久化

    private func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = try decoder.decode([ClipItem].self, from: data)
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
