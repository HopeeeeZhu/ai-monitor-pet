import Cocoa

struct WindowJumper {

    static func activateWindow(for toolType: ToolType) {
        let appIdentifier = bundleIdentifier(for: toolType)
        let appName = applicationName(for: toolType)

        let script: String
        if let bundleId = appIdentifier {
            script = """
            tell application id "\(bundleId)"
                activate
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                activate
            end tell
            """
        }

        executeAppleScript(script, context: "activate \(appName)")
    }

    static func activateWindow(for toolType: ToolType, projectPath: String) {
        let appName = applicationName(for: toolType)

        switch toolType {
        case .claudeDesktop, .codexDesktop:
            activateWindow(for: toolType)
        case .qoder:
            activateTerminalWithPath(projectPath)
        case .aoneCopilot:
            activateIntelliJWithProject(projectPath)
        }

        print("[WindowJumper] Activated \(appName) for project: \(projectPath)")
    }

    private static func activateTerminalWithPath(_ path: String) {
        let projectName = (path as NSString).lastPathComponent
        let script = """
        tell application "System Events"
            set termApps to {"Terminal", "iTerm2", "Warp"}
            repeat with appName in termApps
                if exists (application process appName) then
                    tell application appName to activate
                    return
                end if
            end repeat
        end tell
        tell application "Terminal"
            activate
        end tell
        """
        executeAppleScript(script, context: "activate terminal for \(projectName)")
    }

    private static func activateIntelliJWithProject(_ path: String) {
        let projectName = (path as NSString).lastPathComponent
        let script = """
        tell application "System Events"
            set ideApps to {"IntelliJ IDEA", "IntelliJ IDEA Ultimate", "IntelliJ IDEA CE"}
            repeat with appName in ideApps
                if exists (application process appName) then
                    tell application appName to activate
                    -- 尝试找到对应项目窗口
                    tell process appName
                        set frontmost to true
                        set windowList to every window
                        repeat with w in windowList
                            if name of w contains "\(projectName)" then
                                perform action "AXRaise" of w
                                return
                            end if
                        end repeat
                    end tell
                    return
                end if
            end repeat
        end tell
        """
        executeAppleScript(script, context: "activate IntelliJ for \(projectName)")
    }

    private static func bundleIdentifier(for toolType: ToolType) -> String? {
        switch toolType {
        case .claudeDesktop: return "com.anthropic.claudefordesktop"
        case .codexDesktop: return "com.openai.codex"
        case .qoder: return nil
        case .aoneCopilot: return "com.jetbrains.intellij"
        }
    }

    private static func applicationName(for toolType: ToolType) -> String {
        switch toolType {
        case .claudeDesktop: return "Claude"
        case .codexDesktop: return "Codex"
        case .qoder: return "Terminal"
        case .aoneCopilot: return "IntelliJ IDEA"
        }
    }

    private static func executeAppleScript(_ source: String, context: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let script = NSAppleScript(source: source) else {
                print("[WindowJumper] Failed to create script for: \(context)")
                return
            }

            var error: NSDictionary?
            script.executeAndReturnError(&error)

            if let error = error {
                print("[WindowJumper] Script error (\(context)): \(error)")
            }
        }
    }
}
