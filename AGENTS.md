# AI 监工 — 桌面宠物式 AI 进程状态监测器

## 项目目标

在 macOS 桌面上放一个宠物，实时监测所有与 AI 相关的进程，按项目维度展示状态并给出推送提醒。

### 需要监测的目标（7 个）

Codex cli、Aone Copilot (IntelliJ IDE 内)、Qoder (IDE/CLI)、QoderWork、悟空 Wukong、Codex 桌面端、Codex 桌面端。

### 3 个状态（持续态，需持续知道当前是哪个）

- **空闲 idle** — AI 没在干活
- **在跑 running** — AI 正在执行任务
- **等待授权 waiting-approval** — AI 卡住，需要用户授权/确认

### 3 个 Push（瞬时事件，需要在那一刻推送通知）

- **开始跑** — 用户提交 prompt / AI 开始执行
- **需要授权** — AI 需要权限确认
- **跑完任务** — AI 完成当前任务

### 项目维度

开多个 IDE/CLI 窗口时，需要按项目（cwd）区分各自状态，而非笼统的 App 级。

---

## 产品定义（office-hours 2026-06-06 定稿）

### 核心痛点

同时开很多 AI agent 干活，脑子维护不了"哪个在跑、哪个没跑"的列表。
现状：手动切窗口挖一遍，用眼睛扫每个终端/IDE 的状态。

### 产品形态：桌面动画宠物 + 通知 + 三层钻取面板 + 跳转

- **平时**：宠物安静待着。所有 AI 空闲或正在跑时不打扰。
- **有事**：某个 session 完成 / 需要授权时，宠物弹出通知气泡，告诉用户"是哪个 AI 的哪个对话完成了/需要授权"。
- **点击宠物**：展开状态面板，三层钻取：
  ```
  AI 工具（Codex CLI / Qoder / ...）
    └─ 项目（按 cwd 分组）
         └─ 对话 session
              └─ 任务状态 (idle / running / waiting-approval / done)
  ```
- **点击跳转**：在面板中点击任意 session / 任务 / AI 工具名，跳转到对应的应用程序窗口。

### 宠物行为设计

| 全局状态 | 宠物表现 |
|---------|---------|
| 所有 AI 空闲 | 宠物睡觉/发呆 |
| 有 AI 在跑 | 宠物跑步/忙碌 |
| 有 AI 等待授权 | 宠物举手/叫唤 + 通知气泡 |
| 有 AI 跑完任务 | 宠物点头/庆祝 + 通知气泡 |

通知气泡内容示例："Qoder · 项目A · session3 跑完了" / "Aone Copilot · 项目B 需要授权"

### Office-hours 决策记录

| 问题 | 决策 |
|------|------|
| D1 目标 | 个人工具 / Side project |
| D2 核心痛点 | 开太多 agent，脑子维护不了状态列表 |
| D3 现状 | 手动切窗口用眼睛扫 |
| D4 形态 | 桌面动画宠物（非菜单栏） |
| D5 多 agent 展示 | 宠物做注意力筛选器（有事才提醒）+ 点击展开面板看全局 |
| D6 MVP 范围 | 完整版（宠物+通知+三层钻取+跳转），先接 Aone Copilot + Qoder |

### 技术栈（推荐）

- **App 框架**：Swift + SwiftUI（面板）+ SpriteKit（宠物动画）
- **窗口类型**：NSPanel（always-on-top 浮窗）+ NSStatusBarButton（可选菜单栏入口）
- **监测核心**：事件 hook 优先 + 弹窗轮询兜底
- **跳转**：`NSWorkspace.shared.open()` / AppleScript `activate` 目标 App

---

## 技术调研结论（2026-06-05 实测）

### 架构：双引擎（事件优先 + 轮询兜底）

```
┌────────────────────────────────────────────────────────┐
│                   监工核心 (状态机)                        │
│         维护每个目标的: idle / running / waiting          │
│         主键: cwd (项目路径) + session_id                │
└───────────────▲───────────────────────▲────────────────┘
                │                         │
    ┌───────────┴──────────┐   ┌──────────┴───────────────┐
    │  引擎A: 事件钩子(推送)  │   │  引擎B: 轮询探测(兜底)      │
    │  准、省、首选          │   │  hook覆盖不到时启用        │
    ├──────────────────────┤   ├──────────────────────────┤
    │ Codex CLI: hooks     │   │ Aone Copilot(IntelliJ):  │
    │ Qoder: hooks+audit    │   │   弹窗检测(AXDialog)     │
    │ Codex: notify         │   │ GUI桌面端: Accessibility  │
    │ (复用DockCat式目录投递) │   │ 悟空: ps+日志           │
    └──────────────────────┘   │ 崩溃/卡死检测: ps扫描     │
                                └──────────────────────────┘
```

