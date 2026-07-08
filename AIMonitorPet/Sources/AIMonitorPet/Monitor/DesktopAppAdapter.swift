import ApplicationServices
import Foundation

private struct DesktopAppConfig {
    let tool: ToolType
    let processMatch: String
    let mainExecutable: String
    let workerProcessMatches: [String]
    let projectPath: String
    let cpuThreshold: Double
    let workerCpuThreshold: Double
    let activityDir: String?
    let activityWindowSeconds: TimeInterval
}

private struct DesktopProcessSnapshot {
    var isRunning: Bool = false
    var cpu: Double = 0
    var workerCpu: Double = 0
    var mainPid: pid_t?
}

private enum ActivityLogState {
    case running
    case waitingApproval
    case idle
    case unknown
}

class DesktopAppAdapter {
    private let monitorEngine: MonitorEngine
    private var timer: Timer?
    private var isPolling = false
    private var previousStatuses: [ToolType: AgentStatus] = [:]
    private var pendingIdleSince: [ToolType: Date] = [:]
    private var warnedAboutAccessibility = false
    private var activityCache: [ToolType: (checkedAt: Date, isRecent: Bool)] = [:]
    private let activityCheckInterval: TimeInterval = 5
    private let idleDebounceSeconds: TimeInterval = 12
    private let claudeAuditLookbackSeconds: TimeInterval = 2 * 60 * 60
    private let codexSessionLookbackSeconds: TimeInterval = 5 * 60
    private let activityLogTailByteLimit = 256 * 1024

    private let configs: [DesktopAppConfig] = [
        DesktopAppConfig(
            tool: .claudeDesktop,
            processMatch: "/Applications/Claude.app",
            mainExecutable: "/Applications/Claude.app/Contents/MacOS/Claude",
            workerProcessMatches: ["/Library/Application Support/Claude/claude-code/"],
            projectPath: "/Applications/Claude.app",
            cpuThreshold: 20,
            workerCpuThreshold: 0.2,
            activityDir: NSHomeDirectory() + "/Library/Application Support/Claude/local-agent-mode-sessions",
            activityWindowSeconds: 900
        ),
        DesktopAppConfig(
            tool: .codexDesktop,
            processMatch: "/Applications/Codex.app",
            mainExecutable: "/Applications/Codex.app/Contents/MacOS/Codex",
            workerProcessMatches: ["/Applications/Codex.app/Contents/Resources/codex app-server"],
            projectPath: "/Applications/Codex.app",
            cpuThreshold: 20,
            workerCpuThreshold: 0.2,
            activityDir: NSHomeDirectory() + "/.codex/sessions",
            activityWindowSeconds: 120
        ),
    ]

    private let approvalButtonKeywords = [
        "allow", "approve", "accept", "deny", "reject", "authorize",
        "允许", "同意", "批准", "拒绝", "授权", "确认",
    ]

    init(monitorEngine: MonitorEngine) {
        self.monitorEngine = monitorEngine
    }

