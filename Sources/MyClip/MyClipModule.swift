import AppKit
import SwiftUI
import MyToolKit

@MainActor
public final class MyClipModule: ToolModule {
    private let host: HostContext
    private var store: ClipStore?
    private var panel: PanelController?
    public let descriptor = ToolDescriptor(id: "myclip", name: "MyClip", summary: "留住复制过的文字、图片与文件。",
                                           symbol: "doc.on.clipboard", shortcut: "剪贴板历史")

    public init(host: HostContext) { self.host = host }

    public func start() throws {
        guard store == nil else { return }
        try ToolStorage.prepare(name: "MyClip", legacyBundleID: "com.daodao.myclip")
        Preferences.shared.openHostSettings = host.showSettings
        let store = try ClipStore()
        self.store = store
        panel = PanelController(store: store, previousApplication: host.previousApplication)
    }

    public func open() { panel?.show() }
    public func willTerminate() { panel?.shutdown() }

    #if DEBUG
    public func jsonPreview(search: String = "") -> NSView {
        let example = #"{"requestId":"req_20261111","users":[{"id":123456789012345678901234567890,"profile":{"name":"Alice Wang","email":"alice@example.com","active":true},"roles":["admin","editor"]},{"id":2,"profile":{"name":"Bob Chen","email":"bob@example.com","active":false},"roles":["viewer"]}],"meta":{"total":2,"price":0.1234567890123456789012345,"next":null},"a.b":{"x/y":"特殊键名也可以复制路径"}}"#
        let query = search == "path" ? "$.users[*].profile.name" : search == "fuzzy" ? "alw" : ""
        return NSHostingView(rootView: JSONPreviewView(text: example, copy: { _ in }, initialQuery: query,
                                                       initialSearchMode: search == "path" ? .path : search == "fuzzy" ? .fuzzy : .contains)
            .padding(16).background(Color(nsColor: .textBackgroundColor)))
    }

    public func showPreview(json: Bool = false, expanded: Bool = false) throws -> NSView? {
        let store = try ClipStore(monitorChanges: false)
        if json {
            store.setPreviewItems([ClipItem(text: #"{"users":[{"id":123456789012345678901234567890,"name":"Alice Wang","active":true},{"id":2,"name":"Bob Chen","active":false}],"total":2,"next":null}"#, date: Date())])
        }
        self.store = store
        let panel = PanelController(store: store, previousApplication: { nil }, registerHotKeys: false)
        self.panel = panel
        panel.show()
        if expanded { panel.openPreviewForSmokeTest() }
        return panel.previewContentView
    }

    public func settingsPreview() -> NSView {
        Preferences.shared.openHostSettings = host.showSettings
        return NSHostingView(rootView: SettingsView().environmentObject(Preferences.shared))
    }
    #endif
}
