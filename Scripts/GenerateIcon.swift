import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let iconName = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "AppIcon"
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

func icon(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current!.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    if iconName == "MyActive" {
        NSColor(calibratedRed: 0.76, green: 0.41, blue: 0.12, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 192, yRadius: 192).fill()
        let ivory = NSColor(calibratedRed: 1, green: 0.96, blue: 0.84, alpha: 1)
        ivory.setFill()
        NSBezierPath(ovalIn: NSRect(x: 350, y: 350, width: 324, height: 324)).fill()
        ivory.setStroke()
        for ray in 0..<8 {
            let angle = Double(ray) * .pi / 4
            let path = NSBezierPath(); path.lineWidth = 36; path.lineCapStyle = .round
            path.move(to: NSPoint(x: 512 + cos(angle) * 228, y: 512 + sin(angle) * 228))
            path.line(to: NSPoint(x: 512 + cos(angle) * 304, y: 512 + sin(angle) * 304)); path.stroke()
        }
    } else {
        NSColor(calibratedRed: 0.12, green: 0.20, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 192, yRadius: 192).fill()
        let colors = [NSColor(calibratedRed: 0.44, green: 0.73, blue: 0.67, alpha: 1),
                      NSColor(calibratedRed: 0.93, green: 0.90, blue: 0.81, alpha: 1),
                      NSColor(calibratedRed: 0.67, green: 0.77, blue: 0.83, alpha: 1),
                      NSColor(calibratedRed: 0.87, green: 0.63, blue: 0.44, alpha: 1)]
        for (index, origin) in [(250, 530), (530, 530), (250, 250), (530, 250)].enumerated() {
            colors[index].setFill()
            NSBezierPath(roundedRect: NSRect(x: origin.0, y: origin.1, width: 244, height: 244), xRadius: 48, yRadius: 48).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try icon(size: size).write(to: directory.appendingPathComponent("icon_\(size)x\(size).png"))
    try icon(size: size * 2).write(to: directory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}

// PNG-backed ICNS avoids depending on iconutil's image conversion services.
func bigEndianSize(_ size: Int) -> Data {
    var value = UInt32(size).bigEndian
    return withUnsafeBytes(of: &value) { Data($0) }
}
var chunks = Data()
for (type, size) in [("icp4", 16), ("icp5", 32), ("icp6", 64), ("ic07", 128),
                     ("ic08", 256), ("ic09", 512), ("ic10", 1024),
                     ("ic11", 32), ("ic12", 64), ("ic13", 256), ("ic14", 512)] {
    let png = icon(size: size)
    chunks.append(Data(type.utf8)); chunks.append(bigEndianSize(png.count + 8)); chunks.append(png)
}
var result = Data("icns".utf8)
result.append(bigEndianSize(chunks.count + 8)); result.append(chunks)
try result.write(to: directory.deletingLastPathComponent().appendingPathComponent("\(iconName).icns"))