    func start() {
        print("[DesktopAppAdapter] Starting Claude/Codex desktop monitoring")
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        print("[DesktopAppAdapter] Monitoring stopped")
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let snapshots = self.sampleProcesses()
            let statuses = self.configs.map { config -> (DesktopAppConfig, AgentStatus, [String]) in
                let status = self.detectStatus(for: config, snapshot: snapshots[config.tool] ?? DesktopProcessSnapshot())
                let details = status == .running ? self.runningDetails(for: config) : []
                return (config, status, details)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for (config, status, details) in statuses {
                    self.apply(status, for: config)
                    let tool = config.tool
                    Task { @MainActor in
                        self.monitorEngine.updateDesktopRunningDetails(tool: tool, details: details)
                    }
                }
                self.isPolling = false
            }
        }
    }

    private func sampleProcesses() -> [ToolType: DesktopProcessSnapshot] {
        var snapshots = Dictionary(uniqueKeysWithValues: configs.map { ($0.tool, DesktopProcessSnapshot()) })

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,%cpu=,command="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
        } catch {
            print("[DesktopAppAdapter] ps failed: \(error)")
            return snapshots
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return snapshots }

        for line in output.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces).split(maxSplits: 2, omittingEmptySubsequences: true) { $0 == " " || $0 == "\t" }
            guard parts.count == 3,
                  let pid = pid_t(parts[0]),
                  let cpu = Double(parts[1]) else {
                continue
            }

            let command = String(parts[2])
            for config in configs {
                var snapshot = snapshots[config.tool] ?? DesktopProcessSnapshot()

                if command.contains(config.processMatch) {
                    snapshot.isRunning = true
                    snapshot.cpu += cpu
                    if command.hasPrefix(config.mainExecutable) {
                        snapshot.mainPid = pid
                    }
                }

                if config.workerProcessMatches.contains(where: { command.contains($0) }) {
                    snapshot.isRunning = true
                    snapshot.workerCpu += cpu
                }

                snapshots[config.tool] = snapshot
            }
        }

        return snapshots
    }

    private func detectStatus(for config: DesktopAppConfig, snapshot: DesktopProcessSnapshot) -> AgentStatus {
        guard snapshot.isRunning else { return .idle }

        if let pid = snapshot.mainPid, hasApprovalButton(pid: pid) {
            return .waitingApproval
        }

        if config.tool == .claudeDesktop {
            switch claudeAuditStatus(at: config.activityDir) {
            case .waitingApproval:
                return .waitingApproval
            case .running:
                return .running
            case .idle, .unknown:
                return .idle
            }
        }

        if config.tool == .codexDesktop {
            // app-server 空闲时也常驻吃 CPU(实测 ~17%)，CPU 启发式对 Codex 必然误报；
            // 完全以会话日志为准: 近期有未完成(没出现 task_complete)的 rollout 才算在跑
            return hasActiveCodexSession(at: config.activityDir) ? .running : .idle
        }

        if snapshot.cpu > config.cpuThreshold {
            return .running
        }

        if snapshot.workerCpu > config.workerCpuThreshold {
            return .running
        }

        if hasRecentActivity(for: config) {
            return .running
        }

        return .idle
    }

    private func hasRecentActivity(for config: DesktopAppConfig) -> Bool {
        guard let activityDir = config.activityDir else { return false }

        let now = Date()
        if let cached = activityCache[config.tool],
           now.timeIntervalSince(cached.checkedAt) < activityCheckInterval {
            return cached.isRecent
        }

        let cutoff = now.addingTimeInterval(-config.activityWindowSeconds)
        let isRecent = directoryContainsFileModified(after: cutoff, at: activityDir)
        activityCache[config.tool] = (now, isRecent)
        return isRecent
    }

    private func directoryContainsFileModified(after cutoff: Date, at path: String) -> Bool {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            if modifiedAt > cutoff {
                return true
            }
        }

        return false
    }

    private func claudeAuditStatus(at path: String?) -> ActivityLogState {
        guard let path else { return .unknown }
        let cutoff = Date().addingTimeInterval(-claudeAuditLookbackSeconds)
        var sawRunning = false

        for fileURL in files(named: "audit.jsonl", under: path, modifiedAfter: cutoff) {
            switch latestClaudeAuditState(in: fileURL) {
            case .waitingApproval:
                return .waitingApproval
            case .running:
                sawRunning = true
            case .idle, .unknown:
                continue
            }
        }
        return sawRunning ? .running : .idle
    }

    private func latestClaudeAuditState(in fileURL: URL) -> ActivityLogState {
        for line in tailLines(from: fileURL).reversed() {
            if isClaudeResultLine(line) {
                return .idle
            }
            if isClaudePermissionResponseLine(line) {
                // 用户已点过确认 -> 回到运行中
                return .running
            }
            if isClaudePermissionRequestLine(line) {
                // AskUserQuestion 是 Claude 主动向用户提问(走同一条 permission 通道)，
                // 属于正常对话交互，不算"等待授权"
                if line.contains("\"tool_name\":\"AskUserQuestion\"") {
                    return .running
                }
                return .waitingApproval
            }
            if isClaudeRunningLine(line) {
                return .running
            }
        }
        return .unknown
    }

    private func isClaudePermissionResponseLine(_ line: String) -> Bool {
        line.contains("\"subtype\":\"permission_response\"") || line.contains("\"subtype\": \"permission_response\"")
    }

    private func isClaudeResultLine(_ line: String) -> Bool {
        line.contains("\"type\":\"result\"") || line.contains("\"type\": \"result\"")
    }

    private func isClaudePermissionRequestLine(_ line: String) -> Bool {
        line.contains("\"subtype\":\"permission_request\"") || line.contains("\"subtype\": \"permission_request\"")
    }

    private func isClaudeRunningLine(_ line: String) -> Bool {
        if line.contains("\"subtype\":\"status\"") || line.contains("\"subtype\": \"status\"") {
            return line.contains("\"status\":\"requesting\"") || line.contains("\"status\": \"requesting\"")
        }
        if line.contains("\"subtype\":\"thinking_tokens\"") || line.contains("\"subtype\": \"thinking_tokens\"") {
            return true
        }
        if line.contains("\"subtype\":\"api_retry\"") || line.contains("\"subtype\": \"api_retry\"") {
            return true
        }
        if line.contains("\"type\":\"assistant\"") || line.contains("\"type\": \"assistant\"") {
            return true
        }
        if line.contains("\"type\":\"user\"") || line.contains("\"type\": \"user\"") {
            return line.contains("tool_result")
        }
        return false
    }

    private func hasActiveCodexSession(at path: String?) -> Bool {
        guard let path else { return false }
        let cutoff = Date().addingTimeInterval(-codexSessionLookbackSeconds)

        for fileURL in files(named: nil, under: path, modifiedAfter: cutoff) where fileURL.pathExtension == "jsonl" {
            // 跑动中 tail 可能全是增量输出命不中标记(unknown)，只有明确 task_complete 才算完成
            if latestCodexSessionState(in: fileURL) != .idle {
                return true
            }
        }
        return false
    }

    private func latestCodexSessionState(in fileURL: URL) -> ActivityLogState {
        for line in tailLines(from: fileURL).reversed() {
            if line.contains("\"type\":\"task_complete\"") || line.contains("\"type\": \"task_complete\"") {
                return .idle
            }
            if line.contains("\"phase\":\"final_answer\"") || line.contains("\"phase\": \"final_answer\"") {
                return .idle
            }
            if line.contains("\"type\":\"user_message\"") || line.contains("\"type\": \"user_message\"") {
                return .running
            }
            if line.contains("\"type\":\"function_call\"") || line.contains("\"type\": \"function_call\"") {
                return .running
            }
            if line.contains("\"phase\":\"commentary\"") || line.contains("\"phase\": \"commentary\"") {
                return .running
            }
        }
        return .unknown
    }

    // MARK: - 在跑会话详情 ("项目 · 任务"，供宠物头顶标签展示)

    private let maxDetailCount = 8
    private let claudeDetailLookbackSeconds: TimeInterval = 15 * 60

    private func runningDetails(for config: DesktopAppConfig) -> [String] {
        guard let dir = config.activityDir else { return [] }
        switch config.tool {
        case .codexDesktop: return codexRunningDetails(at: dir)
        case .claudeDesktop: return claudeRunningDetails(at: dir)
        default: return []
        }
    }

    private func codexRunningDetails(at path: String) -> [String] {
        let cutoff = Date().addingTimeInterval(-codexSessionLookbackSeconds)
        var details: [String] = []
        for fileURL in files(named: nil, under: path, modifiedAfter: cutoff) where fileURL.pathExtension == "jsonl" {
            // 任务执行中 tail 可能全是增量输出、命不中任何标记(unknown)，只排除明确已完成的
            guard latestCodexSessionState(in: fileURL) != .idle else { continue }
            let parts = [codexProjectName(in: fileURL), codexTaskName(in: fileURL)].compactMap { $0 }
            details.append(parts.isEmpty ? "会话" : parts.joined(separator: " · "))
            if details.count >= maxDetailCount { break }
        }
        return details
    }

    /// 项目名: rollout 文件开头 session_meta 里的 "cwd" 字段最后一段
    private func codexProjectName(in fileURL: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { handle.closeFile() }
        guard let text = String(data: handle.readData(ofLength: 8192), encoding: .utf8),
              let start = text.range(of: "\"cwd\":\"") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: "\""), start.upperBound < end else { return nil }
        let cwd = String(rest[..<end])
        return cwd.isEmpty ? nil : (cwd as NSString).lastPathComponent
    }

    /// 任务名: 最近一条 user_message 的内容截断
    private func codexTaskName(in fileURL: URL) -> String? {
        for line in tailLines(from: fileURL).reversed() {
            guard line.contains("\"type\":\"user_message\"") || line.contains("\"type\": \"user_message\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let message = payload["message"] as? String else { continue }
            return snippet(message)
        }
        return nil
    }

    private func claudeRunningDetails(at path: String) -> [String] {
        let cutoff = Date().addingTimeInterval(-claudeDetailLookbackSeconds)
        var details: [String] = []
        for fileURL in files(named: "audit.jsonl", under: path, modifiedAfter: cutoff) {
            guard latestClaudeAuditState(in: fileURL) == .running else { continue }
            details.append(claudeTaskName(in: fileURL) ?? "对话")
            if details.count >= maxDetailCount { break }
        }
        return details
    }

    /// 任务名: 最近一条真实用户消息(非 tool_result)的文本截断。Claude 桌面端拿不到稳定的项目路径, 只透出任务。
    private func claudeTaskName(in fileURL: URL) -> String? {
        for line in tailLines(from: fileURL).reversed() {
            guard line.contains("\"type\":\"user\""), !line.contains("tool_result"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any] else { continue }
            if let content = message["content"] as? String, let s = snippet(content) {
                return s
            }
            if let blocks = message["content"] as? [[String: Any]] {
                for block in blocks where (block["type"] as? String) == "text" {
                    if let text = block["text"] as? String, let s = snippet(text) {
                        return s
                    }
                }
            }
        }
        return nil
    }

    /// 清掉标签/压缩空白, 截到 12 个字符
    private func snippet(_ text: String, maxLength: Int = 16) -> String? {
        var t = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        return t.count > maxLength ? String(t.prefix(maxLength)) + "…" : t
    }

    private func files(named fileName: String?, under path: String, modifiedAfter cutoff: Date) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var urls: [URL] = []
        for case let fileURL as URL in enumerator {
            if let fileName, fileURL.lastPathComponent != fileName {
                continue
            }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt > cutoff else {
                continue
            }
            urls.append(fileURL)
        }
        return urls
    }

    private func tailLines(from fileURL: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { handle.closeFile() }

        let size = handle.seekToEndOfFile()
        let limit = UInt64(activityLogTailByteLimit)
        handle.seek(toFileOffset: size > limit ? size - limit : 0)
        let data = handle.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func apply(_ status: AgentStatus, for config: DesktopAppConfig) {
        let previous = previousStatuses[config.tool] ?? .idle
        guard previous != status else { return }

        if status == .idle {
            let now = Date()
            if pendingIdleSince[config.tool] == nil {
                pendingIdleSince[config.tool] = now
                return
            }
            guard now.timeIntervalSince(pendingIdleSince[config.tool] ?? now) >= idleDebounceSeconds else {
                return
            }
        } else {
            pendingIdleSince[config.tool] = nil
        }

        previousStatuses[config.tool] = status
        if status == .idle {
            pendingIdleSince[config.tool] = nil
        }

        let event: StatusEvent
        switch status {
        case .running:
            event = .started
        case .waitingApproval:
            event = .waitingApproval
        case .idle:
            guard previous != .idle else { return }
            event = .completed
        }

        Task { @MainActor in
            monitorEngine.handleEvent(
                tool: config.tool,
                cwd: config.projectPath,
                sessionId: "desktop",
                event: event
            )
            print("[DesktopAppAdapter] \(config.tool.displayName) \(previous.rawValue) -> \(status.rawValue)")
        }
    }

    private func hasApprovalButton(pid: pid_t) -> Bool {
        guard AXIsProcessTrusted() else {
            if !warnedAboutAccessibility {
                warnedAboutAccessibility = true
                print("[DesktopAppAdapter] Accessibility is not enabled; approval detection is disabled")
            }
            return false
        }

        let app = AXUIElementCreateApplication(pid)
        guard let windows = attribute(app, kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return false
        }

        for window in windows where containsApprovalButton(in: window, depth: 0, visitedCount: 0) {
            return true
        }
        return false
    }

    private func containsApprovalButton(in element: AXUIElement, depth: Int, visitedCount: Int) -> Bool {
        guard depth <= 8, visitedCount <= 500 else { return false }

        let role = attribute(element, kAXRoleAttribute as CFString) as? String
        let title = attribute(element, kAXTitleAttribute as CFString) as? String

        if role == kAXButtonRole as String, let title, matchesApprovalKeyword(title) {
            return true
        }

        guard let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] else {
            return false
        }

        var nextVisitedCount = visitedCount + 1
        for child in children {
            nextVisitedCount += 1
            if containsApprovalButton(in: child, depth: depth + 1, visitedCount: nextVisitedCount) {
                return true
            }
        }
        return false
    }

    private func matchesApprovalKeyword(_ title: String) -> Bool {
        let lowered = title.lowercased()
        return approvalButtonKeywords.contains { lowered.contains($0) }
    }

    private func attribute(_ element: AXUIElement, _ attributeName: CFString) -> Any? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attributeName, &value)
        guard error == .success else { return nil }
        return value
    }
}