状态由事件驱动翻转（确定性，非模糊推断）：
```
            UserPromptSubmit              Notification(permission_prompt)
   ┌─────────────┐ ──────────────▶ ┌──────────┐ ──────────────▶ ┌──────────────┐
   │  空闲 idle   │                  │ 在跑 run │                  │ 等待授权 wait │
   └─────────────┘ ◀────────────── └──────────┘ ◀────────────── └──────────────┘
                       Stop                          用户授权后继续
```

### 各目标 × 状态/事件 可行性矩阵

#### 🟢 Codex CLI — 最好接，原生 hook 全覆盖

| 状态/事件 | hook 事件 | 备注 |
|-----------|----------|------|
| 开始跑 | `UserPromptSubmit` | ✅ |
| 需要授权 | `Notification(permission_prompt)` / `PermissionRequest` | ✅ |
| 跑完任务 | `Stop` | ✅ |
| 区分项目 | hook payload 自带 `cwd` + `session_id` | ✅ |

配置位置: `~/.Codex/settings.json` → hooks 段

#### 🟢 Qoder (IDE/CLI) — 最好接，8 类事件 + audit.jsonl

| 状态/事件 | hook 事件 | 备注 |
|-----------|----------|------|
| 开始跑 | `UserPromptSubmit` / `SessionStart` | ✅ |
| 需要授权 | `Notification` | ✅ |
| 跑完任务 | `Stop` / `SessionEnd` | ✅ |
| 区分项目 | `QODER_PROJECT_DIR` 环境变量 / `cwd` + `session_id` | ✅ |

配置位置: `~/.qoder/settings.json` → hooks 段
额外信号源: `~/.qoder/audit/audit.jsonl` — 每行带 cwd+session_id+event，FSEvents 监听即可

#### 🟡→🟢 Codex — notify 机制 + hooks

| 状态/事件 | 手段 | 备注 |
|-----------|------|------|
| 跑完任务 | `notify`(turn-ended) | ✅ 本机已配 |
| 区分项目 | session 文件 | ✅ |

配置位置: `~/.codex/config.toml` → notify / hooks

#### 🟡 Aone Copilot (IntelliJ 内) — hook 有限，弹窗检测补位

| 状态/事件 | 手段 | 备注 |
|-----------|------|------|
| 在跑 | 监听 `~/.r2c/logs/aone-copilot/history/*.jsonl`（有新条目=在跑） | ✅ |
| 跑完 | jsonl 静默 + `afterShellExecution` 最后一条后无新条目 | ⚠️ 可推断 |
| 等待授权 | **IntelliJ 弹窗检测：窗口名匹配"命令安全确认"**（实测验证✅，窗口数+1且标题精确匹配） | ✅ 需辅助功能权限 |
| 区分项目 | jsonl 带 `cwd` + `session_id`；窗口标题含项目名 | ✅ |

限制: hook 只有 `afterShellExecution`，无 `UserPromptSubmit`/`Notification`/`Stop`
本地 IDE 服务(`127.0.0.1:<port>`): 只接收编辑回调(before/after-edit)，无状态查询接口

#### 🟠 Codex / Codex 桌面端 (GUI) — 需 Accessibility

| 状态/事件 | 手段 | 备注 |
|-----------|------|------|
| 是否在运行 | `ps` / `System Events` 进程列表 | ✅ |
| 等待授权 | Accessibility 读弹窗/UI 状态 | ⚠️ 需权限+开窗口 |
| 区分项目 | 多窗口可靠；单窗口多标签退化到 App 级 | ⚠️ |

#### 🟢 悟空 Wukong — 前端日志监听（2026-06-05 实测验证✅）

| 状态/事件 | 日志信号 | 备注 |
|-----------|---------|------|
| 是否在运行 | `ps` 扫 `Wukong.app`/`DingTalkReal` 进程 | ✅ |
| 开始跑 | 前端日志出现 `type:FIRST_TOKEN` | ✅ |
| 在跑 | `FIRST_TOKEN` 之后、`USAGE` 之前的区间 | ✅ |
| **等待授权** | **前端日志出现 `acp_event_type: request_permission`**（实测验证✅） | ✅ 精确匹配 |
| 跑完 | 前端日志出现 `type:USAGE`（token 统计 = 一轮结束） | ✅ |
| 区分项目 | r2c snapshots 有 `automation-session` 会话 ID | ⚠️ 有会话，cwd 待确认 |

