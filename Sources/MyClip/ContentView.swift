import SwiftUI
import ApplicationServices

struct ContentView: View {
    @EnvironmentObject var store: ClipStore
    @EnvironmentObject var state: PanelState
    @EnvironmentObject var prefs: Preferences
    let actions: PanelActions
    @FocusState private var searchFocused: Bool

    private var items: [ClipItem] {
        store.filtered(query: state.query, favorites: state.showFavorites, mode: prefs.searchMode)
    }

    private var previewItem: ClipItem? {
        let items = items
        guard state.previewing, items.indices.contains(state.selection) else { return nil }
        return items[state.selection]
    }

    private var pathSearchRequest: String { "\(store.historyRevision)\n\(state.query)" }

    private var pathError: String? {
        guard Search.isPathQuery(state.query) else { return nil }
        let path = String(state.query.trimmingCharacters(in: .whitespaces).dropFirst(5))
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { return "输入节点路径，例如 path:$.users[*].name" }
        do { _ = try JSONPathQuery(path); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            if items.isEmpty {
                emptyView
            } else {
                cards.overlay {
                    if let item = previewItem {
                        PreviewPane(item: item) { state.previewing = false }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { searchFocused = true }
        .task(id: pathSearchRequest) { await store.searchPath(state.query) }
        .onChange(of: state.openToken) { searchFocused = true }
        .onChange(of: state.query) { state.selection = 0 }
        .onChange(of: state.showFavorites) { state.selection = 0 }
        .onChange(of: state.previewing) { if !state.previewing { searchFocused = true } }
        .onChange(of: items.isEmpty) {
            if items.isEmpty { state.previewing = false }
        }
    }

    // MARK: - 顶栏

    private var hint: String {
        var parts: [String] = []
        if let s = prefs.shortcuts[.open] { parts.append("\(s.display) 呼出") }
        parts += ["↩ 粘贴", "⌘S 收藏"]
        if let s = prefs.shortcuts[.pin] { parts.append("\(s.display) 置顶") }
        if let s = prefs.shortcuts[.delete] { parts.append("\(s.display) 删除") }
        if let s = prefs.shortcuts[.preview] { parts.append("\(s.display) 预览") }
        parts += ["⇥ 切换", "⌘, 设置"]
        return parts.joined(separator: "   ")
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容或 path:$.users[*].id", text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12)
            .frame(width: 290, height: 30)
            .background(Color.primary.opacity(0.07), in: Capsule())

            Menu {
                Picker("搜索方式", selection: $prefs.searchMode) {
                    ForEach(SearchMode.allCases) { Text($0.title).tag($0) }
                }
                Text("path: 前缀按 JSON 节点路径筛选")
            } label: { Text(prefs.searchMode.title).font(.caption) }
                .menuStyle(.borderlessButton).fixedSize()

            TabPill(title: "历史", icon: "clock", selected: !state.showFavorites) { state.showFavorites = false }
            TabPill(title: "收藏", icon: "star.fill", selected: state.showFavorites) { state.showFavorites = true }

            Spacer()

            if let until = store.pausedUntil {
                Button { store.resume() } label: {
                    Label(until == .distantFuture
                          ? "已暂停记录"
                          : "暂停记录至 \(until.formatted(date: .omitted, time: .shortened))",
                          systemImage: "pause.circle.fill")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.orange)
                .help("点击恢复记录")
            }

            if prefs.autoPaste && !state.trusted {
                Button {
                    AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                    actions.close()
                } label: {
                    Label("开启自动粘贴", systemImage: "hand.raised.fill")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.orange)
                .help("授予辅助功能权限后，回车会直接粘贴到当前 App；否则只复制")
            }

            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Menu {
                Button("设置…  ⌘,") { actions.openSettings() }
                Divider()
                if store.pausedUntil == nil {
                    Menu("暂停记录") {
                        Button("5 分钟") { store.pause(minutes: 5) }
                        Button("30 分钟") { store.pause(minutes: 30) }
                        Button("1 小时") { store.pause(minutes: 60) }
                        Button("直到手动恢复") { store.pause(minutes: nil) }
                    }
                } else {
                    Button("恢复记录") { store.resume() }
                }
                Button("清空历史（保留收藏和置顶）") { store.clearHistory() }
                Divider()
                Button("关闭 MyClip 面板") { actions.close() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - 卡片

    private var cards: some View {
        let items = items
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ClipCard(item: item, index: index, selected: index == state.selection)
                            .onTapGesture { actions.select(item, NSEvent.modifierFlags) }
                            .overlay(alignment: .bottomTrailing) {
                                if item.previewImageURL != nil || item.isJSONCandidate {
                                    Button { preview(item) } label: {
                                        Image(systemName: item.isJSONCandidate ? "curlybraces" : "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(8)
                                            .background(.regularMaterial, in: Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .help(item.isJSONCandidate ? "展开 JSON：折叠节点、搜索与复制路径" : "预览图片")
                                    .accessibilityLabel(item.isJSONCandidate ? "展开 JSON" : "预览图片")
                                    .padding(.trailing, 12)
                                    .padding(.bottom, 30)
                                }
                            }
                            .id(item.id)
                            .contextMenu { contextMenu(for: item) }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
            }
            .onChange(of: state.selection) {
                guard items.indices.contains(state.selection) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(items[state.selection].id) }
            }
            .onChange(of: state.openToken) {
                if let first = items.first { proxy.scrollTo(first.id, anchor: .leading) }
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("预览") { preview(item) }
        Button("粘贴") { actions.select(item, []) }
        if item.kind == .text {
            Button("粘贴为纯文本") { actions.paste(item, true) }
            Menu("处理后粘贴") {
                ForEach(TextTransform.allCases) { transform in
                    if transform.startsGroup { Divider() }
                    Button(transform.title) { actions.transform(item, transform) }
                }
            }
        }
        if let ocr = item.ocrText, !ocr.isEmpty {
            Button("粘贴图中文字") { actions.select(ClipItem(text: ocr, date: Date(), sourceApp: item.sourceApp), []) }
            Button("复制图中文字") { actions.copy(ClipItem(text: ocr, date: Date(), sourceApp: item.sourceApp)) }
        }
        Button("仅复制") { actions.copy(item) }
        if item.kind == .file {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
        }
        Divider()
        Button(item.isPinned ? "取消置顶" : "置顶") { store.togglePin(item) }
        Button(item.isFavorite ? "取消收藏" : "收藏") { store.toggleFavorite(item) }
        if let source = item.sourceApp {
            Button("不再记录来自「\(AppInfo.get(source).name)」的内容") { prefs.ignoreApp(source) }
        }
        Divider()
        Button("删除") { store.delete(item) }
    }

    private func preview(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        state.selection = index
        state.previewing = true
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            if store.isSearchingPath {
                ProgressView("查找 JSON 节点…")
            } else {
                Image(systemName: state.showFavorites ? "star" : "doc.on.clipboard")
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                Text(pathError ?? (state.query.isEmpty
                     ? (state.showFavorites ? "还没有收藏，选中卡片按 ⌘S 收藏" : "复制点什么，它会出现在这里")
                     : Search.isPathQuery(state.query) ? "没有包含此路径的 JSON" : "没有匹配的内容"))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TabPill: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(selected ? Color.accentColor : Color.primary.opacity(0.06), in: Capsule())
                .foregroundStyle(selected ? Color.white : Color.primary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let selected: Bool

    var body: some View {
        let app = AppInfo.get(item.sourceApp)
        VStack(spacing: 0) {
            // 头部：类型 + 时间 + 来源 App 图标，背景取图标主色
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.typeTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(item.date.formatted(.relative(presentation: .named)))
                        .font(.system(size: 10))
                        .opacity(0.85)
                }
                Spacer(minLength: 0)
                if item.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 11))
                }
                if item.isFavorite {
                    Image(systemName: "star.fill").font(.system(size: 11))
                }
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .help(app.name)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 52)
            .background(Color(nsColor: app.color))

            content

            HStack {
                Text(item.detail)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if index < 9 { Text("⌘\(index + 1)") }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 230, height: 236)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1)
        )
        .shadow(color: .black.opacity(selected ? 0.25 : 0.1), radius: selected ? 8 : 3, y: 2)
        .scaleEffect(selected ? 1 : 0.97)
        .animation(.easeOut(duration: 0.12), value: selected)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            if item.isJSONCandidate {
                JSONCardPreview(text: item.text)
            } else {
                Text(item.preview)
                    .font(.system(size: 12))
                    .foregroundStyle(item.isLink ? Color.blue : Color.primary)
                    .lineLimit(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        case .image:
            Group {
                if let name = item.imageFile, let image = ImageStore.thumbnail(name) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    Image(systemName: "photo").font(.system(size: 36)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
        case .file:
            if let url = item.previewImageURL, let image = ImageStore.thumbnail(at: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(10)
            } else {
                FileList(urls: item.fileURLs)
                    .padding(12)
            }
        }
    }
}

/// 卡片里的文件：单个文件显示大图标，多个文件显示列表
struct FileList: View {
    let urls: [URL]
    var limit = 6

    var body: some View {
        if urls.count == 1, let url = urls.first {
            VStack(spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .frame(width: 64, height: 64)
                Text(url.lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(urls.prefix(limit)), id: \.self) { url in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(url.lastPathComponent)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if urls.count > limit {
                    Text("还有 \(urls.count - limit) 个…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// 预览选中条目的完整内容
struct PreviewPane: View {
    @EnvironmentObject var store: ClipStore
    let item: ClipItem
    let close: () -> Void

    private var summary: String {
        guard item.kind == .text else { return item.detail }
        let lines = item.text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        return "\(item.text.count) 个字符 · \(lines) 行"
    }

    var body: some View {
        let app = AppInfo.get(item.sourceApp)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                Text(app.name).fontWeight(.semibold)
                Text(item.date.formatted(date: .abbreviated, time: .standard))
                Text(summary)
                if item.rtf != nil { Text("含格式") }
                Spacer()
                if item.kind == .file {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(item.fileURLs) }
                        .buttonStyle(.borderless)
                }
                Button(action: close) {
                    Label("关闭预览", systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                .help("esc 关闭预览")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Divider()

            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        if let url = item.previewImageURL {
            imagePreview(at: url)
        } else {
            switch item.kind {
            case .text:
                if item.isJSONCandidate {
                    JSONPreviewView(text: item.text, copy: store.copyPreviewText).id(item.id)
                } else {
                    ScrollView {
                        Text(String(item.text.prefix(100_000)))
                            .font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            case .image:
                missingImage
            case .file:
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(item.fileURLs, id: \.self) { url in
                            let exists = FileManager.default.fileExists(atPath: url.path)
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                Text(url.lastPathComponent).fontWeight(.medium)
                                Text((url.path as NSString).abbreviatingWithTildeInPath)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if !exists { Text("已不存在").foregroundStyle(.red) }
                            }
                            .font(.system(size: 12))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
        }
    }

    @ViewBuilder
    private func imagePreview(at url: URL) -> some View {
        if let image = NSImage(contentsOf: url) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let ocr = item.ocrText, !ocr.isEmpty {
                    ScrollView {
                        Text(ocr)
                            .font(.system(size: 12))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                    .frame(maxWidth: 280)
                }
            }
        } else {
            missingImage
        }
    }

    private var missingImage: some View {
        ContentUnavailableView("无法预览图片", systemImage: "photo", description: Text("图片文件已丢失或无法读取"))
    }
}
