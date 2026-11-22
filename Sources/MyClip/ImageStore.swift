import AppKit
import CryptoKit
import ImageIO
import MyToolKit

/// 图片条目的存储：按内容哈希命名的 PNG，同一张图只存一份
@MainActor
enum ImageStore {
    static let dir = ToolStorage.directory("MyClip").appendingPathComponent("images", isDirectory: true)

    private static let thumbnails = NSCache<NSString, NSImage>()

    static func url(_ name: String) -> URL {
        dir.appendingPathComponent(name)
    }

    /// 保存为 PNG，返回文件名和像素尺寸
    static func save(_ data: Data, isPNG: Bool) -> (name: String, width: Int, height: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        let converted: Data? = isPNG ? data : rep.representation(using: .png, properties: [:])
        guard let png = converted else { return nil }

        let name = SHA256.hash(data: png).prefix(12).map { String(format: "%02x", $0) }.joined() + ".png"
        let fileURL = url(name)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            guard (try? png.write(to: fileURL, options: .atomic)) != nil else { return nil }
        }
        return (name, rep.pixelsWide, rep.pixelsHigh)
    }

    /// 卡片用的缩略图，最长边 600 像素
    static func thumbnail(_ name: String) -> NSImage? {
        thumbnail(at: url(name))
    }

    static func thumbnail(at url: URL) -> NSImage? {
        // 文件条目引用的原图可能被修改，缓存随文件大小、修改时间更新。
        guard let key = thumbnailKey(for: url) else { return nil }
        if let cached = thumbnails.object(forKey: key) { return cached }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: .zero)
        thumbnails.setObject(image, forKey: key)
        return image
    }

    static func delete(_ name: String) {
        if let key = thumbnailKey(for: url(name)) { thumbnails.removeObject(forKey: key) }
        try? FileManager.default.removeItem(at: url(name))
    }

    private static func thumbnailKey(for url: URL) -> NSString? {
        var fileURL = url
        fileURL.removeAllCachedResourceValues()
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
        return "\(url.path):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(values.fileSize ?? 0)" as NSString
    }

    /// 删除历史里已经不再引用的图片文件
    static func removeOrphans(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for file in files where !names.contains(file) {
            try? FileManager.default.removeItem(at: url(file))
        }
    }
}