技术细节：
- 进程名是 `DingTalkReal`（不是 Wukong），路径 `/Applications/Wukong.app/Contents/MacOS/DingTalkReal`
- 前端日志路径：`~/Library/Application Support/dingtalk-rewind-server/logs/frontend/frontend.<日期>.log`
- 监听方式：FSEvents tail 日志文件，grep 匹配关键词，不需要辅助功能/屏幕录制权限
- r2c snapshots 在 `~/.r2c/logs/wukong/` 下，记录 file-write-call 操作

### 窗口级 + 对话级区分能力

| 目标 | 区分窗口 | 区分对话(session) | 方式 |
|------|---------|------------------|------|
| Codex CLI | ✅ 独立进程 | ✅ `session_id` | hook payload |
| Qoder | ✅ `cwd` | ✅ `session_id` | hook + audit.jsonl |
| Codex | ✅ session | ✅ turn 级 | notify |
| Aone Copilot | ✅ 窗口标题/cwd | ✅ jsonl有session_id ⚠️弹窗只到窗口级 | jsonl + 弹窗 |
| 悟空 | ⚠️ 通常只一个窗口 | ⚠️ r2c有session，但事件日志无对话ID | 日志 + r2c |
| 桌面端GUI | ⚠️ 多窗口可 | ❌ 单窗口多标签看不进去 | Accessibility |

设计建议：展示粒度按"项目"来最安全——所有工具都能靠 cwd/窗口标题区分到项目级。
对话级在 CLI/IDE 场景是 bonus，在 GUI 场景不强求。

### "授权完成"信号（回到 running 的翻转点）

hook 事件列表里没有专门的"授权完成"事件。检测方式：
- **CLI端(Codex/Qoder/Codex)**: 收到 `PreToolUse`/`PostToolUse`（紧跟在 permission_prompt 之后）= 用户授权完，回到 running
- **IntelliJ(Aone Copilot)**: 弹窗"命令安全确认"消失 = 授权完成
- **悟空**: 前端日志在 `request_permission` 之后出现新的 `FIRST_TOKEN` = 授权完继续跑

完整状态机：
```
     UserPromptSubmit          Notification(permission_prompt)
 ┌───────┐ ──────────▶ ┌──────────┐ ──────────────▶ ┌──────────────┐
 │ idle  │              │ running  │                  │   waiting    │
 └───────┘ ◀────────── └──────────┘ ◀────────────── └──────────────┘
               Stop              PreToolUse / 弹窗消失
                                 (= 授权完成，回到 running)
```

### 关键技术事实（本机实测验证）

1. **macOS `ps` STAT 列**: 能分 R(运行)/S(睡眠)，但无有效 wchan，无法靠 ps 区分"等输入"vs"等网络"
2. **macOS System Events (Accessibility)**: 路通，能读前台应用列表和窗口——但需辅助功能权限授权
3. **IntelliJ 弹窗检测（2026-06-05 实测验证✅）**: Aone Copilot 等待授权时弹出独立窗口，标题为**"命令安全确认"**。检测方式：读 idea 进程窗口名列表，匹配含"确认"的窗口。弹窗是 AXStandardWindow（subrole），正常IDE窗口是 AXDialog——可双重区分。单次 <10ms，2s 轮询无感。
4. **DockCat 参考**: 纯推送架构(目录监听 `~/Library/Application Support/DockCat/AgentNotifications/`)，只覆盖"完成态"，不覆盖"等待授权/在跑"

## 工程架构（plan-eng-review 2026-06-06 定稿）

### 模块分解（5 个模块）

```
┌─────────────────────────────────────────────────────────────┐
│                      AI 监工 App (Swift)                       │
├─────────┬───────────┬───────────┬───────────┬───────────────┤
│ M1      │ M2        │ M3        │ M4        │ M5             │
│ 宠物引擎  │ 通知系统    │ 状态面板    │ 监测核心    │ 跳转系统       │
│ SpriteKit│ 气泡+系统  │ SwiftUI   │ 双引擎     │ NSWorkspace   │
│ +NSPanel │ 通知      │ Popover   │ hook+poll  │ +AppleScript  │
└─────────┴───────────┴───────────┴───────────┴───────────────┘
```

### 数据模型

```swift
struct MonitorState {
    var tools: [ToolState]
}
struct ToolState {
    let toolType: ToolType          // .qoder, .aoneCopilot
    let displayName: String
    var projects: [ProjectState]    // 按 cwd 分组
}
struct ProjectState {
    let cwd: String                 // 主键
    let projectName: String         // cwd 最后一段目录名
    var sessions: [SessionState]
}
struct SessionState {
    let sessionId: String
    var displayName: String         // 第一条消息前几个字 或 自动编号
    var status: AgentStatus
    var lastEvent: String
    var lastUpdated: Date
}
enum AgentStatus { case idle, running, waitingApproval }
enum ToolType: String, CaseIterable { case qoder, aoneCopilot }
```

