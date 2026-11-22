import AppKit

/// 来源 App 的名称、图标和主题色（取图标主色，用作卡片头部背景）
@MainActor
enum AppInfo {
    struct Info {
        let name: String
        let icon: NSImage
        let color: NSColor
    }

    private static var cache: [String: Info] = [:]

    private static let fallback = Info(
        name: "未知来源",
        icon: NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil) ?? NSImage(),
        color: NSColor(calibratedWhite: 0.45, alpha: 1)
    )

    static func get(_ bundleID: String?) -> Info {
        guard let bundleID else { return fallback }
        if let info = cache[bundleID] { return info }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            cache[bundleID] = fallback
            return fallback
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        let info = Info(name: name, icon: icon, color: dominantColor(of: icon))
        cache[bundleID] = info
        return info
    }

    private static func dominantColor(of image: NSImage) -> NSColor {
        let size = 16
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return fallback.color }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()

        // 按饱和度加权平均，避免被白边和灰色阴影冲淡
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for x in 0..<size {
            for y in 0..<size {
                guard let c = rep.colorAt(x: x, y: y), c.alphaComponent > 0.5 else { continue }
                let w = c.saturationComponent + 0.05
                r += c.redComponent * w
                g += c.greenComponent * w
                b += c.blueComponent * w
                total += w
            }
        }
        guard total > 0 else { return fallback.color }

        let avg = NSColor(deviceRed: r / total, green: g / total, blue: b / total, alpha: 1)
        // 压暗一点，保证白字可读
        return NSColor(deviceHue: avg.hueComponent,
                       saturation: min(avg.saturationComponent * 1.2, 0.85),
                       brightness: min(avg.brightnessComponent, 0.7),
                       alpha: 1)
    }
}
