import Cocoa
import SwiftUI

class StatusPanelController {

    private var panelWindow: NSPanel?
    private let monitorEngine: MonitorEngine
    private let captureStore: CaptureStore
    private let voiceCaptureController: VoiceCaptureController
    private var isVisible = false
    /// 点击面板外部自动关闭用的事件监听
    private var clickMonitors: [Any] = []
    private weak var petWindowRef: NSWindow?

    init(monitorEngine: MonitorEngine, captureStore: CaptureStore, voiceCaptureController: VoiceCaptureController) {
        self.monitorEngine = monitorEngine
        self.captureStore = captureStore
        self.voiceCaptureController = voiceCaptureController
    }

    func toggle(relativeTo petWindow: NSWindow) {
        if isVisible {
            hide()
        } else {
            show(relativeTo: petWindow)
        }
    }

    func show(relativeTo petWindow: NSWindow) {
        if panelWindow == nil {
            createPanel()
        }

        guard let panel = panelWindow else { return }

        petWindowRef = petWindow
        let petFrame = petWindow.frame
        let panelSize = panel.frame.size
        let panelX = petFrame.midX - panelSize.width / 2
        let panelY = petFrame.maxY + 12

        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))

        // 确保面板不超出屏幕
        if let screen = NSScreen.main {
            var origin = panel.frame.origin
            let screenFrame = screen.visibleFrame

            if origin.x + panelSize.width > screenFrame.maxX {
                origin.x = screenFrame.maxX - panelSize.width - 8
            }
            if origin.x < screenFrame.minX {
                origin.x = screenFrame.minX + 8
            }
            if origin.y + panelSize.height > screenFrame.maxY {
                origin.y = petFrame.minY - panelSize.height - 12
            }
            panel.setFrameOrigin(origin)
        }

        panel.alphaValue = 0
        panel.orderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1.0
        }

        isVisible = true
        installClickMonitors()
    }

    func hide() {
        removeClickMonitors()
        guard let panel = panelWindow else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })

        isVisible = false
    }

    // MARK: - 点击外部关闭

    private func installClickMonitors() {
        removeClickMonitors()
        // 全局监听: 点到其他 App 的窗口/桌面
        if let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in self?.closeIfClickedOutside() }
        ) {
            clickMonitors.append(global)
        }
        // 本地监听: 点到本 App 自己的窗口(面板/宠物)
        if let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] event in
                self?.closeIfClickedOutside()
                return event
            }
        ) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        for monitor in clickMonitors {
            NSEvent.removeMonitor(monitor)
        }
        clickMonitors.removeAll()
    }

    private func closeIfClickedOutside() {
        guard isVisible, let panel = panelWindow else { return }
        let point = NSEvent.mouseLocation
        if panel.frame.contains(point) { return }
        // 点宠物本体不在这里关, 交给宠物的 toggle 逻辑处理(否则会先关再开)
        if let pet = petWindowRef, pet.frame.contains(point) { return }
        hide()
    }

    private func createPanel() {
        let contentView = StatusPanelView(
            monitorEngine: monitorEngine,
            captureStore: captureStore,
            onManualCapture: { [weak self] in
                Task { @MainActor in
                    self?.hide()
                    self?.voiceCaptureController.startManualEntry()
                }
            },
            onClose: { [weak self] in
                self?.hide()
            }
        )
        let hostingView = NSHostingView(rootView: contentView)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow

        hostingView.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 12
        hostingView.layer?.masksToBounds = true

        panel.contentView = hostingView
        panelWindow = panel
    }
}
