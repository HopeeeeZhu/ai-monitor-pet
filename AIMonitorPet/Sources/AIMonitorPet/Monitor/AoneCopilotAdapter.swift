import Foundation

class AoneCopilotAdapter {
    private let monitorEngine: MonitorEngine
    private var fileSource: DispatchSourceFileSystemObject?
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    private var timer: Timer?
    private var wasPopupVisible: Bool = false
    private var currentFilePath: String?
    
    private let historyDirPath: String
    
    /// 跟踪每个 session 的最后活动时间，用于阶梯式结束检测
    private var sessionLastActivity: [String: Date] = [:]
    /// 已知的 session_id 集合，新 session_id 出现 = 任务开始
    private var knownSessionIds: Set<String> = []
    /// 阶梯式超时定时器
    private var completionCheckTimer: Timer?
    /// 第一阶段超时：3秒无活动，标记为可能完成
    private let softTimeoutSeconds: TimeInterval = 3
    /// 第二阶段超时：10秒无活动，确认完成
    private let hardTimeoutSeconds: TimeInterval = 10
    
    init(monitorEngine: MonitorEngine) {
        self.monitorEngine = monitorEngine
        self.historyDirPath = (NSHomeDirectory() as NSString).appendingPathComponent(".r2c/logs/aone-copilot/history")
    }
    
    func start() {
        print("[AoneCopilotAdapter] Starting monitoring at: \(historyDirPath)")
        
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: historyDirPath) {
            print("[AoneCopilotAdapter] History directory does not exist yet, waiting...")
            return
        }
        
        // 启动 JSONL 文件监听
        startFileMonitoring()
        
        // 启动弹窗检测定时器
        startPopupDetection()
        
        // 启动阶梯式结束检测定时器（每秒检查一次）
        startCompletionCheck()
        
