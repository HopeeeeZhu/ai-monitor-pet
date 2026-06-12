import Foundation
import Cocoa
import Combine

@MainActor
class NotificationManager: NSObject, ObservableObject {

    private var monitorEngine: MonitorEngine
    private var petWindow: PetWindow
    private var bubbleWindow: BubbleWindow
    private var cancellables = Set<AnyCancellable>()
    private var previousStatus: AgentStatus = .idle
    private var previousToolStates: [String: AgentStatus] = [:]
    private var previousPetStatusLabel = ""
    private var systemNotificationsAvailable = false

    init(monitorEngine: MonitorEngine, petWindow: PetWindow) {
        self.monitorEngine = monitorEngine
        self.petWindow = petWindow
        self.bubbleWindow = BubbleWindow()
        super.init()

        checkSystemNotificationAvailability()
        bindToMonitorEngine()
    }

    private func checkSystemNotificationAvailability() {
        if Bundle.main.bundleIdentifier != nil {
            systemNotificationsAvailable = true
            print("[NotificationManager] System notifications available")
        } else {
            systemNotificationsAvailable = false
            print("[NotificationManager] No bundle identifier - using bubble notifications only")
        }
    }

    private func bindToMonitorEngine() {
        monitorEngine.$globalStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] newStatus in
                self?.handleGlobalStatusChange(newStatus)
            }
            .store(in: &cancellables)

        monitorEngine.$tools
            .receive(on: RunLoop.main)
            .sink { [weak self] tools in
                self?.handleToolsChange(tools)
            }
            .store(in: &cancellables)

        monitorEngine.$desktopRunningDetails
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updatePetStatusLabel()
            }
            .store(in: &cancellables)
    }

    private func handleGlobalStatusChange(_ newStatus: AgentStatus) {
        let oldStatus = previousStatus
        previousStatus = newStatus

        guard oldStatus != newStatus else { return }

        // 收集当前等待授权的工具，用于生成精确的通知文案
        let waitingTools = monitorEngine.tools.filter { $0.aggregatedStatus == .waitingApproval }

        switch (oldStatus, newStatus) {
        case (_, .running) where oldStatus == .idle:
            break
        case (_, .waitingApproval):
            let toolNames = waitingTools.map { $0.toolType.displayName }.joined(separator: "、")
            let displayName = toolNames.isEmpty ? "AI 工具" : toolNames
            showBubble("⚠️ \(displayName) 需要授权")
            sendSystemNotification(
                title: "\(displayName) 需要授权",
                body: "请切换到对应窗口进行确认操作"
            )
        case (.running, .idle):
            break
        default:
            break
        }

        // 更新宠物头上的状态标签
        updatePetStatusLabel()
    }

    private func handleToolsChange(_ tools: [ToolState]) {
        for tool in tools {
            let toolId = tool.id
            let currentStatus = tool.aggregatedStatus
            let previousToolStatus = previousToolStates[toolId] ?? .idle

            if previousToolStatus != currentStatus {
                previousToolStates[toolId] = currentStatus

                switch (previousToolStatus, currentStatus) {
                case (.idle, .running):
                    break
                case (_, .waitingApproval):
                    showBubble("⚠️ \(tool.toolType.displayName) 需要授权")
                    sendSystemNotification(
                        title: "\(tool.toolType.displayName) 需要授权",
                        body: "请切换到对应窗口进行确认操作"
                    )
                case (.running, .idle):
                    // 任意一个工具跑完任务 -> 跳跃庆祝(即使别的工具还在跑)
                    petWindow.playCelebration()
                default:
                    break
                }
            }
        }

        // 工具状态变化时也更新宠物标签
        updatePetStatusLabel()
    }

    private func showBubble(_ message: String) {
        bubbleWindow.show(message: message, relativeTo: petWindow)
    }

    private func sendSystemNotification(title: String, body: String) {
        guard systemNotificationsAvailable else {
            print("[NotificationManager] System notification skipped (no bundle id): \(title)")
            return
        }

        let script = """
        display notification "\(body)" with title "\(title)" sound name "default"
        """
        DispatchQueue.global(qos: .userInitiated).async {
            guard let appleScript = NSAppleScript(source: script) else { return }
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let error = error {
                print("[NotificationManager] AppleScript notification error: \(error)")
            }
        }
    }

    /// 运行中每个 AI 工具显示一个独立气泡(气泡内每个在跑的项目一行)；需要授权才用临时气泡提醒。
    private func updatePetStatusLabel() {
        let waiting = monitorEngine.tools.contains { $0.aggregatedStatus == .waitingApproval }

        let bubbleTexts = waiting ? [] : runningBubbleTexts()
        let changeKey = bubbleTexts.joined(separator: "\u{1F}")

        guard changeKey != previousPetStatusLabel else { return }
        previousPetStatusLabel = changeKey
        petWindow.updateStatusBubbles(bubbleTexts)
    }

    private let maxLabelLines = 4

    private func runningBubbleTexts() -> [String] {
        var texts: [String] = []
        for tool in monitorEngine.tools where tool.aggregatedStatus == .running {
            let name = tool.toolType.displayName
            var lines: [String]
            if let details = monitorEngine.desktopRunningDetails[tool.toolType], !details.isEmpty {
                // 桌面端: 适配器从活动日志里抽出的 "项目 · 任务"
                lines = details.map { "\(name) · \($0)" }
            } else if tool.toolType == .claudeDesktop || tool.toolType == .codexDesktop {
                lines = ["\(name) · 运行中"]
            } else {
                // hook 类工具: 按项目透出
                lines = tool.projects
                    .filter { $0.aggregatedStatus == .running }
                    .map { "\(name) · \($0.projectName)" }
            }
            if lines.count > maxLabelLines {
                let extra = lines.count - (maxLabelLines - 1)
                lines = Array(lines.prefix(maxLabelLines - 1)) + ["…还有 \(extra) 个在跑"]
            }
            if !lines.isEmpty {
                texts.append(lines.joined(separator: "\n"))
            }
        }
        return texts
    }
}
