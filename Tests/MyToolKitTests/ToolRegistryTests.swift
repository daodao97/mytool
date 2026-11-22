import XCTest
import Combine
@testable import MyToolKit

@MainActor
private final class TestTool: ToolModule {
    let descriptor: ToolDescriptor
    var starts = 0
    var opens = 0
    var stops = 0
    var fails = false
    init(_ id: String) {
        descriptor = ToolDescriptor(id: id, name: id, summary: "", symbol: "", shortcut: "")
    }
    func start() throws {
        starts += 1
        if fails { throw ToolError.legacyAppRunning(descriptor.name) }
    }
    func open() { opens += 1 }
    func willTerminate() { stops += 1 }
}

@MainActor
final class ToolRegistryTests: XCTestCase {
    func testModuleStatusUpdatesReachHostAndUnsubscribeAtShutdown() async throws {
        let tool = StatusTool()
        let registry = try ToolRegistry(modules: [tool])
        registry.startAll()
        XCTAssertEqual(registry.statuses["active"], ToolStatus(label: "未开启", isActive: false))
        tool.updates.send(ToolStatus(label: "屏幕常亮", isActive: true))
        XCTAssertEqual(registry.statuses["active"]?.isActive, true)
        registry.willTerminate()
        XCTAssertEqual(registry.statuses["active"]?.isActive, false)
        tool.updates.send(ToolStatus(label: "已停止订阅", isActive: true))
        XCTAssertEqual(registry.statuses["active"]?.label, "未开启")
    }
    func testOpeningAndReopeningSharesOneBackgroundService() async throws {
        let tool = TestTool("clip")
        let registry = try ToolRegistry(modules: [tool])
        registry.startAll(); registry.startAll()
        registry.open("clip"); registry.open("clip")
        XCTAssertEqual(tool.starts, 1)
        XCTAssertEqual(tool.opens, 2)
        XCTAssertEqual(registry.started, ["clip"])
        registry.willTerminate()
        XCTAssertEqual(tool.stops, 1)
    }

    func testFailedModuleDoesNotBlockOthersAndCanRetry() async throws {
        let clip = TestTool("clip"); clip.fails = true
        let screen = TestTool("screen")
        let registry = try ToolRegistry(modules: [clip, screen])
        registry.startAll()
        XCTAssertEqual(registry.started, ["screen"])
        XCTAssertNotNil(registry.failures["clip"])
        registry.open("clip")
        XCTAssertEqual(clip.opens, 0)
        clip.fails = false
        registry.open("clip")
        XCTAssertEqual(clip.opens, 1)
        XCTAssertNil(registry.failures["clip"])
        XCTAssertEqual(screen.starts, 1)
    }

    func testDuplicateIDsAreRejectedBeforeStartingServices() async {
        let first = TestTool("same"), second = TestTool("same")
        XCTAssertThrowsError(try ToolRegistry(modules: [first, second]))
        XCTAssertEqual(first.starts + second.starts, 0)
    }

    func testFailedModuleIsNotTornDownAsIfItStarted() async throws {
        let tool = TestTool("clip"); tool.fails = true
        let registry = try ToolRegistry(modules: [tool])
        registry.startAll(); registry.open("missing"); registry.willTerminate()
        XCTAssertEqual(tool.starts, 1)
        XCTAssertEqual(tool.stops, 0)
    }
}

@MainActor
private final class StatusTool: ToolModule {
    let descriptor = ToolDescriptor(id: "active", name: "Active", summary: "", symbol: "", shortcut: "")
    let updates = CurrentValueSubject<ToolStatus, Never>(ToolStatus(label: "未开启", isActive: false))
    var statusPublisher: AnyPublisher<ToolStatus, Never>? { updates.eraseToAnyPublisher() }
    func start() throws {}
    func open() {}
    func willTerminate() { updates.send(ToolStatus(label: "未开启", isActive: false)) }
}
