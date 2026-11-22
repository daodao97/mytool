import AppKit
import CoreGraphics
import MyScreenCore

struct DisplayService {
    static func connected() -> [DisplayInfo] {
        let screens = NSScreen.screens
        let primaryTop = screens.first?.frame.maxY ?? 0
        return screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let uuid = CGDisplayCreateUUIDFromDisplayID(displayID).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String }
            let id = uuid ?? "\(CGDisplayVendorNumber(displayID))-\(CGDisplayModelNumber(displayID))-\(CGDisplaySerialNumber(displayID))"
            let frame = CGDisplayBounds(displayID)
            let visible = screen.visibleFrame
            return DisplayInfo(id: id, name: screen.localizedName,
                               frame: Rect(frame),
                               workArea: Rect(x: visible.minX, y: primaryTop - visible.maxY,
                                              width: visible.width, height: visible.height),
                               isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                               isMain: displayID == CGMainDisplayID())
        }.sorted { a, b in
            if a.frame.x != b.frame.x { return a.frame.x < b.frame.x }
            if a.frame.y != b.frame.y { return a.frame.y < b.frame.y }
            return a.id < b.id
        }
    }
}

extension Rect {
    init(_ frame: CGRect) { self.init(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
