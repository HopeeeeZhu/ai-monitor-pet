import Cocoa

enum CodexTaskLauncher {
    private static let codexPath = "/Applications/Codex.app/Contents/Resources/codex"
    private static let dailyScrumPath = NSHomeDirectory() + "/Documents/DailyScrum"

    static func launch(item: CaptureItem) {
        let prompt = promptText(for: item)
        copyToPasteboard(prompt)
        openCodexProject(at: targetProjectPath(for: item))
        pasteAndSendInCodex()
    }

    private static func targetProjectPath(for item: CaptureItem) -> String {
        // 第一版先统一投到 DailyScrum；想法类任务明确要求落在这里。
        dailyScrumPath
    }

    private static func promptText(for item: CaptureItem) -> String {
        switch item.kind {
        case .todo:
            return """
            请把下面这条待办作为一个 Codex 任务处理。先理解目标，必要时查看当前项目上下文，然后开始执行。

            待办：
            \(item.text)
            """
        case .idea:
            return """
            请把下面这个临时想法整理成 DailyScrum 项目里的一个可执行任务。先判断应该落在哪里，必要时更新项目内的待办/文档，然后开始执行。

            想法：
            \(item.text)
            """
        }
    }

    private static func copyToPasteboard(_ prompt: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)
    }

    private static func openCodexProject(at path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: codexPath)
        task.arguments = ["app", path]

        do {
            try task.run()
        } catch {
            print("[CodexTaskLauncher] Failed to open Codex app: \(error)")
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Codex.app"))
        }
    }

    private static func pasteAndSendInCodex() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.8) {
            let script = """
            tell application id "com.openai.codex"
                activate
            end tell
            delay 0.2
            tell application "System Events"
                tell process "Codex"
                    set frontmost to true
                end tell
                keystroke "v" using command down
                delay 0.1
                key code 36
            end tell
            """

            guard let appleScript = NSAppleScript(source: script) else {
                print("[CodexTaskLauncher] Failed to create paste script")
                return
            }

            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)

            if let error {
                print("[CodexTaskLauncher] Paste script error: \(error)")
            }
        }
    }
}
