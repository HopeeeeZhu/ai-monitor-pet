import AppKit
import SwiftUI

enum CaptureFilter: String, CaseIterable, Identifiable {
    case todo
    case idea

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .todo: return "待办"
        case .idea: return "想法"
        }
    }
}

struct StatusPanelView: View {
    @ObservedObject var monitorEngine: MonitorEngine
    @ObservedObject var captureStore: CaptureStore
    var onManualCapture: (() -> Void)?
    var onClose: (() -> Void)?
    @State private var selectedTool: ToolState?
    @State private var selectedProject: ProjectState?
    @State private var showingCaptureInbox = false
    @State private var captureFilter: CaptureFilter = .idea

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            contentView
        }
        .frame(width: 300, height: 300)
        .background(.ultraThinMaterial)
    }

    private var headerView: some View {
        HStack {
            if showingCaptureInbox {
                backButton { showingCaptureInbox = false }
            } else if selectedProject != nil {
                backButton { selectedProject = nil }
            } else if selectedTool != nil {
                backButton { selectedTool = nil }
            }

            Text(navigationTitle)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button(action: {
                selectedTool = nil
                selectedProject = nil
                showingCaptureInbox.toggle()
            }) {
                Image(systemName: showingCaptureInbox ? "tray.full.fill" : "tray.full")
                    .font(.system(size: 14))
                    .foregroundColor(showingCaptureInbox ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("捕获箱")

            statusIndicator(for: monitorEngine.globalStatus)

            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭面板")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var contentView: some View {
        if showingCaptureInbox {
            captureInboxView
        } else if let project = selectedProject {
            sessionListView(project: project)
        } else if let tool = selectedTool {
            projectListView(tool: tool)
        } else {
            toolListView
        }
    }

    private var navigationTitle: String {
        if showingCaptureInbox {
            return "捕获箱"
        } else if let project = selectedProject {
            return project.projectName
        } else if let tool = selectedTool {
            return tool.toolType.displayName
        }
        return Self.dailyTitle
    }

    // MARK: - Capture Inbox

    private var captureInboxView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                HStack(spacing: 8) {
                    Picker("", selection: $captureFilter) {
                        ForEach(CaptureFilter.allCases) { filter in
                            Text(filter.displayName).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    if let onManualCapture {
                        Button(action: onManualCapture) {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .help("手动记录待办")
                    }
                }

                if filteredCaptureItems.isEmpty {
                    emptyStateView(message: "暂无记录")
                } else {
                    ForEach(filteredCaptureItems) { item in
                        CaptureRowView(item: item) {
                            captureStore.toggleCompleted(item)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var filteredCaptureItems: [CaptureItem] {
        switch captureFilter {
        case .todo:
            return captureStore.recentItems.filter { $0.kind == .todo }
        case .idea:
            return captureStore.recentItems.filter { $0.kind == .idea }
        }
    }

    /// 每日一句: 按日期轮换, 当天内固定
    private static let dailyTitles = [
        "Magic in progress ✨",
        "Today's a canvas 🎨",
        "Stay curious 🌟",
        "Create like a kid 🖍️",
        "Make it fun 🎈",
        "Little wins add up 🌱",
        "Wonder more 🔭",
        "Dream in color 🌈",
        "Plot twist ahead 🎢",
        "Sparks flying ⚡",
        "Brew something new ☕",
        "Follow the fun 🧭",
        "Shine on 🌞",
        "Ideas grow here 🪴",
    ]

    private static var dailyTitle: String {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        return dailyTitles[day % dailyTitles.count]
    }

    // MARK: - Tool List (Layer 1)

    private var toolListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                usageSection
                codexRunningSection
                if visibleTools.isEmpty && !hasCodexRunningDetails {
                    emptyStateView(message: "暂无 AI 工具在线")
                } else {
                    ForEach(visibleTools) { tool in
                        ToolRowView(tool: tool)
                            .onTapGesture { selectedTool = tool }
                    }
                }
            }
            .padding(12)
        }
    }

    private var visibleTools: [ToolState] {
        monitorEngine.tools.filter { $0.toolType != .codexDesktop }
    }

    private var hasCodexRunningDetails: Bool {
        !(monitorEngine.desktopRunningDetails[.codexDesktop] ?? []).isEmpty
    }

    // MARK: - 额度区块 (Layer 1 顶部)

    @ViewBuilder
    private var usageSection: some View {
        let order: [ToolType] = [.codexDesktop]
        if order.contains(where: { monitorEngine.usage[$0] != nil }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("额度")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(order) { tool in
                    if let usage = monitorEngine.usage[tool] {
                        UsageRowView(toolName: tool.displayName, usage: usage)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Codex 运行中项目 (Layer 1 顶部)

    @ViewBuilder
    private var codexRunningSection: some View {
        let details = monitorEngine.desktopRunningDetails[.codexDesktop] ?? []
        if !details.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Codex 运行中")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ForEach(Array(details.enumerated()), id: \.offset) { _, detail in
                    CodexRunningRowView(detail: detail)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: - Project List (Layer 2)

    private func projectListView(tool: ToolState) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if tool.projects.isEmpty {
                    emptyStateView(message: "暂无活跃项目")
                } else {
                    ForEach(tool.projects) { project in
                        ProjectRowView(project: project)
                            .onTapGesture { selectedProject = project }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Session List (Layer 3)

    private func sessionListView(project: ProjectState) -> some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                if project.sessions.isEmpty {
                    emptyStateView(message: "暂无活跃会话")
                } else {
                    ForEach(project.sessions) { session in
                        SessionRowView(session: session)
                            .onTapGesture {
                                if let tool = selectedTool {
                                    WindowJumper.activateWindow(for: tool.toolType, projectPath: project.id)
                                }
                            }
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Helpers

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.accentColor)
        }
        .buttonStyle(.plain)
    }

    private func statusIndicator(for status: AgentStatus) -> some View {
        Circle()
            .fill(status.color)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .fill(status.color.opacity(0.4))
                    .frame(width: 16, height: 16)
            )
    }

    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }
}

// MARK: - Row Views

struct UsageRowView: View {
    let toolName: String
    let usage: ToolUsage

    var body: some View {
        HStack(spacing: 10) {
            Text(toolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 48, alignment: .leading)

            if let note = usage.note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
            } else {
                usageGauge(label: "5h", window: usage.fiveHour)
                usageGauge(label: "周", window: usage.weekly)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .help(tooltip)
    }

    @ViewBuilder
    private func usageGauge(label: String, window: UsageWindow?) -> some View {
        if let window {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .fixedSize()
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                        Capsule()
                            .fill(barColor(window.percent))
                            .frame(width: geo.size.width * min(window.percent, 100) / 100)
                    }
                }
                .frame(width: 40, height: 5)
                Text("\(Int(window.percent.rounded()))%")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(barColor(window.percent))
                    .frame(width: 28, alignment: .leading)
            }
        }
    }

    private func barColor(_ percent: Double) -> Color {
        if percent >= 90 { return .red }
        if percent >= 70 { return .orange }
        return .green
    }

    private var tooltip: String {
        var parts: [String] = []
        if let fiveHour = usage.fiveHour, let resetsAt = fiveHour.resetsAt {
            parts.append("5小时窗口 \(Self.resetFormatter.string(from: resetsAt)) 重置")
        }
        if let weekly = usage.weekly, let resetsAt = weekly.resetsAt {
            parts.append("周限额 \(Self.resetFormatter.string(from: resetsAt)) 重置")
        }
        parts.append("更新于\(usage.updatedAt.timeAgoDisplay)")
        return parts.joined(separator: " · ")
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d HH:mm"
        return formatter
    }()
}

struct CodexRunningRowView: View {
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(projectName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if let taskName {
                    Text(taskName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("运行中")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.green.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .help(detail)
    }

    private var projectName: String {
        splitDetail.first ?? detail
    }

    private var taskName: String? {
        guard splitDetail.count > 1 else { return nil }
        return splitDetail.dropFirst().joined(separator: " · ")
    }

    private var splitDetail: [String] {
        detail.components(separatedBy: " · ").filter { !$0.isEmpty }
    }
}

struct ToolRowView: View {
    let tool: ToolState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(tool.aggregatedStatus.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(tool.toolType.displayName)
                    .font(.system(size: 14, weight: .medium))
                Text("\(tool.projects.count) 个项目")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(tool.aggregatedStatus.displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(tool.aggregatedStatus.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(tool.aggregatedStatus.color.opacity(0.12))
                .cornerRadius(4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct ProjectRowView: View {
    let project: ProjectState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(project.aggregatedStatus.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.projectName)
                    .font(.system(size: 14, weight: .medium))
                Text("\(project.sessions.count) 个会话")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(project.aggregatedStatus.displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(project.aggregatedStatus.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(project.aggregatedStatus.color.opacity(0.12))
                .cornerRadius(4)

            Image(systemName: "chevron.right")
                .font(.system(size: 12))
                .foregroundColor(Color(nsColor: .tertiaryLabelColor))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct SessionRowView: View {
    let session: SessionState

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(session.status.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayName)
                    .font(.system(size: 14, weight: .medium))
                HStack(spacing: 4) {
                    Text(session.lastEvent)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(session.lastUpdated.timeAgoDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(session.status.displayText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(session.status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(session.status.color.opacity(0.12))
                .cornerRadius(4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct CaptureRowView: View {
    let item: CaptureItem
    let onToggleComplete: () -> Void
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if item.kind == .todo {
                Button(action: onToggleComplete) {
                    Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundColor(item.isCompleted ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .help(item.isCompleted ? "标记为未完成" : "标记为完成")
                .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(item.kind.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(kindColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(kindColor.opacity(0.12))
                        .cornerRadius(4)

                    Text(item.createdAt.timeAgoDisplay)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    if let reminderAt = item.reminderAt, item.kind == .todo {
                        Text("提醒 \(reminderAt.shortReminderDisplay)")
                            .font(.system(size: 11))
                            .foregroundColor(item.isCompleted ? .secondary : .orange)
                            .lineLimit(1)
                    }

                    Spacer()
                }

                Text(item.text)
                    .font(.system(size: 13))
                    .foregroundColor(item.isCompleted ? .secondary : .primary)
                    .strikethrough(item.isCompleted)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 7) {
                Button(action: copyText) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(copied ? .green : .secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("复制内容")

                Button(action: { CodexTaskLauncher.launch(item: item) }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.accentColor)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .help("发送到 Codex")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private var kindColor: Color {
        switch item.kind {
        case .todo: return .orange
        case .idea: return .blue
        }
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        copied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            copied = false
        }
    }
}

// MARK: - Extensions

extension AgentStatus {
    var color: Color {
        switch self {
        case .idle: return .gray
        case .running: return .green
        case .waitingApproval: return .orange
        }
    }

    var displayText: String {
        switch self {
        case .idle: return "空闲"
        case .running: return "运行中"
        case .waitingApproval: return "等待确认"
        }
    }
}

extension Date {
    var timeAgoDisplay: String {
        let seconds = Int(-timeIntervalSinceNow)
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(seconds / 60)分钟前" }
        if seconds < 86400 { return "\(seconds / 3600)小时前" }
        return "\(seconds / 86400)天前"
    }

    var shortReminderDisplay: String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(self) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: self)
    }
}