        print("[AoneCopilotAdapter] Monitoring started")
    }
    
    func stop() {
        fileSource?.cancel()
        directorySource?.cancel()
        timer?.invalidate()
        completionCheckTimer?.invalidate()
        fileHandle?.closeFile()
        fileHandle = nil
        print("[AoneCopilotAdapter] Monitoring stopped")
    }
    
    private func startFileMonitoring() {
        // 找到最新的 jsonl 文件
        guard let latestFile = getLatestJsonlFile() else {
            print("[AoneCopilotAdapter] No jsonl files found yet")
            return
        }
        
        print("[AoneCopilotAdapter] Monitoring file: \(latestFile)")
        
        currentFilePath = latestFile
        
        // 打开文件
        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: latestFile))
            lastOffset = try fileHandle?.seekToEnd() ?? 0
        } catch {
            print("[AoneCopilotAdapter] Failed to open file: \(error)")
            return
        }
        
        // 监听目录变化（新文件创建）
        let dirDescriptor = open(historyDirPath, O_EVTONLY)
        if dirDescriptor != -1 {
            directorySource = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirDescriptor,
                eventMask: [.write, .extend],
                queue: DispatchQueue.global(qos: .background)
            )
            
            directorySource?.setEventHandler { [weak self] in
                self?.handleDirectoryChange()
            }
            
            directorySource?.resume()
        }
        
        // 监听当前文件变化
        let fileDescriptor = fileHandle?.fileDescriptor ?? -1
        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .background)
        )
        
        fileSource?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }
        
        fileSource?.resume()
    }
    
    private func handleDirectoryChange() {
        // 检查是否有更新的 jsonl 文件
        guard let latestFile = getLatestJsonlFile() else { return }
        
        // 如果文件改变了，重新打开
        if let currentPath = currentFilePath, currentPath != latestFile {
            print("[AoneCopilotAdapter] Switching to new file: \(latestFile)")
            fileSource?.cancel()
            fileHandle?.closeFile()
            
            do {
                fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: latestFile))
                lastOffset = 0
                currentFilePath = latestFile
                
                let fileDescriptor = fileHandle?.fileDescriptor ?? -1
                fileSource = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: fileDescriptor,
                    eventMask: .write,
                    queue: DispatchQueue.global(qos: .background)
                )
                
                fileSource?.setEventHandler { [weak self] in
                    self?.handleFileChange()
                }
                
                fileSource?.resume()
            } catch {
                print("[AoneCopilotAdapter] Failed to open new file: \(error)")
            }
        }
    }
    
    private func handleFileChange() {
        guard let fileHandle = fileHandle else { return }
        
        do {
            try fileHandle.seek(toOffset: lastOffset)
            let newData = fileHandle.readDataToEndOfFile()
            lastOffset = try fileHandle.offset()
            
            if let content = String(data: newData, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    parseLine(line)
                }
            }
        } catch {
            print("[AoneCopilotAdapter] Error reading file: \(error)")
        }
    }
    
    private func parseLine(_ line: String) {
        guard let lineData = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }
        
        // 实际格式: session_id 和 cwd 在 data 嵌套对象里
        let dataObj = json["data"] as? [String: Any] ?? [:]
        let cwd = dataObj["cwd"] as? String ?? "/unknown"
        let sessionId = dataObj["session_id"] as? String ?? dataObj["trace_id"] as? String ?? UUID().uuidString
        let hookEvent = json["hookEvent"] as? String ?? ""
        
        // 记录该 session 的最后活动时间
        sessionLastActivity[sessionId] = Date()
        
        // 判断是否是新 session（新 session_id 出现 = 任务开始）
        let isNewSession = !knownSessionIds.contains(sessionId)
        if isNewSession {
            knownSessionIds.insert(sessionId)
            print("[AoneCopilotAdapter] New session detected: \(sessionId.prefix(8))")
        }
        
        // 每条 afterShellExecution 都意味着 AI 正在运行中
        // 新 session 和后续活动都映射为 started（即 running 状态）
        Task { @MainActor in
            monitorEngine.handleEvent(
                tool: .aoneCopilot,
                cwd: cwd,
                sessionId: sessionId,
                event: .started
            )
            print("[AoneCopilotAdapter] Event: \(hookEvent) for session \(sessionId.prefix(8))")
        }
    }
    
    private func startPopupDetection() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.checkPopupVisibility()
        }
    }
    
    private func checkPopupVisibility() {
        let script = """
        tell application "System Events"
            set ideaRunning to (name of processes) contains "idea"
            if ideaRunning then
                tell process "idea"
                    set windowList to name of every window
                    set hasPopup to false
                    repeat with windowName in windowList
                        if windowName contains "命令安全确认" then
                            set hasPopup to true
                            exit repeat
                        end if
                    end repeat
                    return hasPopup
                end tell
            else
                return false
            end if
        end tell
        """
        
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let isPopupVisible = output == "true"
                
                Task { @MainActor in
                    if isPopupVisible && !wasPopupVisible {
                        // 弹窗出现 -> waitingApproval
                        print("[AoneCopilotAdapter] Popup appeared -> waitingApproval")
                        monitorEngine.markAllRunningAsWaitingApproval(for: .aoneCopilot)
                    } else if !isPopupVisible && wasPopupVisible {
                        // 弹窗消失 -> 回到 running
                        print("[AoneCopilotAdapter] Popup disappeared -> back to running")
                        monitorEngine.markAllWaitingApprovalAsRunning(for: .aoneCopilot)
                    }
                    wasPopupVisible = isPopupVisible
                }
            }
        } catch {
            print("[AoneCopilotAdapter] Popup detection error: \(error)")
        }
    }
    
    private func getLatestJsonlFile() -> String? {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: historyDirPath) else {
            return nil
        }
        
        let jsonlFiles = contents.filter { $0.hasSuffix(".jsonl") }
        guard !jsonlFiles.isEmpty else { return nil }
        
        // 按修改时间排序，返回最新的
        let sortedFiles = jsonlFiles.sorted { file1, file2 in
            let path1 = (historyDirPath as NSString).appendingPathComponent(file1)
            let path2 = (historyDirPath as NSString).appendingPathComponent(file2)
            
            let attrs1 = try? fileManager.attributesOfItem(atPath: path1)
            let attrs2 = try? fileManager.attributesOfItem(atPath: path2)
            
            let date1 = attrs1?[.modificationDate] as? Date ?? Date.distantPast
            let date2 = attrs2?[.modificationDate] as? Date ?? Date.distantPast
            
            return date1 > date2
        }
        
        return (historyDirPath as NSString).appendingPathComponent(sortedFiles.first!)
    }
    
    // MARK: - 阶梯式结束检测
    
    private func startCompletionCheck() {
        completionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkSessionCompletion()
        }
    }
    
    private func checkSessionCompletion() {
        let now = Date()
        var sessionsToComplete: [String] = []
        
        for (sessionId, lastActivity) in sessionLastActivity {
            let idleSeconds = now.timeIntervalSince(lastActivity)
            
            if idleSeconds >= hardTimeoutSeconds {
                // 第二阶段：10 秒无活动，确认完成，标记 idle
                sessionsToComplete.append(sessionId)
            }
        }
        
        guard !sessionsToComplete.isEmpty else { return }
        
        Task { @MainActor in
            for sessionId in sessionsToComplete {
                monitorEngine.handleEvent(
                    tool: .aoneCopilot,
                    cwd: "/unknown",
                    sessionId: sessionId,
                    event: .completed
                )
                print("[AoneCopilotAdapter] Session \(sessionId.prefix(8)) idle for >\(Int(hardTimeoutSeconds))s -> completed")
            }
            
            // 清理已完成的 session 跟踪数据
            for sessionId in sessionsToComplete {
                sessionLastActivity.removeValue(forKey: sessionId)
            }
        }
    }
}
