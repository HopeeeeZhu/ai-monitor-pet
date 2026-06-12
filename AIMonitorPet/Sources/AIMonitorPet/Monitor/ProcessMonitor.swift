import Foundation

class ProcessMonitor {
    private let monitorEngine: MonitorEngine
    private var timer: Timer?
    
    /// 记录每个工具的进程是否存活，用于检测进程退出事件
    private var processAliveState: [ToolType: Bool] = [:]
    
    init(monitorEngine: MonitorEngine) {
        self.monitorEngine = monitorEngine
    }
    
    func start() {
        print("[ProcessMonitor] Starting process monitoring")
        
        // 每 5 秒检查一次进程存活状态
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.checkProcesses()
        }
        
        // 立即执行一次检查
        checkProcesses()
    }
    
    func stop() {
        timer?.invalidate()
        timer = nil
        print("[ProcessMonitor] Process monitoring stopped")
    }
    
    private func checkProcesses() {
        // Qoder 进程检测
        checkProcessAlive(tool: .qoder, processPattern: "Qoder")
        // Aone Copilot 的结束检测完全由 AoneCopilotAdapter 的阶梯式超时处理
        // 不在这里检测进程，因为 Aone Copilot Agent 可能在终端/IDEA 等不同进程中运行
    }
    
    private func checkProcessAlive(tool: ToolType, processPattern: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", processPattern]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            
            let isAlive = !output.isEmpty && task.terminationStatus == 0
            let wasAlive = processAliveState[tool] ?? true
            processAliveState[tool] = isAlive
            
            Task { @MainActor in
                if wasAlive && !isAlive {
                    // 进程从活着变为退出 → 立即标记所有 session 为 idle
                    print("[ProcessMonitor] Process '\(processPattern)' exited, marking all sessions as idle")
                    monitorEngine.markAllSessionsIdle(for: tool)
                }
                // 关键改动：进程活着但无输出 → 不做任何操作（仍然保持 running）
                // 结束检测交给各自的 Adapter 通过事件/阶梯式超时处理
            }
        } catch {
            print("[ProcessMonitor] Error checking process '\(processPattern)': \(error)")
        }
    }
}
