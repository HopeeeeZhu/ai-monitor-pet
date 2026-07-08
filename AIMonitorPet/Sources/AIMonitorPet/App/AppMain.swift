import Cocoa
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate {
    private var monitorEngine: MonitorEngine!
    private var qoderAdapter: QoderAdapter!
    private var aoneCopilotAdapter: AoneCopilotAdapter!
    private var desktopAppAdapter: DesktopAppAdapter!
    private var signalFileAdapter: SignalFileAdapter!
    private var processMonitor: ProcessMonitor!
    private var usageMonitor: UsageMonitor!
    private var petWindow: PetWindow!
    private var notificationManager: NotificationManager!
    private var captureStore: CaptureStore!
    private var voiceCaptureController: VoiceCaptureController!
    private var captureNotificationDelegate: CaptureNotificationDelegate!

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== AIMonitorPet Starting ===")

        // 初始化监控引擎
        monitorEngine = MonitorEngine.shared
        captureStore = CaptureStore()
        voiceCaptureController = VoiceCaptureController(store: captureStore)
        captureNotificationDelegate = CaptureNotificationDelegate()
        UNUserNotificationCenter.current().delegate = captureNotificationDelegate

        // 初始化宠物窗口
        petWindow = PetWindow(
            monitorEngine: monitorEngine,
            voiceCaptureController: voiceCaptureController,
            captureStore: captureStore
        )
        petWindow.show()
        voiceCaptureController.startHotKey()

        // 初始化通知系统
        notificationManager = NotificationManager(monitorEngine: monitorEngine, petWindow: petWindow)

        // 初始化适配器
        qoderAdapter = QoderAdapter(monitorEngine: monitorEngine)
        aoneCopilotAdapter = AoneCopilotAdapter(monitorEngine: monitorEngine)
        desktopAppAdapter = DesktopAppAdapter(monitorEngine: monitorEngine)
        signalFileAdapter = SignalFileAdapter(monitorEngine: monitorEngine)
        processMonitor = ProcessMonitor(monitorEngine: monitorEngine)

        // DesktopAppAdapter 监听 Claude.app / Codex.app 的桌面端状态
        desktopAppAdapter.start()
        // SignalFileAdapter 处理通过 hook 脚本写入 ~/.ai_monitor/events.jsonl 的事件
        signalFileAdapter.start()
        // AoneCopilotAdapter 直接监听 .r2c/logs 的 jsonl（Aone Copilot 没有外部 hook 机制）
        aoneCopilotAdapter.start()
        // ProcessMonitor 作为兜底，检测进程退出
        processMonitor.start()
        // UsageMonitor 读取 Codex 订阅额度(面板顶部展示)
        usageMonitor = UsageMonitor(monitorEngine: monitorEngine)
        usageMonitor.start()

        print("=== All adapters started, pet window visible ===")
        print("Global status: \(monitorEngine.globalStatus.rawValue)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        print("=== AIMonitorPet Stopping ===")
        qoderAdapter.stop()
        aoneCopilotAdapter.stop()
        desktopAppAdapter.stop()
        signalFileAdapter.stop()
        processMonitor.stop()
        usageMonitor.stop()
        voiceCaptureController.stopHotKey()
    }
}

@main
enum AppEntry {
    private static var appDelegate: AppDelegate?

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        appDelegate = AppDelegate()
        app.delegate = appDelegate
        app.finishLaunching()

        app.run()
    }
}
