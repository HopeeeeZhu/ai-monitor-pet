# 小安竺来咯 🏃

一个 macOS 桌面宠物，帮你盯着电脑上所有 AI 工具的干活状态。

同时开很多 AI agent 干活时，脑子根本记不住"哪个在跑、哪个卡住了、哪个跑完了"。小安竺替你记：AI 在跑任务时她跑步，需要授权时举手提醒你，任务跑完跳跃庆祝，没事时安静睡觉。

## 功能

- **状态监测**：实时跟踪每个 AI 工具的三种状态——空闲 / 在跑 / 等待授权，按项目和会话区分
- **气泡通知**：某个 AI 跑完任务或需要授权时，宠物头顶弹出气泡告诉你"是谁的哪个任务"，配合 macOS 系统通知
- **任务标签**：宠物头顶实时显示正在跑的「工具 · 项目 · 任务」
- **状态面板**：左键点击宠物展开三层钻取面板：AI 工具 → 项目 → 会话，可点击跳转到对应应用窗口
- **语音捕获箱**（v1.2.0 新增）：按 `Control + Option + V` 直接语音记录待办或临时想法，宠物脚下显示录音状态
- **待办提醒**（v1.2.0 新增）：语音待办可手动设置提醒时间，到点未完成会发送 macOS 桌面通知；捕获箱内可筛选待办/想法并勾选完成
- **额度显示**（v1.1.0 新增）：面板顶部显示 Claude 和 Codex 的订阅额度——5 小时窗口 + 周限额的已用百分比，悬停可看重置时间。Claude 凭证过期自动刷新，无需手动操作

## 支持的 AI 工具

| AI 工具 | 配置 | 能看到什么 |
|---------|------|-----------|
| Claude 桌面端（含 Cowork） | 零配置 | 状态 + 任务名 + 额度 |
| Codex 桌面端 | 零配置 | 状态 + 项目 + 任务名 + 额度 |
| Aone Copilot（IntelliJ 内） | 零配置 | 状态 + 项目 |
| Qoder | 配 hooks（见下） | 状态 + 项目 + 会话 |

**Qoder 配置**：在 `~/.qoder/settings.json` 里配 hooks，把事件写到 `~/.ai_monitor/events.jsonl`，每行一条 JSON：

```json
{"tool": "qoder", "event": "started", "session_id": "xxx", "cwd": "/path/to/project"}
```

`event` 取值：`started` / `waiting` / `completed`。

其他工具（Cursor、Windsurf、Gemini CLI 等）暂未适配——大部分工具只要有 hook 机制或本地日志，加一个适配器就能接入。

## 安装

