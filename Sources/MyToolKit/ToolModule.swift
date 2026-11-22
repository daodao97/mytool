import AppKit
import Combine

public struct ToolDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let summary: String
    public let symbol: String
    public let shortcut: String

    public init(id: String, name: String, summary: String, symbol: String, shortcut: String) {
        self.id = id; self.name = name; self.summary = summary
        self.symbol = symbol; self.shortcut = shortcut
    }
}

public struct ToolStatus: Equatable, Sendable {
    public let label: String
    public let isActive: Bool
    public init(label: String, isActive: Bool) { self.label = label; self.isActive = isActive }
}

/// Each tool owns its windows and background work. Only the host owns NSApplication.
@MainActor
public protocol ToolModule: AnyObject {
    var descriptor: ToolDescriptor { get }
    func start() throws
    func open()
    func makeMenu() -> NSMenu?
    func willTerminate()
    var statusPublisher: AnyPublisher<ToolStatus, Never>? { get }
}

public extension ToolModule {
    func makeMenu() -> NSMenu? { nil }
    func willTerminate() {}
    var statusPublisher: AnyPublisher<ToolStatus, Never>? { nil }
}

@MainActor
public struct HostContext {
    public let showHome: () -> Void
    public let showSettings: () -> Void
    public let restart: () -> Void
    public let previousApplication: () -> NSRunningApplication?

    public init(showHome: @escaping () -> Void, showSettings: @escaping () -> Void,
                restart: @escaping () -> Void, previousApplication: @escaping () -> NSRunningApplication?) {
        self.showHome = showHome; self.showSettings = showSettings
        self.restart = restart; self.previousApplication = previousApplication
    }
}

public enum ToolError: LocalizedError {
    case duplicateID(String)
    case legacyAppRunning(String)

    public var errorDescription: String? {
        switch self {
        case .duplicateID(let id): return "子应用标识重复：\(id)"
        case .legacyAppRunning(let name):
            return "请先退出独立版 \(name)，再点击重试，以免重复监听或占用快捷键。"
        }
    }
}

@MainActor
public final class ToolRegistry: ObservableObject {
    public let modules: [any ToolModule]
    @Published public private(set) var started: Set<String> = []
    @Published public private(set) var failures: [String: String] = [:]
    @Published public private(set) var statuses: [String: ToolStatus] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]

    public init(modules: [any ToolModule]) throws {
        var ids: Set<String> = []
        for module in modules {
            guard ids.insert(module.descriptor.id).inserted else { throw ToolError.duplicateID(module.descriptor.id) }
        }
        self.modules = modules
    }

    public func startAll() { for module in modules { _ = start(module) } }

    public func open(_ id: String) {
        guard let module = modules.first(where: { $0.descriptor.id == id }), start(module) else { return }
        module.open()
    }

    public func willTerminate() {
        for module in modules.reversed() where started.contains(module.descriptor.id) { module.willTerminate() }
        subscriptions.removeAll()
    }

    @discardableResult private func start(_ module: any ToolModule) -> Bool {
        let id = module.descriptor.id
        if started.contains(id) { return true }
        do {
            try module.start()
            started.insert(id); failures.removeValue(forKey: id)
            if let publisher = module.statusPublisher {
                subscriptions[id] = publisher.removeDuplicates().sink { [weak self] status in self?.statuses[id] = status }
            }
            return true
        } catch {
            failures[id] = error.localizedDescription
            return false
        }
    }
}
