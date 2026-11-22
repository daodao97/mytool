import AppKit

public enum ToolStorage {
    public static func directory(_ name: String) -> URL {
        #if DEBUG
        if let root = ProcessInfo.processInfo.environment["MYTOOL_PREVIEW_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MyTool", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    public static func defaults(_ name: String) -> UserDefaults {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MYTOOL_PREVIEW_ROOT"] != nil {
            return UserDefaults(suiteName: "dev.daodao.MyTool.Preview.\(name)")!
        }
        #endif
        return UserDefaults(suiteName: "dev.daodao.MyTool.\(name)")!
    }

    /// Copy once into an isolated directory. A failed copy never publishes a partial migration.
    public static func migrateDirectory(from source: URL, to destination: URL,
                                        fileManager: FileManager = .default) throws {
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".migration-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: staging) }
        if fileManager.fileExists(atPath: source.path) {
            try fileManager.copyItem(at: source, to: staging)
        } else {
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        }
        try fileManager.moveItem(at: staging, to: destination)
    }

    public static func migrateDefaults(from legacyDomain: String, to domain: String,
                                       defaults reader: UserDefaults = .standard) {
        let marker = "mytool.migratedLegacyDefaults"
        var destination = reader.persistentDomain(forName: domain) ?? [:]
        guard destination[marker] as? Bool != true else { return }
        for (key, value) in reader.persistentDomain(forName: legacyDomain) ?? [:] where destination[key] == nil {
            destination[key] = value
        }
        destination[marker] = true
        reader.setPersistentDomain(destination, forName: domain)
    }

    @MainActor public static func prepare(name: String, legacyBundleID: String) throws {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: legacyBundleID).isEmpty else {
            throw ToolError.legacyAppRunning(name)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try migrateDirectory(from: support.appendingPathComponent(name), to: directory(name))
        migrateDefaults(from: legacyBundleID, to: "dev.daodao.MyTool.\(name)")
    }
}
