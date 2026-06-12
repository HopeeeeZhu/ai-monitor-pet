import Foundation
import Security

// MARK: - 额度模型

struct UsageWindow {
    var percent: Double // 0-100 已用百分比
    var resetsAt: Date?
}

struct ToolUsage {
    var fiveHour: UsageWindow?
    var weekly: UsageWindow?
    var updatedAt: Date
    /// 拿不到数据时的提示文案(如凭证过期)
    var note: String?
}

/// 读取 Claude / Codex 的订阅额度用量
/// - Codex: 解析 ~/.codex/sessions 最新 rollout jsonl 里的 rate_limits(纯本地)
/// - Claude: 钥匙串取 Claude Code OAuth token, 调 /api/oauth/usage(同 /usage 命令的数据源)
class UsageMonitor {
    private let monitorEngine: MonitorEngine
    private var codexTimer: Timer?
    private var claudeTimer: Timer?
    private let codexInterval: TimeInterval = 60
    /// OAuth usage 接口社区实测 180s 轮询安全, 更频繁会 429
    private let claudeInterval: TimeInterval = 180
    private let tailByteLimit = 256 * 1024

    init(monitorEngine: MonitorEngine) {
        self.monitorEngine = monitorEngine
    }

    func start() {
        print("[UsageMonitor] Starting usage polling (codex \(Int(codexInterval))s / claude \(Int(claudeInterval))s)")
        codexTimer = Timer.scheduledTimer(withTimeInterval: codexInterval, repeats: true) { [weak self] _ in
            self?.pollCodexAsync()
        }
        claudeTimer = Timer.scheduledTimer(withTimeInterval: claudeInterval, repeats: true) { [weak self] _ in
            self?.pollClaude()
        }
        pollCodexAsync()
        pollClaude()
    }

    func stop() {
        codexTimer?.invalidate()
        claudeTimer?.invalidate()
        codexTimer = nil
        claudeTimer = nil
    }

    private func publish(_ usage: ToolUsage, for tool: ToolType) {
        Task { @MainActor in
            self.monitorEngine.updateUsage(tool: tool, usage: usage)
        }
    }

    // MARK: - Codex (本地 rollout 日志)

