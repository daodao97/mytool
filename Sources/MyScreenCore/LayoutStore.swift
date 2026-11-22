import Foundation

public enum LayoutStoreError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidData
    case notLoaded
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "布局文件版本 \(version) 不受当前应用支持"
        case .invalidData: return "布局文件数据无效"
        case .notLoaded: return "无法读取原有布局，已停止写入以保留数据"
        }
    }
}

public struct LayoutArchive: Codable, Sendable {
    public var version = 1
    public var profiles: [LayoutProfile] = []
    public init() {}
}

public final class LayoutStore {
    public let url: URL
    public private(set) var archive = LayoutArchive()
    public private(set) var recoveryMessage: String?
    private var didLoad = false
    public init(url: URL) { self.url = url }
    private var backupURL: URL { url.appendingPathExtension("backup") }
    public func load() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { didLoad = true; return }
        do { archive = try decode(url); didLoad = true }
        catch {
            if case LayoutStoreError.unsupportedVersion = error { throw error }
            if let backup = try? decode(backupURL) {
                archive = backup; didLoad = true
                recoveryMessage = "布局文件损坏，已读取上一次备份。原文件保留为 layouts.json.damaged。"
                let damaged = url.appendingPathExtension("damaged")
                if FileManager.default.fileExists(atPath: damaged.path) { try FileManager.default.removeItem(at: damaged) }
                try FileManager.default.moveItem(at: url, to: damaged)
            } else { throw error }
        }
    }
    private func decode(_ file: URL) throws -> LayoutArchive {
        let decoded = try JSONDecoder().decode(LayoutArchive.self, from: Data(contentsOf: file))
        guard decoded.version == 1 else { throw LayoutStoreError.unsupportedVersion(decoded.version) }
        guard Set(decoded.profiles.map(\.id)).count == decoded.profiles.count,
              decoded.profiles.allSatisfy({ profile in
                  !profile.displays.isEmpty && Set(profile.displays.map(\.id)).count == profile.displays.count &&
                  Set(profile.windows.map(\.id)).count == profile.windows.count &&
                  profile.displays.allSatisfy { $0.frame.isValid && $0.workArea.isValid } &&
                  profile.windows.allSatisfy { $0.frame.isValid && profile.displays.map(\.id).contains($0.displayID) }
              }) else {
            throw LayoutStoreError.invalidData
        }
        return decoded
    }
    public func replace(_ profiles: [LayoutProfile]) throws {
        guard didLoad else {
            throw LayoutStoreError.notLoaded
        }
        var next = archive; next.profiles = profiles
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(next)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            // Do not discard a known-good backup if writing the new snapshot fails.
            let previous = try Data(contentsOf: url)
            try previous.write(to: backupURL, options: .atomic)
        }
        try data.write(to: url, options: .atomic)
        archive = next
    }

    /// Keep transition checkpoints separate from the frequently replaced last-write backup.
    public func checkpoint() throws {
        guard didLoad else { throw LayoutStoreError.notLoaded }
        guard !archive.profiles.isEmpty else { return }
        let folder = url.deletingLastPathComponent().appendingPathComponent("history")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(Date().timeIntervalSince1970)-\(UUID().uuidString).json")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(archive).write(to: file, options: .atomic)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        for old in files.dropFirst(20) { try FileManager.default.removeItem(at: old) }
    }
}
