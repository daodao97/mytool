import SwiftUI

struct JSONCardPreview: View {
    let text: String
    @State private var document: JSONDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let document {
                HStack {
                    Label("JSON", systemImage: "curlybraces").fontWeight(.semibold)
                    Spacer()
                    Text("\(document.root.children.count) \(document.root.kind == .array ? "项" : "个字段")")
                        .foregroundStyle(.secondary)
                }.font(.system(size: 11))
                ForEach(document.root.children.prefix(4)) { child in
                    Text(child.name + ": " + child.summary)
                        .font(.system(size: 11, design: .monospaced)).lineLimit(2)
                }
                if document.root.children.count > 4 { Text("…").foregroundStyle(.secondary) }
            } else {
                Text(String(text.prefix(500))).font(.system(size: 12)).lineLimit(9)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(12)
            .task(id: text) {
                let result = await Task.detached(priority: .userInitiated) { JSONDocumentCache.shared.document(text) }.value
                if !Task.isCancelled { document = result }
            }
    }
}

struct JSONPreviewView: View {
    let text: String
    let copy: (String) -> Void
    var initialQuery = ""
    var initialSearchMode: JSONNodeSearchMode = .contains
    @State private var document: JSONDocument?
    @State private var error: String?
    @State private var finished = false

    var body: some View {
        Group {
            if let document { JSONExplorer(document: document, copy: copy, initialQuery: initialQuery, initialSearchMode: initialSearchMode) }
            else if finished {
                VStack(alignment: .leading, spacing: 8) {
                    if let error { Label(error, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
                    ScrollView {
                        Text(String(text.prefix(100_000))).font(.system(size: 13, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else { ProgressView("解析 JSON…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: text) {
            document = nil; error = nil; finished = false
            let result = await Task.detached(priority: .userInitiated) { JSONDocumentCache.shared.result(text) }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let document): self.document = document
            case .failure(let error): self.error = error.localizedDescription
            case nil: break
            }
            finished = true
        }
    }
}

enum JSONNodeSearchMode: String, CaseIterable, Identifiable {
    case contains = "键 / 值", fuzzy = "模糊", path = "Node Path"
    var id: Self { self }
}

private enum JSONViewMode: String, CaseIterable, Identifiable {
    case tree = "树形", formatted = "格式化", raw = "原文"
    var id: Self { self }
}

struct JSONExplorer: View {
    let document: JSONDocument
    let copy: (String) -> Void
    @State private var query = ""
    @State private var searchMode: JSONNodeSearchMode = .contains
    @State private var viewMode: JSONViewMode = .tree
    @State private var expanded: Set<Int>
    @State private var collapsedMatches: Set<Int> = []
    @State private var matches: Set<Int>?
    @State private var pathError: String?
    @State private var selectedID: Int
    @State private var rowLimit = 500
    @State private var showDetail = false
    @State private var feedback: String?
    @State private var formattedText: String?
    @FocusState private var searchFocused: Bool

    init(document: JSONDocument, copy: @escaping (String) -> Void,
         initialQuery: String = "", initialSearchMode: JSONNodeSearchMode = .contains) {
        self.document = document; self.copy = copy
        _query = State(initialValue: initialQuery)
        _searchMode = State(initialValue: initialSearchMode)
        _expanded = State(initialValue: Set(document.nodes.filter { $0.isContainer && $0.path.count < 2 }.map(\.id)))
        _selectedID = State(initialValue: document.root.id)
    }

    private var selected: JSONNode { document.nodes[selectedID] }
    private var rows: [JSONTreeRow] { JSONTree.rows(in: document, expanded: expanded, matches: matches, collapsedMatches: collapsedMatches) }
    private var request: String { searchMode.rawValue + "\n" + query }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            if viewMode == .tree {
                searchBar
                if let pathError { Text(pathError).font(.caption).foregroundStyle(.orange) }
                tree
                inspector
            } else {
                if viewMode == .formatted && formattedText == nil { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    let content = viewMode == .raw ? document.source : formattedText ?? ""
                    ScrollView {
                        Text(String(content.prefix(100_000))).textSelection(.enabled)
                            .font(.system(size: 13, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if content.count > 100_000 { Text("预览前 100,000 个字符，复制会包含完整内容。").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .task(id: request) { await search() }
        .task(id: viewMode) {
            if viewMode == .formatted && formattedText == nil {
                let value = await Task.detached(priority: .userInitiated) { document.root.json(pretty: true) }.value
                if !Task.isCancelled { formattedText = value }
            }
        }
        .onAppear { searchFocused = true }
    }

    private var controls: some View {
        HStack {
            Label("JSON", systemImage: "curlybraces").font(.system(size: 12, weight: .semibold))
            Text("\(document.nodes.count) 个节点").font(.caption).foregroundStyle(.secondary)
            Picker("展示", selection: $viewMode) {
                ForEach(JSONViewMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(width: 215)
            if viewMode == .tree {
                Button("全部展开") { expandAll() }.disabled(pathError != nil)
                Button("全部折叠") { collapseAll() }
            }
            Spacer(minLength: 4)
            if let feedback { Text(feedback).font(.caption).foregroundStyle(.tint) }
            Menu("复制") {
                Button("复制原文") { copied(document.source, label: "原文") }
                Button("复制格式化 JSON") { copyJSON(document.root, pretty: true) }
                Button("复制压缩 JSON") { copyJSON(document.root, pretty: false) }
            }.fixedSize()
        }.controlSize(.small)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(searchMode == .path ? "$.users[*].name 或 /users/0/name" : "搜索键名或值", text: $query)
                .textFieldStyle(.plain).focused($searchFocused)
                .onSubmit { moveMatch(1) }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("清除节点搜索")
            }
            Picker("搜索方式", selection: $searchMode) {
                ForEach(JSONNodeSearchMode.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 125)
            if let matches {
                Text("\(matches.count) 个匹配").font(.caption).foregroundStyle(.secondary)
                Button { moveMatch(-1) } label: { Image(systemName: "chevron.up") }.help("上一个匹配")
                Button { moveMatch(1) } label: { Image(systemName: "chevron.down") }.help("下一个匹配")
            }
            Button { searchFocused = true } label: { Image(systemName: "text.magnifyingglass") }
                .keyboardShortcut("f", modifiers: .command).help("搜索 JSON 节点（⌘F）")
            Menu {
                Text("字段：$.user.name 或 user.name")
                Text("数组：$.users[0] 或 users.0")
                Text("通配：$.users[*].name")
                Text("递归字段：$..name")
                Text("特殊键：$[\"a.b\"][\"\"]")
                Text("JSON Pointer：/users/0/name")
                Text("路径区分大小写；不支持筛选表达式和切片。")
            } label: { Image(systemName: "questionmark.circle") }.menuStyle(.borderlessButton).fixedSize()
        }.controlSize(.small).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
    }

    private var tree: some View {
        let rows = rows
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows.prefix(rowLimit)) { row in nodeRow(row).id(row.id) }
                    if rows.count > rowLimit {
                        Button("显示更多（还有 \(rows.count - rowLimit) 个节点）") { rowLimit += 500 }
                            .padding(10)
                    }
                    if rows.isEmpty {
                        ContentUnavailableView("没有匹配的节点", systemImage: "magnifyingglass",
                                               description: Text(pathError == nil ? "试试其他键名、值或路径。" : "请检查路径格式。"))
                    }
                }.padding(.vertical, 4)
            }
            .onChange(of: selectedID) {
                if let index = rows.firstIndex(where: { $0.id == selectedID }), index >= rowLimit { rowLimit = index + 100 }
                DispatchQueue.main.async { proxy.scrollTo(selectedID, anchor: .center) }
            }
        }.background(Color.primary.opacity(0.015), in: RoundedRectangle(cornerRadius: 6))
    }

    private func nodeRow(_ row: JSONTreeRow) -> some View {
        let node = row.node
        return HStack(spacing: 6) {
            if node.isContainer && !node.children.isEmpty {
                Button { toggle(node.id) } label: {
                    Image(systemName: row.expanded ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(row.expanded ? "折叠" : "展开") \(node.nodePath)")
            } else { Color.clear.frame(width: 18, height: 22) }
            Text(String(node.name.prefix(200))).foregroundStyle(node.path.last.map { if case .index = $0 { return Color.secondary }; return Color.blue } ?? Color.primary)
                .lineLimit(1)
            Text(":").foregroundStyle(.tertiary)
            Text(node.summary).foregroundStyle(valueColor(node.kind)).lineLimit(1)
            Spacer(minLength: 0)
            if matches?.contains(node.id) == true { Image(systemName: "magnifyingglass").foregroundStyle(.tint).font(.caption2) }
            Text(node.kind.rawValue).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.font(.system(size: 12, design: .monospaced))
            .padding(.leading, CGFloat(min(node.path.count, 20)) * 16 + 4).padding(.trailing, 10).padding(.vertical, 3)
            .background(selectedID == node.id ? Color.accentColor.opacity(0.13) : matches?.contains(node.id) == true ? Color.accentColor.opacity(0.055) : .clear,
                        in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle()).onTapGesture { selectedID = node.id; feedback = nil }
            .help(String(node.nodePath.prefix(1000)))
            .contextMenu {
                Button("复制节点值") { copyValue(node) }
                Button("复制节点 JSON") { copyJSON(node, pretty: true) }
                Button("复制 Node Path") { copied(node.nodePath, label: "路径") }
                Button("复制 JSON Pointer") { copied(node.pointer, label: "JSON Pointer") }
                Button("复制键名") { copied(node.name, label: "键名") }
            }
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack {
                Text(selected.nodePath).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .lineLimit(1).truncationMode(.middle).help(selected.nodePath)
                Spacer()
                Button("复制路径") { copied(selected.nodePath, label: "路径") }
                Button("复制节点值") { copyValue(selected) }
            }.controlSize(.small)
            DisclosureGroup("节点详情", isExpanded: $showDetail) {
                ScrollView {
                    Text(String((selected.isContainer ? selected.summary : selected.value).prefix(100_000)))
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 70)
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        collapsedMatches = []; rowLimit = 500; pathError = nil
        guard !text.isEmpty else { matches = nil; return }
        do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
        let mode = searchMode
        let result = await Task.detached(priority: .userInitiated) { () -> Result<Set<Int>, Error> in
            Result {
                if mode == .path { return try JSONPathQuery(text).matchingIDs(in: document) }
                return document.matching(text, fuzzy: mode == .fuzzy)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let ids): matches = ids; if let first = ids.min() { selectedID = first }
        case .failure(let error): matches = []; pathError = error.localizedDescription
        }
    }
    private func toggle(_ id: Int) {
        if matches != nil {
            if !collapsedMatches.insert(id).inserted { collapsedMatches.remove(id) }
        } else if !expanded.insert(id).inserted { expanded.remove(id) }
    }
    private func expandAll() {
        if matches != nil { collapsedMatches = [] }
        else { expanded = Set(document.nodes.filter(\.isContainer).map(\.id)) }
    }
    private func collapseAll() {
        if matches != nil { collapsedMatches = [document.root.id] }
        else { expanded = [] }
    }
    private func moveMatch(_ delta: Int) {
        guard let matches, !matches.isEmpty else { return }
        let ids = matches.sorted()
        let index = ids.firstIndex(of: selectedID) ?? (delta > 0 ? -1 : 0)
        selectedID = ids[(index + delta + ids.count) % ids.count]
        collapsedMatches.subtract(document.context(for: [selectedID]))
    }
    private func valueColor(_ kind: JSONNode.Kind) -> Color {
        switch kind { case .string: return .green; case .number: return .blue; case .boolean: return .orange; default: return .secondary }
    }
    private func copied(_ value: String, label: String) { copy(value); feedback = "已复制\(label)" }
    private func copyValue(_ node: JSONNode) {
        if node.isContainer { copyJSON(node, pretty: true) }
        else { copied(node.value, label: "节点值") }
    }
    private func copyJSON(_ node: JSONNode, pretty: Bool) {
        Task {
            let value = await Task.detached(priority: .userInitiated) { node.json(pretty: pretty) }.value
            copied(value, label: pretty ? "格式化 JSON" : "压缩 JSON")
        }
    }
}
