# DockCat Agent 通知版 - 安装说明

## 1. 安装 DockCat
将 `DockCat.app` 拖到"应用程序"文件夹，双击运行。

## 2. 安装通知脚本
打开终端，运行：
```bash
sudo cp notify-dockcat.sh /usr/local/bin/notify-dockcat
sudo chmod 755 /usr/local/bin/notify-dockcat
```

## 3. 配置你的 Agent

### Claude（CLI 模式）
右键小猫 → Agent 通知 → 一键配置 Claude Hook，然后重启 Claude Desktop。

### Cursor / 悟空 / Qoderwork
右键小猫 → Agent 通知 → 复制配置指令 → 选择对应的 agent，粘贴到该 agent 的全局 Rules 设置中。

### 手动发通知（任何 agent 或脚本）
```bash
notify-dockcat <agent名> "通知内容"
```
例如：
```bash
notify-dockcat cursor "代码重构完成"
notify-dockcat wukong "文档已生成"
```

## 通知原理
Agent 完成任务后，往 `~/Library/Application Support/DockCat/AgentNotifications/` 写入 JSON 文件，小猫会自动读取并弹出气泡。
