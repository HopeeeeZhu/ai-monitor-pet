#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""AX 探测: 把某个 app 的窗口树(角色/标题/值)整棵打印出来。
用法:
  ./.venv/bin/python axdump.py            # 默认探测 Codex.app
  ./.venv/bin/python axdump.py Claude.app # 探测别的 app
在 app 正常状态、以及它弹出授权/确认框时各跑一次, 对比输出发给 Claude。
"""
import sys
import subprocess
from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementCopyAttributeValue,
    AXIsProcessTrusted,
)

MATCH = sys.argv[1] if len(sys.argv) > 1 else "Codex.app"


def attr(el, a):
    err, val = AXUIElementCopyAttributeValue(el, a, None)
    return val if err == 0 else None


def main_pid(match):
    out = subprocess.run(["ps", "-axo", "pid=,command="], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) < 2:
            continue
        pid, cmd = parts
        if match in cmd and "/Contents/MacOS/" in cmd and "Helper" not in cmd:
            return int(pid)
    return None


def main():
    if not AXIsProcessTrusted():
        print("[!] 没有辅助功能权限, AX 读不到任何东西。先去 系统设置>隐私与安全性>辅助功能 给终端打勾。")
        return
    pid = main_pid(MATCH)
    if not pid:
        print(f"[!] 没找到匹配 '{MATCH}' 的主进程, 确认 app 开着, 或换个匹配串。")
        return
    print(f"探测 {MATCH} (pid={pid})\n")
    app = AXUIElementCreateApplication(pid)
    count = [0]

    def walk(el, depth):
        if depth > 12 or count[0] > 800:
            return
        count[0] += 1
        role = attr(el, "AXRole") or "?"
        sub = attr(el, "AXSubrole") or ""
        title = attr(el, "AXTitle") or ""
        val = attr(el, "AXValue")
        val = (str(val)[:40] if val is not None else "")
        desc = attr(el, "AXDescription") or ""
        bits = [role + (f"/{sub}" if sub else "")]
        if title:
            bits.append(f"title={title!r}")
        if desc:
            bits.append(f"desc={desc!r}")
        if val:
            bits.append(f"val={val!r}")
        print("  " * depth + " ".join(bits))
        for child in (attr(el, "AXChildren") or []):
            walk(child, depth + 1)

    wins = attr(app, "AXWindows") or []
    print(f"窗口数 = {len(wins)}\n")
    for w in wins:
        walk(w, 0)
    print(f"\n共遍历 {count[0]} 个节点。")


if __name__ == "__main__":
    main()
