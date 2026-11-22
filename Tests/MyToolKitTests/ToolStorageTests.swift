import XCTest
@testable import MyToolKit

final class ToolStorageTests: XCTestCase {
    private func withDirectory(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testMigrationCopiesNestedDataAndNeverOverwritesOnRelaunch() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("old")
            let destination = root.appendingPathComponent("new/clip")
            let image = source.appendingPathComponent("images/test.png")
            try FileManager.default.createDirectory(at: image.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("image".utf8).write(to: image)
            try Data("history".utf8).write(to: source.appendingPathComponent("history.json"))
            try ToolStorage.migrateDirectory(from: source, to: destination)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("images/test.png")), Data("image".utf8))
            try Data("new history".utf8).write(to: destination.appendingPathComponent("history.json"))
            try ToolStorage.migrateDirectory(from: source, to: destination)
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("history.json"), encoding: .utf8), "new history")
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("history.json"), encoding: .utf8), "history")
        }
    }

    func testFreshInstallCreatesItsOwnEmptyDirectory() throws {
        try withDirectory { root in
            let destination = root.appendingPathComponent("new/screen")
            try ToolStorage.migrateDirectory(from: root.appendingPathComponent("missing"), to: destination)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        }
    }

    func testFailedCopyLeavesNoPublishedDirectoryOrPartialStaging() throws {
        try withDirectory { root in
            let source = root.appendingPathComponent("old")
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let parent = root.appendingPathComponent("new")
            let destination = parent.appendingPathComponent("clip")
            XCTAssertThrowsError(try ToolStorage.migrateDirectory(from: source, to: destination, fileManager: FailingCopy()))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testSettingsMigrationPreservesUserChangesAndIsolatesModules() {
        let prefix = "dev.mytool.tests.\(UUID().uuidString)"
        let old = "\(prefix).legacy", clip = "\(prefix).clip", screen = "\(prefix).screen"
        let defaults = MemoryDefaults()
        defer { for domain in [old, clip, screen] { defaults.removePersistentDomain(forName: domain) } }
        defaults.setPersistentDomain(["shortcut": Data([1, 2]), "autoPaste": true], forName: old)
        defaults.setPersistentDomain(["autoPaste": false], forName: clip)
        ToolStorage.migrateDefaults(from: old, to: clip, defaults: defaults)
        XCTAssertEqual(defaults.persistentDomain(forName: clip)?["autoPaste"] as? Bool, false)
        XCTAssertEqual(defaults.persistentDomain(forName: clip)?["shortcut"] as? Data, Data([1, 2]))
        XCTAssertNil(defaults.persistentDomain(forName: screen))
        defaults.setPersistentDomain(["later": true], forName: old)
        ToolStorage.migrateDefaults(from: old, to: clip, defaults: defaults)
        XCTAssertNil(defaults.persistentDomain(forName: clip)?["later"])
        XCTAssertEqual(defaults.persistentDomain(forName: old)?["later"] as? Bool, true)
    }
}

private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var domains: [String: [String: Any]] = [:]
    override func persistentDomain(forName domainName: String) -> [String: Any]? { domains[domainName] }
    override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { domains[domainName] = domain }
    override func removePersistentDomain(forName domainName: String) { domains.removeValue(forKey: domainName) }
}

private final class FailingCopy: FileManager, @unchecked Sendable {
    override func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try createDirectory(at: dstURL, withIntermediateDirectories: true)
        throw CocoaError(.fileWriteOutOfSpace)
    }
}
