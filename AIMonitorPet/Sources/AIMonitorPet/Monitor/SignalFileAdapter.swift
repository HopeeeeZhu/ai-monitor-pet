import Foundation

class SignalFileAdapter {
    private let monitorEngine: MonitorEngine
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    
    private let signalFilePath: String
    
    init(monitorEngine: MonitorEngine) {
        self.monitorEngine = monitorEngine
        self.signalFilePath = (NSHomeDirectory() as NSString).appendingPathComponent(".ai_monitor/events.jsonl")
        
        // 确保目录存在
        let dirPath = (NSHomeDirectory() as NSString).appendingPathComponent(".ai_monitor")
        try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
    }
    
    func start() {
        print("[SignalFileAdapter] Starting monitoring at: \(signalFilePath)")
        
        // 确保文件存在
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: signalFilePath) {
            print("[SignalFileAdapter] Signal file does not exist yet, creating...")
            try? "".write(toFile: signalFilePath, atomically: true, encoding: .utf8)
        }
        
        // 打开文件并定位到末尾
        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: signalFilePath))
            lastOffset = try fileHandle?.seekToEnd() ?? 0
        } catch {
            print("[SignalFileAdapter] Failed to open signal file: \(error)")
            return
        }
        
        // 创建文件系统监听源
        let fileDescriptor = fileHandle?.fileDescriptor ?? -1
        fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .background)
        )
        
        fileSource?.setEventHandler { [weak self] in
            self?.handleFileChange()
        }
        
        fileSource?.setCancelHandler { [weak self] in
            self?.fileHandle?.closeFile()
            self?.fileHandle = nil
        }
        
        fileSource?.resume()
        print("[SignalFileAdapter] Monitoring started")
    }
    
    func stop() {
        fileSource?.cancel()
        fileSource = nil
        print("[SignalFileAdapter] Monitoring stopped")
    }
    
    private func handleFileChange() {
        guard let fileHandle = fileHandle else { return }
        
        do {
            // 定位到上次读取的位置
            try fileHandle.seek(toOffset: lastOffset)
            
            // 读取新数据
            let newData = fileHandle.readDataToEndOfFile()
            lastOffset = try fileHandle.offset()
            
            // 解析新行
            if let content = String(data: newData, encoding: .utf8) {
                let lines = content.components(separatedBy: .newlines)
                for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                    parseLine(line)
                }
            }
        } catch {
            print("[SignalFileAdapter] Error reading file: \(error)")
        }
    }
    
    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[SignalFileAdapter] Failed to parse line: \(line)")
            return
        }
        
        let tool = json["tool"] as? String ?? ""
        let event = json["event"] as? String ?? ""
        let sessionId = json["session_id"] as? String ?? UUID().uuidString
        let cwd = json["cwd"] as? String ?? "/unknown"
        
        // 忽略空事件
        guard !event.isEmpty, !tool.isEmpty else { return }
        
        // 映射事件
        let statusEvent: StatusEvent
        switch event {
        case "started":
            statusEvent = .started
        case "waiting":
            statusEvent = .waitingApproval
        case "completed":
            // 检查 background_tasks：如果有后台任务还在跑，不算真正完成
            if let backgroundTasks = json["background_tasks"] as? [Any], !backgroundTasks.isEmpty {
                print("[SignalFileAdapter] Completed event has \(backgroundTasks.count) background tasks, treating as still running")
                statusEvent = .started  // 还有后台任务，保持 running
            } else if let stopHookActive = json["stop_hook_active"] as? Bool, stopHookActive {
                print("[SignalFileAdapter] stop_hook_active=true, treating as still running")
                statusEvent = .started  // stop hook 链还在执行，保持 running
            } else {
                statusEvent = .completed
            }
        default:
            print("[SignalFileAdapter] Unknown event: \(event)")
            return
        }
        
        // 确定工具类型
        let toolType: ToolType
        if tool == "qoder" {
            toolType = .qoder
        } else if tool == "aone-copilot" {
            toolType = .aoneCopilot
        } else {
            print("[SignalFileAdapter] Unknown tool: \(tool)")
            return
        }
        
        // 通知引擎
        Task { @MainActor in
            monitorEngine.handleEvent(
                tool: toolType,
                cwd: cwd,
                sessionId: sessionId,
                event: statusEvent
            )
            print("[SignalFileAdapter] Event: \(tool)/\(event) -> \(statusEvent) for session \(sessionId.prefix(8))")
        }
    }
}
