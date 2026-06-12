# DockCat Agent 通知集成指南

让你的 AI Agent 完成任务后，在小猫头上弹出气泡通知。

## 原理

DockCat 监听目录 `~/Library/Application Support/DockCat/AgentNotifications/`。任何程序只要往这个目录写入一个 JSON 文件，DockCat 就会读取、显示气泡、然后删除该文件。

JSON 格式：
```json
{
  "source": "claude",
  "message": "代码审查完成，发现3个建议",
  "timestamp": "2026-05-29T14:30:00Z"
}
```

## 通用方式：Shell 脚本

把 `notify-dockcat.sh` 复制到 `/usr/local/bin/` 或任意 PATH 目录：

```bash
cp Scripts/notify-dockcat.sh /usr/local/bin/notify-dockcat
chmod +x /usr/local/bin/notify-dockcat
```

使用：
```bash
notify-dockcat claude "代码审查完成"
notify-dockcat cursor "构建成功，0个错误"
notify-dockcat wukong "任务 #42 已完成"
notify-dockcat qoderwork "PR 已合并到 main"
```

---

## 各 Agent 配置

### 1. Claude Desktop (Hooks)

在 Claude Desktop 的 hooks 配置文件 `~/.claude/settings.json` 中添加：

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "notify-dockcat claude \"Claude 完成了一个操作\""
          }
        ]
      }
    ]
  }
}
```

如果你只想在特定工具完成时通知（比如 bash 执行完毕），可以修改 `matcher`：

```json
{
  "matcher": "bash|write_file",
  "hooks": [
    {
      "type": "command",
      "command": "notify-dockcat claude \"Claude 完成了代码操作\""
    }
  ]
}
```

也可以在 Claude 的对话结束后触发（使用 `Stop` hook）：

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "notify-dockcat claude \"Claude 任务完成啦\""
          }
        ]
      }
    ]
  }
}
```

### 2. Cursor

**方式 A：Task 配置**

在项目的 `.vscode/tasks.json` 中添加一个后置任务：

```json
{
  "version": "2.0.0",
  "tasks": [
    {
      "label": "notify-dockcat-cursor",
      "type": "shell",
      "command": "notify-dockcat cursor \"Cursor 任务完成\"",
      "presentation": { "reveal": "silent" }
    }
  ]
}
```

**方式 B：Cursor Rules**

在项目根目录的 `.cursorrules` 文件末尾加入：

```
When you finish a task, run this command to notify the user:
notify-dockcat cursor "任务完成: <brief description>"
```

### 3. 悟空

如果悟空支持任务完成回调或 shell hook，直接配置：

```bash
notify-dockcat wukong "悟空完成了任务"
```

如果不支持内置 hook，可以用包装脚本：

```bash
#!/bin/bash
# run-wukong-task.sh
wukong run "$@"
EXIT_CODE=$?
if [ $EXIT_CODE -eq 0 ]; then
    notify-dockcat wukong "任务成功完成"
else
    notify-dockcat wukong "任务执行失败 (exit $EXIT_CODE)"
fi
exit $EXIT_CODE
```

### 4. Qoderwork

与悟空类似，如果支持 hook 则直接配置，否则使用包装脚本：

```bash
#!/bin/bash
# run-qoderwork-task.sh
qoderwork "$@"
EXIT_CODE=$?
notify-dockcat qoderwork "Qoderwork 任务完成 (exit $EXIT_CODE)"
exit $EXIT_CODE
```

---

## 高级用法

### 在 Python 中发送通知

```python
import json, os, time

def notify_dockcat(source: str, message: str):
    notify_dir = os.path.expanduser(
        "~/Library/Application Support/DockCat/AgentNotifications"
    )
    os.makedirs(notify_dir, exist_ok=True)
    filename = f"{int(time.time())}-{source}.json"
    with open(os.path.join(notify_dir, filename), "w") as f:
        json.dump({"source": source, "message": message}, f)

# 使用
notify_dockcat("claude", "分析报告已生成")
```

### 在 Node.js 中发送通知

```javascript
const fs = require('fs');
const path = require('path');
const os = require('os');

function notifyDockCat(source, message) {
  const dir = path.join(
    os.homedir(),
    'Library/Application Support/DockCat/AgentNotifications'
  );
  fs.mkdirSync(dir, { recursive: true });
  const filename = `${Date.now()}-${source}.json`;
  fs.writeFileSync(
    path.join(dir, filename),
    JSON.stringify({ source, message, timestamp: new Date().toISOString() })
  );
}

// 使用
notifyDockCat('cursor', 'Build succeeded');
```

### 测试

安装脚本后，可以直接在终端测试：

```bash
notify-dockcat test "这是一条测试通知"
```

如果 DockCat 正在运行，你应该会看到小猫头上弹出气泡。
