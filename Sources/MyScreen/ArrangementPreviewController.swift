import AppKit
import MyScreenCore

struct ArrangementPreview: Equatable {
    let frame: Rect
    let action: WindowAction?
    let placements: [WindowPlacement]
    let label: String?
    init(frame: Rect, action: WindowAction?, placements: [WindowPlacement] = [], label: String? = nil) {
        self.frame = frame; self.action = action; self.placements = placements; self.label = label
    }
    var title: String { label ?? action?.title ?? "填充空闲区域" }
}

struct ArrangementSelection {
    let preview: ArrangementPreview
    let pointer: CGPoint

    func applies(at point: CGPoint, displays: [DisplayInfo]) -> Bool {
        hypot(point.x - pointer.x, point.y - pointer.y) <= 44 && displays.contains {
            let frame = preview.frame, area = $0.workArea
            return frame.isValid && frame.x >= area.x && frame.y >= area.y && frame.maxX <= area.maxX && frame.maxY <= area.maxY
        }
    }
}

/// A nonactivating, click-through panel never becomes a window-management target.
@MainActor
final class ArrangementPreviewController {
    private var panel: PreviewPanel?
    private var preview: ArrangementPreview?
    private var companions: [ArrangementPreviewController] = []

    func show(_ target: ArrangementPreview) {
        guard preview != target else { return }
        let wasVisible = panel?.isVisible == true
        if panel == nil {
            let panel = PreviewPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            panel.contentView = ArrangementPreviewView()
            self.panel = panel
        }
        guard let panel else { return }
        preview = target
        let otherFrames = target.placements.map(\.frame).filter { $0 != target.frame }
        while companions.count > otherFrames.count { companions.removeLast().hide() }
        while companions.count < otherFrames.count { companions.append(ArrangementPreviewController()) }
        for (controller, frame) in zip(companions, otherFrames) {
            controller.show(ArrangementPreview(frame: frame, action: nil, label: "随同排布"))
        }
        (panel.contentView as? ArrangementPreviewView)?.title = target.title
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let frame = NSRect(x: target.frame.x, y: primaryTop - target.frame.maxY,
                           width: target.frame.width, height: target.frame.height)
        if wasVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                panel.animator().setFrame(frame, display: true)
            }
        } else { panel.setFrame(frame, display: true) }
        if !wasVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.1
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        preview = nil
        // Immediate dismissal avoids a stale highlight after cancellation or mouse-up.
        panel?.orderOut(nil)
        companions.forEach { $0.hide() }
    }
}

private final class PreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class ArrangementPreviewView: NSView {
    var title = "左半屏" { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        let rect = bounds.insetBy(dx: 7, dy: 7)
        let path = NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16)
        accent.withAlphaComponent(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency ? 0.32 : 0.16).setFill()
        path.fill()
        accent.withAlphaComponent(0.85).setStroke()
        path.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 4 : 2
        path.stroke()

        let text = "松开吸附 · \(title)   ⌥ 暂停"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.labelColor
        ]
        let size = text.size(withAttributes: attributes)
        let label = NSRect(x: bounds.midX - (size.width + 28) / 2,
                           y: bounds.midY - 18, width: size.width + 28, height: 36)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill()
        NSBezierPath(roundedRect: label, xRadius: 18, yRadius: 18).fill()
        text.draw(at: NSPoint(x: label.minX + 14, y: label.midY - size.height / 2), withAttributes: attributes)
    }
}
