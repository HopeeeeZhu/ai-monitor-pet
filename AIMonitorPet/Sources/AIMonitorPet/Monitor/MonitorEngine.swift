import Foundation

enum StatusEvent {
    case started
    case waitingApproval
    case completed
}

@MainActor
class MonitorEngine: ObservableObject {
    @Published var tools: [ToolState] = []
    @Published var globalStatus: AgentStatus = .idle
    /// 桌面端(Claude/Codex)正在跑的会话详情("项目 · 任务")，供宠物头顶状态标签展示
    @Published var desktopRunningDetails: [ToolType: [String]] = [:]
    /// Claude/Codex 订阅额度用量(5小时窗口 + 周限额)，由 UsageMonitor 推送
    @Published var usage: [ToolType: ToolUsage] = [:]
    
    static let shared = MonitorEngine()
    
    private var idleCheckTimer: Timer?
    /// 超时兜底：仅作为极端情况保护（如 hook 异常未触发）
    /// Aone Copilot 有 sessionEnd hook 实时结束，不依赖超时
    /// Qoder 有空事件实时结束，不依赖超时
    private let idleTimeoutSeconds: TimeInterval = 300
    
    private init() {
        startIdleCheck()
    }
    
    private func startIdleCheck() {
        idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIdleSessions()
            }
        }
    }
    
    private func checkIdleSessions() {
        let now = Date()
        var hasChanges = false
        
        for toolIndex in tools.indices {
            if isPolledDesktopTool(tools[toolIndex].toolType) {
                continue
            }
            for projectIndex in tools[toolIndex].projects.indices {
                for sessionIndex in tools[toolIndex].projects[projectIndex].sessions.indices {
                    let session = tools[toolIndex].projects[projectIndex].sessions[sessionIndex]
                    if session.status == .running && now.timeIntervalSince(session.lastUpdated) > idleTimeoutSeconds {
                        tools[toolIndex].projects[projectIndex].sessions[sessionIndex].status = .idle
                        hasChanges = true
                    }
                }
            }
        }
        
        if hasChanges {
            updateGlobalStatus()
        }
    }

    private func isPolledDesktopTool(_ tool: ToolType) -> Bool {
        tool == .claudeDesktop || tool == .codexDesktop
    }
    
    func handleEvent(tool: ToolType, cwd: String, sessionId: String, event: StatusEvent) {
        // 找到或创建对应的 ToolState
        if let toolIndex = tools.firstIndex(where: { $0.toolType == tool }) {
            var toolState = tools[toolIndex]
            
            // 找到或创建对应的 ProjectState
            if let projectIndex = toolState.projects.firstIndex(where: { $0.id == cwd }) {
                var projectState = toolState.projects[projectIndex]
                
                // 找到或创建对应的 SessionState
                if let sessionIndex = projectState.sessions.firstIndex(where: { $0.id == sessionId }) {
                    var sessionState = projectState.sessions[sessionIndex]
                    sessionState.status = mapEventToStatus(event)
                    sessionState.lastEvent = "\(event)"
                    sessionState.lastUpdated = Date()
                    projectState.sessions[sessionIndex] = sessionState
                } else if event == .completed {
                    // completed 事件但 session_id 不匹配
                    // 不做广播清空，忽略这个事件（避免误杀其他正在运行的 session）
                    print("[MonitorEngine] Ignoring completed event with unknown session_id: \(sessionId.prefix(12))")
                } else {
                    let newSession = SessionState(
                        id: sessionId,
                        displayName: "Session \(sessionId.prefix(8))",
                        status: mapEventToStatus(event),
                        lastEvent: "\(event)",
                        lastUpdated: Date()
                    )
                    projectState.sessions.append(newSession)
                }
                
                toolState.projects[projectIndex] = projectState
            } else if event == .completed {
                // completed 事件但项目不匹配，忽略（避免误杀其他项目的 running session）
                print("[MonitorEngine] Ignoring completed event with unknown cwd: \(cwd)")
            } else {
                let projectName = (cwd as NSString).lastPathComponent
                let newProject = ProjectState(
                    id: cwd,
                    projectName: projectName,
                    sessions: [
                        SessionState(
                            id: sessionId,
                            displayName: "Session \(sessionId.prefix(8))",
                            status: mapEventToStatus(event),
                            lastEvent: "\(event)",
                            lastUpdated: Date()
                        )
                    ]
                )
                toolState.projects.append(newProject)
            }
            
            tools[toolIndex] = toolState
        } else {
            // 创建新的 ToolState
            let projectName = (cwd as NSString).lastPathComponent
            let newTool = ToolState(
                id: tool.rawValue,
                toolType: tool,
                projects: [
                    ProjectState(
                        id: cwd,
                        projectName: projectName,
                        sessions: [
                            SessionState(
                                id: sessionId,
                                displayName: "Session \(sessionId.prefix(8))",
                                status: mapEventToStatus(event),
                                lastEvent: "\(event)",
                                lastUpdated: Date()
                            )
                        ]
                    )
                ]
            )
            tools.append(newTool)
        }
        
        // 更新全局状态
        updateGlobalStatus()
        
        // 发送通知
        NotificationCenter.default.post(name: NSNotification.Name("MonitorStateDidChange"), object: nil)
    }
    
    func updateDesktopRunningDetails(tool: ToolType, details: [String]) {
        guard (desktopRunningDetails[tool] ?? []) != details else { return }
        desktopRunningDetails[tool] = details
    }

    func updateUsage(tool: ToolType, usage: ToolUsage) {
        self.usage[tool] = usage
    }

    private func mapEventToStatus(_ event: StatusEvent) -> AgentStatus {
        switch event {
        case .started:
            return .running
        case .waitingApproval:
            return .waitingApproval
        case .completed:
            return .idle
        }
    }
    
    private func updateGlobalStatus() {
        // 优先级: waitingApproval > running > idle
        if tools.contains(where: { $0.aggregatedStatus == .waitingApproval }) {
            globalStatus = .waitingApproval
        } else if tools.contains(where: { $0.aggregatedStatus == .running }) {
            globalStatus = .running
        } else {
            globalStatus = .idle
        }
    }
    
    func markAllSessionsIdle(for tool: ToolType) {
        if let toolIndex = tools.firstIndex(where: { $0.toolType == tool }) {
            var toolState = tools[toolIndex]
            for projectIndex in toolState.projects.indices {
                for sessionIndex in toolState.projects[projectIndex].sessions.indices {
                    toolState.projects[projectIndex].sessions[sessionIndex].status = .idle
                }
            }
            tools[toolIndex] = toolState
            updateGlobalStatus()
            NotificationCenter.default.post(name: NSNotification.Name("MonitorStateDidChange"), object: nil)
        }
    }
    
    func markAllWaitingApprovalAsRunning(for tool: ToolType) {
        if let toolIndex = tools.firstIndex(where: { $0.toolType == tool }) {
            var toolState = tools[toolIndex]
            var hasChanged = false
            for projectIndex in toolState.projects.indices {
                for sessionIndex in toolState.projects[projectIndex].sessions.indices {
                    if toolState.projects[projectIndex].sessions[sessionIndex].status == .waitingApproval {
                        toolState.projects[projectIndex].sessions[sessionIndex].status = .running
                        toolState.projects[projectIndex].sessions[sessionIndex].lastEvent = "PopupDismissed"
                        toolState.projects[projectIndex].sessions[sessionIndex].lastUpdated = Date()
                        hasChanged = true
                    }
                }
            }
            if hasChanged {
                tools[toolIndex] = toolState
                updateGlobalStatus()
                NotificationCenter.default.post(name: NSNotification.Name("MonitorStateDidChange"), object: nil)
            }
        }
    }
    
    func markAllRunningAsWaitingApproval(for tool: ToolType) {
        if let toolIndex = tools.firstIndex(where: { $0.toolType == tool }) {
            var toolState = tools[toolIndex]
            var hasChanged = false
            for projectIndex in toolState.projects.indices {
                for sessionIndex in toolState.projects[projectIndex].sessions.indices {
                    if toolState.projects[projectIndex].sessions[sessionIndex].status == .running {
                        toolState.projects[projectIndex].sessions[sessionIndex].status = .waitingApproval
                        toolState.projects[projectIndex].sessions[sessionIndex].lastEvent = "PopupAppeared"
                        toolState.projects[projectIndex].sessions[sessionIndex].lastUpdated = Date()
                        hasChanged = true
                    }
                }
            }
            if hasChanged {
                tools[toolIndex] = toolState
                updateGlobalStatus()
                NotificationCenter.default.post(name: NSNotification.Name("MonitorStateDidChange"), object: nil)
            }
        }
    }
}