    private func pollCodexAsync() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if let usage = self.readCodexUsage() {
                self.publish(usage, for: .codexDesktop)
            }
        }
    }

    private func readCodexUsage() -> ToolUsage? {
        let sessionsDir = NSHomeDirectory() + "/.codex/sessions"
        // 按修改时间取最新的几个 rollout, 找到第一个带 rate_limits 的
        for fileURL in newestJsonlFiles(under: sessionsDir, limit: 5) {
            if let usage = latestRateLimits(in: fileURL) {
                return usage
            }
        }
        return nil
    }

    private func newestJsonlFiles(under path: String, limit: Int) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(URL, Date)] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "jsonl" {
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate else {
                continue
            }
            files.append((fileURL, modifiedAt))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    private func latestRateLimits(in fileURL: URL) -> ToolUsage? {
        for line in tailLines(from: fileURL).reversed() {
            guard line.contains("\"rate_limits\""),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let rateLimits = payload["rate_limits"] as? [String: Any] else {
                continue
            }

            let eventDate = (obj["timestamp"] as? String).flatMap(parseISO8601) ?? Date()
            let fiveHour = usageWindow(from: rateLimits["primary"], eventDate: eventDate)
            let weekly = usageWindow(from: rateLimits["secondary"], eventDate: eventDate)
            guard fiveHour != nil || weekly != nil else { continue }
            return ToolUsage(fiveHour: fiveHour, weekly: weekly, updatedAt: eventDate, note: nil)
        }
        return nil
    }

    private func usageWindow(from value: Any?, eventDate: Date) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let percent = doubleValue(dict["used_percent"]) else {
            return nil
        }
        var resetsAt: Date?
        if let seconds = doubleValue(dict["resets_in_seconds"]) {
            resetsAt = eventDate.addingTimeInterval(seconds)
        }
        return UsageWindow(percent: percent, resetsAt: resetsAt)
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let n = value as? NSNumber { return n.doubleValue }
        return nil
    }

    // MARK: - Claude (OAuth usage 接口 + 自动刷新 token)

    private struct ClaudeCredentials {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
    }

    private enum UsageFetchResult {
        case success(ToolUsage)
        case unauthorized
        case failure
    }

    /// Claude Code 的公开 OAuth client id(官方 CLI 同款)
    private let claudeClientId = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private let keychainService = "Claude Code-credentials"
    private var claudeCreds: ClaudeCredentials?

    private func pollClaude() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.pollClaudeSync()
        }
    }

    private func pollClaudeSync() {
        guard var creds = claudeCreds ?? readClaudeCredentials() else {
            publish(ToolUsage(fiveHour: nil, weekly: nil, updatedAt: Date(),
                              note: "未找到 Claude Code 凭证"), for: .claudeDesktop)
            return
        }

        // 过期或临期(60s 内)先刷新
        if let expiresAt = creds.expiresAt, expiresAt.timeIntervalSinceNow < 60,
           let refreshed = refreshClaudeCredentials(creds) {
            creds = refreshed
        }
        claudeCreds = creds

        switch fetchClaudeUsage(accessToken: creds.accessToken) {
        case .success(let usage):
            publish(usage, for: .claudeDesktop)
        case .unauthorized:
            // 本地 expiresAt 不准时兜底: 401 后强制刷新再试一次
            if let refreshed = refreshClaudeCredentials(creds) {
                claudeCreds = refreshed
                if case .success(let usage) = fetchClaudeUsage(accessToken: refreshed.accessToken) {
                    publish(usage, for: .claudeDesktop)
                    return
                }
            }
            // 刷新也失败: 丢掉缓存, 下一轮重新读钥匙串
            claudeCreds = nil
            publish(ToolUsage(fiveHour: nil, weekly: nil, updatedAt: Date(),
                              note: "Claude 登录已失效, 重新登录 Claude Code 后恢复"), for: .claudeDesktop)
        case .failure:
            // 网络失败/429: 保留上次数据, 不覆盖
            break
        }
    }

    private func fetchClaudeUsage(accessToken: String) -> UsageFetchResult {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // 必须带 claude-code UA, 否则会被限流桶持续 429
        request.setValue("claude-code/2.0.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let (data, status) = performRequest(request)
        if status == 401 { return .unauthorized }
        guard status == 200, let data,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[UsageMonitor] Claude usage request failed, status \(status)")
            return .failure
        }

        let fiveHour = claudeWindow(from: obj["five_hour"])
        let weekly = claudeWindow(from: obj["seven_day"])
        return .success(ToolUsage(fiveHour: fiveHour, weekly: weekly, updatedAt: Date(), note: nil))
    }

    /// 用 refresh token 换新 access token(与 Claude Code 官方刷新同一接口), 成功后写回钥匙串保持同步
    /// Claude Code cli.js 用的是 platform.claude.com; 旧的 console.anthropic.com 会被限流(429), 仅作兜底
    private let tokenEndpoints: [(url: String, userAgent: String)] = [
        ("https://platform.claude.com/v1/oauth/token", "claude-cli/2.0.0 (external, cli)"),
        ("https://console.anthropic.com/v1/oauth/token", "anthropic"),
    ]

    private func refreshClaudeCredentials(_ creds: ClaudeCredentials) -> ClaudeCredentials? {
        guard let refreshToken = creds.refreshToken else { return nil }

        var responseData: Data?
        for endpoint in tokenEndpoints {
            var request = URLRequest(url: URL(string: endpoint.url)!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(endpoint.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 15
            request.httpBody = try? JSONSerialization.data(withJSONObject: [
                "grant_type": "refresh_token",
                "refresh_token": refreshToken,
                "client_id": claudeClientId,
            ])

            let (data, status) = performRequest(request)
            if status == 200 {
                responseData = data
                break
            }
            print("[UsageMonitor] Claude token refresh failed at \(endpoint.url), status \(status)")
        }

        guard let data = responseData,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = obj["access_token"] as? String else {
            return nil
        }

        var expiresAt: Date?
        if let expiresIn = doubleValue(obj["expires_in"]) {
            expiresAt = Date().addingTimeInterval(expiresIn)
        }
        let refreshed = ClaudeCredentials(
            accessToken: accessToken,
            refreshToken: (obj["refresh_token"] as? String) ?? refreshToken,
            expiresAt: expiresAt
        )
        writeBackToKeychain(refreshed)
        print("[UsageMonitor] Claude token refreshed")
        return refreshed
    }

    private func claudeWindow(from value: Any?) -> UsageWindow? {
        guard let dict = value as? [String: Any],
              let percent = doubleValue(dict["utilization"]) else {
            return nil
        }
        let resetsAt = (dict["resets_at"] as? String).flatMap(parseISO8601)
        return UsageWindow(percent: percent, resetsAt: resetsAt)
    }

    private func readClaudeCredentials() -> ClaudeCredentials? {
        // 1) 钥匙串(macOS 上 Claude Code 的标准存放处)
        if let data = readKeychainCredentialsData(), let creds = parseCredentials(data) {
            return creds
        }
        // 2) 兜底: ~/.claude/.credentials.json
        let fallbackPath = NSHomeDirectory() + "/.claude/.credentials.json"
        if let data = FileManager.default.contents(atPath: fallbackPath),
           let creds = parseCredentials(data) {
            return creds
        }
        return nil
    }

    private func parseCredentials(_ data: Data) -> ClaudeCredentials? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else {
            return nil
        }
        var expiresAt: Date?
        if let ms = doubleValue(oauth["expiresAt"]) {
            expiresAt = Date(timeIntervalSince1970: ms / 1000)
        }
        return ClaudeCredentials(accessToken: token,
                                 refreshToken: oauth["refreshToken"] as? String,
                                 expiresAt: expiresAt)
    }

    private func readKeychainCredentialsData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    /// 刷新成功后把新 token 写回钥匙串, 让 Claude Code 也能用上(保持原 JSON 结构, 仅更新字段)
    private func writeBackToKeychain(_ creds: ClaudeCredentials) {
        guard let data = readKeychainCredentialsData(),
              var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              var oauth = obj["claudeAiOauth"] as? [String: Any] else {
            return
        }
        oauth["accessToken"] = creds.accessToken
        if let refreshToken = creds.refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        if let expiresAt = creds.expiresAt {
            oauth["expiresAt"] = Int(expiresAt.timeIntervalSince1970 * 1000)
        }
        obj["claudeAiOauth"] = oauth
        guard let newData = try? JSONSerialization.data(withJSONObject: obj) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: newData] as CFDictionary)
        if status != errSecSuccess {
            // 写回失败不影响本 App(token 在内存里), 只是 Claude Code 下次要自己再刷一遍
            print("[UsageMonitor] Keychain write-back failed: \(status)")
        }
    }

    /// 同步执行 HTTP 请求(仅在后台队列调用)
    private func performRequest(_ request: URLRequest) -> (Data?, Int) {
        var resultData: Data?
        var statusCode = 0
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, _ in
            resultData = data
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 20)
        return (resultData, statusCode)
    }

    // MARK: - 工具函数

    private func tailLines(from fileURL: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return [] }
        defer { handle.closeFile() }

        let size = handle.seekToEndOfFile()
        let limit = UInt64(tailByteLimit)
        handle.seek(toFileOffset: size > limit ? size - limit : 0)
        let data = handle.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    /// 兼容带/不带小数秒(包括 6 位微秒)的 ISO8601
    private func parseISO8601(_ string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) { return date }

        // 去掉小数秒再试(ISO8601DateFormatter 对 6 位微秒可能解析失败)
        let stripped = string.replacingOccurrences(of: "\\.\\d+", with: "", options: .regularExpression)
        return plain.date(from: stripped)
    }
}
