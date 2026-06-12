import Foundation

enum AgentStatus: String, Codable {
    case idle
    case running
    case waitingApproval
}

enum ToolType: String, CaseIterable, Identifiable {
    case claudeDesktop
    case codexDesktop
    case qoder
    case aoneCopilot
    
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .claudeDesktop: return "Claude"
        case .codexDesktop: return "Codex"
        case .qoder: return "Qoder"
        case .aoneCopilot: return "Aone Copilot"
        }
    }
}

struct SessionState: Identifiable {
    let id: String // sessionId
    var displayName: String
    var status: AgentStatus
    var lastEvent: String
    var lastUpdated: Date
}

struct ProjectState: Identifiable {
    let id: String // cwd path
    var projectName: String
    var sessions: [SessionState]
    
    var aggregatedStatus: AgentStatus {
        if sessions.contains(where: { $0.status == .waitingApproval }) { return .waitingApproval }
        if sessions.contains(where: { $0.status == .running }) { return .running }
        return .idle
    }
}

struct ToolState: Identifiable {
    let id: String // toolType.rawValue
    let toolType: ToolType
    var projects: [ProjectState]
    
    var aggregatedStatus: AgentStatus {
        if projects.contains(where: { $0.aggregatedStatus == .waitingApproval }) { return .waitingApproval }
        if projects.contains(where: { $0.aggregatedStatus == .running }) { return .running }
        return .idle
    }
}
