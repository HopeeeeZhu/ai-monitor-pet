import Foundation

class QoderAdapter {
    private let monitorEngine: MonitorEngine
    private var fileSource: DispatchSourceFileSystemObject?
    private var fileHandle: FileHandle?
    private var lastOffset: UInt64 = 0
    
    private let auditFilePath: String
    
    init(monitorEngine: MonitorEngine) {
        self.monitorEngine = monitorEngine
        self.auditFilePath = (NSHomeDirectory() as NSString).appendingPathComponent(".qoder/audit/audit.jsonl")
    }
    
    func start() {
        print("[QoderAdapter] Starting monitoring at: \(auditFilePath)")
        
        // 确保文件存在
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: auditFilePath) {
            print("[QoderAdapter] Audit file does not exist yet, waiting...")
            return
        }
        
        // 打开文件并定位到末尾
        do {
            fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: auditFilePath))
            lastOffset = try fileHandle?.seekToEnd() ?? 0
        } catch {
            print("[QoderAdapter] Failed to open audit file: \(error)")
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
        print("[QoderAdapter] Monitoring started")
    }
    
    func stop() {
        fileSource?.cancel()
        fileSource = nil
        print("[QoderAdapter] Monitoring stopped")
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
            print("[QoderAdapter] Error reading file: \(error)")
        }
    }
    
    private func parseLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        
        // 实际格式: _event 或 hook_event_name 字段
        let event = json["_event"] as? String ?? json["hook_event_name"] as? String ?? ""
        let cwd = json["cwd"] as? String ?? "/unknown"
        let sessionId = json["session_id"] as? String ?? UUID().uuidString
        
        // 忽略空事件
        guard !event.isEmpty else { return }
        
        // 映射事件
        let statusEvent: StatusEvent
        if event.contains("UserPromptSubmit") || event.contains("SessionStart") || event.contains("PreToolUse") {
            statusEvent = .started
        } else if event.contains("Notification") || event.contains("Pause") {
            statusEvent = .waitingApproval
        } else if event.contains("Stop") || event.contains("SessionEnd") {
            statusEvent = .completed
        } else if event == "UNKNOWN" || event.isEmpty {
            return // 忽略无意义事件
        } else {
            // 其他事件（如 PostToolUse）视为运行中
            statusEvent = .started
        }
        
        // 通知引擎
        Task { @MainActor in
            monitorEngine.handleEvent(
                tool: .qoder,
                cwd: cwd,
                sessionId: sessionId,
                event: statusEvent
            )
            print("[QoderAdapter] Event: \(event) -> \(statusEvent) for session \(sessionId.prefix(8))")
        }
    }
}