1. 到 [Releases 页面](https://github.com/HopeeeeZhu/ai-monitor-pet/releases) 下载最新 dmg，双击打开，把 `小安竺来咯.app` 拖进 Applications。
2. 第一次打开：右键 App → 「打开」→ 再点「打开」。如果提示"已损坏"，终端里跑一句后重试：
   ```
   xattr -cr /Applications/小安竺来咯.app
   ```
3. 授予**辅助功能**权限（检测"需要授权"弹窗用）：系统设置 → 隐私与安全性 → 辅助功能 → 打开 小安竺来咯。
4. 使用语音捕获时会弹**麦克风**和**语音识别**权限；使用待办提醒时会弹**通知**权限。按需允许即可。
5. 首次启动会弹**钥匙串授权**（读取 Claude 额度用），输入密码点「始终允许」。不授权也能用，只是 Claude 额度不显示。

日常操作：左键拖动换位置，左键单击开关面板，右键调大小或退出。按 `Control + Option + V` 开始语音记录，再按一次停止；左键面板右上角的收纳盒图标进入捕获箱。

想把宠物换成自己小朋友的形象？见 [给朋友的安装与定制指引](给朋友的安装与定制指引.md)。

## 额度显示原理

- **Codex**：纯本地读取 `~/.codex/sessions` 会话日志里的 `rate_limits` 字段，每 60 秒刷新，不发任何网络请求
- **Claude**：调用官方 OAuth usage 接口（即 Claude Code `/usage` 命令的数据源），token 从钥匙串**只读**，每 3 分钟刷新一次数据。**监工绝不刷新或写回 token**——刷新会轮换 refresh token、挤掉 Claude CLI 的登录（详见「踩坑记录」）。token 过期就等 Claude Code 自己用时刷新，监工下一轮重读钥匙串即可拿到新 token；这期间额度数字保持上次的值

## 自行构建

需要 macOS 14+ 和 Xcode 命令行工具：

```bash
cd AIMonitorPet
swift build -c release
cp .build/release/AIMonitorPet "dist/AI监工.app/Contents/MacOS/AI监工"
codesign --force --deep --sign - "dist/AI监工.app"
open -n "dist/AI监工.app"   # 必须用 -n, 见下方「踩坑」
```

或直接跑一键脚本 `AIMonitorPet/rebuild.sh`（编译 → 替换 → 签名 → 重启）。

## 项目结构

```
AIMonitorPet/          Swift 主程序（日常使用版）
  Sources/AIMonitorPet/
    Pet/               宠物窗口 + SpriteKit 动画
    Monitor/           监测核心：各 AI 工具适配器 + 额度监测
    Panel/             三层钻取状态面板 (SwiftUI)
    Notification/      气泡 + 系统通知
    Capture/           语音捕获箱 + 待办提醒
    Jump/              点击跳转到应用窗口
  Assets/              宠物动画帧 (16 张 PNG，4 动作 × 4 帧)
  dist/                打包产物 (.app / .dmg)
pet-monitor/           早期 Python/pyobjc 原型（已弃用）
CLAUDE.md              产品定义与技术调研记录
```

## 踩坑记录

**0. 监工自动刷新 token 反复挤掉 Claude CLI 登录（2026-06-23 改只读修复）⚠️ 最坑**
监工和 Claude CLI 共用钥匙串里同一份 OAuth 凭证。OAuth 的 refresh token 是**一次性轮换**的——拿它换新 access token 时，服务器会作废旧的、发一个新的。旧版监工每轮会主动刷新临期 token 并写回钥匙串，于是和 CLI 互相踩踏：监工先刷新就作废了 CLI 手里的 refresh token → **CLI 登录失效**；CLI 先刷新则监工 401 → 面板「登录已失效」。表现为反复 `/login` 都治不好。
- 根治：监工改成**纯只读**——删掉所有刷新/写回逻辑（`refreshClaudeCredentials`/`writeBackToKeychain`），每轮只 `readClaudeCredentials()` 读当前 token。过期就等 Claude Code 自己刷，下一轮重读即可。代价：长时间完全不用 Claude 时额度数字不实时。
- 教训：**监控工具绝不能改动被监控对象的共享状态**（尤其是会轮换的凭证）。

**1. 额度请求失败时整行消失（2026-06-23 修复）**
`UsageMonitor` 调 Claude OAuth usage 接口，遇到非 200/401（最常见是 **429 限流**）走 `.failure` 分支。面板只在 `usage[.claudeDesktop]` 有值时才渲染 Claude 那一行，所以刚重启 + 失败时整行凭空消失，看起来像"登录没了"。
- 限流诱因：短时间内反复 `/login` + 重启 App，把 OAuth usage 的限流桶打满（接口实测 180s 轮询才安全，且必须带 `claude-code` UA，否则持续 429）。
- 修复：加 `claudePublishedOnce` 标记，`.failure` 且从未发布过时补一行占位"额度获取中…"，限流过去后下一轮自动恢复成真实额度。**终端登录状态与此无关，别被误导去反复重登。**

**2. 重新编译后界面没变 —— `open` 不启动新二进制（2026-06-23）**
macOS 上若已有同 bundle id 的 App 在跑，`open xxx.app` 只会把旧实例切到前台，不会启动新编译的二进制。机器上同时装了 dmg 版「小安竺来咯」时尤其容易中招。
- 解法：先 `pkill` / `quit` 掉所有旧实例，再用 `open -n` 强制起新实例：
  ```bash
  osascript -e 'quit app "小安竺来咯"' 2>/dev/null; pkill -f "小安竺\|AI监工\|AIMonitorPet"; sleep 2; open -n ~/Desktop/workspace/AI监工/AIMonitorPet/dist/AI监工.app
  ```

## 版本历史

- **v1.2.0**（2026-07-04）：新增语音捕获箱、全局快捷键录音、待办/想法分类、待办提醒和完成状态
- **v1.1.1**（2026-06-11）：点击面板外部自动关闭、面板标题每日一句（14 句轮换）、跑步动画帧序优化
- **v1.1.0**（2026-06-11）：面板额度显示（Claude/Codex）、Claude 凭证自动刷新、面板瘦身 + 关闭按钮
- **v1.0.0**（2026-06-09）：首个版本——宠物动画、状态监测、通知、三层面板、跳转
