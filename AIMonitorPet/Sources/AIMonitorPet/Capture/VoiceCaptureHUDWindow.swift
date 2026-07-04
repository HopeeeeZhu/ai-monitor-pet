import Cocoa
import SwiftUI

private final class VoiceCaptureHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class VoiceCaptureHUDWindow {
    private let panel: NSPanel

    init(contentView: VoiceCaptureHUDView) {
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 320, height: 250)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 8
        hostingView.layer?.masksToBounds = true

        let panel = VoiceCaptureHUDPanel(
            contentRect: hostingView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        self.panel = panel
    }

    var isVisible: Bool {
        panel.isVisible
    }

    func show(relativeTo anchorWindow: NSWindow) {
        position(relativeTo: anchorWindow)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    func position(relativeTo anchorWindow: NSWindow) {
        let anchor = anchorWindow.frame
        let size = panel.frame.size
        let gap: CGFloat = 8

        var origin = NSPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.minY - size.height - gap
        )

        if let screenFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            if origin.y < screenFrame.minY + gap {
                origin.y = anchor.minY + gap
            }
            if origin.x < screenFrame.minX + gap {
                origin.x = screenFrame.minX + gap
            }
            if origin.x + size.width > screenFrame.maxX - gap {
                origin.x = screenFrame.maxX - size.width - gap
            }
            if origin.y + size.height > screenFrame.maxY - gap {
                origin.y = screenFrame.maxY - size.height - gap
            }
        }

        panel.setFrameOrigin(origin)
    }
}
