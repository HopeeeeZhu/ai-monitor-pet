# AI 监工 — 桌面宠物 (轻量版)

监测 **Claude.app** 和 **Codex.app**，在桌面放一个会动的宠物：

| AI 状态 | 宠物 |
|--------|------|
| 都没在干活 | 睡觉 💤 |
| 有 app 在跑任务 | 跑动 🏃 |
| 有 app 需要授权 | 头顶弹气泡 ⚠️ + 系统通知 |

## 安装

```bash
cd pet-monitor
chmod +x setup.sh run.sh
./setup.sh
```

把一张头像图片命名为 `pet.png` 放进 `pet-monitor/` 目录（正方形效果最好，会自动裁成圆形）。没有图片也能跑，会显示一个占位圆。

## 运行

```bash
./run.sh            # 正常启动
./run.sh --debug    # 打印每次检测的细节，用来调参
```

- 拖动宠物可移动，位置会被记住。
- 右键宠物 → 退出。

## 首次运行：授权辅助功能

"需要授权"检测靠 **Accessibility（辅助功能）** 读取 app 窗口里的按钮。第一次运行后：

系统设置 → 隐私与安全性 → 辅助功能 → 把运行脚本的 **终端**（Terminal / iTerm）打开开关。然后重启脚本。

没有这个权限，宠物的"睡觉/跑动"仍然正常，只是"需要授权"气泡不会触发。

## 这是启发式检测（重要）

Claude.app 和 Codex.app 是 Electron 类应用，**不像 CLI 那样有原生事件 hook**，所以检测是尽力而为的：

- **"在跑"** = 进程 CPU 占用超过阈值（默认 30%）。不同机器空闲基线不同。
  用 `./run.sh --debug` 看每个 app 的实时 `cpu=` 值：空闲时记下数字，跑任务时记下数字，
  把 `monitor.py` 顶部 `APPS` 里的 `cpu_threshold` 设成两者之间。

- **"需要授权"** = 用 Accessibility 在 app 窗口里找标题含「允许/同意/拒绝/Allow/Approve/Deny…」的按钮。
  如果你的 app 把授权弹窗画在网页内部，Accessibility 可能读不到 —— `--debug` 里 `btns=[]` 一直为空就是这种情况。
  那时把真实弹窗的按钮文字加进 `monitor.py` 的 `APPROVAL_BTN_KEYWORDS`，或告诉我 `--debug` 的输出，我来换检测方式。

## 调参速查（都在 monitor.py 顶部）

| 变量 | 作用 |
|------|------|
| `APPS[*].match` | 进程命令行匹配串（确认 app 真实进程名，可用 `--debug` 的 `pid=` 验证） |
| `APPS[*].cpu_threshold` | "在跑"的 CPU 阈值 |
| `APPROVAL_BTN_KEYWORDS` | "需要授权"按钮关键词 |
| `POLL_INTERVAL` | 检测间隔(秒) |