### 数据流

```
Qoder audit.jsonl ──(FSEvents)──▶ M4a Qoder适配器 ──▶ M4 状态机 ──▶ M2 通知
AoneCopilot jsonl ──(FSEvents)──▶ M4a AoneCopilot适配器 ─┘    │      ├▶ M1 宠物动画
M4b 弹窗检测(2s轮询) ──────────────────────────────────────────┘      └▶ M3 面板
M3 面板 ──(点击)──▶ M5 跳转
```

### M4a 适配器详情

**Qoder**: tail `~/.qoder/audit/audit.jsonl`(DispatchSource), 解析 event/cwd/session_id
- UserPromptSubmit → running, Notification → waitingApproval, Stop → idle

**Aone Copilot**: 
- 在跑: tail `~/.r2c/logs/aone-copilot/history/*.jsonl`(新条目=running)
- 等待授权: 2s轮询 idea 进程窗口列表, 匹配"命令安全确认"
- 授权完成: 弹窗消失 → running

### M4b 轮询引擎

- 弹窗检测: 每2s AppleScript读idea窗口名, 匹配"命令安全确认"
- 进程存活: 每5s pgrep检查, 崩溃→所有session标idle
- 分级策略: 目标进程不在跑时关闭该目标的轮询

### M1 宠物引擎

- NSPanel(floating, borderless, transparent) + SpriteKit scene
- **宠物素材：用用户女儿的照片生成像素风/卡通风 sprite sheet**
- 4个状态动画: 睡觉(idle) / 跑步(running) / 举手(waitingApproval) / 庆祝(done)
- 状态优先级: waitingApproval > running > idle
- 可拖拽, 位置记忆(UserDefaults)
- 左键点击 → toggle状态面板

### M2 通知系统

- 触发: status翻转到waitingApproval或从running翻到idle
- 内容: "{工具名} · {项目名} · {session名} {事件}"
- 宠物气泡(SKLabelNode) + macOS系统通知(UNUserNotificationCenter)兜底
- 防骚扰: 相同session相同状态5秒内不重复

### M3 状态面板

- NSPopover + SwiftUI, 三层钻取:
  L1 ToolListView → L2 ProjectListView → L3 SessionListView
- 状态图标: 💤idle / 🔄running / ⚠️waitingApproval
- @ObservedObject绑定MonitorState实时刷新
- 每层可点击跳转(→M5)

### M5 跳转系统

- Qoder: AppleScript activate + 窗口标题匹配项目名
- IntelliJ: AppleScript activate + 窗口标题匹配
- 限制: 跳转只能到窗口级, 无法精确到session/对话

### 工程决策记录

| 问题 | 决策 |
|------|------|
| E1 宠物素材 | 路线B：用女儿照片生成Q版卡通风立绘，再拆成4个动作的帧动画sprite sheet（睡觉/跑步/举手/庆祝） |
| E2 session显示名 | 先调研能拿到什么; fallback: 取第一条消息前几个字 |
| E3 启动初始化 | 方案C：三管齐下快照（pgrep检查进程存活 + AppleScript弹窗检测 + 扫最近日志推断session状态） |

### 落地步骤（office-hours 2026-06-06 定稿）

#### Phase 1（MVP，先接 Aone Copilot + Qoder）
1. macOS 桌面宠物 App（Swift + SpriteKit）：宠物动画 + 通知气泡
2. 状态监测核心：双引擎（hook事件 + 弹窗轮询兜底）
3. 三层钻取状态面板：AI工具 → 项目 → 对话session → 任务状态
4. 点击跳转：面板中点击 session/任务/AI 跳转到对应应用窗口
5. 先接 Aone Copilot(IntelliJ) + Qoder(IDE/CLI)

#### Phase 2（扩展更多工具）
6. 接入 Codex CLI、Codex
7. 接入悟空（前端日志监听）
8. 接入 Codex/Codex 桌面端 GUI（Accessibility）

---

## gstack

Use /browse from gstack for all web browsing. Never use mcp__claude-in-chrome__* tools.
Available skills: /office-hours, /plan-ceo-review, /plan-eng-review, /plan-design-review,
/design-consultation, /design-shotgun, /design-html, /review, /ship, /land-and-deploy,
/canary, /benchmark, /browse, /open-gstack-browser, /qa, /qa-only, /design-review,
/setup-browser-cookies, /setup-deploy, /setup-gbrain, /sync-gbrain, /retro, /investigate,
/document-release, /document-generate, /codex, /cso, /autoplan, /pair-agent, /careful, /freeze,
/guard, /unfreeze, /gstack-upgrade, /learn.

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec

## Imported Claude Cowork project instructions
